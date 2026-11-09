-- =====================================================================
-- 2단계 DB 검증 테스트 (로컬 전용, 가상 데이터만 사용)
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE TEMP TABLE t_results (n serial, label text, passed boolean, detail text);
GRANT ALL ON t_results TO PUBLIC;

-- 지정 사용자로 SQL 실행 → 성공 기대
CREATE FUNCTION pg_temp.as_ok(p_user uuid, p_label text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    IF p_user IS NULL THEN EXECUTE 'SET LOCAL ROLE anon';
    ELSE EXECUTE 'SET LOCAL ROLE authenticated';
         PERFORM set_config('request.jwt.claim.sub', p_user::text, true); END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    INSERT INTO t_results(label, passed) VALUES (p_label, true);
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    INSERT INTO t_results(label, passed, detail) VALUES (p_label, false, SQLERRM);
  END;
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $$;

-- 지정 사용자로 SQL 실행 → 실패(거부) 기대
CREATE FUNCTION pg_temp.as_fail(p_user uuid, p_label text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    IF p_user IS NULL THEN EXECUTE 'SET LOCAL ROLE anon';
    ELSE EXECUTE 'SET LOCAL ROLE authenticated';
         PERFORM set_config('request.jwt.claim.sub', p_user::text, true); END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    INSERT INTO t_results(label, passed, detail) VALUES (p_label, false, '거부되어야 하는데 성공함');
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    INSERT INTO t_results(label, passed, detail) VALUES (p_label, true, '거부됨: ' || SQLERRM);
  END;
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $$;

-- 지정 사용자로 조회한 행 수 확인
CREATE FUNCTION pg_temp.as_count(p_user uuid, p_label text, p_sql text, p_expected int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE c int;
BEGIN
  IF p_user IS NULL THEN EXECUTE 'SET LOCAL ROLE anon';
  ELSE EXECUTE 'SET LOCAL ROLE authenticated';
       PERFORM set_config('request.jwt.claim.sub', p_user::text, true); END IF;
  BEGIN
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') q' INTO c;
  EXCEPTION WHEN insufficient_privilege THEN c := 0;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub', '', true);
  INSERT INTO t_results(label, passed, detail)
  VALUES (p_label, c = p_expected, format('기대 %s, 실제 %s', p_expected, c));
END $$;

CREATE FUNCTION pg_temp.check(p_label text, p_cond boolean, p_detail text DEFAULT NULL) RETURNS void
LANGUAGE sql AS $$ INSERT INTO t_results(label, passed, detail) VALUES (p_label, coalesce(p_cond,false), p_detail) $$;

-- ---------- 가상 사용자·조직 (실제 인물·기관 데이터 아님) ----------
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'admin@test.local'),
  ('00000000-0000-0000-0000-00000000000b', 'reviewer@test.local'),
  ('00000000-0000-0000-0000-00000000000c', 'member@test.local'),
  ('00000000-0000-0000-0000-00000000000d', 'viewer@test.local'),
  ('00000000-0000-0000-0000-00000000000e', 'inactive@test.local'),
  ('00000000-0000-0000-0000-00000000000f', 'noprofile@test.local'),
  ('00000000-0000-0000-0000-000000000010', 'firstadmin@test.local');
INSERT INTO stations (name, location) VALUES ('테스트 안전센터', ST_SetSRID(ST_MakePoint(127.487, 34.950), 4326));
INSERT INTO profiles (user_id, display_name, station_id, role, is_active) VALUES
  ('00000000-0000-0000-0000-00000000000a', '관리자(테스트)', 1, 'admin', true),
  ('00000000-0000-0000-0000-00000000000b', '검토자(테스트)', 1, 'reviewer', true),
  ('00000000-0000-0000-0000-00000000000c', '대원(테스트)',   1, 'member', true),
  ('00000000-0000-0000-0000-00000000000d', '열람(테스트)',   1, 'viewer', true),
  ('00000000-0000-0000-0000-00000000000e', '비활성(테스트)', 1, 'admin', false);
INSERT INTO sources (name, default_trust, is_automatic) VALUES ('테스트 공공데이터', 'L3', true);

\set A '''00000000-0000-0000-0000-00000000000a'''
\set R '''00000000-0000-0000-0000-00000000000b'''
\set M '''00000000-0000-0000-0000-00000000000c'''
\set V '''00000000-0000-0000-0000-00000000000d'''
\set X '''00000000-0000-0000-0000-00000000000e'''
\set N '''00000000-0000-0000-0000-00000000000f'''
\set F '''00000000-0000-0000-0000-000000000010'''

-- ===== 1. 차종 템플릿 (표-3) =====
SELECT pg_temp.check('T01 표-3 차종 10종 등록', (SELECT count(*) FROM vehicle_types) = 10);
SELECT pg_temp.check('T02 모든 템플릿 Ri < Ro',
  NOT EXISTS (SELECT 1 FROM vehicle_types WHERE inner_turning_radius_m >= outer_turning_radius_m));
SELECT pg_temp.check('T03 템플릿 신뢰등급 L3', NOT EXISTS (SELECT 1 FROM vehicle_types WHERE trust <> 'L3'));

-- ===== 2. 차량 등록·범위 검사 =====
SELECT pg_temp.as_ok(:A, 'T04 관리자: 템플릿에서 차량 생성',
  $q$SELECT create_vehicle_from_type((SELECT id FROM vehicle_types WHERE name='46m 고가사다리차'), 1, '테스트굴절1')$q$);
SELECT pg_temp.check('T05 템플릿 복사 차량은 만재 중량 미입력(NULL)',
  (SELECT gross_weight_full_t IS NULL AND spec_trust = 'L3' FROM vehicles WHERE call_sign='테스트굴절1'));
SELECT pg_temp.as_fail(:A, 'T06 전고 395(cm 단위 실수) 거부',
  $q$INSERT INTO vehicles (station_id, call_sign, height_m) VALUES (1, '오류1', 395)$q$);
SELECT pg_temp.as_fail(:A, 'T07 Ri ≥ Ro 거부',
  $q$INSERT INTO vehicles (station_id, call_sign, inner_turning_radius_m, outer_turning_radius_m) VALUES (1, '오류2', 11, 10)$q$);
SELECT pg_temp.as_fail(:A, 'T08 공차 > 만재 거부',
  $q$INSERT INTO vehicles (station_id, call_sign, curb_weight_t, gross_weight_full_t) VALUES (1, '오류3', 20, 15)$q$);
SELECT pg_temp.as_fail(:A, 'T09 축하중 1개만 입력 거부',
  $q$INSERT INTO vehicles (station_id, call_sign, axle_loads_t) VALUES (1, '오류4', ARRAY[8.0])$q$);
SELECT pg_temp.as_fail(:A, 'T10 미러 포함 폭 < 차체 폭 거부',
  $q$INSERT INTO vehicles (station_id, call_sign, body_width_m, width_with_mirrors_m) VALUES (1, '오류5', 2.49, 2.30)$q$);
SELECT pg_temp.as_ok(:A, 'T11 정상 제원 차량 등록',
  $q$INSERT INTO vehicles (station_id, call_sign, length_m, body_width_m, width_with_mirrors_m, height_m,
       max_height_measured_m, wheelbase_m, turning_radius_m, inner_turning_radius_m, outer_turning_radius_m,
       curb_weight_t, gross_weight_full_t, axle_loads_t, spec_source, spec_trust)
     VALUES (1, '테스트펌프1', 8.63, 2.49, 2.80, 3.35, 3.48, 4.64, 9.0, 5.5, 9.9, 11.0, 13.1,
       ARRAY[5.1, 8.0], '가상 데이터', 'L2')$q$);

-- ===== 3. 제원 수정 이력 =====
SELECT pg_temp.as_fail(:A, 'T12 사유 없는 제원 수정 거부',
  $q$UPDATE vehicles SET height_m = 3.40 WHERE call_sign = '테스트펌프1'$q$);
SELECT pg_temp.as_ok(:A, 'T13 사유 있는 제원 수정',
  $q$UPDATE vehicles SET height_m = 3.40, change_reason = '경광등 교체 후 재측정' WHERE call_sign = '테스트펌프1'$q$);
SELECT pg_temp.check('T14 이력에 변경 전·후 값 저장',
  (SELECT old_values->>'height_m' = '3.35' AND new_values->>'height_m' = '3.40'
          AND changed_by = '00000000-0000-0000-0000-00000000000a'
     FROM vehicle_spec_history ORDER BY id DESC LIMIT 1));
SELECT pg_temp.as_fail(:A, 'T15 같은 사유 재사용 수정 거부',
  $q$UPDATE vehicles SET height_m = 3.41 WHERE call_sign = '테스트펌프1'$q$);
SELECT pg_temp.as_ok(:A, 'T16 제원 외 항목(활성 여부)은 사유 없이 수정',
  $q$UPDATE vehicles SET is_active = true WHERE call_sign = '테스트펌프1'$q$);

-- ===== 4. 위험정보 규칙 =====
SELECT pg_temp.as_fail(:R, 'T17 L3 자료를 확인됨(verified)으로 저장 거부 (비대칭 규칙)',
  $q$INSERT INTO hazards (hazard_type, value, geom, trust, status, title, last_checked_on)
     VALUES ('height_limit', 3.5, ST_SetSRID(ST_MakePoint(127.49, 34.95),4326), 'L3', 'verified', 't', current_date)$q$);
SELECT pg_temp.as_fail(:R, 'T18 높이 제한인데 값 없음 거부',
  $q$INSERT INTO hazards (hazard_type, geom, trust, title)
     VALUES ('height_limit', ST_SetSRID(ST_MakePoint(127.49, 34.95),4326), 'L1', 't')$q$);
SELECT pg_temp.as_fail(:R, 'T19 높이 0.3m(비정상 값) 거부',
  $q$INSERT INTO hazards (hazard_type, value, geom, trust, title)
     VALUES ('height_limit', 0.3, ST_SetSRID(ST_MakePoint(127.49, 34.95),4326), 'L1', 't')$q$);
SELECT pg_temp.as_fail(:R, 'T20 국외 좌표(위경도 뒤바뀜) 거부',
  $q$INSERT INTO hazards (hazard_type, value, geom, trust, title)
     VALUES ('height_limit', 3.5, ST_SetSRID(ST_MakePoint(34.95, 127.49),4326), 'L1', 't')$q$);
SELECT pg_temp.as_fail(:R, 'T21 확인됨인데 확인일 없음 거부',
  $q$INSERT INTO hazards (hazard_type, value, geom, trust, status, title)
     VALUES ('height_limit', 3.5, ST_SetSRID(ST_MakePoint(127.49, 34.95),4326), 'L1', 'verified', 't')$q$);
-- [변경] T22: verified로 바로 등록하던 방식 → 미검증 등록 후 현장 검증 절차
SELECT pg_temp.as_fail(:R, 'T22a 검토자: verified로 바로 등록 거부 (현장 검증 절차 필수)',
  $q$INSERT INTO hazards (hazard_type, value, geom, trust, status, title, last_checked_on, direction)
     VALUES ('height_limit', 3.45, ST_SetSRID(ST_MakePoint(127.4900, 34.9500),4326), 'L1', 'verified',
             '테스트 굴다리X', current_date, 'both')$q$);
SELECT pg_temp.as_ok(:R, 'T22 검토자: 굴다리 높이 3.45m 미검증 등록 후 현장 검증',
  $q$DO $d$ DECLARE hid bigint; BEGIN
       INSERT INTO hazards (hazard_type, value, geom, trust, status, title, direction)
       VALUES ('height_limit', 3.45, ST_SetSRID(ST_MakePoint(127.4900, 34.9500),4326), 'L3', 'unverified',
               '테스트 굴다리', 'both') RETURNING id INTO hid;
       PERFORM verify_hazard_on_site(hid, 'confirmed', 'laser_measure', current_date, 3.45,
               '굴다리 하단 최저점 레이저 실측, 2회 측정 평균');
     END $d$$q$);
SELECT pg_temp.as_ok(:R, 'T23 검토자: 기간 지난 공사 등록',
  $q$INSERT INTO hazards (hazard_type, geom, trust, title, valid_from, valid_to)
     VALUES ('construction', ST_SetSRID(ST_MakePoint(127.4910, 34.9505),4326), 'L3', '테스트 공사', '2026-01-01', '2026-01-31')$q$);
SELECT pg_temp.check('T24 기간 지난 공사는 expired로 표시',
  (SELECT effective_status = 'expired' FROM hazards_effective WHERE title = '테스트 공사'));

-- 충돌
SELECT pg_temp.as_ok(:R, 'T25 출처 충돌 등록',
  $q$INSERT INTO conflicts (hazard_id, description)
     VALUES ((SELECT id FROM hazards WHERE title='테스트 굴다리'), '공공데이터 3.2m vs 실측 3.45m')$q$);
SELECT pg_temp.check('T26 미해결 충돌 → effective_status = conflict',
  (SELECT effective_status = 'conflict' FROM hazards_effective WHERE title = '테스트 굴다리'));

-- 공간 검색
SELECT pg_temp.as_count(:V, 'T27 반경 200m 내 위험정보 검색 (열람자)',
  $q$SELECT * FROM hazards_near(127.4905, 34.9502, 200)$q$, 2);
SELECT pg_temp.as_count(:V, 'T28 반경 10m에는 없음',
  $q$SELECT * FROM hazards_near(127.5000, 34.9600, 10)$q$, 0);

-- 중복 수집 방지
INSERT INTO hazard_sources (source_id, original_record_id, original_value)
  VALUES ((SELECT id FROM sources WHERE name='테스트 공공데이터'), 'REC-001', 3.2);
SELECT pg_temp.as_fail(:R, 'T29 같은 출처·같은 원본 ID 중복 거부',
  $q$INSERT INTO hazard_sources (source_id, original_record_id, original_value)
     VALUES ((SELECT id FROM sources WHERE name='테스트 공공데이터'), 'REC-001', 3.2)$q$);

-- ===== 5. 권한 (RLS) =====
SELECT pg_temp.as_count(NULL, 'T30 비로그인: 차량 0건', $q$SELECT * FROM vehicles$q$, 0);
SELECT pg_temp.as_count(NULL, 'T31 비로그인: 위험정보 0건', $q$SELECT * FROM hazards$q$, 0);
SELECT pg_temp.as_count(:X, 'T32 비활성 계정: 차량 0건', $q$SELECT * FROM vehicles$q$, 0);
SELECT pg_temp.as_count(:V, 'T33 열람자: 차량 조회 가능', $q$SELECT * FROM vehicles$q$, 2);
SELECT pg_temp.as_fail(:V, 'T34 열람자: 위험정보 등록 거부',
  $q$INSERT INTO hazards (hazard_type, geom, trust, title) VALUES ('other', ST_SetSRID(ST_MakePoint(127.49,34.95),4326), 'L5', 'x')$q$);
SELECT pg_temp.as_fail(:M, 'T35 대원: 차량 등록 거부',
  $q$INSERT INTO vehicles (station_id, call_sign) VALUES (1, '무단')$q$);
SELECT pg_temp.as_ok(:M, 'T36a 대원: 차량 제원 수정 시도 (RLS로 0건 처리 기대)',
  $q$UPDATE vehicles SET height_m = 4.00, change_reason = '무단 수정' WHERE call_sign='테스트펌프1'$q$);
SELECT pg_temp.check('T36 대원 수정 시도 후에도 전고 3.40 유지',
  (SELECT height_m = 3.40 FROM vehicles WHERE call_sign='테스트펌프1'));
SELECT pg_temp.as_ok(:M, 'T37 대원: 본인 명의 현장 제보',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, measured_value, geom, memo)
     VALUES ('00000000-0000-0000-0000-00000000000c', 'width_limit', 2.7,
             ST_SetSRID(ST_MakePoint(127.4920, 34.9510),4326), '주차로 유효폭 감소')$q$);
SELECT pg_temp.as_fail(:M, 'T38 대원: 타인 명의 제보 거부',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, geom)
     VALUES ('00000000-0000-0000-0000-00000000000b', 'other', ST_SetSRID(ST_MakePoint(127.49,34.95),4326))$q$);
