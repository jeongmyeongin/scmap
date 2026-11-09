import { describe, expect, it, vi } from 'vitest';
import { SearchService, validateQuery, type Backend, type Place } from '@/lib/search';

const SUNCHEON: Place = { id: '1', name: '순천시청', address: '전남 순천시 장명로 30', position: { lat: 34.9506, lng: 127.4872 } };
const SWAPPED: Place = { id: '2', name: '좌표 오류', address: 'x', position: { lat: 127.4872, lng: 34.9506 } };

function fakeBackend(responses: Array<{ status: 'OK' | 'ZERO_RESULT' | 'ERROR'; places?: Place[] }>) {
  const calls: string[] = [];
  const backend: Backend = {
    search: vi.fn(async (_mode, q) => {
      calls.push(q);
      const r = responses.shift() ?? { status: 'OK', places: [SUNCHEON] };
      return { status: r.status, places: r.places ?? [] };
    }),
  };
  return { backend, calls };
}

function clock(start = 1_000_000) {
  let t = start;
  return { now: () => t, advance: (ms: number) => { t += ms; } };
}

describe('검색어 검증', () => {
  it('S01 1글자·빈칸은 호출하지 않음', async () => {
    const { backend, calls } = fakeBackend([]);
    const s = new SearchService(backend);
    expect((await s.search('address', ' 순 ', null)).kind).toBe('invalid');
    expect((await s.search('address', '   ', null)).kind).toBe('invalid');
    expect(calls.length).toBe(0);
  });
  it('S02 60글자 초과 거부', () => {
    expect(validateQuery('가'.repeat(61))).not.toBeNull();
    expect(validateQuery('순천시 장명로 30')).toBeNull();
  });
});

describe('쿼터 절약', () => {
  it('S03 같은 검색은 캐시에서 응답 (API 1회)', async () => {
    const c = clock();
    const { backend, calls } = fakeBackend([{ status: 'OK', places: [SUNCHEON] }]);
    const s = new SearchService(backend, { now: c.now });
    const a = await s.search('address', '순천시 장명로 30', null);
    c.advance(5000);
    const b = await s.search('address', '  순천시   장명로 30 ', null);
    expect(a.kind).toBe('results');
    expect(b).toMatchObject({ kind: 'results', fromCache: true });
    expect(calls.length).toBe(1);
  });
  it('S04 캐시는 10분 뒤 만료', async () => {
    const c = clock();
    const { backend, calls } = fakeBackend([]);
    const s = new SearchService(backend, { now: c.now });
    await s.search('address', '순천역', null);
    c.advance(10 * 60 * 1000 + 1);
    await s.search('address', '순천역', null);
    expect(calls.length).toBe(2);
  });
  it('S05 1.5초 안 연속 호출은 거부 (다른 검색어)', async () => {
    const c = clock();
    const { backend, calls } = fakeBackend([]);
    const s = new SearchService(backend, { now: c.now });
    await s.search('address', '순천역', null);
    c.advance(500);
    const r = await s.search('address', '순천만', null);
    expect(r.kind).toBe('throttled');
    expect(calls.length).toBe(1);
    c.advance(1100);
    expect((await s.search('address', '순천만', null)).kind).toBe('results');
    expect(calls.length).toBe(2);
  });
  it('S06 같은 검색 동시 요청은 1회만 호출', async () => {
    const { backend, calls } = fakeBackend([]);
    const s = new SearchService(backend);
    const [a, b] = await Promise.all([s.search('keyword', '순천역', null), s.search('keyword', '순천역', null)]);
    expect(a).toEqual(b);
    expect(calls.length).toBe(1);
  });
  it('S07 실제 API 호출마다 집계 콜백 (캐시 응답은 제외)', async () => {
    const c = clock();
    const onApiCall = vi.fn();
    const { backend } = fakeBackend([]);
    const s = new SearchService(backend, { now: c.now, onApiCall });
    await s.search('address', '순천역', null);
    c.advance(2000);
    await s.search('address', '순천역', null);
    expect(onApiCall).toHaveBeenCalledTimes(1);
  });
  it('S08 키워드 검색 캐시는 지도 중심 약 1km 격자별로 구분', async () => {
    const c = clock();
    const { backend, calls } = fakeBackend([]);
    const s = new SearchService(backend, { now: c.now });
    await s.search('keyword', '편의점', { lat: 34.95, lng: 127.48 });
    c.advance(2000);
    await s.search('keyword', '편의점', { lat: 34.951, lng: 127.481 }); // 같은 격자 → 캐시
    c.advance(2000);
    await s.search('keyword', '편의점', { lat: 34.99, lng: 127.48 });   // 다른 격자 → 호출
    expect(calls.length).toBe(2);
  });
});

