-- =====================================================================
-- 04. 차종 기본 템플릿 — 「[표-3] 국내 소방차의 제원(Specification)과 회전반경」
-- 원본 문서명·발행기관 [미확인] → 신뢰등급 L3(참고값)
-- "차량 중량"은 공차/총중량 불명 → listed_weight_t에만 저장, 판정에 사용하지 않음
-- 열 "t"는 의미 미확인 → 저장하지 않음
-- =====================================================================
INSERT INTO sources (name, provider, default_trust, is_automatic, notes)
VALUES ('[표-3] 국내 소방차의 제원과 회전반경', '미확인', 'L3', false,
        '2026-11-09 사용자 제공 이미지. 원본 문서명·발행기관·발행연도 미확인');

INSERT INTO vehicle_types (name, length_m, body_width_m, height_m, wheelbase_m, overhang_m,
  turning_radius_m, inner_turning_radius_m, outer_turning_radius_m,
  listed_weight_t, listed_weight_note, source_id, trust)
SELECT v.name, v.len, v.w, v.h, v.wb, v.oh, v.r, v.ri, v.ro, v.wt, v.note,
       (SELECT id FROM sources WHERE name = '[표-3] 국내 소방차의 제원과 회전반경'), 'L3'
FROM (VALUES
  ('52m 고가사다리차',   11.50, 2.49, 3.95, 5.91, 1.5, 9.5, 5.2, 10.7, 26.5, NULL),
  ('46m 고가사다리차',   11.40, 2.49, 3.95, 5.91, 1.5, 9.5, 5.2, 10.7, 23.5, NULL),
  ('32m 고가사다리차',   11.20, 2.49, 3.90, 5.91, 1.5, 9.5, 5.2, 10.7, 21.0, NULL),
  ('61.5m 굴절차',       12.00, 2.50, 3.70, 6.50, 1.6, 9.7, 5.0, 11.0, 40.0, NULL),
  ('35.0m 굴절차',       10.76, 2.49, 3.85, 6.20, 1.4, 9.6, 5.1, 10.7, 24.5, NULL),
  ('27.0m 굴절차',       11.68, 2.49, 3.85, 5.80, 1.4, 9.5, 5.3, 10.6, 21.4, NULL),
  ('18.0m 굴절차',       10.08, 2.48, 3.75, 5.70, 1.2, 9.5, 5.4, 10.5, 18.0, '원본 14~18T (상한값 저장)'),
  ('대형 소방펌프차',     8.63, 2.49, 3.35, 4.64, 1.3, 9.0, 5.5,  9.9, 13.1, NULL),
  ('중형 소방펌프차',     7.60, 2.23, 2.85, 4.25, 1.2, 7.7, 4.4,  8.6,  8.5, NULL),
  ('소형 소방펌프차',     6.12, 2.18, 2.15, 3.55, 1.2, 6.9, 3.9,  7.7,  3.9, NULL)
) AS v(name, len, w, h, wb, oh, r, ri, ro, wt, note);

UPDATE vehicle_types SET listed_weight_note = coalesce(listed_weight_note || '; ', '') || '공차/총중량 불명';