SELECT pg_temp.as_fail(:M, 'T39 대원: 본인 제보 직접 승인 처리 거부',
  $q$SELECT review_field_report((SELECT max(id) FROM field_reports), true, 'self')$q$);
SELECT pg_temp.as_count(:V, 'T40 열람자: 타인 제보 0건', $q$SELECT * FROM field_reports$q$, 0);
-- [변경] T41·T42: 채택 즉시 L1·verified → 채택 시 L4·검증 대기
SELECT pg_temp.as_ok(:R, 'T41 검토자: 제보 채택 → 검증 대기 위험정보 생성',
  $q$SELECT review_field_report((SELECT max(id) FROM field_reports), true, '제보 내용 타당')$q$);
SELECT pg_temp.check('T42 채택 제보는 L4·pending_review (verified 아님)',
  (SELECT h.trust = 'L4' AND h.status = 'pending_review' AND f.status = 'approved'
          AND h.source_report_id = f.id AND h.last_checked_on IS NULL
     FROM field_reports f JOIN hazards h ON h.id = f.hazard_id ORDER BY f.id DESC LIMIT 1));
SELECT pg_temp.as_fail(:R, 'T43 이미 처리된 제보 재처리 거부',
  $q$SELECT review_field_report((SELECT max(id) FROM field_reports), false, 'again')$q$);
