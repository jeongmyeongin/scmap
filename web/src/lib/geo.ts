/** 좌표 (WGS84) */
export interface LatLng {
  lat: number;
  lng: number;
}

/**
 * 대한민국 대략 범위 — DB의 geom_in_korea()와 같은 값 (경도 124~132, 위도 33~39).
 * 범위 밖 좌표는 검색 결과·지도 선택에서 버린다 (위경도 뒤바뀜 등 오류 차단).
 */
export const KOREA_BOUNDS = { minLng: 124, maxLng: 132, minLat: 33, maxLat: 39 } as const;

export function isInKorea(p: LatLng): boolean {
  return (
    Number.isFinite(p.lat) &&
    Number.isFinite(p.lng) &&
    p.lng >= KOREA_BOUNDS.minLng &&
    p.lng <= KOREA_BOUNDS.maxLng &&
    p.lat >= KOREA_BOUNDS.minLat &&
    p.lat <= KOREA_BOUNDS.maxLat
  );
}

/** 지도 첫 화면 중심: 순천시청 부근 (근사 좌표, 위치 권한이 없을 때만 사용) */
export const DEFAULT_CENTER: LatLng = { lat: 34.9506, lng: 127.4872 };

/** 좌표를 화면 표시용 문자열로 (소수 5자리 ≈ 1m) */
export function formatLatLng(p: LatLng): string {
  return `${p.lat.toFixed(5)}, ${p.lng.toFixed(5)}`;
}

/** 두 좌표 사이 거리 (m, 하버사인) */
export function distanceMeters(a: LatLng, b: LatLng): number {
  const R = 6371000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}
