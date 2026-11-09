#!/usr/bin/env bash
# 로컬 PostgreSQL + PostGIS에 스키마를 새로 만들고 테스트를 실행한다.
# 사용법: ./run_tests.sh   (postgres 사용자 권한 필요)
set -euo pipefail
cd "$(dirname "$0")"
DB=firenav_test
PSQL="psql -v ON_ERROR_STOP=1 -q -X"

su postgres -c "dropdb --if-exists $DB && createdb $DB"
for f in local/00_supabase_shim.sql migrations/01_schema.sql migrations/02_functions.sql \
         migrations/03_rls.sql migrations/04_seed_vehicle_types.sql; do
  echo ">> $f"
  su postgres -c "$PSQL -d $DB -f $PWD/$f"
done
echo ">> tests/test_all.sql"
su postgres -c "$PSQL -d $DB -f $PWD/tests/test_all.sql"