SELECT pg_temp.as_fail(:M, 'T44 대원: 자기 역할을 admin으로 변경 거부',
  $q$UPDATE profiles SET role = 'admin' WHERE user_id = '00000000-0000-0000-0000-00000000000c'$q$);
SELECT pg_temp.as_ok(:M, 'T45 대원: 자기 표시명 변경 허용',
  $q$UPDATE profiles SET display_name = '대원2(테스트)' WHERE user_id = '00000000-0000-0000-0000-00000000000c'$q$);
SELECT pg_temp.as_count(:M, 'T46 대원: 다른 사람 프로필 0건(본인만)', $q$SELECT * FROM profiles$q$, 1);
SELECT pg_temp.as_count(:M, 'T47 대원: 변경 이력(audit_log) 0건', $q$SELECT * FROM audit_log$q$, 0);
SELECT pg_temp.as_fail(:A, 'T48 관리자도 audit_log 직접 수정 불가',
  $q$DELETE FROM audit_log$q$);
SELECT pg_temp.as_fail(:R, 'T49 검토자: 위험정보 삭제 거부(관리자 전용)',
  $q$DO $d$ BEGIN
       DELETE FROM hazards WHERE title = '테스트 굴다리';
       IF NOT FOUND THEN RAISE EXCEPTION 'RLS로 0건 삭제'; END IF;
     END $d$$q$);

