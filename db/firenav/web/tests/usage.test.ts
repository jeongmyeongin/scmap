import { beforeEach, describe, expect, it } from 'vitest';
import { readTodayCalls, recordCall } from '@/lib/usage';

describe('기기별 호출 횟수', () => {
  beforeEach(() => localStorage.clear());
  it('U01 호출마다 1씩 증가', () => {
    const d = new Date(2026, 10, 9);
    recordCall(d); recordCall(d);
    expect(readTodayCalls(d)).toBe(2);
  });
  it('U02 날짜가 바뀌면 0부터, 지난 기록은 삭제', () => {
    recordCall(new Date(2026, 10, 9));
    recordCall(new Date(2026, 10, 10));
    expect(readTodayCalls(new Date(2026, 10, 10))).toBe(1);
    expect(localStorage.length).toBe(1);
  });
  it('U03 숫자 외 정보(검색어·주소)는 저장하지 않음', () => {
    recordCall(new Date(2026, 10, 9));
    const all = Object.keys(localStorage).map((k) => k + '=' + localStorage.getItem(k)).join(';');
    expect(all).toMatch(/^firenav:kakao-calls:2026-11-09=1$/);
  });
});
