-- P03 Identity & groups: adult attestation, invites, sign-up gate, leave/remove, protected deletion.
-- FR-A02, FR-A03, FR-A04, FR-A05, FR-A06, T19. Interim policies: OP-06, OP-07, OP-10 (BUILD_PLAN §6).

create extension if not exists pgcrypto with schema extensions;

-------------------------------------------------------------------------------
-- Schema additions
-------------------------------------------------------------------------------
create table public.invitation (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_group (id) on delete cascade,
  token_hash bytea not null unique,                -- sha256 of the token; the token itself is never stored
  note text check (char_length(note) <= 80),       -- e.g. "for Mum", shown to members only
  invited_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by uuid references auth.users (id) on delete set null,
  revoked_at timestamptz,
  check (expires_at > created_at)
);
create index invitation_group_idx on public.invitation (group_id, created_at desc);

alter table public.family_group
  add column deletion_requested_at timestamptz,
  add column deletion_requested_by uuid references auth.users (id) on delete set null,
  add column deletion_scheduled_for timestamptz;

-- Emails allowed to sign up without an invite (founder bootstrap). Managed by the operator via SQL only.
create table app.signup_allowlist (
  email text primary key check (email = lower(email)),
  added_at timestamptz not null default now()
);

alter table public.invitation enable row level security;
revoke all on public.invitation from anon, authenticated;
-- Column grant (not table grant): token_hash is useless without the token, but stays out of client reads.
grant select (id, group_id, note, invited_by, created_at, expires_at, used_at, used_by, revoked_at)
  on public.invitation to authenticated;
create policy invitation_select on public.invitation for select to authenticated
  using (app.is_member(group_id));

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
create function app.hash_token(p_token text)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.sha256(convert_to(p_token, 'UTF8'))
$$;

create function app.assert_adult()
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
  if not exists (
    select 1 from public.profile
     where user_id = app.current_user_id() and adult_attested_at is not null
  ) then
    raise exception 'adult_attestation_required' using errcode = '42501';
  end if;
end;
$$;

create function app.is_custodian(p_group_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.group_membership
     where group_id = p_group_id and user_id = p_user_id
       and role = 'custodian' and left_at is null
  )
$$;

-------------------------------------------------------------------------------
-- Sign-up gate (Supabase "before user created" auth hook).
-- Allows: allowlisted emails, or sign-ups carrying a currently valid invite token
-- in user_metadata.invite_token. The token is consumed later by rpc_accept_invite.
-------------------------------------------------------------------------------
create function app.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_email text := lower(event -> 'user' ->> 'email');
  v_token text := event -> 'user' -> 'user_metadata' ->> 'invite_token';
begin
  if exists (select 1 from app.signup_allowlist where email = v_email) then
    return '{}'::jsonb;
  end if;
  if v_token is not null and exists (
    select 1 from public.invitation
     where token_hash = app.hash_token(v_token)
       and used_at is null and revoked_at is null and expires_at > now()
  ) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'fam.ly is invite-only. Ask a family member for an invite link.'));
end;
$$;

grant usage on schema app to supabase_auth_admin;
grant execute on function app.hook_before_user_created(jsonb) to supabase_auth_admin;

