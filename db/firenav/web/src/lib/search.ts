import { isInKorea, type LatLng } from './geo';

/**
 * 카카오 쿼터를 아끼는 검색 서비스.
 * 원칙 (검증 보고서 3-1): 유료 OFF 유지, 반복 호출 방지, 결과 캐싱, 호출 최소화,
 * 쿼터 초과 시 검색만 멈추고 지도·위치 기능은 계속 동작.
 *
 * 카카오 JS SDK 검색은 콜백으로 OK / ZERO_RESULT / ERROR 상태만 알려 준다.
 * HTTP 429(쿼터 초과)를 다른 오류와 구분할 수 없으므로 [판단],
 * ERROR가 연속되면 쿼터 초과 가능성을 포함해 검색을 일시 중지한다.
 */

export type SearchMode = 'address' | 'keyword';

export interface Place {
  id: string;
  name: string;
  address: string;
  position: LatLng;
}

/** 실제 검색을 수행하는 쪽 (운영: 카카오 SDK, 테스트: 대역) */
export type BackendStatus = 'OK' | 'ZERO_RESULT' | 'ERROR';
export interface Backend {
  search(mode: SearchMode, query: string, near: LatLng | null): Promise<{ status: BackendStatus; places: Place[] }>;
}

export type SearchOutcome =
  | { kind: 'results'; places: Place[]; fromCache: boolean; droppedOutsideKorea: number }
  | { kind: 'empty' }
  | { kind: 'invalid'; message: string }
  | { kind: 'throttled'; retryInMs: number }
  | { kind: 'paused'; resumeAt: number }
  | { kind: 'error'; message: string };

export interface SearchOptions {
  minIntervalMs?: number;      // 연속 호출 최소 간격
  cacheTtlMs?: number;         // 캐시 보관 시간 (짧게: 약관상 저장 허용 범위 미확인)
  cacheMax?: number;
  errorsBeforePause?: number;  // 연속 ERROR 몇 번이면 일시 중지
  pauseMs?: number;            // 일시 중지 시간
  now?: () => number;
  onApiCall?: () => void;      // 실제 API 호출 시 (호출 횟수 집계용)
}

export const QUERY_MIN = 2;
export const QUERY_MAX = 60;

export function normalizeQuery(q: string): string {
  return q.replace(/\s+/g, ' ').trim();
}

export function validateQuery(q: string): string | null {
  const n = normalizeQuery(q);
  if (n.length < QUERY_MIN) return `검색어를 ${QUERY_MIN}글자 이상 입력하세요.`;
  if (n.length > QUERY_MAX) return `검색어는 ${QUERY_MAX}글자 이하로 입력하세요.`;
  return null;
}

/** 키워드 검색은 지도 중심에 따라 결과가 달라지므로 약 1km 격자로 캐시 키를 나눈다 */
function cacheKey(mode: SearchMode, query: string, near: LatLng | null): string {
  const q = normalizeQuery(query).toLowerCase();
  if (mode === 'address' || !near) return `${mode}|${q}`;
  return `${mode}|${q}|${near.lat.toFixed(2)},${near.lng.toFixed(2)}`;
}

export class SearchService {
  private readonly backend: Backend;
  private readonly o: Required<Omit<SearchOptions, 'onApiCall'>> & Pick<SearchOptions, 'onApiCall'>;
  private cache = new Map<string, { at: number; places: Place[]; dropped: number }>();
  private inFlight = new Map<string, Promise<SearchOutcome>>();
  private lastCallAt = -Infinity;
  private consecutiveErrors = 0;
  private pausedUntil = 0;

  constructor(backend: Backend, opts: SearchOptions = {}) {
    this.backend = backend;
    this.o = {
      minIntervalMs: opts.minIntervalMs ?? 1500,
      cacheTtlMs: opts.cacheTtlMs ?? 10 * 60 * 1000,
      cacheMax: opts.cacheMax ?? 50,
      errorsBeforePause: opts.errorsBeforePause ?? 2,
      pauseMs: opts.pauseMs ?? 10 * 60 * 1000,
      now: opts.now ?? (() => Date.now()),
      onApiCall: opts.onApiCall,
    };
  }

  /** 검색이 일시 중지 상태면 재개 시각, 아니면 null */
  pausedUntilTime(): number | null {
    return this.o.now() < this.pausedUntil ? this.pausedUntil : null;
  }

  async search(mode: SearchMode, rawQuery: string, near: LatLng | null): Promise<SearchOutcome> {
    const invalid = validateQuery(rawQuery);
    if (invalid) return { kind: 'invalid', message: invalid };
    const query = normalizeQuery(rawQuery);
    const key = cacheKey(mode, query, near);
    const now = this.o.now();

    // 1) 캐시: API를 부르지 않음
    const hit = this.cache.get(key);
    if (hit && now - hit.at < this.o.cacheTtlMs) {
      return hit.places.length
        ? { kind: 'results', places: hit.places, fromCache: true, droppedOutsideKorea: hit.dropped }
        : { kind: 'empty' };
    }

    // 2) 같은 검색이 진행 중이면 그 결과를 공유 (중복 호출 방지)
    const pending = this.inFlight.get(key);
    if (pending) return pending;

    // 3) 일시 중지 중
    if (now < this.pausedUntil) return { kind: 'paused', resumeAt: this.pausedUntil };

    // 4) 연속 호출 제한
    const wait = this.lastCallAt + this.o.minIntervalMs - now;
    if (wait > 0) return { kind: 'throttled', retryInMs: wait };

    this.lastCallAt = now;
    const p = this.callBackend(mode, query, near, key).finally(() => this.inFlight.delete(key));
    this.inFlight.set(key, p);
    return p;
  }

  private async callBackend(mode: SearchMode, query: string, near: LatLng | null, key: string): Promise<SearchOutcome> {
    this.o.onApiCall?.();
    let res: { status: BackendStatus; places: Place[] };
    try {
      res = await this.backend.search(mode, query, near);
    } catch {
      res = { status: 'ERROR', places: [] };
    }

    if (res.status === 'ERROR') {
      this.consecutiveErrors += 1;
      if (this.consecutiveErrors >= this.o.errorsBeforePause) {
        this.pausedUntil = this.o.now() + this.o.pauseMs;
        this.consecutiveErrors = 0;
        return { kind: 'paused', resumeAt: this.pausedUntil };
      }
      return { kind: 'error', message: '검색 서버가 응답하지 않았습니다. 잠시 후 다시 시도하세요.' };
    }
    this.consecutiveErrors = 0;

    // 대한민국 범위 밖 좌표는 버림 (DB 규칙과 동일)
    const valid = res.places.filter((p) => isInKorea(p.position));
    const dropped = res.places.length - valid.length;
    this.remember(key, valid, dropped);
    if (res.status === 'ZERO_RESULT' || valid.length === 0) return { kind: 'empty' };
    return { kind: 'results', places: valid, fromCache: false, droppedOutsideKorea: dropped };
  }

  private remember(key: string, places: Place[], dropped: number) {
    if (this.cache.size >= this.o.cacheMax) {
      const oldest = this.cache.keys().next().value;
      if (oldest !== undefined) this.cache.delete(oldest);
    }
    this.cache.set(key, { at: this.o.now(), places, dropped });
  }
}
