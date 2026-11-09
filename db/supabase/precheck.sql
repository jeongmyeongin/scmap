-- =====================================================================
-- Supabase 적용 후 점검 (조회 전용 — 데이터를 바꾸지 않음)
-- 사용: Supabase SQL Editor에 붙여넣고 실행 → "판정" 열이 모두 OK인지 확인
-- 결과 화면을 캡처해 공유해 주시면 README의 "Supabase 실행 결과"를 갱신합니다.
-- =====================================================================
WITH checks AS (
  SELECT 1 AS no, 'PostGIS가 extensions 스키마에 설치됨' AS item, 'extensions' AS expected,
         (SELECT extnamespace::regnamespace::text FROM pg_extension WHERE extname = 'postgis') AS actual
  UNION ALL
  SELECT 2, 'auth.uid() 함수 존재', 'true',
         (to_regprocedure('auth.uid()') IS NOT NULL)::text
  UNION ALL
  SELECT 3, 'RLS가 꺼진 public 테이블 수', '0',
         (SELECT count(*) FROM pg_class
           WHERE relnamespace = 'public'::regnamespace AND relkind = 'r' AND NOT relrowsecurity)::text
  UNION ALL
  SELECT 4, '비로그인(anon)이 가진 public 테이블 권한 수', '0',
         (SELECT count(*) FROM information_schema.role_table_grants
           WHERE grantee = 'anon' AND table_schema = 'public')::text
  UNION ALL
  SELECT 5, '비로그인이 제보 채택 함수 실행 가능', 'false',
         has_function_privilege('anon', 'public.review_field_report(bigint, boolean, text)', 'execute')::text
  UNION ALL
  SELECT 6, '비로그인이 현장 검증 함수 실행 가능', 'false',
         has_function_privilege('anon',
           'public.verify_hazard_on_site(bigint, public.verification_outcome, public.verification_method, date, numeric, text)',
           'execute')::text
  UNION ALL
  SELECT 7, '비로그인이 차량 생성 함수 실행 가능', 'false',
         has_function_privilege('anon', 'public.create_vehicle_from_type(bigint, bigint, text)', 'execute')::text
  UNION ALL
  SELECT 8, '위험정보 뷰가 security_invoker (RLS 우회 방지)', 'true',
         coalesce((SELECT 'security_invoker=true' = ANY(reloptions) FROM pg_class
                    WHERE oid = 'public.hazards_effective'::regclass), false)::text
  UNION ALL
  SELECT 9, '로그인 사용자의 검증 이력 쓰기 권한', 'false',
         (has_table_privilege('authenticated', 'public.hazard_verifications', 'insert')
          OR has_table_privilege('authenticated', 'public.hazard_verifications', 'update')
          OR has_table_privilege('authenticated', 'public.hazard_verifications', 'delete'))::text
  UNION ALL
  SELECT 10, 'verified 우회 차단 트리거 존재', 'true',
         EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'hazard_verified_guard'
                  AND tgrelid = 'public.hazards'::regclass)::text
  UNION ALL
  SELECT 11, '표-3 차종 템플릿 수', '10',
         (SELECT count(*) FROM public.vehicle_types)::text
  UNION ALL
  SELECT 12, '활성 관리자 수 (최초 관리자 등록 후)', '1 이상',
         (SELECT count(*) FROM public.profiles WHERE role = 'admin' AND is_active)::text
)
SELECT no AS "번호", item AS "점검 항목", expected AS "기대값", actual AS "결과",
       CASE
         WHEN no = 12 THEN CASE WHEN actual::int >= 1 THEN 'OK' ELSE '최초 관리자 미등록' END
         WHEN actual = expected THEN 'OK'
         ELSE '확인 필요'
       END AS "판정"
FROM checks ORDER BY no;
