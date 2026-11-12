-- P04: FR-V01, FR-V02. Permission parity for all adults (D09), cross-group denial, maintenance and
-- deactivation flag (never cancel) affected bookings.
begin;
select plan(25);

\ir _fixtures.psql

-- a2 is a plain member (not custodian): every routine car action must work for them too.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');

select lives_ok(
  $$ select set_config('test.car2', public.rpc_upsert_vehicle('00000000-0000-0000-0000-00000000000a', '  Corolla ')::text, true) $$,
  'a plain member can add a car');
select is((select name from public.vehicle where id = current_setting('test.car2')::uuid), 'Corolla',
  'car name is trimmed');
select throws_ok(
  $$ select public.rpc_upsert_vehicle('00000000-0000-0000-0000-00000000000a', 'corolla') $$,
  '23505', 'duplicate_name', 'car names are unique per family, ignoring case');
select throws_ok(
  $$ select public.rpc_upsert_vehicle('00000000-0000-0000-0000-00000000000a', '   ') $$,
  '22023', 'invalid_name', 'blank car name is rejected');
select lives_ok(
  format('select public.rpc_upsert_vehicle(%L, %L, %L)', '00000000-0000-0000-0000-00000000000a',
         'Family A Car (blue)', '00000000-0000-0000-0000-0000000000ca'),
  'a plain member can rename a car they did not add');

-- Cross-group: b1 can't touch group A's car, and gets the same answer as for a missing car.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok(
  format('select public.rpc_upsert_vehicle(%L, %L, %L)', '00000000-0000-0000-0000-00000000000a',
         'Hijacked', '00000000-0000-0000-0000-0000000000ca'),
  'P0002', 'not_found', 'b1 cannot rename group A''s car');
select throws_ok(
  $$ select public.rpc_upsert_vehicle('00000000-0000-0000-0000-00000000000b', 'x',
       '00000000-0000-0000-0000-0000000000ca') $$,
  'P0002', 'not_found', 'b1 cannot move group A''s car into group B by passing their own group');
select throws_ok(
  $$ select public.rpc_set_vehicle_active('00000000-0000-0000-0000-0000000000ca', false) $$,
  'P0002', 'not_found', 'b1 cannot deactivate group A''s car');
select throws_ok(
  $$ select public.rpc_add_unavailability('00000000-0000-0000-0000-0000000000ca',
       '2027-05-01 08:00+04', '2027-05-01 18:00+04', 'x') $$,
  'P0002', 'not_found', 'b1 cannot add maintenance to group A''s car');

-- Bookings to be affected: a1 on 1 May 10-12, a2 on 2 May 10-12.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  '2027-05-01 10:00+04', '2027-05-01 12:00+04', 'p04-a1-0001');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  '2027-05-02 10:00+04', '2027-05-02 12:00+04', 'p04-a2-0001');

-- Maintenance (FR-V02)
select throws_ok(
  $$ select public.rpc_add_unavailability('00000000-0000-0000-0000-0000000000ca',
       now() - interval '3 hours', now() - interval '1 hour', 'old') $$,
  '22023', 'ends_in_past', 'maintenance that already ended is rejected');
select lives_ok(
  $$ select set_config('test.m1', public.rpc_add_unavailability('00000000-0000-0000-0000-0000000000ca',
       '2027-05-01 08:00+04', '2027-05-01 18:00+04', 'Service')::text, true) $$,
  'a plain member can add maintenance');
select lives_ok(
  $$ select set_config('test.m2', public.rpc_add_unavailability('00000000-0000-0000-0000-0000000000ca',
       '2027-05-01 11:00+04', '2027-05-01 13:00+04', 'Tyres')::text, true) $$,
  'overlapping maintenance windows are allowed');
select is((select needs_reconciliation from public.vehicle_reservation where idempotency_key = 'p04-a1-0001'),
  true, 'a1''s booking under maintenance is flagged');
select is((select status::text from public.vehicle_reservation where idempotency_key = 'p04-a1-0001'),
  'reserved', '...but not cancelled');
select is((select needs_reconciliation from public.vehicle_reservation where idempotency_key = 'p04-a2-0001'),
  false, 'booking outside maintenance is not flagged');

select lives_ok(format('select public.rpc_remove_unavailability(%L)', current_setting('test.m1')),
  'a plain member can remove maintenance');
select is((select needs_reconciliation from public.vehicle_reservation where idempotency_key = 'p04-a1-0001'),
  true, 'still flagged while another window overlaps');
select lives_ok(format('select public.rpc_remove_unavailability(%L)', current_setting('test.m2')),
  'remove the second window');
select is((select needs_reconciliation from public.vehicle_reservation where idempotency_key = 'p04-a1-0001'),
  false, 'flag clears once no maintenance overlaps');

-- Deactivation
select lives_ok($$ select public.rpc_set_vehicle_active('00000000-0000-0000-0000-0000000000ca', false) $$,
  'a plain member can deactivate a car');
select is((select count(*) from public.vehicle_reservation
            where vehicle_id = '00000000-0000-0000-0000-0000000000ca' and needs_reconciliation), 2::bigint,
  'every future booking on a deactivated car is flagged');
select throws_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-05-03 10:00+04', '2027-05-03 12:00+04', 'p04-a2-0002') $$,
  '55000', 'vehicle_inactive', 'an inactive car cannot be booked');
select lives_ok($$ select public.rpc_set_vehicle_active('00000000-0000-0000-0000-0000000000ca', true) $$,
  'reactivate');
select is((select count(*) from public.vehicle_reservation
            where vehicle_id = '00000000-0000-0000-0000-0000000000ca' and needs_reconciliation), 0::bigint,
  'flags clear on reactivation');

-- A car that's out can't be deactivated.
select pg_temp.logout();
update public.vehicle_reservation set status = 'in_use_reported' where idempotency_key = 'p04-a2-0001';
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.rpc_set_vehicle_active('00000000-0000-0000-0000-0000000000ca', false) $$,
  '55000', 'vehicle_in_use', 'cannot deactivate a car that is reported out');

select * from finish();
rollback;
