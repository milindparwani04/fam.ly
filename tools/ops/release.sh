#!/usr/bin/env bash
# Release fam.ly to production, in the order docs/runbooks/deploy.md requires:
#   checks -> backup -> migrations (dry run, confirm, push) -> web app.
# Run it yourself in Git Bash from anywhere in the repo:   bash tools/ops/release.sh
# Needs: Docker running (backup), `supabase login` done, supabase/.env.hosted with SUPABASE_DB_PASSWORD,
# apps/web/.env.production.local, wrangler logged in.
# Stops at the first failure. Nothing is changed in production before you type "yes".
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# The SUPABASE_ACCESS_TOKEN in .env.hosted is an old fine-grained token; use the one from `supabase login`.
unset SUPABASE_ACCESS_TOKEN

say "1/5  Working tree"
branch=$(git branch --show-current)
if [ "$branch" != "main" ]; then echo "On '$branch', not main. Stopping."; exit 1; fi
if [ -n "$(git status --porcelain)" ]; then git status --short; echo "Uncommitted changes. Commit first."; exit 1; fi
echo "main @ $(git rev-parse --short HEAD), clean"

say "2/5  Checks (typecheck, domain tests)"
pnpm typecheck
pnpm --filter @famly/domain test

say "3/5  Backup"
docker info >/dev/null 2>&1 || { echo "Docker isn't running. Start Docker Desktop and run this again."; exit 1; }
pnpm ops:backup

say "4/5  Database migrations"
SUPABASE_DB_PASSWORD=$(grep '^SUPABASE_DB_PASSWORD=' supabase/.env.hosted | cut -d= -f2)
export SUPABASE_DB_PASSWORD
pnpm exec supabase db push --dry-run
printf '\nThose are the migrations that will run on PRODUCTION. Type "yes" to push them: '
read -r answer
if [ "$answer" != "yes" ]; then echo "Stopped. Nothing changed in production (the backup was still taken)."; exit 1; fi
pnpm exec supabase db push --yes
pnpm exec supabase migration list | tail -5

say "5/5  Web app"
pnpm --filter @famly/web run deploy

say "Done"
echo "Released main @ $(git rev-parse --short HEAD)."
echo "Now: open the app, sign in, check Today / Plans / Settings -> Documents, and run 'pnpm ops:metrics 1'."
