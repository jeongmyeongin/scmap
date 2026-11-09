-- =====================================================================
-- 02. 함수·트리거
-- =====================================================================
SET search_path = public, extensions;

-- 현재 사용자의 역할 (비활성 사용자는 NULL → 아무 권한 없음)
CREATE OR REPLACE FUNCTION app_current_role() RETURNS user_role
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT role FROM profiles WHERE user_id = auth.uid() AND is_active
$$;

CREATE OR REPLACE FUNCTION app_has_role(VARIADIC roles user_role[]) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT coalesce(app_current_role() = ANY(roles), false)
$$;

-- ---------- updated_at / 작성자 자동 기록 ----------
CREATE OR REPLACE FUNCTION trg_touch() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  IF TG_TABLE_NAME IN ('vehicles','hazards') THEN
    NEW.updated_by := auth.uid();
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER touch_profiles BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION trg_touch();
CREATE TRIGGER touch_vehicles BEFORE UPDATE ON vehicles FOR EACH ROW EXECUTE FUNCTION trg_touch();
CREATE TRIGGER touch_hazards  BEFORE UPDATE ON hazards  FOR EACH ROW EXECUTE FUNCTION trg_touch();

CREATE OR REPLACE FUNCTION trg_set_creator() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.created_by := coalesce(NEW.created_by, auth.uid());
  RETURN NEW;
END $$;
CREATE TRIGGER creator_vehicles BEFORE INSERT ON vehicles FOR EACH ROW EXECUTE FUNCTION trg_set_creator();
CREATE TRIGGER creator_hazards  BEFORE INSERT ON hazards  FOR EACH ROW EXECUTE FUNCTION trg_set_creator();

-- ---------- 차량 제원 이력: 제원이 바뀌면 사유 필수 + 이력 저장 ----------
CREATE OR REPLACE FUNCTION trg_vehicle_spec_history() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  spec_cols text[] := ARRAY['length_m','body_width_m','width_with_mirrors_m','height_m',
    'max_height_measured_m','wheelbase_m','front_overhang_m','rear_overhang_m',
    'turning_radius_m','inner_turning_radius_m','outer_turning_radius_m',
    'curb_weight_t','gross_weight_full_t','axle_loads_t','spec_source','spec_trust'];
  o jsonb := to_jsonb(OLD);
  n jsonb := to_jsonb(NEW);
  old_part jsonb := '{}';
  new_part jsonb := '{}';
  c text;
BEGIN
  FOREACH c IN ARRAY spec_cols LOOP
    IF (o -> c) IS DISTINCT FROM (n -> c) THEN
      old_part := old_part || jsonb_build_object(c, o -> c);
      new_part := new_part || jsonb_build_object(c, n -> c);
    END IF;
  END LOOP;

  IF new_part <> '{}' THEN
    IF NEW.change_reason IS NULL OR btrim(NEW.change_reason) = ''
       OR NEW.change_reason IS NOT DISTINCT FROM OLD.change_reason THEN
      RAISE EXCEPTION '차량 제원 수정에는 새 수정 사유(change_reason)가 필요합니다'
        USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO vehicle_spec_history (vehicle_id, old_values, new_values, reason, changed_by)
    VALUES (NEW.id, old_part, new_part, NEW.change_reason, auth.uid());
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER vehicle_spec_history BEFORE UPDATE ON vehicles
  FOR EACH ROW EXECUTE FUNCTION trg_vehicle_spec_history();

-- ---------- 공통 변경 이력 (audit_log) ----------
CREATE OR REPLACE FUNCTION trg_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, actor)
  VALUES (
    TG_TABLE_NAME,
    coalesce((to_jsonb(NEW) ->> 'id'), (to_jsonb(OLD) ->> 'id'),
             (to_jsonb(NEW) ->> 'user_id'), (to_jsonb(OLD) ->> 'user_id')),
    TG_OP,
    CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
    CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END,
    auth.uid());
  RETURN coalesce(NEW, OLD);
END $$;

CREATE TRIGGER audit_stations      AFTER INSERT OR UPDATE OR DELETE ON stations      FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_profiles      AFTER INSERT OR UPDATE OR DELETE ON profiles      FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_sources       AFTER INSERT OR UPDATE OR DELETE ON sources       FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_vehicle_types AFTER INSERT OR UPDATE OR DELETE ON vehicle_types FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_vehicles      AFTER INSERT OR UPDATE OR DELETE ON vehicles      FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_hazards       AFTER INSERT OR UPDATE OR DELETE ON hazards       FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_conflicts     AFTER INSERT OR UPDATE OR DELETE ON conflicts     FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_field_reports AFTER INSERT OR UPDATE OR DELETE ON field_reports FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- ---------- 사용자는 자기 역할·소속·활성 여부를 바꿀 수 없음 ----------
CREATE OR REPLACE FUNCTION trg_profile_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT app_has_role('admin')
     AND (NEW.role IS DISTINCT FROM OLD.role
          OR NEW.station_id IS DISTINCT FROM OLD.station_id
          OR NEW.is_active IS DISTINCT FROM OLD.is_active) THEN
    RAISE EXCEPTION '역할·소속·활성 여부는 관리자만 변경할 수 있습니다'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER profile_guard BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION trg_profile_guard();

