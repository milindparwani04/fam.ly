-- Reservation core: bookings, outings, status history. FR-V04..V08, BR-007, T01, T02.
-- BUILD_PLAN §3.2 (booking invariant) and §3.3 (state machine).

create type public.reservation_status as enum ('reserved', 'in_use_reported', 'completed', 'cancelled');
create type public.outing_status as enum ('planned', 'departed', 'returned', 'cancelled');
create type public.status_report_kind as enum
  ('left', 'home', 'home_and_car_returned', 'eta_update', 'issue', 'correction');

create table public.vehicle_reservation (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  vehicle_id uuid not null,
  owner_id uuid not null references auth.users (id) on delete cascade,
  period tstzrange not null,
  starts_at timestamptz generated always as (lower(period)) stored,
  ends_at timestamptz generated always as (upper(period)) stored,
  status public.reservation_status not null default 'reserved',
  vehicle_returned_at timestamptz,
  possession_uncertain boolean not null default false,
  needs_reconciliation boolean not null default false,   -- set when maintenance is added over it
  idempotency_key text not null check (char_length(idempotency_key) between 8 and 100),
  version int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (group_id, id),
  unique (owner_id, idempotency_key),
  foreign key (group_id, vehicle_id) references public.vehicle (group_id, id) on delete cascade,
  constraint reservation_period_bounded check (
    not isempty(period) and not lower_inf(period) and not upper_inf(period)
    and lower_inc(period) and not upper_inc(period)
  ),
  -- The invariant (FR-V05). Cancelled/completed rows fall out so their slot is released.
  -- Late returns never extend period (R3): overdue is derived, not stored.
  constraint reservation_no_overlap exclude using gist (vehicle_id with =, period with &&)
    where (status in ('reserved', 'in_use_reported'))
);
create index vehicle_reservation_group_start_idx on public.vehicle_reservation (group_id, starts_at);

-- Every reservation has exactly one outing; car-free outings have reservation_id null (FR-F02).
create table public.outing (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_group (id) on delete cascade,
  owner_id uuid not null references auth.users (id) on delete cascade,
  reservation_id uuid unique,
  planned_start timestamptz not null,
  planned_return timestamptz not null,
  expected_return_at timestamptz,
  departure_reported_at timestamptz,
  home_reported_at timestamptz,
  status public.outing_status not null default 'planned',
  version int not null default 1,
  created_at timestamptz not null default now(),
  unique (group_id, id),
  foreign key (group_id, reservation_id) references public.vehicle_reservation (group_id, id) on delete cascade,
  check (planned_return > planned_start)
);

-- Append-only history (FR-V10, FR-S09). Corrections append, never delete.
create table public.status_report (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  outing_id uuid not null,
  kind public.status_report_kind not null,
  reported_by uuid references auth.users (id) on delete set null,
  reported_at timestamptz not null default now(),
  payload jsonb not null default '{}',
  idempotency_key text,
  foreign key (group_id, outing_id) references public.outing (group_id, id) on delete cascade,
  unique (reported_by, idempotency_key)
);
create index status_report_outing_idx on public.status_report (outing_id, reported_at);

alter table public.vehicle_reservation enable row level security;
alter table public.outing enable row level security;
alter table public.status_report enable row level security;
revoke all on public.vehicle_reservation, public.outing, public.status_report from anon, authenticated;
grant select on public.vehicle_reservation, public.outing, public.status_report to authenticated;

create policy vehicle_reservation_select on public.vehicle_reservation for select to authenticated
  using (app.is_member(group_id));
create policy outing_select on public.outing for select to authenticated
  using (app.is_member(group_id));
create policy status_report_select on public.status_report for select to authenticated
  using (app.is_member(group_id));

-------------------------------------------------------------------------------
-- Locks the car row for writers. Every write that can change a car's occupancy goes
-- through here first, so reservation-vs-maintenance checks are serialised per car.
-- The exclusion constraint stays as the last line of defence.
-------------------------------------------------------------------------------
create function app.lock_vehicle_for_member(p_vehicle_id uuid)
returns public.vehicle
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group_id uuid;
  v_vehicle public.vehicle;
begin
  select group_id into v_group_id from public.vehicle where id = p_vehicle_id;
  if v_group_id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_group_id);   -- check before locking: no locks on foreign rows

  select * into v_vehicle from public.vehicle where id = p_vehicle_id for update;
  return v_vehicle;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_create_reservation (FR-V04, T01, T02)