describe('오류·쿼터 초과 대비', () => {
  it('S09 ERROR 1회는 오류 안내, 2회 연속이면 10분 일시 중지', async () => {
    const c = clock();
    const { backend, calls } = fakeBackend([{ status: 'ERROR' }, { status: 'ERROR' }]);
    const s = new SearchService(backend, { now: c.now });
    expect((await s.search('address', '순천역', null)).kind).toBe('error');
    c.advance(2000);
    const r = await s.search('address', '순천만', null);
    expect(r.kind).toBe('paused');
    c.advance(2000);
    expect((await s.search('address', '조례동', null)).kind).toBe('paused'); // 호출 없이 거부
    expect(calls.length).toBe(2);
    expect(s.pausedUntilTime()).not.toBeNull();
    c.advance(10 * 60 * 1000);
    expect((await s.search('address', '조례동', null)).kind).toBe('results');
    expect(s.pausedUntilTime()).toBeNull();
  });
  it('S10 일시 중지 중에도 캐시된 결과는 응답', async () => {
    const c = clock();
    const { backend } = fakeBackend([{ status: 'OK', places: [SUNCHEON] }, { status: 'ERROR' }, { status: 'ERROR' }]);
    const s = new SearchService(backend, { now: c.now });
    await s.search('address', '순천시청', null);
    c.advance(2000); await s.search('address', 'a1', null);
    c.advance(2000); await s.search('address', 'a2', null);
    expect(s.pausedUntilTime()).not.toBeNull();
    expect((await s.search('address', '순천시청', null)).kind).toBe('results');
  });
  it('S11 성공 응답이 오면 연속 오류 횟수 초기화', async () => {
    const c = clock();
    const { backend } = fakeBackend([{ status: 'ERROR' }, { status: 'OK', places: [SUNCHEON] }, { status: 'ERROR' }]);
    const s = new SearchService(backend, { now: c.now });
    await s.search('address', 'b1', null);
    c.advance(2000); await s.search('address', 'b2', null);
    c.advance(2000);
    expect((await s.search('address', 'b3', null)).kind).toBe('error');
  });
  it('S12 백엔드 예외도 ERROR로 처리 (앱이 멈추지 않음)', async () => {
    const backend: Backend = { search: async () => { throw new Error('network'); } };
    const s = new SearchService(backend);
    expect((await s.search('address', '순천역', null)).kind).toBe('error');
  });
});

describe('좌표 검증 (DB와 같은 국내 범위)', () => {
  it('S13 위경도가 뒤바뀐 결과는 제외하고 제외 건수 표시', async () => {
    const { backend } = fakeBackend([{ status: 'OK', places: [SUNCHEON, SWAPPED] }]);
    const s = new SearchService(backend);
    const r = await s.search('address', '순천', null);
    expect(r).toMatchObject({ kind: 'results', droppedOutsideKorea: 1 });
    if (r.kind === 'results') expect(r.places.map((p) => p.id)).toEqual(['1']);
  });
  it('S14 모든 결과가 범위 밖이면 결과 없음', async () => {
    const { backend } = fakeBackend([{ status: 'OK', places: [SWAPPED] }]);
    const s = new SearchService(backend);
    expect((await s.search('address', '순천', null)).kind).toBe('empty');
  });
  it('S15 ZERO_RESULT는 결과 없음', async () => {
    const { backend } = fakeBackend([{ status: 'ZERO_RESULT' }]);
    const s = new SearchService(backend);
    expect((await s.search('address', '없는주소', null)).kind).toBe('empty');
  });
});