-- ===== 6. 변경 이력 =====
SELECT pg_temp.check('T50 audit_log에 차량·위험정보·제보 변경 기록',
  (SELECT count(DISTINCT table_name) >= 3 FROM audit_log
    WHERE table_name IN ('vehicles','hazards','field_reports')));
SELECT pg_temp.check('T51 audit_log에 행위자(actor) 기록',
  EXISTS (SELECT 1 FROM audit_log WHERE table_name='hazards' AND actor = '00000000-0000-0000-0000-00000000000b'));

-- ===== 7. 개인정보 최소화 구조 =====
SELECT pg_temp.check('T52 출동주소·경로이력·사진 컬럼 없음',
  NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public'
                 AND column_name ~* '(address|route|photo|image|incident|dispatch)'));


-- ===== 8. 자기 승인 방지 =====
SELECT pg_temp.as_ok(:R, 'T53 검토자: 본인 명의 제보 작성',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, measured_value, geom)
     VALUES ('00000000-0000-0000-0000-00000000000b', 'height_limit', 3.3, ST_SetSRID(ST_MakePoint(127.493,34.952),4326))$q$);
SELECT pg_temp.as_fail(:R, 'T54 검토자: 본인 제보 자기 승인 거부',
  $q$SELECT review_field_report((SELECT max(id) FROM field_reports), true, 'self')$q$);
