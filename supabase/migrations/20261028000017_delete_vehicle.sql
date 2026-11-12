-- Delete a car (founder request, 28 Oct 2026): offered under Inactive Cars, for a car the family no
-- longer has. Any adult member may do it (D09 parity with deactivate). Two guards keep it safe:
--   * the car must be inactive first, so deleting is always a deliberate second step;
--   * it must have no live bookings (upcoming or reported out), so nobody loses a plan they rely on.
-- Its past bookings, maintenance, outings and their status history go with it, the same cascade the
-- nightly retention already uses. Family events keep their details and simply lose the car link.
-- The audit trail keeps a record of who deleted which car.

create function public.rpc_delete_vehicle(p_vehicle_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vehicle public.vehicle;
begin
  v_vehicle := app.lock_vehicle_for_member(p_vehicle_id);

  if v_vehicle.active then
    raise exception 'vehicle_active' using errcode = '55000';
  end if;

  if exists (
    select 1 from public.vehicle_reservation
     where vehicle_id = p_vehicle_id
       and (status = 'in_use_reported' or (status = 'reserved' and upper(period) > now()))
  ) then
    raise exception 'vehicle_has_bookings' using errcode = '55000';
  end if;

  delete from public.vehicle where id = p_vehicle_id;

  perform app.audit(v_vehicle.group_id, 'vehicle.delete', 'vehicle', p_vehicle_id,
                    jsonb_build_object('name', v_vehicle.name), null);
end;
$$;

revoke execute on function public.rpc_delete_vehicle(uuid) from public, anon;
grant execute on function public.rpc_delete_vehicle(uuid) to authenticated;
