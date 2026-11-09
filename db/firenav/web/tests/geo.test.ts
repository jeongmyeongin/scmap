import { describe, expect, it } from 'vitest';
import { DEFAULT_CENTER, distanceMeters, isInKorea } from '@/lib/geo';

describe('geo', () => {
  it('G01 순천 좌표는 국내 범위', () => expect(isInKorea(DEFAULT_CENTER)).toBe(true));
  it('G02 위경도 뒤바뀜·NaN·(0,0)은 범위 밖', () => {
    expect(isInKorea({ lat: 127.48, lng: 34.95 })).toBe(false);
    expect(isInKorea({ lat: NaN, lng: 127 })).toBe(false);
    expect(isInKorea({ lat: 0, lng: 0 })).toBe(false);
  });
  it('G03 DB geom_in_korea와 같은 경계값 (경도 124~132, 위도 33~39)', () => {
    expect(isInKorea({ lat: 33, lng: 124 })).toBe(true);
    expect(isInKorea({ lat: 39, lng: 132 })).toBe(true);
    expect(isInKorea({ lat: 32.99, lng: 127 })).toBe(false);
  });
  it('G04 위도 0.01도 ≈ 1.11km', () => {
    const d = distanceMeters({ lat: 34.95, lng: 127.48 }, { lat: 34.96, lng: 127.48 });
    expect(d).toBeGreaterThan(1100);
    expect(d).toBeLessThan(1125);
  });
});
