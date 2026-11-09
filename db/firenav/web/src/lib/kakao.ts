import type { Backend, Place, SearchMode } from './search';
import type { LatLng } from './geo';

/* eslint-disable @typescript-eslint/no-explicit-any */
// 카카오 지도 JS SDK의 필요한 부분만 최소로 선언 (공식 타입 패키지 없음)
export type Kakao = any;
declare global {
  interface Window {
    kakao?: Kakao;
  }
}

export type LoadError =
  | { kind: 'no-key' }
  | { kind: 'script-failed' }   // 네트워크 차단, 도메인 미등록, 쿼터 초과 등 원인 구분 불가
  | { kind: 'timeout' }
  | { kind: 'init-failed' };

const SDK_URL = 'https://dapi.kakao.com/v2/maps/sdk.js';
let loading: Promise<Kakao> | null = null;

/**
 * 카카오 지도 SDK를 한 번만 불러온다. (services 라이브러리 = 주소·장소 검색)
 * 실패해도 앱 전체가 멈추지 않도록 원인을 돌려준다.
 */
export function loadKakao(appKey: string | undefined, timeoutMs = 10000, doc: Document = document): Promise<Kakao> {
  if (!appKey) return Promise.reject<Kakao>({ kind: 'no-key' } satisfies LoadError);
  if (typeof window !== 'undefined' && window.kakao?.maps?.services) return Promise.resolve(window.kakao);
  if (loading) return loading;

  loading = new Promise<Kakao>((resolve, reject) => {
    const script = doc.createElement('script');
    script.src = `${SDK_URL}?appkey=${encodeURIComponent(appKey)}&libraries=services&autoload=false`;
    script.async = true;
    const timer = setTimeout(() => fail({ kind: 'timeout' }), timeoutMs);
    function fail(e: LoadError) {
      clearTimeout(timer);
      loading = null;
      script.remove();
      reject(e);
    }
    script.onerror = () => fail({ kind: 'script-failed' });
    script.onload = () => {
      const k = window.kakao;
      if (!k?.maps?.load) return fail({ kind: 'init-failed' });
      k.maps.load(() => {
        clearTimeout(timer);
        resolve(k);
      });
    };
    doc.head.appendChild(script);
  });
  return loading;
}

/** 테스트용: 로더 상태 초기화 */
export function resetKakaoLoaderForTest() {
  loading = null;
}

export function loadErrorMessage(e: unknown): string {
  const kind = (e as LoadError)?.kind;
  switch (kind) {
    case 'no-key':
      return '카카오 JavaScript 키가 설정되지 않았습니다. 배포 설정의 NEXT_PUBLIC_KAKAO_JS_KEY 값을 확인하세요.';
    case 'timeout':
      return '지도를 10초 안에 불러오지 못했습니다. 통신 상태를 확인하고 다시 여세요.';
    case 'init-failed':
      return '지도 프로그램을 초기화하지 못했습니다. 카카오 앱에서 이 사이트 도메인이 등록되어 있는지 확인하세요.';
    default:
      return '지도를 불러오지 못했습니다. 통신 상태, 카카오 앱의 사이트 도메인 등록, 일일 사용량 한도를 확인하세요.';
  }
}

/** 카카오 SDK 검색 결과 → 앱 공통 형식 */
function mapStatus(k: Kakao, status: string): 'OK' | 'ZERO_RESULT' | 'ERROR' {
  const S = k.maps.services.Status;
  if (status === S.OK) return 'OK';
  if (status === S.ZERO_RESULT) return 'ZERO_RESULT';
  return 'ERROR';
}

export function createKakaoBackend(k: Kakao): Backend {
  const geocoder = new k.maps.services.Geocoder();
  const places = new k.maps.services.Places();
  return {
    search(mode: SearchMode, query: string, near: LatLng | null) {
      return new Promise((resolve) => {
        if (mode === 'address') {
          geocoder.addressSearch(query, (result: any[], status: string) => {
            const st = mapStatus(k, status);
            resolve({
              status: st,
              places:
                st === 'OK'
                  ? result.map((r, i): Place => ({
                      id: `a${i}-${r.x},${r.y}`,
                      name: r.road_address?.address_name || r.address_name,
                      address: r.address?.address_name || r.address_name,
                      position: { lat: Number(r.y), lng: Number(r.x) },
                    }))
                  : [],
            });
          });
        } else {
          const opts = near ? { location: new k.maps.LatLng(near.lat, near.lng) } : {};
          places.keywordSearch(
            query,
            (result: any[], status: string) => {
              const st = mapStatus(k, status);
              resolve({
                status: st,
                places:
                  st === 'OK'
                    ? result.map((r): Place => ({
                        id: `k${r.id}`,
                        name: r.place_name,
                        address: r.road_address_name || r.address_name,
                        position: { lat: Number(r.y), lng: Number(r.x) },
                      }))
                    : [],
              });
            },
            opts,
          );
        }
      });
    },
  };
}
