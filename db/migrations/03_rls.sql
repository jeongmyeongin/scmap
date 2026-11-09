-- =====================================================================
-- 03. 행 수준 보안 (RLS)
-- anon(비로그인): 아무것도 볼 수 없음
-- viewer: 열람 / member: 열람 + 현장 제보 / reviewer: + 위험정보 편집·제보 검토 / admin: 전체
-- 주의(Supabase 문서 확인): 새 함수는 기본적으로 모든 역할이 호출 가능 → 쓰기 함수는 명시적으로 회수
-- =====================================================================
SET search_path = public, extensions;

-- 테이블 권한 (실제 허용 범위는 아래 정책이 결정)
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON
  stations, profiles, sources, vehicle_types, vehicles, hazards, hazard_sources,
  ingest_runs, conflicts, field_reports TO authenticated;
GRANT SELECT ON vehicle_spec_history, audit_log, hazards_effective, hazard_verifications TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON FUNCTION review_field_report(bigint, boolean, text),
                         verify_hazard_on_site(bigint, verification_outcome, verification_method, date, numeric, text),
                         create_vehicle_from_type(bigint, bigint, text),
                         hazards_near(double precision, double precision, double precision),
                         app_current_role(), app_has_role(user_role[]) TO authenticated;
REVOKE EXECUTE ON FUNCTION review_field_report(bigint, boolean, text),
                           verify_hazard_on_site(bigint, verification_outcome, verification_method, date, numeric, text),
                           create_vehicle_from_type(bigint, bigint, text) FROM PUBLIC, anon;

ALTER TABLE stations             ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles             ENABLE ROW LEVEL SECURITY;
ALTER TABLE sources              ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_types        ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicles             ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_spec_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE hazards              ENABLE ROW LEVEL SECURITY;
ALTER TABLE hazard_sources       ENABLE ROW LEVEL SECURITY;
ALTER TABLE ingest_runs          ENABLE ROW LEVEL SECURITY;
ALTER TABLE conflicts            ENABLE ROW LEVEL SECURITY;
ALTER TABLE field_reports        ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log            ENABLE ROW LEVEL SECURITY;
ALTER TABLE hazard_verifications ENABLE ROW LEVEL SECURITY;

-- 열람: 활성 사용자 전원
CREATE POLICY read_all ON stations             FOR SELECT TO authenticated USING (app_current_role() IS NOT NULL);
CREATE POLICY read_all ON sources              FOR SELECT TO authenticated USING (app_current_role() IS NOT NULL);
CREATE POLICY read_all ON vehicle_types        FOR SELECT TO authenticated USING (app_current_role() IS NOT NULL);
CREATE POLICY read_all ON vehicles             FOR SELECT TO authenticated USING (app_current_role() IS NOT NULL);
CREATE POLICY read_all ON vehicle_spec_history FOR SELECT TO authenticated USING (app_current_role() IS NOT NULL);
CREATE POLICY read_all ON hazards              FOR SELECT TO authenticated USING (app_current_role() IS NOT NULL);
CREATE POLICY read_all ON hazard_sources       FOR SELECT TO authenticated USING (app_current_role() IS NOT NULL);
CREATE POLICY read_all ON conflicts            FOR SELECT TO authenticated USING (app_current_role() IS NOT NULL);
CREATE POLICY read_all ON hazard_verifications FOR SELECT TO authenticated USING (app_current_role() IS NOT NULL);
-- hazard_verifications 쓰기 정책 없음: verify_hazard_on_site()로만 기록, 수정·삭제 불가

-- 관리자 전용 쓰기
CREATE POLICY admin_write ON stations      FOR ALL TO authenticated USING (app_has_role('admin')) WITH CHECK (app_has_role('admin'));
CREATE POLICY admin_write ON sources       FOR ALL TO authenticated USING (app_has_role('admin')) WITH CHECK (app_has_role('admin'));
CREATE POLICY admin_write ON vehicle_types FOR ALL TO authenticated USING (app_has_role('admin')) WITH CHECK (app_has_role('admin'));
CREATE POLICY admin_write ON vehicles      FOR ALL TO authenticated USING (app_has_role('admin')) WITH CHECK (app_has_role('admin'));
CREATE POLICY admin_read  ON ingest_runs   FOR SELECT TO authenticated USING (app_has_role('admin'));
CREATE POLICY admin_read  ON audit_log     FOR SELECT TO authenticated USING (app_has_role('admin'));
-- ingest_runs 쓰기는 수집 작업(service_role, RLS 우회)만. audit_log 쓰기는 트리거만.

-- 위험정보: 검토자·관리자 편집, 삭제는 관리자
CREATE POLICY editor_insert ON hazards FOR INSERT TO authenticated WITH CHECK (app_has_role('admin','reviewer'));
CREATE POLICY editor_update ON hazards FOR UPDATE TO authenticated USING (app_has_role('admin','reviewer')) WITH CHECK (app_has_role('admin','reviewer'));
CREATE POLICY admin_delete  ON hazards FOR DELETE TO authenticated USING (app_has_role('admin'));
CREATE POLICY editor_write  ON hazard_sources FOR ALL TO authenticated USING (app_has_role('admin','reviewer')) WITH CHECK (app_has_role('admin','reviewer'));
CREATE POLICY editor_write  ON conflicts      FOR ALL TO authenticated USING (app_has_role('admin','reviewer')) WITH CHECK (app_has_role('admin','reviewer'));

-- 프로필: 본인 또는 관리자 열람, 본인은 표시명만 수정(트리거가 역할 변경 차단), 생성·삭제는 관리자
CREATE POLICY self_or_admin_read ON profiles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR app_has_role('admin'));
CREATE POLICY self_or_admin_update ON profiles FOR UPDATE TO authenticated
  USING (user_id = auth.uid() OR app_has_role('admin'))
  WITH CHECK (user_id = auth.uid() OR app_has_role('admin'));
CREATE POLICY admin_insert ON profiles FOR INSERT TO authenticated WITH CHECK (app_has_role('admin'));
CREATE POLICY admin_delete ON profiles FOR DELETE TO authenticated USING (app_has_role('admin'));

-- 현장 제보: 대원 이상 본인 명의로 작성, 본인 것 또는 검토자·관리자 열람
-- 승인·반려는 review_field_report() 함수로만 (직접 UPDATE 정책 없음)
CREATE POLICY member_insert ON field_reports FOR INSERT TO authenticated
  WITH CHECK (app_has_role('admin','reviewer','member') AND reporter_id = auth.uid() AND status = 'pending');
CREATE POLICY own_or_reviewer_read ON field_reports FOR SELECT TO authenticated
  USING (reporter_id = auth.uid() OR app_has_role('admin','reviewer'));
CREATE POLICY own_pending_delete ON field_reports FOR DELETE TO authenticated
  USING (reporter_id = auth.uid() AND status = 'pending');
