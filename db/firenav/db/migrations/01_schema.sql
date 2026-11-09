-- =====================================================================
-- 소방차량 맞춤형 안전경로 안내 시스템 — 01. 스키마
-- 단위: 길이 m, 중량 t(톤), 좌표 WGS84(EPSG:4326)
-- 설계 원칙
--  * 출동 주소·신고 내용·대원 위치·경로 이력 테이블은 만들지 않는다 (개인정보 최소화)
--  * 현장 사진 컬럼은 두지 않는다 (시제품 제외, 보안 답변 후 결정)
--  * "확인됨(verified)" 상태는 신뢰등급 L1·L2에서만 허용 (비대칭 규칙)
-- =====================================================================
-- PostGIS는 Supabase 권장대로 extensions 스키마에 설치
-- (Supabase 문서: create extension postgis with schema "extensions")
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;
SET search_path = public, extensions;

-- ---------- 열거형 ----------
CREATE TYPE user_role AS ENUM ('admin', 'reviewer', 'member', 'viewer');
-- admin: 관리자 / reviewer: 제보 검토자 / member: 대원(제보 가능) / viewer: 열람만

CREATE TYPE trust_level AS ENUM ('L1', 'L2', 'L3', 'L4', 'L5');
-- L1 현장 실측(검증 절차 완료) / L2 관리기관 공식 / L3 공공데이터 자동
-- L4 커뮤니티(OSM)·현장 검증 전 채택 제보 / L5 추정

CREATE TYPE hazard_type AS ENUM (
  'height_limit',     -- 높이 제한 (value = 유효높이 m)
  'width_limit',      -- 폭 제한 (value = 유효폭 m)
  'weight_limit',     -- 총중량 제한 (value = t)
  'axle_limit',       -- 축하중 제한 (value = t)
  'length_limit',     -- 길이 제한 (value = m)
  'narrow_road',      -- 협소도로 (value = 유효폭 m, 모르면 NULL)
  'sharp_curve',      -- 급커브 (value = 곡률반경 m, 모르면 NULL)
  'bridge',           -- 교량 (value = 제한중량 t, 모르면 NULL)
  'tunnel',           -- 터널 (value = 유효높이 m, 모르면 NULL)
  'construction',     -- 공사·통제
  'one_way',          -- 일방통행
  'entry_difficult',  -- 소방차 진입곤란지역 (서 내부 목록)
  'other'
);

CREATE TYPE verification_status AS ENUM (
  'unverified',       -- 미검증
  'pending_review',   -- 검토 대기
  'verified',         -- 확인됨 (L1·L2만)
  'conflict',         -- 출처 간 충돌 → 판정 시 통행불가(검증대기)로 취급
  'rejected',         -- 반려
  'expired'           -- 유효기간 경과
);

CREATE TYPE travel_direction AS ENUM ('both', 'forward', 'backward');
CREATE TYPE report_status AS ENUM ('pending', 'approved', 'rejected');
CREATE TYPE conflict_status AS ENUM ('open', 'resolved');
-- report_status 'approved' = 제보 내용 채택(검토 통과). 현장 검증 완료를 뜻하지 않음

-- 현장 확인 방법
CREATE TYPE verification_method AS ENUM (
  'tape_measure',       -- 줄자 실측
  'laser_measure',      -- 레이저 거리측정기 실측
  'vehicle_trial',      -- 실제 차량 시험 통행
  'visual_inspection',  -- 육안 확인 (값 측정 없음)
  'official_document'   -- 관리기관 공식 자료 (→ L2)
);
-- 현장 확인 결과
CREATE TYPE verification_outcome AS ENUM (
  'confirmed',          -- 위험요소 확인, 측정값 기록 → verified
  'not_found',          -- 현장에 해당 위험요소 없음 → rejected
  'inconclusive'        -- 확인 불가 → 검증 대기 유지
);

-- ---------- 공통 검사 함수 (위험정보·제보·검증에 같은 규칙 적용) ----------
-- 대한민국 대략 범위 (경도 124~132, 위도 33~39)
CREATE FUNCTION geom_in_korea(g geometry) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = public, extensions AS $$
  SELECT ST_Intersects(g, ST_MakeEnvelope(124, 33, 132, 39, 4326))
$$;