-- ---------- 차종 템플릿에서 차량 생성 ----------
-- 템플릿 값은 L3(참고값)로 복사. 만재 중량은 표의 중량이 공차/총중량 불명이므로 복사하지 않음
CREATE OR REPLACE FUNCTION create_vehicle_from_type(p_type_id bigint, p_station_id bigint, p_call_sign text)
RETURNS bigint
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, extensions AS $$
DECLARE
  t vehicle_types;
  new_id bigint;
BEGIN
  SELECT * INTO t FROM vehicle_types WHERE id = p_type_id;
  IF NOT FOUND THEN RAISE EXCEPTION '차종 템플릿이 없습니다: %', p_type_id; END IF;
  INSERT INTO vehicles (station_id, vehicle_type_id, call_sign, length_m, body_width_m, height_m,
    wheelbase_m, turning_radius_m, inner_turning_radius_m, outer_turning_radius_m,
    spec_source, spec_trust)
  VALUES (p_station_id, p_type_id, p_call_sign, t.length_m, t.body_width_m, t.height_m,
    t.wheelbase_m, t.turning_radius_m, t.inner_turning_radius_m, t.outer_turning_radius_m,
    '차종 템플릿: ' || t.name, 'L3')
  RETURNING id INTO new_id;
  RETURN new_id;
END $$;

