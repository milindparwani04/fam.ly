-- Delete a car (28 Oct 2026): inactive cars only, never with live bookings, any adult member, tenant-isolated.
-- Past bookings, outings and status history go with the car; family events keep their details.
begin;
select plan(16);

\ir _fixtures.psql

-- A finished booking with an outing, status history and a linked family event.
insert into public.vehicle_reservation (id, group_id, vehicle_id, owner_id, period, status, idempotency_key) values
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000ca',
   '00000000-0000-0000-0000-0000000000a1', tstzrange(now() - interval '3 days', now() - interval '2 days'), 'completed', 'del-past-0001');
insert into public.outing (id, group_id, owner_id, reservation_id, planned_start, planned_return, status) values
  ('00000000-0000-0000-0000-000000000401', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-000000000301', now() - interval '3 days', now() - interval '2 days', 'returned');
insert into public.status_report (group_id, outing_id, kind, reported_by, reported_at) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000401', 'home_and_car_returned',
   '00000000-0000-0000-0000-0000000000a1', now() - interval '2 days');
-- The outing put the booking on the calendar (migration 021); the family renamed the plan.
update public.family_event set title = 'Beach day' where reservation_id = '00000000-0000-0000-0000-000000000301';
select set_config('t.ev', (select id::text from public.family_event
  where reservation_id = '00000000-0000-0000-0000-000000000301'), true);
-- An upcoming booking that must block the delete until it's cancelled.
insert into public.vehicle_reservation (id, group_id, vehicle_id, owner_id, period, status, idempotency_key) values
  ('00000000-0000-0000-0000-000000000302', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000ca',
   '00000000-0000-0000-0000-0000000000a1', tstzrange(now() + interval '2 days', now() + interval '3 days'), 'reserved', 'del-next-0001');

-- a2 is a plain member: deleting follows the same parity as deactivating (D09).
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');

select throws_ok(
  $$ select public.rpc_delete_vehicle('00000000-0000-0000-0000-0000000000ca') $$,
  '55000', 'vehicle_active', 'an active car cannot be deleted: deactivate first');

select lives_ok(
  $$ select public.rpc_set_vehicle_active('00000000-0000-0000-0000-0000000000ca', false) $$,
  'the car is deactivated');

select throws_ok(
  $$ select public.rpc_delete_vehicle('00000000-0000-0000-0000-0000000000ca') $$,
  '55000', 'vehicle_has_bookings', 'a car with an upcoming booking cannot be deleted');

-- A car reported out also blocks it, even once its booked time has passed.
select pg_temp.logout();
update public.vehicle_reservation set status = 'cancelled' where id = '00000000-0000-0000-0000-000000000302';
insert into public.vehicle_reservation (id, group_id, vehicle_id, owner_id, period, status, idempotency_key) values
  ('00000000-0000-0000-0000-000000000303', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000ca',
   '00000000-0000-0000-0000-0000000000a1', tstzrange(now() - interval '5 hours', now() - interval '1 hour'), 'in_use_reported', 'del-out-0001');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(
  $$ select public.rpc_delete_vehicle('00000000-0000-0000-0000-0000000000ca') $$,
  '55000', 'vehicle_has_bookings', 'a car that is out right now cannot be deleted');

select pg_temp.logout();
update public.vehicle_reservation set status = 'completed', vehicle_returned_at = now()
 where id = '00000000-0000-0000-0000-000000000303';

-- Another family can't delete it, and gets the same answer as for a missing car.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok(
  $$ select public.rpc_delete_vehicle('00000000-0000-0000-0000-0000000000ca') $$,
  'P0002', 'not_found', 'b1 cannot delete group A''s car');
select throws_ok(
  $$ select public.rpc_delete_vehicle('00000000-0000-0000-0000-0000000000ff') $$,
  'P0002', 'not_found', 'a missing car is not_found');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok(
  $$ select public.rpc_delete_vehicle('00000000-0000-0000-0000-0000000000ca') $$,
  'a plain member deletes an inactive car with no live bookings');

select pg_temp.logout();
select is((select count(*)::int from public.vehicle where id = '00000000-0000-0000-0000-0000000000ca'), 0, 'the car is gone');
select is((select count(*)::int from public.vehicle_reservation where vehicle_id = '00000000-0000-0000-0000-0000000000ca'), 0,
  'its bookings went with it');
select is((select count(*)::int from public.outing where id = '00000000-0000-0000-0000-000000000401'), 0, 'and their outings');
select is((select count(*)::int from public.status_report where outing_id = '00000000-0000-0000-0000-000000000401'), 0,
  'and their status history');
select is((select title from public.family_event where id = current_setting('t.ev')::uuid), 'Beach day',
  'the family event is kept');
select is((select reservation_id from public.family_event where id = current_setting('t.ev')::uuid), null,
  'and only loses its car link');
select is((select count(*)::int from public.audit_log
            where action = 'vehicle.delete' and target_id = '00000000-0000-0000-0000-0000000000ca'
              and actor_id = '00000000-0000-0000-0000-0000000000a2' and before ->> 'name' = 'Family A Car'), 1,
  'the delete is audited with who and which car');
select is((select count(*)::int from public.vehicle where id = '00000000-0000-0000-0000-0000000000cb'), 1,
  'the other family''s car is untouched');

-- Anonymous callers can't reach it at all.
select ok(not has_function_privilege('anon', 'public.rpc_delete_vehicle(uuid)', 'execute'), 'anon cannot execute it');

select * from finish();
rollback;