-- 유형별 값 허용 범위 (NULL은 별도 규칙에서 판단)
CREATE FUNCTION hazard_value_in_range(t hazard_type, v numeric) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NULL OR CASE t
    WHEN 'height_limit' THEN v BETWEEN 1.0 AND 10.0
    WHEN 'tunnel'       THEN v BETWEEN 1.0 AND 10.0
    WHEN 'width_limit'  THEN v BETWEEN 1.0 AND 30.0
    WHEN 'narrow_road'  THEN v BETWEEN 1.0 AND 30.0
    WHEN 'weight_limit' THEN v BETWEEN 1.0 AND 100.0
    WHEN 'bridge'       THEN v BETWEEN 1.0 AND 100.0
    WHEN 'axle_limit'   THEN v BETWEEN 1.0 AND 30.0
    WHEN 'length_limit' THEN v BETWEEN 3.0 AND 50.0
    WHEN 'sharp_curve'  THEN v BETWEEN 1.0 AND 500.0
    ELSE false            -- 값이 없어야 하는 유형(공사·일방통행 등)에 값이 들어오면 오류
  END
$$;

-- 제한 유형은 값 필수
CREATE FUNCTION hazard_requires_value(t hazard_type) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT t IN ('height_limit','width_limit','weight_limit','axle_limit','length_limit')
$$;

