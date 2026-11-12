-- Foundation: app helpers, profiles, family groups, membership, audit log.
-- BUILD_PLAN §3.1, §3.4. Forward-fix only; no down migration.

create extension if not exists btree_gist with schema extensions;

create schema if not exists app;
grant usage on schema app to authenticated;

-- Single seam over Supabase auth so the domain SQL stays portable (BUILD_PLAN §1 fallback).
create function app.current_user_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select auth.uid()
$$;

-------------------------------------------------------------------------------
-- profile
-------------------------------------------------------------------------------
create table public.profile (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default '' check (char_length(display_name) <= 80),
  time_zone text not null default 'Asia/Dubai',
  adult_attested_at timestamptz,
  created_at timestamptz not null default now()
);

create function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profile (user_id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', ''))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();

-------------------------------------------------------------------------------
-- family_group / group_membership
-------------------------------------------------------------------------------
create table public.family_group (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  time_zone text not null default 'Asia/Dubai',
  snooze_cap int not null default 4 check (snooze_cap between 0 and 12),   -- OP-03 interim
  retention_days int not null default 90 check (retention_days >= 1),     -- OP-04 interim
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create type public.membership_role as enum ('member', 'custodian');

create table public.group_membership (
  group_id uuid not null references public.family_group (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.membership_role not null default 'member',
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (group_id, user_id)
);
create index group_membership_user_idx on public.group_membership (user_id) where left_at is null;

-- SECURITY DEFINER so policies on group_membership itself don't recurse.
create function app.is_member(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.group_membership m
    join public.family_group g on g.id = m.group_id
    where m.group_id = p_group_id
      and m.user_id = app.current_user_id()
      and m.left_at is null
      and g.deleted_at is null
  )
$$;

create function app.assert_member(p_group_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.current_user_id() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not app.is_member(p_group_id) then
    -- Same error for "doesn't exist" and "not yours": no cross-tenant existence oracle (T22).
    raise exception 'not_found' using errcode = 'P0002';
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- audit_log (append-only)
-------------------------------------------------------------------------------
create table public.audit_log (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.family_group (id) on delete cascade,
  actor_id uuid references auth.users (id) on delete set null,
  action text not null,
  target_type text not null,
  target_id uuid,
  reason text,
  before jsonb,
  after jsonb,
  at timestamptz not null default now()
);
create index audit_log_group_at_idx on public.audit_log (group_id, at desc);

create function app.audit(
  p_group_id uuid, p_action text, p_target_type text, p_target_id uuid,
  p_before jsonb default null, p_after jsonb default null, p_reason text default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_log (group_id, actor_id, action, target_type, target_id, reason, before, after)
  values (p_group_id, app.current_user_id(), p_action, p_target_type, p_target_id, p_reason, p_before, p_after)
$$;

-------------------------------------------------------------------------------
-- RLS: deny by default, members read their groups. Clients never write tables directly.
-------------------------------------------------------------------------------
alter table public.profile enable row level security;
alter table public.family_group enable row level security;
alter table public.group_membership enable row level security;
alter table public.audit_log enable row level security;

revoke all on public.profile, public.family_group, public.group_membership, public.audit_log
  from anon, authenticated;
grant select on public.profile, public.family_group, public.group_membership, public.audit_log
  to authenticated;

create policy profile_select on public.profile for select to authenticated
  using (
    user_id = app.current_user_id()
    or exists (
      select 1 from public.group_membership m
      where m.user_id = profile.user_id and m.left_at is null and app.is_member(m.group_id)
    )
  );

create policy family_group_select on public.family_group for select to authenticated
  using (app.is_member(id));

create policy group_membership_select on public.group_membership for select to authenticated
  using (app.is_member(group_id));

create policy audit_log_select on public.audit_log for select to authenticated
  using (app.is_member(group_id));

-------------------------------------------------------------------------------
-- rpc_create_group (interim: full invite flow lands in P03)
-------------------------------------------------------------------------------
create function public.rpc_create_group(p_name text, p_time_zone text default 'Asia/Dubai')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_group_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_time_zone) then
    raise exception 'invalid_time_zone' using errcode = '22023';
  end if;

  insert into public.family_group (name, time_zone)
  values (btrim(p_name), p_time_zone)
  returning id into v_group_id;

  insert into public.group_membership (group_id, user_id, role)
  values (v_group_id, v_uid, 'custodian');

  perform app.audit(v_group_id, 'group.create', 'family_group', v_group_id, null,
                    jsonb_build_object('name', btrim(p_name)));
  return v_group_id;
end;
$$;

-- Functions are executable by PUBLIC by default; lock everything down, then grant explicitly.
revoke execute on all functions in schema app from public, anon;
grant execute on function app.current_user_id(), app.is_member(uuid) to authenticated;
revoke execute on function public.rpc_create_group(text, text) from public, anon;
grant execute on function public.rpc_create_group(text, text) to authenticated;