SELECT pg_temp.as_fail(:A, 'T55 관리자: 높이 39.5m(단위 오류) 차량 거부',
  $q$INSERT INTO vehicles (station_id, call_sign, height_m) VALUES (1, '오류6', 39.5)$q$);


-- ===== 9. 제보 채택과 현장 검증 분리 (보완 1) =====
SELECT pg_temp.as_fail(:R, 'T56 검토자: 채택 제보를 UPDATE로 직접 verified 전환 거부',
  $q$UPDATE hazards SET status='verified', trust='L1', last_checked_on=current_date
      WHERE source_report_id = (SELECT min(id) FROM field_reports WHERE status='approved')$q$);
SELECT pg_temp.as_fail(:R, 'T57 검토자: 검증 이력 테이블 직접 INSERT 거부',
  $q$INSERT INTO hazard_verifications (hazard_id, outcome, method, verified_on, evidence, verified_by, previous_status, previous_trust)
     VALUES ((SELECT max(id) FROM hazards), 'confirmed', 'tape_measure', current_date, '직접 기록 시도입니다', '00000000-0000-0000-0000-00000000000b', 'unverified', 'L4')$q$);
SELECT pg_temp.as_fail(:M, 'T58 대원: 현장 검증 함수 호출 거부',
  $q$SELECT verify_hazard_on_site((SELECT hazard_id FROM field_reports WHERE status='approved' ORDER BY id LIMIT 1),
       'confirmed', 'tape_measure', current_date, 2.65, '줄자로 최협소 지점 실측함')$q$);
SELECT pg_temp.as_fail(NULL, 'T59 비로그인: 현장 검증 함수 호출 거부',
  $q$SELECT verify_hazard_on_site(1, 'confirmed', 'tape_measure', current_date, 2.65, '비로그인 호출 시도입니다')$q$);