-------------------------------------------------------------------------------
create function public.rpc_create_reservation(
  p_vehicle_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_vehicle public.vehicle;
  v_period tstzrange;
  v_id uuid;
  v_conflict record;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 100 then
    raise exception 'invalid_idempotency_key' using errcode = '22023';
  end if;

  -- Fast replay path for a retried request (T02).
  select id into v_id from public.vehicle_reservation
   where owner_id = v_uid and idempotency_key = p_idempotency_key;
  if v_id is not null then
    return v_id;
  end if;

  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'invalid_period' using errcode = '22023';
  end if;
  if p_starts_at < now() - interval '5 minutes' then
    raise exception 'starts_in_past' using errcode = '22023';
  end if;
  if p_ends_at - p_starts_at > interval '14 days' then
    raise exception 'too_long' using errcode = '22023';
  end if;
  v_period := tstzrange(p_starts_at, p_ends_at, '[)');

  v_vehicle := app.lock_vehicle_for_member(p_vehicle_id);

  -- A concurrent retry with the same key may have committed while we waited for the lock.
  select id into v_id from public.vehicle_reservation
   where owner_id = v_uid and idempotency_key = p_idempotency_key;
  if v_id is not null then
    return v_id;
  end if;

  if not v_vehicle.active then
    raise exception 'vehicle_inactive' using errcode = '55000';
  end if;

  select lower(u.period) as starts_at, upper(u.period) as ends_at into v_conflict
    from public.vehicle_unavailability u
   where u.vehicle_id = p_vehicle_id and u.period && v_period
   order by lower(u.period)
   limit 1;
  if found then
    raise exception 'vehicle_unavailable' using errcode = '23P01',
      detail = jsonb_build_object('starts_at', v_conflict.starts_at, 'ends_at', v_conflict.ends_at)::text;
  end if;

  begin
    insert into public.vehicle_reservation (group_id, vehicle_id, owner_id, period, idempotency_key)
    values (v_vehicle.group_id, p_vehicle_id, v_uid, v_period, p_idempotency_key)
    returning id into v_id;
  exception
    when exclusion_violation then
      select r.id, r.owner_id, r.starts_at, r.ends_at into v_conflict
        from public.vehicle_reservation r
       where r.vehicle_id = p_vehicle_id
         and r.status in ('reserved', 'in_use_reported')
         and r.period && v_period
       order by r.starts_at
       limit 1;
      raise exception 'reservation_conflict' using errcode = '23P01',
        detail = jsonb_build_object(
          'reservation_id', v_conflict.id, 'owner_id', v_conflict.owner_id,
          'starts_at', v_conflict.starts_at, 'ends_at', v_conflict.ends_at)::text;
    when unique_violation then
      select id into v_id from public.vehicle_reservation
       where owner_id = v_uid and idempotency_key = p_idempotency_key;
      if v_id is null then
        raise;
      end if;
      return v_id;
  end;

  insert into public.outing (group_id, owner_id, reservation_id, planned_start, planned_return)
  values (v_vehicle.group_id, v_uid, v_id, p_starts_at, p_ends_at);

  perform app.audit(v_vehicle.group_id, 'reservation.create', 'vehicle_reservation', v_id, null,
                    jsonb_build_object('vehicle_id', p_vehicle_id, 'starts_at', p_starts_at, 'ends_at', p_ends_at));
  return v_id;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_cancel_reservation (FR-V06, journey 9). Owner only; releases the slot at once.
-------------------------------------------------------------------------------
create function public.rpc_cancel_reservation(p_reservation_id uuid, p_expected_version int default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_res public.vehicle_reservation;
begin
  select * into v_res from public.vehicle_reservation where id = p_reservation_id;
  if v_res.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_res.group_id);

  select * into v_res from public.vehicle_reservation where id = p_reservation_id for update;

  if v_res.owner_id <> v_uid then
    raise exception 'not_owner' using errcode = '42501';
  end if;
  if p_expected_version is not null and v_res.version <> p_expected_version then
    raise exception 'stale_version' using errcode = '55000';
  end if;
  if v_res.status = 'cancelled' then
    return;   -- idempotent
  end if;
  if v_res.status <> 'reserved' then
    raise exception 'invalid_state' using errcode = '55000', detail = v_res.status::text;
  end if;

  update public.vehicle_reservation
     set status = 'cancelled', version = version + 1, updated_at = now()
   where id = p_reservation_id;
  update public.outing
     set status = 'cancelled', version = version + 1
   where reservation_id = p_reservation_id;

  perform app.audit(v_res.group_id, 'reservation.cancel', 'vehicle_reservation', p_reservation_id,
                    jsonb_build_object('status', v_res.status), jsonb_build_object('status', 'cancelled'));
end;
$$;

-------------------------------------------------------------------------------
-- rpc_add_unavailability (FR-V02). Flags overlapping live bookings for reconciliation;
-- it never silently cancels someone else's booking.
-------------------------------------------------------------------------------
create function public.rpc_add_unavailability(
  p_vehicle_id uuid, p_starts_at timestamptz, p_ends_at timestamptz, p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vehicle public.vehicle;
  v_period tstzrange;
  v_id uuid;
begin
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'invalid_period' using errcode = '22023';
  end if;
  v_period := tstzrange(p_starts_at, p_ends_at, '[)');

  v_vehicle := app.lock_vehicle_for_member(p_vehicle_id);

  insert into public.vehicle_unavailability (group_id, vehicle_id, period, reason, created_by)
  values (v_vehicle.group_id, p_vehicle_id, v_period, p_reason, app.current_user_id())
  returning id into v_id;

  update public.vehicle_reservation
     set needs_reconciliation = true, updated_at = now()
   where vehicle_id = p_vehicle_id
     and status in ('reserved', 'in_use_reported')
     and period && v_period;

  perform app.audit(v_vehicle.group_id, 'vehicle.unavailability.add', 'vehicle_unavailability', v_id, null,
                    jsonb_build_object('starts_at', p_starts_at, 'ends_at', p_ends_at, 'reason', p_reason));
  return v_id;
end;
$$;

revoke execute on function app.lock_vehicle_for_member(uuid) from public, anon, authenticated;
revoke execute on function public.rpc_create_reservation(uuid, timestamptz, timestamptz, text) from public, anon;
revoke execute on function public.rpc_cancel_reservation(uuid, int) from public, anon;
revoke execute on function public.rpc_add_unavailability(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.rpc_create_reservation(uuid, timestamptz, timestamptz, text) to authenticated;
grant execute on function public.rpc_cancel_reservation(uuid, int) to authenticated;
grant execute on function public.rpc_add_unavailability(uuid, timestamptz, timestamptz, text) to authenticated;
