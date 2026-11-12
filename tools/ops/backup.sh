#!/usr/bin/env bash
# Data-only backup of the hosted fam.ly database (schema is rebuilt from migrations on restore).
# Writes backups/famly-<UTC timestamp>.dump plus a .counts file for verifying restores.
# Needs: Docker, `supabase link` done (supabase/.temp/pooler-url), SUPABASE_DB_PASSWORD in supabase/.env.hosted.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: keep container paths as-is
cd "$(dirname "$0")/../.."

POOLER=$(cat supabase/.temp/pooler-url)
PGPASSWORD=$(grep '^SUPABASE_DB_PASSWORD=' supabase/.env.hosted | cut -d= -f2)
export PGPASSWORD
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NAME="famly-$STAMP"
mkdir -p backups
HOSTDIR=$(cd backups && (pwd -W 2>/dev/null || pwd))

# Our schemas plus the two auth tables that hold accounts. Sessions/tokens are deliberately excluded.
TABLES=(-t 'public.*' -t 'app.*' -t auth.users -t auth.identities)

docker run --rm -e PGPASSWORD -v "$HOSTDIR:/backups" postgres:17-alpine \
  pg_dump "$POOLER" --data-only --format=custom --no-owner --no-privileges "${TABLES[@]}" --file="/backups/$NAME.dump"

# Row counts at backup time, one "schema.table count" per line.
docker run --rm -i -e PGPASSWORD postgres:17-alpine psql "$POOLER" -tA -F ' ' > "backups/$NAME.counts" <<'SQL'
select format('select %L || '' '' || count(*) from %I.%I;', schemaname || '.' || relname, schemaname, relname)
  from pg_stat_user_tables
 where schemaname in ('public', 'app') or (schemaname = 'auth' and relname in ('users', 'identities'))
 order by 1
\gexec
SQL

echo "backup: backups/$NAME.dump ($(du -h "backups/$NAME.dump" | cut -f1)), $(wc -l < "backups/$NAME.counts") tables counted"
