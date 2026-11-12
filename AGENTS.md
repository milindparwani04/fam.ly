# Setting up fam.ly for a family (instructions for AI agents)

You are helping someone run **their own** copy of fam.ly for **their own** family. Start from a blank slate:
no families, people, cars or plans exist until they create them in the app. Never copy data from anywhere else.
The only sample data in this repo is the clearly fake demo family in `supabase/demo/` (local use only).

Work through the parts in order and tell the person what you're doing at each step. **Ask the person** for anything
that's theirs to decide or that needs their accounts (marked 👤). Never invent emails, domains or keys, and never
commit secrets: `.env*`, `supabase/.env.hosted` and `supabase/functions/.env` are git-ignored on purpose.

## What they'll need

| Thing | Why | Cost |
|---|---|---|
| Node 22+, pnpm 10 (`corepack enable`), Docker Desktop, git | build, local database | free |
| 👤 A Supabase account | database, sign-in, push sender, scheduled jobs | free tier is plenty for a family |
| 👤 A Cloudflare account | hosts the web app (static files only) | free |
| 👤 Optional: a domain | a nicer address than `famly.<account>.workers.dev` | ~£10/year |
| 👤 Optional: a Resend account + verified domain | reliable sign-in code emails (Supabase's built-in sender only allows a few per hour) | free tier |

Ask up front: their family's name, their own email (they become the first member), their time zone, and whether
they have a domain.

## Part 1: run it locally first (proves the machine is ready)

```sh
pnpm install
pnpm db:start                      # Docker must be running
pnpm db:reset
pnpm typecheck && pnpm --filter @famly/domain test && pnpm exec supabase test db   # all should pass
cp apps/web/.env.example apps/web/.env.local
pnpm exec supabase status -o env   # put API_URL in VITE_SUPABASE_URL and ANON_KEY in VITE_SUPABASE_ANON_KEY
pnpm --filter @famly/web dev       # http://127.0.0.1:5173
```

Sign in as `founder@test.local` (seeded in `supabase/seed.sql`); read the code at http://127.0.0.1:54324. Create a
family, add a car, make a plan. That's the whole app working locally. Push notifications need Part 2.

## Part 2: push keys (VAPID)

Generate one key pair for this family (keep the private key secret):

```sh
pnpm dlx web-push generate-vapid-keys
```

- `supabase/functions/.env` (copy from `.env.example`): `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
  `VAPID_SUBJECT=mailto:<their email>`, and `PUSH_DISPATCH_SECRET` = a long random string
  (`node -e "console.log(crypto.randomBytes(24).toString('hex'))"`).
- `apps/web/.env.local`: `VITE_VAPID_PUBLIC_KEY` = the same public key.

## Part 3: their hosted Supabase project

1. 👤 Create a project at https://supabase.com/dashboard. Pick the region closest to the family. Save the database
   password in `supabase/.env.hosted` as `SUPABASE_DB_PASSWORD=...`.
2. Note the **project ref** (the `xxxx` in `https://xxxx.supabase.co`) and link:
   `pnpm exec supabase link --project-ref <ref>`
3. Edit the `[remotes.production]` section at the bottom of `supabase/config.toml`:
   - `project_id = "<ref>"`
   - `site_url` and `additional_redirect_urls` = the app's address from Part 4 (e.g. `https://famly.<account>.workers.dev`
     or their domain). You can come back and fix this after Part 4.
   - Email: with Resend, set `admin_email` to an address on their verified domain and put `RESEND_API_KEY=...` in
     `supabase/.env.hosted`. Without Resend, delete the whole `[remotes.production.auth.email.smtp]` block.
4. Push the database and auth settings:
   ```sh
   export SUPABASE_DB_PASSWORD=...            # from supabase/.env.hosted
   pnpm exec supabase db push                 # every migration: tables, security, RPCs, scheduled jobs
   export RESEND_API_KEY=...                  # only if using Resend
   pnpm exec supabase config push --project-ref <ref>
   ```