SELECT pg_temp.as_fail(:R, 'T60 제한 유형 측정값 없이 confirmed 거부',
  $q$SELECT verify_hazard_on_site((SELECT hazard_id FROM field_reports WHERE status='approved' ORDER BY id LIMIT 1),
       'confirmed', 'tape_measure', current_date, NULL, '줄자로 최협소 지점 실측함')$q$);
SELECT pg_temp.as_fail(:R, 'T61 제한 유형 육안 확인만으로 검증 거부',
  $q$SELECT verify_hazard_on_site((SELECT hazard_id FROM field_reports WHERE status='approved' ORDER BY id LIMIT 1),
       'confirmed', 'visual_inspection', current_date, 2.65, '눈으로 보기에 좁아 보였음')$q$);
SELECT pg_temp.as_fail(:R, 'T62 측정값 단위 오류(폭 265, cm 입력) 거부',
  $q$SELECT verify_hazard_on_site((SELECT hazard_id FROM field_reports WHERE status='approved' ORDER BY id LIMIT 1),
       'confirmed', 'tape_measure', current_date, 265, '줄자로 최협소 지점 실측함')$q$);
SELECT pg_temp.as_fail(:R, 'T63 미래 확인 날짜 거부',
  $q$SELECT verify_hazard_on_site((SELECT hazard_id FROM field_reports WHERE status='approved' ORDER BY id LIMIT 1),
       'confirmed', 'tape_measure', current_date + 1, 2.65, '줄자로 최협소 지점 실측함')$q$);
SELECT pg_temp.as_fail(:R, 'T64 근거 10자 미만 거부',
  $q$SELECT verify_hazard_on_site((SELECT hazard_id FROM field_reports WHERE status='approved' ORDER BY id LIMIT 1),
       'confirmed', 'tape_measure', current_date, 2.65, '확인함')$q$);
SELECT pg_temp.check('T65a 실패한 검증 시도 후에도 검증 대기 유지',
  (SELECT status = 'pending_review' AND trust = 'L4' FROM hazards
    WHERE id = (SELECT hazard_id FROM field_reports WHERE status='approved' ORDER BY id LIMIT 1)));
SELECT pg_temp.as_ok(:R, 'T65 검토자: 정상 현장 검증 (줄자 2.65m)',
  $q$SELECT verify_hazard_on_site((SELECT hazard_id FROM field_reports WHERE status='approved' ORDER BY id LIMIT 1),
       'confirmed', 'tape_measure', current_date, 2.65, '주정차 차량 사이 최협소 지점 줄자 실측')$q$);
SELECT pg_temp.check('T66 검증 후 L1·verified, 값=현장 측정값(2.65), 확인일 기록',
  (SELECT status = 'verified' AND trust = 'L1' AND value = 2.65 AND last_checked_on = current_date FROM hazards
    WHERE id = (SELECT hazard_id FROM field_reports WHERE status='approved' ORDER BY id LIMIT 1)));
SELECT pg_temp.check('T67 검증 이력: 검증자·날짜·방법·근거·측정값·이전 상태 기록',
  (SELECT verified_by = '00000000-0000-0000-0000-00000000000b' AND verified_on = current_date
          AND method = 'tape_measure' AND evidence LIKE '%줄자%' AND measured_value = 2.65
          AND previous_status = 'pending_review' AND previous_trust = 'L4' AND previous_value = 2.7
     FROM hazard_verifications ORDER BY id DESC LIMIT 1));
SELECT pg_temp.as_fail(:R, 'T68 verified 상태에서 값 직접 수정 거부',
  $q$UPDATE hazards SET value = 3.5 WHERE title = '테스트 굴다리'$q$);
SELECT pg_temp.as_ok(:R, 'T69 verified 상태에서 설명만 수정 허용',
  $q$UPDATE hazards SET description = '야간 조명 없음' WHERE title = '테스트 굴다리'$q$);
SELECT pg_temp.as_ok(:R, 'T70 관리기관 공식 자료로 검증',
  $q$DO $d$ DECLARE hid bigint; BEGIN
       INSERT INTO hazards (hazard_type, value, geom, trust, title)
       VALUES ('weight_limit', 20, ST_SetSRID(ST_MakePoint(127.4950, 34.9550),4326), 'L3', '테스트 교량') RETURNING id INTO hid;
       PERFORM verify_hazard_on_site(hid, 'confirmed', 'official_document', current_date, 18,
               '도로관리청 공문 제2026-0000호 통행제한 18t');
     END $d$$q$);
SELECT pg_temp.check('T71 관리기관 자료 검증은 L2, 값 18t로 갱신',
  (SELECT trust = 'L2' AND status = 'verified' AND value = 18 FROM hazards WHERE title = '테스트 교량'));
