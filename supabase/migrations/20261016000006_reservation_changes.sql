-- P05 Reservation changes: edit, extend, exceptional override (flagged off). FR-V06, FR-V08, T10, T15, T16.

-------------------------------------------------------------------------------
-- Feature flags (global). booking_override stays off until OP-05 is decided.
-------------------------------------------------------------------------------
create table app.feature_flag (
  name text primary key,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into app.feature_flag (name, enabled) values ('booking_override', false);

create function app.flag_enabled(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select enabled from app.feature_flag where name = p_name), false)
$$;

-------------------------------------------------------------------------------
-- Shared checks for any write that sets a booking's window.
-------------------------------------------------------------------------------
create function app.check_booking_window(
  p_vehicle public.vehicle, p_period tstzrange, p_exclude_reservation uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_conflict record;
begin
  if upper(p_period) - lower(p_period) > interval '14 days' then
    raise exception 'too_long' using errcode = '22023';
  end if;
  if not p_vehicle.active then
    raise exception 'vehicle_inactive' using errcode = '55000';
  end if;

  select lower(u.period) as starts_at, upper(u.period) as ends_at into v_conflict
    from public.vehicle_unavailability u
   where u.vehicle_id = p_vehicle.id and u.period && p_period
   order by lower(u.period)
   limit 1;
  if found then
    raise exception 'vehicle_unavailable' using errcode = '23P01',
      detail = jsonb_build_object('starts_at', v_conflict.starts_at, 'ends_at', v_conflict.ends_at)::text;
  end if;

  -- Checked explicitly (under the car lock) so the error can name the clashing booking.
  -- The exclusion constraint still backstops this.
  select r.id, r.owner_id, r.starts_at, r.ends_at into v_conflict
    from public.vehicle_reservation r
   where r.vehicle_id = p_vehicle.id
     and r.status in ('reserved', 'in_use_reported')
     and r.period && p_period
     and r.id is distinct from p_exclude_reservation
   order by r.starts_at
   limit 1;
  if found then
    raise exception 'reservation_conflict' using errcode = '23P01',
      detail = jsonb_build_object('reservation_id', v_conflict.id, 'owner_id', v_conflict.owner_id,
                                  'starts_at', v_conflict.starts_at, 'ends_at', v_conflict.ends_at)::text;
  end if;
end;
$$;

-- Loads a booking for a write by its owner: membership, car lock (same order as create),
-- row lock, ownership and optimistic version check.
create function app.lock_own_reservation(p_reservation_id uuid, p_expected_version int)
returns public.vehicle_reservation
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_res public.vehicle_reservation;
begin
  select * into v_res from public.vehicle_reservation where id = p_reservation_id;
  if v_res.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.lock_vehicle_for_member(v_res.vehicle_id);
  select * into v_res from public.vehicle_reservation where id = p_reservation_id for update;

  if v_res.owner_id <> app.current_user_id() then
    raise exception 'not_owner' using errcode = '42501';
  end if;
  if p_expected_version is not null and v_res.version <> p_expected_version then
    raise exception 'stale_version' using errcode = '55000';
  end if;
  return v_res;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_update_reservation (FR-V06): owner moves or resizes a booking that hasn't started being used.
-------------------------------------------------------------------------------
create function public.rpc_update_reservation(
  p_reservation_id uuid, p_starts_at timestamptz, p_ends_at timestamptz, p_expected_version int
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_res public.vehicle_reservation;
  v_vehicle public.vehicle;
  v_period tstzrange;
begin
  if p_expected_version is null then
    raise exception 'stale_version' using errcode = '55000';
  end if;
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'invalid_period' using errcode = '22023';
  end if;

  v_res := app.lock_own_reservation(p_reservation_id, p_expected_version);
  if v_res.status <> 'reserved' then
    raise exception 'invalid_state' using errcode = '55000', detail = v_res.status::text;
  end if;
  -- Leaving an already-started window alone is fine; moving the start into the past is not.
  if p_starts_at <> v_res.starts_at and p_starts_at < now() - interval '5 minutes' then
    raise exception 'starts_in_past' using errcode = '22023';
  end if;
  if p_ends_at <= now() then
    raise exception 'ends_in_past' using errcode = '22023';
  end if;

  v_period := tstzrange(p_starts_at, p_ends_at, '[)');
  select * into v_vehicle from public.vehicle where id = v_res.vehicle_id;
  perform app.check_booking_window(v_vehicle, v_period, v_res.id);

  update public.vehicle_reservation
     set period = v_period, version = version + 1, updated_at = now()
   where id = v_res.id;
  update public.outing
     set planned_start = p_starts_at, planned_return = p_ends_at, version = version + 1
   where reservation_id = v_res.id;
  perform app.recompute_reconciliation(v_res.vehicle_id);

  perform app.audit(v_res.group_id, 'reservation.update', 'vehicle_reservation', v_res.id,
                    jsonb_build_object('starts_at', v_res.starts_at, 'ends_at', v_res.ends_at),
                    jsonb_build_object('starts_at', p_starts_at, 'ends_at', p_ends_at));
  return v_res.version + 1;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_extend_reservation (FR-V08, T15): push the end later, including while the car is out.
-- Never moves or shortens anyone else's booking: a clash is rejected with who/when.
-------------------------------------------------------------------------------
create function public.rpc_extend_reservation(p_reservation_id uuid, p_ends_at timestamptz, p_expected_version int)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_res public.vehicle_reservation;
  v_vehicle public.vehicle;
  v_period tstzrange;
begin
  if p_expected_version is null then
    raise exception 'stale_version' using errcode = '55000';
  end if;

  v_res := app.lock_own_reservation(p_reservation_id, p_expected_version);
  if v_res.status not in ('reserved', 'in_use_reported') then
    raise exception 'invalid_state' using errcode = '55000', detail = v_res.status::text;
  end if;
  if p_ends_at is null or p_ends_at <= v_res.ends_at then
    raise exception 'invalid_period' using errcode = '22023';
  end if;

  v_period := tstzrange(v_res.starts_at, p_ends_at, '[)');
  select * into v_vehicle from public.vehicle where id = v_res.vehicle_id;
  perform app.check_booking_window(v_vehicle, v_period, v_res.id);

  update public.vehicle_reservation
     set period = v_period, version = version + 1, updated_at = now()
   where id = v_res.id;
  update public.outing
     set planned_return = p_ends_at, version = version + 1
   where reservation_id = v_res.id;

  perform app.audit(v_res.group_id, 'reservation.extend', 'vehicle_reservation', v_res.id,
                    jsonb_build_object('ends_at', v_res.ends_at), jsonb_build_object('ends_at', p_ends_at));
  return v_res.version + 1;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_override_reservation (FR-V06, T16): exceptional cancellation of someone else's booking.
-- Requires a reason; immutable audit row. Disabled until OP-05 decides who may use it.
-- Owner notification is added with the outbox (P08).
-------------------------------------------------------------------------------
create function public.rpc_override_reservation(p_reservation_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_res public.vehicle_reservation;
begin
  if not app.flag_enabled('booking_override') then
    raise exception 'feature_disabled' using errcode = '55000';
  end if;

  select * into v_res from public.vehicle_reservation where id = p_reservation_id;
  if v_res.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_res.group_id);
  if char_length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'reason_required' using errcode = '22023';
  end if;

  select * into v_res from public.vehicle_reservation where id = p_reservation_id for update;
  if v_res.status <> 'reserved' then
    raise exception 'invalid_state' using errcode = '55000', detail = v_res.status::text;
  end if;

  update public.vehicle_reservation
     set status = 'cancelled', version = version + 1, updated_at = now()
   where id = v_res.id;
  update public.outing set status = 'cancelled', version = version + 1 where reservation_id = v_res.id;

  perform app.audit(v_res.group_id, 'reservation.override', 'vehicle_reservation', v_res.id,
                    jsonb_build_object('status', v_res.status, 'owner_id', v_res.owner_id),
                    jsonb_build_object('status', 'cancelled'), btrim(p_reason));
end;
$$;

-- Audit rows are append-only. Two cascades are allowed through:
--   * deleting a family removes its audit trail (FR-D03 group deletion), and
--   * deleting an account anonymises its actor_id (ON DELETE SET NULL).
create function app.audit_log_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE'
     and not exists (select 1 from public.family_group where id = old.group_id) then
    return old;
  end if;
  if tg_op = 'UPDATE' and old.actor_id is not null and new.actor_id is null
     and (to_jsonb(new) - 'actor_id') = (to_jsonb(old) - 'actor_id') then
    return new;
  end if;
  raise exception 'audit_log is append-only' using errcode = '42501';
end;
$$;
create trigger audit_log_no_update_delete
  before update or delete on public.audit_log
  for each row execute function app.audit_log_immutable();

revoke execute on function app.flag_enabled(text), app.check_booking_window(public.vehicle, tstzrange, uuid),
  app.lock_own_reservation(uuid, int), app.audit_log_immutable()
  from public, anon, authenticated;

revoke execute on function
  public.rpc_update_reservation(uuid, timestamptz, timestamptz, int),
  public.rpc_extend_reservation(uuid, timestamptz, int),
  public.rpc_override_reservation(uuid, text)
  from public, anon;
grant execute on function
  public.rpc_update_reservation(uuid, timestamptz, timestamptz, int),
  public.rpc_extend_reservation(uuid, timestamptz, int),
  public.rpc_override_reservation(uuid, text)
  to authenticated;
