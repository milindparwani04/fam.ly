#!/usr/bin/env bash
# P10-2 operator report: pilot metrics from the hosted database (aggregates only).
# Usage: pnpm ops:metrics [days]   (default 28, max 90 = retention window)
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
DAYS=${1:-28}
POOLER=$(cat supabase/.temp/pooler-url)
PGPASSWORD=$(grep '^SUPABASE_DB_PASSWORD=' supabase/.env.hosted | cut -d= -f2)
export PGPASSWORD
docker run --rm -e PGPASSWORD postgres:17-alpine psql "$POOLER" -tA -c "select jsonb_pretty(public.ops_pilot_metrics($DAYS))"