SELECT pg_temp.as_ok(:R, 'T72 현장에 없음(not_found) 처리',
  $q$DO $d$ DECLARE hid bigint; BEGIN
       INSERT INTO hazards (hazard_type, geom, trust, title)
       VALUES ('narrow_road', ST_SetSRID(ST_MakePoint(127.4960, 34.9560),4326), 'L4', '테스트 협소') RETURNING id INTO hid;
       PERFORM verify_hazard_on_site(hid, 'not_found', 'visual_inspection', current_date, NULL,
               '현장 확인 결과 도로 확장 공사 완료됨');
     END $d$$q$);
SELECT pg_temp.check('T73 not_found → rejected',
  (SELECT status = 'rejected' FROM hazards WHERE title = '테스트 협소'));
SELECT pg_temp.as_fail(:A, 'T74 관리자도 검증 이력 수정 불가',
  $q$UPDATE hazard_verifications SET evidence = '기록 변조 시도입니다'$q$);
SELECT pg_temp.as_fail(:A, 'T75 관리자도 검증 이력 삭제 불가',
  $q$DELETE FROM hazard_verifications$q$);
-- 제보자 본인 검증 금지: 검토자 본인 제보(T53)를 관리자가 채택 → 검토자가 검증 시도
SELECT pg_temp.as_ok(:A, 'T76 관리자: 검토자 제보 채택',
  $q$SELECT review_field_report((SELECT max(id) FROM field_reports
       WHERE reporter_id = '00000000-0000-0000-0000-00000000000b'), true, '채택')$q$);
SELECT pg_temp.as_fail(:R, 'T77 제보자 본인은 자기 제보 현장 검증 불가',
  $q$SELECT verify_hazard_on_site((SELECT hazard_id FROM field_reports
       WHERE reporter_id = '00000000-0000-0000-0000-00000000000b' AND status='approved'),
       'confirmed', 'laser_measure', current_date, 3.3, '레이저로 하단 최저점 실측함')$q$);
SELECT pg_temp.check('T78 검증 관련 변경이 audit_log에 기록',
  EXISTS (SELECT 1 FROM audit_log WHERE table_name = 'hazard_verifications'));

-- ===== 10. 현장 제보 데이터 검증 (보완 3) =====
SELECT pg_temp.as_fail(:M, 'T79 제보 위경도 뒤바뀜 거부',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, measured_value, geom)
     VALUES ('00000000-0000-0000-0000-00000000000c', 'height_limit', 3.4, ST_SetSRID(ST_MakePoint(34.95, 127.49),4326))$q$);
SELECT pg_temp.as_fail(:M, 'T80 제보 국외 좌표(0,0) 거부',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, measured_value, geom)
     VALUES ('00000000-0000-0000-0000-00000000000c', 'height_limit', 3.4, ST_SetSRID(ST_MakePoint(0, 0),4326))$q$);
SELECT pg_temp.as_fail(:M, 'T81 제보 높이 34.5(단위 오류) 거부',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, measured_value, geom)
     VALUES ('00000000-0000-0000-0000-00000000000c', 'height_limit', 34.5, ST_SetSRID(ST_MakePoint(127.49, 34.95),4326))$q$);
SELECT pg_temp.as_fail(:M, 'T82 제보 폭 270(cm 입력) 거부',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, measured_value, geom)
     VALUES ('00000000-0000-0000-0000-00000000000c', 'width_limit', 270, ST_SetSRID(ST_MakePoint(127.49, 34.95),4326))$q$);
SELECT pg_temp.as_fail(:M, 'T83 제보 중량 15000(kg 입력) 거부',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, measured_value, geom)
     VALUES ('00000000-0000-0000-0000-00000000000c', 'weight_limit', 15000, ST_SetSRID(ST_MakePoint(127.49, 34.95),4326))$q$);
SELECT pg_temp.as_fail(:M, 'T84 제한 유형 제보에 측정값 없음 거부',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, geom)
     VALUES ('00000000-0000-0000-0000-00000000000c', 'height_limit', ST_SetSRID(ST_MakePoint(127.49, 34.95),4326))$q$);
SELECT pg_temp.as_fail(:M, 'T85 값이 없어야 하는 유형(공사)에 값 거부',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, measured_value, geom)
     VALUES ('00000000-0000-0000-0000-00000000000c', 'construction', 5, ST_SetSRID(ST_MakePoint(127.49, 34.95),4326))$q$);