-------------------------------------------------------------------------------
-- Profile & attestation (FR-A02; OP-10 interim = explicit 18+ self-attestation)
-------------------------------------------------------------------------------
create function public.rpc_update_profile(p_display_name text, p_time_zone text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.current_user_id() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if char_length(btrim(p_display_name)) not between 1 and 80 then
    raise exception 'invalid_display_name' using errcode = '22023';
  end if;
  if p_time_zone is not null
     and not exists (select 1 from pg_catalog.pg_timezone_names where name = p_time_zone) then
    raise exception 'invalid_time_zone' using errcode = '22023';
  end if;
  update public.profile
     set display_name = btrim(p_display_name),
         time_zone = coalesce(p_time_zone, time_zone)
   where user_id = app.current_user_id();
end;
$$;

create function public.rpc_attest_adult(p_confirm boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.current_user_id() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_confirm is not true then
    -- Ineligible route: no attestation recorded, so no membership can follow (FR-A02).
    raise exception 'adult_attestation_required' using errcode = '42501';
  end if;
  update public.profile
     set adult_attested_at = coalesce(adult_attested_at, now())
   where user_id = app.current_user_id();
end;
$$;

-- Replaces the P02 version: creating a group now requires attestation.
create or replace function public.rpc_create_group(p_name text, p_time_zone text default 'Asia/Dubai')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_group_id uuid;
begin
  perform app.assert_adult();
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 80 then
    raise exception 'invalid_name' using errcode = '22023';
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

-------------------------------------------------------------------------------
-- Invitations (FR-A03): random 32-byte token, only its hash stored, single-use, revocable.
-------------------------------------------------------------------------------
create function public.rpc_create_invite(p_group_id uuid, p_note text default null, p_ttl_hours int default 72)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
  v_id uuid;
  v_expires timestamptz;
begin
  perform app.assert_member(p_group_id);
  if p_ttl_hours is null or p_ttl_hours not between 1 and 168 then
    raise exception 'invalid_ttl' using errcode = '22023';
  end if;
  if (select deletion_requested_at from public.family_group where id = p_group_id) is not null then
    raise exception 'group_pending_deletion' using errcode = '55000';
  end if;

  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_expires := now() + make_interval(hours => p_ttl_hours);

  insert into public.invitation (group_id, token_hash, note, invited_by, expires_at)
  values (p_group_id, app.hash_token(v_token), nullif(btrim(p_note), ''), app.current_user_id(), v_expires)
  returning id into v_id;

  perform app.audit(p_group_id, 'invite.create', 'invitation', v_id, null,
                    jsonb_build_object('expires_at', v_expires, 'note', p_note));
  -- The plaintext token is returned exactly once.
  return jsonb_build_object('invitation_id', v_id, 'token', v_token, 'expires_at', v_expires);
end;
$$;

create function public.rpc_revoke_invite(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inv public.invitation;
begin
  select * into v_inv from public.invitation where id = p_invitation_id;
  if v_inv.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_inv.group_id);
  if v_inv.used_at is not null then
    raise exception 'invite_used' using errcode = '55000';
  end if;
  if v_inv.revoked_at is not null then
    return;
  end if;
  update public.invitation set revoked_at = now() where id = p_invitation_id;
  perform app.audit(v_inv.group_id, 'invite.revoke', 'invitation', p_invitation_id);
end;
$$;

-- Returns why a token can't be used, or null if it can. Caller must hold the row lock if it matters.
create function app.invite_problem(v_inv public.invitation)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when v_inv.id is null then 'invite_invalid'
    when v_inv.revoked_at is not null then 'invite_revoked'
    when v_inv.used_at is not null then 'invite_used'
    when v_inv.expires_at <= now() then 'invite_expired'
    when exists (select 1 from public.family_group g
                  where g.id = v_inv.group_id
                    and (g.deleted_at is not null or g.deletion_requested_at is not null)) then 'invite_invalid'
  end
$$;

-- "You're invited to <family> by <name>". Callable before sign-up (anon); the 256-bit token is the secret.
create function public.rpc_preview_invite(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_inv public.invitation;
  v_problem text;
begin
  select * into v_inv from public.invitation where token_hash = app.hash_token(coalesce(p_token, ''));
  v_problem := app.invite_problem(v_inv);
  if v_problem is not null then
    return jsonb_build_object('valid', false, 'reason', v_problem);
  end if;
  return jsonb_build_object(
    'valid', true,
    'group_name', (select name from public.family_group where id = v_inv.group_id),
    'invited_by', (select display_name from public.profile where user_id = v_inv.invited_by),
    'expires_at', v_inv.expires_at);
end;
$$;

create function public.rpc_accept_invite(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_inv public.invitation;
  v_problem text;
begin
  perform app.assert_adult();

  select * into v_inv from public.invitation
   where token_hash = app.hash_token(coalesce(p_token, ''))
   for update;
  v_problem := app.invite_problem(v_inv);
  if v_problem is not null then
    raise exception '%', v_problem using errcode = '22023';
  end if;

  if exists (select 1 from public.group_membership
              where group_id = v_inv.group_id and user_id = v_uid and left_at is null) then
    raise exception 'already_member' using errcode = '55000';
  end if;

  insert into public.group_membership (group_id, user_id, role)
  values (v_inv.group_id, v_uid, 'member')
  on conflict (group_id, user_id) do update
     set left_at = null, joined_at = now(), role = 'member';   -- re-joining after leaving

  update public.invitation set used_at = now(), used_by = v_uid where id = v_inv.id;

  perform app.audit(v_inv.group_id, 'member.join', 'group_membership', v_uid, null,
                    jsonb_build_object('invitation_id', v_inv.id));
  return v_inv.group_id;
end;
$$;

-------------------------------------------------------------------------------
-- Leaving and removal (FR-A06; OP-07 interim):
--   * blocked while the member has a booking reported in use (car may be with them)
--   * their future 'reserved' bookings are cancelled, with an audit entry each
--   * the last remaining member cannot leave (delete the group instead)
--   * if the last custodian leaves, the longest-standing remaining member becomes custodian
-- Member notices are emitted once the notification outbox lands (P08).
-------------------------------------------------------------------------------
create function app.exit_member(p_group_id uuid, p_user_id uuid, p_action text, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_res record;
  v_successor uuid;
begin
  -- Serialise membership changes per group.
  perform 1 from public.family_group where id = p_group_id for update;

  if not exists (select 1 from public.group_membership
                  where group_id = p_group_id and user_id = p_user_id and left_at is null) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if (select count(*) from public.group_membership
       where group_id = p_group_id and left_at is null) = 1 then
    raise exception 'last_member' using errcode = '55000';
  end if;

  if exists (select 1 from public.vehicle_reservation
              where group_id = p_group_id and owner_id = p_user_id and status = 'in_use_reported') then
    raise exception 'has_car_in_use' using errcode = '55000';
  end if;

  for v_res in
    select id, status from public.vehicle_reservation
     where group_id = p_group_id and owner_id = p_user_id and status = 'reserved'
     for update
  loop
    update public.vehicle_reservation
       set status = 'cancelled', version = version + 1, updated_at = now()
     where id = v_res.id;
    update public.outing set status = 'cancelled', version = version + 1 where reservation_id = v_res.id;
    perform app.audit(p_group_id, 'reservation.cancel_on_exit', 'vehicle_reservation', v_res.id,
                      jsonb_build_object('status', v_res.status), jsonb_build_object('status', 'cancelled'),
                      p_reason);
  end loop;

  update public.group_membership set left_at = now()
   where group_id = p_group_id and user_id = p_user_id;

  if not exists (select 1 from public.group_membership
                  where group_id = p_group_id and role = 'custodian' and left_at is null) then
    select user_id into v_successor from public.group_membership
     where group_id = p_group_id and left_at is null
     order by joined_at, user_id
     limit 1;
    update public.group_membership set role = 'custodian'
     where group_id = p_group_id and user_id = v_successor;
    perform app.audit(p_group_id, 'member.custodian_succession', 'group_membership', v_successor);
  end if;

  perform app.audit(p_group_id, p_action, 'group_membership', p_user_id, null, null, p_reason);
end;
$$;

create function public.rpc_leave_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.assert_member(p_group_id);
  perform app.exit_member(p_group_id, app.current_user_id(), 'member.leave', null);
end;
$$;

-- Any adult may remove another (D09 routine admin parity); a reason is required and audited.
create function public.rpc_remove_member(p_group_id uuid, p_user_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.assert_member(p_group_id);
  if p_user_id = app.current_user_id() then
    raise exception 'use_leave_group' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  perform app.exit_member(p_group_id, p_user_id, 'member.remove', btrim(p_reason));
end;
$$;

-- Custodians manage the custodian role. A group always keeps at least one custodian.
create function public.rpc_set_member_role(p_group_id uuid, p_user_id uuid, p_role public.membership_role)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.assert_member(p_group_id);
  if not app.is_custodian(p_group_id, app.current_user_id()) then
    raise exception 'custodian_required' using errcode = '42501';
  end if;
  perform 1 from public.family_group where id = p_group_id for update;
  if p_role = 'member' and (
       select count(*) from public.group_membership
        where group_id = p_group_id and role = 'custodian' and left_at is null and user_id <> p_user_id
     ) = 0 then
    raise exception 'last_custodian' using errcode = '55000';
  end if;
  update public.group_membership set role = p_role
   where group_id = p_group_id and user_id = p_user_id and left_at is null;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.audit(p_group_id, 'member.set_role', 'group_membership', p_user_id, null,
                    jsonb_build_object('role', p_role));
end;
$$;

-------------------------------------------------------------------------------
-- Protected group deletion (FR-A04; OP-06 interim): custodian only, typed group name,
-- 7-day soft-delete window that any adult can cancel. Final purge runs in P09-3.
-------------------------------------------------------------------------------
create function public.rpc_request_group_deletion(p_group_id uuid, p_confirm_name text)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group public.family_group;
begin
  perform app.assert_member(p_group_id);
  if not app.is_custodian(p_group_id, app.current_user_id()) then
    raise exception 'custodian_required' using errcode = '42501';
  end if;
  select * into v_group from public.family_group where id = p_group_id for update;
  if p_confirm_name is distinct from v_group.name then
    raise exception 'confirm_name_mismatch' using errcode = '22023';
  end if;
  if v_group.deletion_requested_at is not null then
    return v_group.deletion_scheduled_for;
  end if;

  update public.family_group
     set deletion_requested_at = now(),
         deletion_requested_by = app.current_user_id(),
         deletion_scheduled_for = now() + interval '7 days'
   where id = p_group_id
  returning deletion_scheduled_for into v_group.deletion_scheduled_for;

  -- Outstanding invites die with the request.
  update public.invitation set revoked_at = now()
   where group_id = p_group_id and used_at is null and revoked_at is null;

  perform app.audit(p_group_id, 'group.deletion_requested', 'family_group', p_group_id, null,
                    jsonb_build_object('scheduled_for', v_group.deletion_scheduled_for));
  return v_group.deletion_scheduled_for;
end;
$$;

create function public.rpc_cancel_group_deletion(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.assert_member(p_group_id);
  update public.family_group
     set deletion_requested_at = null, deletion_requested_by = null, deletion_scheduled_for = null
   where id = p_group_id and deletion_requested_at is not null;
  if found then
    perform app.audit(p_group_id, 'group.deletion_cancelled', 'family_group', p_group_id);
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------
revoke execute on function app.hash_token(text), app.assert_adult(), app.is_custodian(uuid, uuid),
  app.invite_problem(public.invitation), app.exit_member(uuid, uuid, text, text),
  app.hook_before_user_created(jsonb)
  from public, anon, authenticated;

revoke execute on function
  public.rpc_update_profile(text, text),
  public.rpc_attest_adult(boolean),
  public.rpc_create_invite(uuid, text, int),
  public.rpc_revoke_invite(uuid),
  public.rpc_preview_invite(text),
  public.rpc_accept_invite(text),
  public.rpc_leave_group(uuid),
  public.rpc_remove_member(uuid, uuid, text),
  public.rpc_set_member_role(uuid, uuid, public.membership_role),
  public.rpc_request_group_deletion(uuid, text),
  public.rpc_cancel_group_deletion(uuid)
  from public, anon;

grant execute on function
  public.rpc_update_profile(text, text),
  public.rpc_attest_adult(boolean),
  public.rpc_create_invite(uuid, text, int),
  public.rpc_revoke_invite(uuid),
  public.rpc_preview_invite(text),
  public.rpc_accept_invite(text),
  public.rpc_leave_group(uuid),
  public.rpc_remove_member(uuid, uuid, text),
  public.rpc_set_member_role(uuid, uuid, public.membership_role),
  public.rpc_request_group_deletion(uuid, text),
  public.rpc_cancel_group_deletion(uuid)
  to authenticated;
grant execute on function public.rpc_preview_invite(text) to anon;
