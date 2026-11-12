-- P04 Vehicle inventory: deactivate/reactivate, remove maintenance, unique names, reconciliation flags.
-- FR-V01, FR-V02. Any adult may manage cars (D09 routine admin parity).

-- Two cars called "Corolla" and "corolla" in one family is a recipe for wrong bookings.
create unique index vehicle_group_name_uniq on public.vehicle (group_id, lower(name));

-- Same convenience columns as vehicle_reservation, so clients never parse range literals.
alter table public.vehicle_unavailability
  add column starts_at timestamptz generated always as (lower(period)) stored,
  add column ends_at timestamptz generated always as (upper(period)) stored;

-------------------------------------------------------------------------------
-- A live booking needs reconciliation while its car is inactive or under maintenance
-- during its window. Recomputed (not toggled) so adding/removing windows can't drift.
-- Bookings are flagged, never silently cancelled: the owner decides (FR-V02).
-------------------------------------------------------------------------------
create function app.recompute_reconciliation(p_vehicle_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.vehicle_reservation r
     set needs_reconciliation = flagged, updated_at = now()
    from (
      select r2.id,
             (not v.active
              or exists (select 1 from public.vehicle_unavailability u
                          where u.vehicle_id = r2.vehicle_id and u.period && r2.period)) as flagged
        from public.vehicle_reservation r2
        join public.vehicle v on v.id = r2.vehicle_id
       where r2.vehicle_id = p_vehicle_id
         and r2.status in ('reserved', 'in_use_reported')
    ) f
   where r.id = f.id and r.needs_reconciliation is distinct from f.flagged
$$;

-------------------------------------------------------------------------------
-- rpc_upsert_vehicle: validation + friendly duplicate-name error (replaces P02 version).
-------------------------------------------------------------------------------
create or replace function public.rpc_upsert_vehicle(p_group_id uuid, p_name text, p_vehicle_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_id uuid;
  v_old text;
begin
  perform app.assert_member(p_group_id);
  if char_length(v_name) not between 1 and 60 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;

  begin
    if p_vehicle_id is null then
      insert into public.vehicle (group_id, name)
      values (p_group_id, v_name)
      returning id into v_id;
      perform app.audit(p_group_id, 'vehicle.create', 'vehicle', v_id, null, jsonb_build_object('name', v_name));
    else
      select name into v_old from public.vehicle where id = p_vehicle_id and group_id = p_group_id for update;
      if not found then
        raise exception 'not_found' using errcode = 'P0002';
      end if;
      update public.vehicle
         set name = v_name, version = version + 1
       where id = p_vehicle_id
      returning id into v_id;
      perform app.audit(p_group_id, 'vehicle.rename', 'vehicle', v_id,
                        jsonb_build_object('name', v_old), jsonb_build_object('name', v_name));
    end if;
  exception
    when unique_violation then
      raise exception 'duplicate_name' using errcode = '23505';
  end;
  return v_id;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_set_vehicle_active: deactivate (sold, long-term off the road) or reactivate.
-- Deactivating is blocked while the car is reported out; future bookings are flagged.
-------------------------------------------------------------------------------
create function public.rpc_set_vehicle_active(p_vehicle_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vehicle public.vehicle;
begin
  if p_active is null then
    raise exception 'invalid_state' using errcode = '22023';
  end if;
  v_vehicle := app.lock_vehicle_for_member(p_vehicle_id);
  if v_vehicle.active = p_active then
    return;   -- idempotent
  end if;

  if not p_active and exists (
    select 1 from public.vehicle_reservation
     where vehicle_id = p_vehicle_id and status = 'in_use_reported'
  ) then
    raise exception 'vehicle_in_use' using errcode = '55000';
  end if;

  update public.vehicle set active = p_active, version = version + 1 where id = p_vehicle_id;
  perform app.recompute_reconciliation(p_vehicle_id);
  perform app.audit(v_vehicle.group_id,
                    case when p_active then 'vehicle.reactivate' else 'vehicle.deactivate' end,
                    'vehicle', p_vehicle_id,
                    jsonb_build_object('active', v_vehicle.active), jsonb_build_object('active', p_active));
end;
$$;

-------------------------------------------------------------------------------
-- rpc_add_unavailability: replaces the P01 version (adds ends-in-past check, uses recompute).
-------------------------------------------------------------------------------
create or replace function public.rpc_add_unavailability(
  p_vehicle_id uuid, p_starts_at timestamptz, p_ends_at timestamptz, p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vehicle public.vehicle;
  v_id uuid;
begin
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'invalid_period' using errcode = '22023';
  end if;
  if p_ends_at <= now() then
    raise exception 'ends_in_past' using errcode = '22023';
  end if;
  if char_length(coalesce(p_reason, '')) > 200 then
    raise exception 'reason_too_long' using errcode = '22023';
  end if;

  v_vehicle := app.lock_vehicle_for_member(p_vehicle_id);

  insert into public.vehicle_unavailability (group_id, vehicle_id, period, reason, created_by)
  values (v_vehicle.group_id, p_vehicle_id, tstzrange(p_starts_at, p_ends_at, '[)'),
          nullif(btrim(p_reason), ''), app.current_user_id())
  returning id into v_id;

  perform app.recompute_reconciliation(p_vehicle_id);
  perform app.audit(v_vehicle.group_id, 'vehicle.unavailability.add', 'vehicle_unavailability', v_id, null,
                    jsonb_build_object('starts_at', p_starts_at, 'ends_at', p_ends_at, 'reason', p_reason));
  return v_id;
end;
$$;

create function public.rpc_remove_unavailability(p_unavailability_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.vehicle_unavailability;
begin
  select * into v_row from public.vehicle_unavailability where id = p_unavailability_id;
  if v_row.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.lock_vehicle_for_member(v_row.vehicle_id);

  delete from public.vehicle_unavailability where id = p_unavailability_id;
  perform app.recompute_reconciliation(v_row.vehicle_id);
  perform app.audit(v_row.group_id, 'vehicle.unavailability.remove', 'vehicle_unavailability', v_row.id,
                    jsonb_build_object('starts_at', lower(v_row.period), 'ends_at', upper(v_row.period),
                                       'reason', v_row.reason), null);
end;
$$;

revoke execute on function app.recompute_reconciliation(uuid) from public, anon, authenticated;
revoke execute on function public.rpc_set_vehicle_active(uuid, boolean) from public, anon;
revoke execute on function public.rpc_remove_unavailability(uuid) from public, anon;
grant execute on function public.rpc_set_vehicle_active(uuid, boolean) to authenticated;
grant execute on function public.rpc_remove_unavailability(uuid) to authenticated;