SELECT pg_temp.as_fail(:M, 'T86 미래 측정일 제보 거부',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, measured_value, geom, measured_on)
     VALUES ('00000000-0000-0000-0000-00000000000c', 'height_limit', 3.4, ST_SetSRID(ST_MakePoint(127.49, 34.95),4326), current_date + 3)$q$);
SELECT pg_temp.check('T87 오류 제보는 하나도 저장되지 않아 위험정보로 넘어갈 수 없음',
  NOT EXISTS (SELECT 1 FROM field_reports WHERE NOT geom_in_korea(geom)
               OR NOT hazard_value_in_range(hazard_type, measured_value)));
SELECT pg_temp.as_ok(:M, 'T88 정상 제보 (공사, 값 없음)',
  $q$INSERT INTO field_reports (reporter_id, hazard_type, geom, memo)
     VALUES ('00000000-0000-0000-0000-00000000000c', 'construction', ST_SetSRID(ST_MakePoint(127.497, 34.957),4326), '상수도 공사로 1차로 통제')$q$);

-- ===== 11. 최초 관리자 생성 절차 (보완 2) =====
SELECT pg_temp.as_count(:N, 'T89 프로필 없는 신규 가입자: 차량 0건', $q$SELECT * FROM vehicles$q$, 0);
SELECT pg_temp.as_fail(:N, 'T90 프로필 없는 신규 가입자: 본인 admin 프로필 생성 거부',
  $q$INSERT INTO profiles (user_id, display_name, role) VALUES ('00000000-0000-0000-0000-00000000000f', '자칭관리자', 'admin')$q$);
SELECT pg_temp.as_fail(:N, 'T91 프로필 없는 신규 가입자: viewer 프로필 자가 생성도 거부',
  $q$INSERT INTO profiles (user_id, display_name, role) VALUES ('00000000-0000-0000-0000-00000000000f', '자가등록', 'viewer')$q$);
SELECT pg_temp.as_fail(:V, 'T92 열람자: 다른 사용자를 admin으로 변경 거부',
  $q$DO $d$ BEGIN
       UPDATE profiles SET role = 'admin' WHERE user_id = '00000000-0000-0000-0000-00000000000c';
       IF NOT FOUND THEN RAISE EXCEPTION 'RLS로 0건'; END IF;
     END $d$$q$);
SELECT pg_temp.as_fail(:R, 'T93 검토자: 비활성 admin 계정 재활성화 거부',
  $q$DO $d$ BEGIN
       UPDATE profiles SET is_active = true WHERE user_id = '00000000-0000-0000-0000-00000000000e';
       IF NOT FOUND THEN RAISE EXCEPTION 'RLS로 0건'; END IF;
     END $d$$q$);
-- SQL Editor 시뮬레이션: postgres 권한, 로그인 사용자(JWT) 없음
DO $$ BEGIN
  PERFORM set_config('request.jwt.claim.sub', '', false);
  INSERT INTO profiles (user_id, display_name, role, is_active)
  VALUES ('00000000-0000-0000-0000-000000000010', '최초 관리자', 'admin', true);
  INSERT INTO t_results(label, passed) VALUES ('T94 SQL Editor(관리자 DB 권한)에서 최초 관리자 등록', true);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO t_results(label, passed, detail) VALUES ('T94 SQL Editor(관리자 DB 권한)에서 최초 관리자 등록', false, SQLERRM);
END $$;
SELECT pg_temp.as_ok(:F, 'T95 최초 관리자: 로그인 후 안전센터 등록 가능',
  $q$INSERT INTO stations (name) VALUES ('최초관리자 테스트 센터')$q$);
SELECT pg_temp.check('T96 최초 관리자 등록이 audit_log에 기록',
  EXISTS (SELECT 1 FROM audit_log WHERE table_name='profiles' AND record_id = '00000000-0000-0000-0000-000000000010'));
SELECT pg_temp.as_fail(NULL, 'T97 비로그인: 제보 채택 함수 호출 거부',
  $q$SELECT review_field_report(1, true, 'x')$q$);

-- ---------- 결과 ----------
\echo
\echo ======== 테스트 결과 ========
SELECT n AS "번호", CASE WHEN passed THEN '통과' ELSE '실패' END AS "결과", label AS "항목", left(coalesce(detail,''), 70) AS "상세"
  FROM t_results ORDER BY n;
SELECT count(*) FILTER (WHERE passed) AS "통과", count(*) FILTER (WHERE NOT passed) AS "실패", count(*) AS "전체" FROM t_results;