-- ---------- 현장 제보 검토 (검토자·관리자) ----------
-- 채택(p_approve = true) 시: L4·검증 대기(pending_review) 위험정보 생성. verified가 되지 않음
-- verified 전환은 verify_hazard_on_site()의 별도 현장 확인 절차로만 가능
CREATE OR REPLACE FUNCTION review_field_report(p_report_id bigint, p_approve boolean, p_note text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  r field_reports;
  h_id bigint;
BEGIN
  IF NOT app_has_role('admin', 'reviewer') THEN
    RAISE EXCEPTION '제보 검토 권한이 없습니다' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT * INTO r FROM field_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '제보가 없습니다: %', p_report_id; END IF;
  IF r.status <> 'pending' THEN RAISE EXCEPTION '이미 처리된 제보입니다'; END IF;
  IF r.reporter_id = auth.uid() THEN
    RAISE EXCEPTION '본인 제보는 본인이 채택할 수 없습니다' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_approve THEN
    INSERT INTO hazards (hazard_type, value, geom, trust, status, title, description,
                         source_report_id, created_by)
    VALUES (r.hazard_type, r.measured_value, r.geom, 'L4', 'pending_review',
            '현장 제보 #' || r.id || ' (현장 검증 대기)', r.memo, r.id, auth.uid())
    RETURNING id INTO h_id;
  END IF;

  UPDATE field_reports
     SET status = CASE WHEN p_approve THEN 'approved'::report_status ELSE 'rejected'::report_status END,
         reviewer_id = auth.uid(), review_note = p_note, reviewed_at = now(), hazard_id = h_id
   WHERE id = p_report_id;
  RETURN h_id;
END $$;

-- ---------- 현장 검증 (검토자·관리자) ----------
-- 누가(auth.uid), 언제(verified_on), 어떤 근거(method, evidence, measured_value)를 hazard_verifications에 남김
-- confirmed  → 측정값 반영, L1(관리기관 자료는 L2)·verified
-- not_found  → rejected
-- inconclusive → pending_review 유지
CREATE OR REPLACE FUNCTION verify_hazard_on_site(
  p_hazard_id bigint, p_outcome verification_outcome, p_method verification_method,
  p_verified_on date, p_measured_value numeric, p_evidence text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  h hazards;
  v_id bigint;
  reporter uuid;
BEGIN
  IF NOT app_has_role('admin', 'reviewer') THEN
    RAISE EXCEPTION '현장 검증 권한이 없습니다' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT * INTO h FROM hazards WHERE id = p_hazard_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '위험정보가 없습니다: %', p_hazard_id; END IF;
  IF p_verified_on IS NULL OR p_verified_on > current_date THEN
    RAISE EXCEPTION '현장 확인 날짜가 없거나 미래입니다' USING ERRCODE = 'check_violation';
  END IF;
  -- 제보자 본인은 자기 제보를 현장 검증할 수 없음
  SELECT reporter_id INTO reporter FROM field_reports WHERE id = h.source_report_id;
  IF reporter IS NOT NULL AND reporter = auth.uid() THEN
    RAISE EXCEPTION '제보자 본인은 해당 제보를 현장 검증할 수 없습니다' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_outcome = 'confirmed' THEN
    IF hazard_requires_value(h.hazard_type) AND p_measured_value IS NULL THEN
      RAISE EXCEPTION '제한 유형은 현장 측정값이 필요합니다' USING ERRCODE = 'check_violation';
    END IF;
    IF p_method = 'visual_inspection' AND hazard_requires_value(h.hazard_type) THEN
      RAISE EXCEPTION '제한 유형은 육안 확인만으로 검증할 수 없습니다 (실측 필요)' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT hazard_value_in_range(h.hazard_type, p_measured_value) THEN
      RAISE EXCEPTION '측정값이 허용 범위를 벗어났습니다 (단위 확인): %', p_measured_value USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  INSERT INTO hazard_verifications (hazard_id, outcome, method, verified_on, measured_value, evidence,
                                    verified_by, previous_value, previous_status, previous_trust)
  VALUES (h.id, p_outcome, p_method, p_verified_on, p_measured_value, p_evidence,
          auth.uid(), h.value, h.status, h.trust)
  RETURNING id INTO v_id;

  IF p_outcome = 'confirmed' THEN
    UPDATE hazards
       SET value = CASE WHEN p_measured_value IS NOT NULL THEN p_measured_value ELSE value END,
           trust = CASE WHEN p_method = 'official_document' THEN 'L2'::trust_level ELSE 'L1'::trust_level END,
           status = 'verified', last_checked_on = p_verified_on
     WHERE id = h.id;
  ELSIF p_outcome = 'not_found' THEN
    UPDATE hazards SET status = 'rejected', last_checked_on = p_verified_on WHERE id = h.id;
  ELSE
    UPDATE hazards SET status = 'pending_review' WHERE id = h.id AND status <> 'verified';
  END IF;
  RETURN v_id;
END $$;

-- ---------- verified 우회 차단 ----------
-- verified 전환·verified 상태에서 핵심값 변경은 같은 트랜잭션에서 기록된 현장 검증 이력이 있어야만 허용
-- (hazard_verifications는 클라이언트가 직접 쓸 수 없으므로 우회 불가)
CREATE OR REPLACE FUNCTION trg_hazard_verified_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF NEW.status <> 'verified' THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    RAISE EXCEPTION '위험정보는 확인됨(verified) 상태로 바로 등록할 수 없습니다. 등록 후 현장 검증 절차를 거치세요'
      USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.status = 'verified'
     AND NEW.value IS NOT DISTINCT FROM OLD.value
     AND NEW.trust = OLD.trust
     AND NEW.hazard_type = OLD.hazard_type
     AND ST_Equals(NEW.geom, OLD.geom)
     AND NEW.last_checked_on IS NOT DISTINCT FROM OLD.last_checked_on THEN
    RETURN NEW;   -- 설명·제목 등 부가 정보만 수정
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM hazard_verifications v
     WHERE v.hazard_id = NEW.id AND v.outcome = 'confirmed'
       AND v.created_at = now()                       -- 같은 트랜잭션에서 기록됨
       AND v.verified_on = NEW.last_checked_on
       AND (v.measured_value IS NULL OR v.measured_value = NEW.value)) THEN
    RAISE EXCEPTION '확인됨(verified) 전환·핵심값 수정은 현장 검증 절차(verify_hazard_on_site)로만 가능합니다'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER hazard_verified_guard BEFORE INSERT OR UPDATE ON hazards
  FOR EACH ROW EXECUTE FUNCTION trg_hazard_verified_guard();

-- ---------- 현장 제보: 미래 측정일 금지 ----------
CREATE OR REPLACE FUNCTION trg_report_date_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.measured_on > current_date THEN
    RAISE EXCEPTION '측정일이 미래입니다: %', NEW.measured_on USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER report_date_guard BEFORE INSERT OR UPDATE ON field_reports
  FOR EACH ROW EXECUTE FUNCTION trg_report_date_guard();

CREATE TRIGGER audit_hazard_verifications AFTER INSERT OR UPDATE OR DELETE ON hazard_verifications
  FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- ---------- 판정 엔진이 읽는 위험정보 뷰 ----------
-- 기간이 끝난 항목은 expired, 미해결 충돌이 있으면 conflict로 보이게 함
CREATE OR REPLACE VIEW hazards_effective WITH (security_invoker = true) AS
SELECT h.*,
  CASE
    WHEN h.valid_to IS NOT NULL AND h.valid_to < current_date THEN 'expired'::verification_status
    WHEN EXISTS (SELECT 1 FROM conflicts c WHERE c.hazard_id = h.id AND c.status = 'open')
      THEN 'conflict'::verification_status
    ELSE h.status
  END AS effective_status
FROM hazards h
WHERE h.status <> 'rejected';

-- 지점 반경 검색 (m)
CREATE OR REPLACE FUNCTION hazards_near(p_lon double precision, p_lat double precision, p_radius_m double precision)
RETURNS SETOF hazards_effective
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public, extensions AS $$
  SELECT * FROM hazards_effective
   WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)::geography, p_radius_m)
$$;
