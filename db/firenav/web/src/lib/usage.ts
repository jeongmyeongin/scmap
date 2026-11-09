/**
 * 이 기기에서 오늘 카카오 검색 API를 몇 번 불렀는지 숫자만 센다.
 * - 검색어·주소·좌표는 기록하지 않는다 (개인정보 최소화)
 * - 카카오는 앱 키별 사용량 통계를 제공하지 않으므로 [고객센터], 이 숫자는 "이 기기" 기준 참고값이다.
 *   앱 전체 사용량(월 300만 쿼터 대비)은 알 수 없다.
 */
const PREFIX = 'firenav:kakao-calls:';

function todayKey(d = new Date()): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${PREFIX}${y}-${m}-${day}`;
}

function store(): Storage | null {
  try {
    return typeof window !== 'undefined' ? window.localStorage : null;
  } catch {
    return null; // 사생활 보호 모드 등에서 저장소 접근 불가
  }
}

export function readTodayCalls(d = new Date()): number {
  const s = store();
  if (!s) return 0;
  try {
    const v = Number(s.getItem(todayKey(d)));
    return Number.isFinite(v) && v > 0 ? Math.floor(v) : 0;
  } catch {
    return 0;
  }
}

export function recordCall(d = new Date()): number {
  const s = store();
  const next = readTodayCalls(d) + 1;
  if (!s) return next;
  try {
    s.setItem(todayKey(d), String(next));
    // 지난 날짜 기록은 정리 (숫자만 있지만 쌓이지 않게)
    for (let i = s.length - 1; i >= 0; i--) {
      const k = s.key(i);
      if (k && k.startsWith(PREFIX) && k !== todayKey(d)) s.removeItem(k);
    }
  } catch {
    /* 저장 실패해도 검색에는 영향 없음 */
  }
  return next;
}