-- ---------- 조직·사용자 ----------
CREATE TABLE stations (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name        text NOT NULL UNIQUE,                 -- 예: 순천소방서, ○○119안전센터
  location    geometry(Point, 4326),
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- 실명 대신 표시명·직위 사용 권장 (개인정보 최소화)
CREATE TABLE profiles (
  user_id      uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text NOT NULL,
  station_id   bigint REFERENCES stations(id),
  role         user_role NOT NULL DEFAULT 'viewer',
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------- 출처 ----------
CREATE TABLE sources (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name             text NOT NULL UNIQUE,            -- 예: 순천소방서 진입곤란지역 목록, OSM
  provider         text,                            -- 제공기관
  url              text,
  license          text,
  update_cycle     text,                            -- 갱신 주기 (모르면 NULL = 미확인)
  default_trust    trust_level NOT NULL,
  is_automatic     boolean NOT NULL DEFAULT false,  -- 자동 수집 여부
  notes            text,
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- ---------- 차량 ----------
-- 차종 기본 템플릿 (예: 「[표-3] 국내 소방차의 제원과 회전반경」)
-- 판정용 확정값이 아니며, 실제 차량 등록 시 출발값으로만 사용
CREATE TABLE vehicle_types (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name                     text NOT NULL UNIQUE,
  length_m                 numeric(5,2),
  body_width_m             numeric(4,2),
  height_m                 numeric(4,2),     -- 제원표 전고 (장비 포함 여부 불명일 수 있음)
  wheelbase_m              numeric(4,2),
  overhang_m               numeric(4,2),     -- 원본 표의 Of (전·후 구분 불명)
  turning_radius_m         numeric(4,2),     -- R
  inner_turning_radius_m   numeric(4,2),     -- Ri
  outer_turning_radius_m   numeric(4,2),     -- Ro
  listed_weight_t          numeric(5,2),     -- 표의 "차량 중량" (공차/총중량 불명)
  listed_weight_note       text,
  source_id                bigint REFERENCES sources(id),
  trust                    trust_level NOT NULL DEFAULT 'L3',
  created_at               timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE vehicles (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  station_id                  bigint NOT NULL REFERENCES stations(id),
  vehicle_type_id             bigint REFERENCES vehicle_types(id),
  call_sign                   text NOT NULL UNIQUE,     -- 호출명
  -- 판정에 쓰는 제원 (NULL = 미확인 → 해당 항목 판정은 "미확인")
  length_m                    numeric(5,2),
  body_width_m                numeric(4,2),             -- 차체 폭
  width_with_mirrors_m        numeric(4,2),             -- 미러 포함 폭 (폭 판정 기준)
  height_m                    numeric(4,2),             -- 제원표 전고
  max_height_measured_m       numeric(4,2),             -- 장비 포함 최고점 실측 (높이 판정 기준)
  wheelbase_m                 numeric(4,2),
  front_overhang_m            numeric(4,2),
  rear_overhang_m             numeric(4,2),
  turning_radius_m            numeric(4,2),
  inner_turning_radius_m      numeric(4,2),
  outer_turning_radius_m      numeric(4,2),
  curb_weight_t               numeric(5,2),             -- 공차 중량
  gross_weight_full_t         numeric(5,2),             -- 만재 중량 (중량 판정 기준)
  axle_loads_t                numeric(5,2)[],           -- 축별 하중, 앞축부터
  spec_source                 text,                     -- 예: 차량등록증, 제조사 제원표, 실측
  spec_trust                  trust_level NOT NULL DEFAULT 'L3',
  is_active                   boolean NOT NULL DEFAULT true,
  change_reason               text,                     -- 제원 수정 시 필수 (트리거 검사)
  created_by                  uuid REFERENCES auth.users(id),
  updated_by                  uuid REFERENCES auth.users(id),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),

  -- 입력 범위 검사: 단위 오류(cm·kg 입력 등)를 저장 단계에서 차단
  CONSTRAINT chk_length      CHECK (length_m              IS NULL OR length_m              BETWEEN 3   AND 15),
  CONSTRAINT chk_body_width  CHECK (body_width_m          IS NULL OR body_width_m          BETWEEN 1.5 AND 3.0),
  CONSTRAINT chk_mirror_w    CHECK (width_with_mirrors_m  IS NULL OR width_with_mirrors_m  BETWEEN 1.5 AND 3.5),
  CONSTRAINT chk_height      CHECK (height_m              IS NULL OR height_m              BETWEEN 1.5 AND 5.0),
  CONSTRAINT chk_max_height  CHECK (max_height_measured_m IS NULL OR max_height_measured_m BETWEEN 1.5 AND 5.0),
  CONSTRAINT chk_wheelbase   CHECK (wheelbase_m           IS NULL OR wheelbase_m           BETWEEN 2   AND 8),
  CONSTRAINT chk_turning     CHECK (turning_radius_m      IS NULL OR turning_radius_m      BETWEEN 4   AND 15),
  CONSTRAINT chk_ri_ro       CHECK (inner_turning_radius_m IS NULL OR outer_turning_radius_m IS NULL
                                    OR inner_turning_radius_m < outer_turning_radius_m),
  CONSTRAINT chk_curb        CHECK (curb_weight_t         IS NULL OR curb_weight_t         BETWEEN 1 AND 50),
  CONSTRAINT chk_gross       CHECK (gross_weight_full_t   IS NULL OR gross_weight_full_t   BETWEEN 1 AND 50),
  CONSTRAINT chk_curb_gross  CHECK (curb_weight_t IS NULL OR gross_weight_full_t IS NULL
                                    OR curb_weight_t <= gross_weight_full_t),
  CONSTRAINT chk_mirror_ge   CHECK (body_width_m IS NULL OR width_with_mirrors_m IS NULL
                                    OR body_width_m <= width_with_mirrors_m),
  CONSTRAINT chk_axles       CHECK (axle_loads_t IS NULL OR
                                    (cardinality(axle_loads_t) BETWEEN 2 AND 6
                                     AND 0.5 <= ALL(axle_loads_t) AND 15 >= ALL(axle_loads_t)))
);

CREATE TABLE vehicle_spec_history (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id   bigint NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
  old_values   jsonb NOT NULL,
  new_values   jsonb NOT NULL,
  reason       text NOT NULL,
  changed_by   uuid,
  changed_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------- 도로 위험정보 ----------
CREATE TABLE hazards (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hazard_type          hazard_type NOT NULL,
  value                numeric(6,2),            -- 단위는 hazard_type에 따라 고정 (위 주석)
  geom                 geometry(Geometry, 4326) NOT NULL,   -- Point 또는 LineString
  -- 그래프 링크 연결: 관리자가 지도에서 직접 선택 (가장 가까운 도로 자동 연결 금지)
  edge_refs            text[],                  -- 예: OSM way id + 구간 식별자
  direction            travel_direction NOT NULL DEFAULT 'both',
  grade_separated_warn boolean NOT NULL DEFAULT false,  -- 교량·터널·고가 근처 경고 확인 여부
  trust                trust_level NOT NULL,
  status               verification_status NOT NULL DEFAULT 'unverified',
  title                text NOT NULL,
  description          text,
  valid_from           date,
  valid_to             date,                    -- 공사 등 기간 한정
  last_checked_on      date,                    -- 마지막 현장·자료 확인일
  primary_source_id    bigint REFERENCES sources(id),
  source_report_id     bigint,                  -- 채택된 현장 제보에서 생성된 경우 (FK는 아래에서 추가)
  created_by           uuid REFERENCES auth.users(id),
  updated_by           uuid REFERENCES auth.users(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_geom_kind CHECK (GeometryType(geom) IN ('POINT', 'LINESTRING')),
  CONSTRAINT chk_geom_area CHECK (geom_in_korea(geom)),
  CONSTRAINT chk_limit_has_value CHECK (NOT hazard_requires_value(hazard_type) OR value IS NOT NULL),
  CONSTRAINT chk_value_range CHECK (hazard_value_in_range(hazard_type, value)),
  -- 비대칭 규칙: "확인됨"은 L1·L2에서만
  CONSTRAINT chk_verified_trust CHECK (status <> 'verified' OR trust IN ('L1','L2')),
  CONSTRAINT chk_verified_checked CHECK (status <> 'verified' OR last_checked_on IS NOT NULL),
  CONSTRAINT chk_valid_period CHECK (valid_from IS NULL OR valid_to IS NULL OR valid_from <= valid_to)
);
CREATE INDEX hazards_geom_gix ON hazards USING gist (geom);
CREATE INDEX hazards_geog_gix ON hazards USING gist ((geom::geography));
CREATE INDEX hazards_status_idx ON hazards (status);

-- 한 위험정보의 여러 출처 원본값 (충돌 검출·출처 기록)
CREATE TABLE hazard_sources (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hazard_id           bigint REFERENCES hazards(id) ON DELETE CASCADE,
  source_id           bigint NOT NULL REFERENCES sources(id),
  original_record_id  text NOT NULL,          -- 원본 데이터의 레코드 식별자
  original_value      numeric(6,2),
  original_payload    jsonb,                  -- 원본 레코드 그대로
  collected_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_source_record UNIQUE (source_id, original_record_id)  -- 중복 수집 방지
);

CREATE TABLE ingest_runs (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_id       bigint NOT NULL REFERENCES sources(id),
  started_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz,
  inserted_count  int NOT NULL DEFAULT 0,
  updated_count   int NOT NULL DEFAULT 0,
  skipped_count   int NOT NULL DEFAULT 0,
  error_message   text
);

CREATE TABLE conflicts (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hazard_id     bigint NOT NULL REFERENCES hazards(id) ON DELETE CASCADE,
  description   text NOT NULL,
  status        conflict_status NOT NULL DEFAULT 'open',
  resolved_by   uuid REFERENCES auth.users(id),
  resolved_at   timestamptz,
  resolution    text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------- 현장 제보 (사진 없음: 시제품 제외) ----------
CREATE TABLE field_reports (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reporter_id    uuid NOT NULL REFERENCES auth.users(id),
  hazard_type    hazard_type NOT NULL,
  measured_value numeric(6,2),
  geom           geometry(Point, 4326) NOT NULL,
  memo           text,
  measured_on    date NOT NULL DEFAULT current_date,
  status         report_status NOT NULL DEFAULT 'pending',
  reviewer_id    uuid REFERENCES auth.users(id),
  review_note    text,
  reviewed_at    timestamptz,
  hazard_id      bigint REFERENCES hazards(id),   -- 채택 시 생성된 위험정보 (검증 대기 상태)
  created_at     timestamptz NOT NULL DEFAULT now(),

  -- 제보 단계에서 좌표·단위 오류 차단 (승인 과정에서 오류값이 위험정보로 넘어가지 않게)
  CONSTRAINT chk_report_geom_area CHECK (geom_in_korea(geom)),
  CONSTRAINT chk_report_value_range CHECK (hazard_value_in_range(hazard_type, measured_value)),
  CONSTRAINT chk_report_limit_has_value CHECK (NOT hazard_requires_value(hazard_type) OR measured_value IS NOT NULL)
  -- measured_on 미래 날짜 금지는 트리거에서 검사 (CHECK에는 현재 날짜를 쓰지 않음)
);
ALTER TABLE hazards ADD CONSTRAINT fk_hazard_source_report
  FOREIGN KEY (source_report_id) REFERENCES field_reports(id);

-- ---------- 현장 검증 이력 (누가·언제·어떤 근거로) ----------
-- 클라이언트는 직접 쓸 수 없고 verify_hazard_on_site() 함수로만 기록. 수정·삭제 불가
CREATE TABLE hazard_verifications (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hazard_id       bigint NOT NULL REFERENCES hazards(id) ON DELETE CASCADE,
  outcome         verification_outcome NOT NULL,
  method          verification_method NOT NULL,
  verified_on     date NOT NULL,                 -- 현장 확인 날짜
  measured_value  numeric(6,2),                  -- 현장 측정값
  evidence        text NOT NULL,                 -- 근거: 측정 위치·방법·참고자료
  verified_by     uuid NOT NULL REFERENCES auth.users(id),
  previous_value  numeric(6,2),
  previous_status verification_status NOT NULL,
  previous_trust  trust_level NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_evidence_len CHECK (length(btrim(evidence)) >= 10)
);
CREATE INDEX hazard_verifications_hazard_idx ON hazard_verifications (hazard_id, created_at DESC);

-- ---------- 변경 이력 (모든 주요 테이블) ----------
CREATE TABLE audit_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  table_name  text NOT NULL,
  record_id   text NOT NULL,
  action      text NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
  old_data    jsonb,
  new_data    jsonb,
  actor       uuid,
  at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_table_record_idx ON audit_log (table_name, record_id);
