# 연결 방법 (GitHub → Supabase → 배포)

순서대로 진행한다. 각 단계에서 **결제수단 입력을 요구하면 중단하고 알린다** (0원 원칙).

## 1. GitHub에 올리기 (코딩 도구 없이 웹에서)

1. github.com 가입 (무료 계정).
2. 오른쪽 위 **+ → New repository**.
3. Repository name: `firenav` (원하는 이름 가능).
4. **Private**(비공개) 선택을 권장한다. 기관 관련 프로젝트이고 아직 승인 전이기 때문이다 [판단].
5. "Add a README file"은 **체크하지 않는다** (이미 있음). **Create repository**.
6. 새 저장소 화면에서 **uploading an existing file** 링크를 누른다.
7. 내려받은 `firenav-repo.zip`의 압축을 풀고, `firenav` 폴더 **안의 내용물 전부**(README.md, SETUP.md, .gitignore, db 폴더)를 끌어다 놓는다.
   - `.gitignore`처럼 점으로 시작하는 파일은 운영체제에서 숨김 파일로 보일 수 있다. 숨김 파일 표시를 켜고 함께 올린다.
8. 아래 **Commit changes**를 누른다.
9. 확인: 저장소 첫 화면에 README 내용과 `db` 폴더가 보이면 완료.

비공개 저장소는 GitHub Actions 무료 사용량이 월 한도 안에서만 동작하고, 결제수단이 없으면 소진 시 차단된다(과금 아님) [확인: GitHub 공식 문서]. 지금 단계에서는 Actions를 쓰지 않는다.

## 2. Supabase 연결 (DB 생성)

정보보안 답변 전에는 **가상·공개 데이터만** 넣는다 (A안 적용 조건).

1. supabase.com 가입 → **New project**.
2. Region: **Northeast Asia (Seoul)**, Plan: **Free**.
3. Database password는 강하게 정하고 **본인만 아는 곳에 보관**한다. 채팅·GitHub에 올리지 않는다.
4. 프로젝트 생성 후 **Database → Extensions**에서 `postgis`를 검색해 활성화한다. 스키마는 기본값 `extensions` 그대로 둔다.
5. **SQL Editor**에서 아래 파일 내용을 하나씩 붙여넣고 실행한다 (순서 중요):
   1. `db/migrations/01_schema.sql`
   2. `db/migrations/02_functions.sql`
   3. `db/migrations/03_rls.sql`
   4. `db/migrations/04_seed_vehicle_types.sql`
   - `db/local/00_supabase_shim.sql`과 `db/tests/`는 **실행하지 않는다**.
6. 최초 관리자 등록: `db/README.md`의 "최초 관리자 등록" 절차대로 진행한다.
7. `db/supabase/precheck.sql`을 실행해 12개 항목의 "판정"을 확인한다.
8. 결과 화면(또는 오류 메시지)을 캡처해 공유한다. 그 결과로 "실제 Supabase 테스트 결과"를 기록한다.

하지 말 것:
- **service_role 키**를 어디에도 붙여넣지 않는다 (RLS를 우회하는 키).
- 실제 차량 제원·대원 실명 계정을 정보보안 답변 전에 입력하지 않는다.

## 3. 카카오 앱 만들기 (지도 키 발급)

1. developers.kakao.com 로그인 → **내 애플리케이션 → 애플리케이션 추가하기**. 앱 이름 예: `firenav-시제품`. 이 프로젝트 전용으로 새로 만든다 (쿼터는 앱 단위 [고객센터]).
2. 앱 화면의 **앱 키**에서 **JavaScript 키**를 복사해 둔다. REST API 키·Admin 키는 쓰지 않는다.
3. **플랫폼 → Web → 사이트 도메인**에 다음을 등록한다 (메뉴 이름 [요확인]):
   - `http://localhost:3000` (직접 실행할 때만)
   - Cloudflare 배포 주소 (4번에서 생기는 `https://프로젝트이름.pages.dev`) — 배포 후 추가
4. 카카오맵 사용 설정이 별도로 있으면 켠다 [요확인: 앱 설정에서 카카오맵 활성화가 필요한지].
5. **유료 사용 설정이 OFF인지 확인한다.** 비즈월렛·결제 카드는 등록하지 않는다.

## 4. Cloudflare Pages 배포 (GitHub 연결)

먼저 이번 3단계 파일(`web` 폴더, 수정된 `README.md`·`SETUP.md`·`.gitignore`)을 GitHub 저장소에 올린다. 기존 파일과 이름이 같으면 덮어쓴다.

1. dash.cloudflare.com 가입 → **Workers & Pages → Create → Pages → Connect to Git** (메뉴 이름 [요확인]).
2. GitHub 계정을 연결하고 `firenav` 저장소만 선택한다 (모든 저장소 접근 허용은 하지 않음).
3. 빌드 설정:

| 항목 | 값 |
| --- | --- |
| Framework preset | Next.js (Static HTML Export) — 목록에 없으면 None |
| Root directory | `web` |
| Build command | `npm run build` |
| Build output directory | `out` |
| 환경 변수 `NEXT_PUBLIC_KAKAO_JS_KEY` | 카카오 JavaScript 키 |
| 환경 변수 `NODE_VERSION` | `22` |

4. **Save and Deploy**. 빌드가 끝나면 `https://프로젝트이름.pages.dev` 주소가 생긴다.
5. 그 주소를 카카오 앱의 사이트 도메인(3-3)에 추가한다. 추가하기 전에는 지도가 뜨지 않는다.
6. 휴대폰으로 주소를 열어 확인한다: 지도 표시, 위치 권한 허용 후 파란 점, "순천시 장명로 30" 주소 검색, 목적지로 지정.
7. 화면 캡처나 오류 메시지를 공유한다. 그 결과로 "실제 환경 검증"을 기록한다.

Cloudflare 가입·연결 중 결제수단을 요구하면 멈추고 알린다. Vercel을 쓰려면 무료(Hobby) 요금제의 기관 업무 이용 조건을 먼저 확인해야 한다 [미확인].

## 5. Supabase는 4단계 전에 연결

2번 순서 그대로 진행하면 된다. 3단계 웹앱은 아직 DB를 쓰지 않는다.