5. In the dashboard, check **Authentication → Hooks**: *Before User Created* must point at the Postgres function
   `app.hook_before_user_created` (enable it if `config push` didn't). This hook is what keeps sign-up invite-only;
   don't enable sign-ups without it. Under **Authentication → Emails**, the sign-in email should show a 6-digit
   `{{ .Token }}` code (template `supabase/templates/code.html`), not a link.
6. In the dashboard **SQL editor**, run (with their real values):
   ```sql
   -- The first member. Everyone else joins through invite links from inside the app.
   insert into app.signup_allowlist (email) values ('<their email>');
   -- Where scheduled jobs call the Edge Functions, and the shared secret they use.
   update app.config set value = 'https://<ref>.supabase.co/functions/v1/push-dispatch' where key = 'push_dispatch_url';
   update app.config set value = 'https://<ref>.supabase.co/functions/v1/health-check' where key = 'health_check_url';
   update app.config set value = '<PUSH_DISPATCH_SECRET from Part 2>' where key = 'push_dispatch_secret';
   ```
7. Deploy the functions and their secrets:
   ```sh
   pnpm exec supabase functions deploy push-dispatch --no-verify-jwt --use-api
   pnpm exec supabase functions deploy health-check --no-verify-jwt --use-api
   pnpm exec supabase secrets set --env-file supabase/functions/.env
   pnpm exec supabase secrets set APP_URL=<app address>
   # optional health alerts by email (needs Resend):
   pnpm exec supabase secrets set RESEND_API_KEY=... OPS_ALERT_EMAIL=<their email> OPS_ALERT_FROM="fam.ly monitor <no-reply@their-domain>"
   ```

## Part 4: the web app on Cloudflare

1. Create `apps/web/.env.production.local`:
   ```
   VITE_SUPABASE_URL=https://<ref>.supabase.co
   VITE_SUPABASE_ANON_KEY=<Project Settings → API → anon / publishable key>
   VITE_VAPID_PUBLIC_KEY=<public key from Part 2>
   ```
2. 👤 `pnpm exec wrangler login` (opens their browser).
3. Optional custom domain: in `apps/web/wrangler.jsonc` add
   `"routes": [{ "pattern": "<their domain>", "custom_domain": true }]` (the domain must be on their Cloudflare account).
4. Deploy: `pnpm --filter @famly/web run deploy`. Note the address it prints and make sure Part 3 step 3's
   `site_url` matches it (re-run `config push` if you changed it).

## Part 5: first run (with the person)

1. Open the app address on their phone. On iPhone: Share → **Add to Home Screen**, then open it from the home
   screen (push only works there, iOS 16.4+).
2. Sign in with the allowlisted email, enter their name, confirm 18+, then **create the family** (name + time zone).
3. Settings → turn on notifications on each phone. Settings → work hours, quiet hours, categories.
4. Cars tab → add the family's cars. Members & Invites → make an invite link per person and send it to them;
   each person opens it on their own phone. A visiting relative can be invited for their stay and removed after.
5. Plans → New: try a menu, a plan and a stay. At 22:00 (family time) people who accepted that day's menu are
   asked to rate it; at 18:00 anyone with open to-dos gets a reminder.

## When things go wrong

- **No sign-in email:** without Resend, Supabase's sender is heavily rate-limited; wait or set up Resend.
  Check the address is in `app.signup_allowlist` (first person) or that they used an invite link.
- **No pushes:** the app must be opened from the home screen on iPhone; Settings → notifications must be on; check
  `app.config` URLs/secret match the function secret (`supabase secrets list`), and the function logs in the dashboard.
- **Database changes later:** add a new migration file (never edit applied ones), run `pnpm exec supabase test db`,
  back up (`pnpm ops:backup`), then `supabase db push`, then redeploy the web app.

## Working on the code

- All writes go through `rpc_*` functions in `supabase/migrations`; tables are read-only to clients via RLS.
  Add pgTAP tests in `supabase/tests/database` for every new RPC (run them on a freshly reset database).
- Regenerate client types after schema changes: `pnpm --filter @famly/web gen:types`.
- Keep Today, Plans and Cars on one screen without page scrolling; lists scroll inside their own card.
