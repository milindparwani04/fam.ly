#!/usr/bin/env bash
# P09-4 restore rehearsal: restore a backup into the LOCAL Supabase stack, verify row counts against
# the .counts file written at backup time, then wipe the local database again (real family data
# must not linger in the development database).
# Usage: tools/ops/restore-rehearsal.sh backups/famly-<stamp>.dump
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: keep container paths as-is
cd "$(dirname "$0")/../.."
DUMP=${1:?usage: restore-rehearsal.sh backups/<file>.dump}
COUNTS="${DUMP%.dump}.counts"
DB=supabase_db_famly

echo "1/5 fresh local schema from migrations"
pnpm exec supabase db reset >/dev/null 2>&1

echo "2/5 clear rows that migrations/seed create, so restored rows don't collide"
docker exec -i "$DB" psql -U postgres -q -v ON_ERROR_STOP=1 <<'SQL'
truncate app.config, app.signup_allowlist, app.feature_flag;
SQL

echo "3/5 restore data (triggers disabled so no notifications or prompts are generated)"
docker cp "$DUMP" "$DB:/tmp/restore.dump"
docker exec "$DB" pg_restore -U supabase_admin -d postgres --data-only --disable-triggers --no-owner /tmp/restore.dump
docker exec "$DB" rm /tmp/restore.dump

echo "4/5 verify row counts"
FAIL=0
while read -r table expected; do
  actual=$(docker exec "$DB" psql -U postgres -tA -c "select count(*) from $table")
  if [ "$actual" != "$expected" ]; then echo "  MISMATCH $table: backup $expected, restored $actual"; FAIL=1; fi
done < "$COUNTS"
[ $FAIL = 0 ] && echo "  all $(wc -l < "$COUNTS") tables match"

echo "5/5 wipe local copy"
pnpm exec supabase db reset >/dev/null 2>&1
exit $FAIL
