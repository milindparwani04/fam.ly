-- FR-V04..V06, FR-V02, T01 (no overlap), T02 (idempotent retry), journey 9 (cancel releases slot).
begin;
select plan(19);

\ir _fixtures.psql

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');

select lives_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-03-01 10:00+04', '2027-03-01 12:00+04', 'a1-key-000001') $$,
  'a1 books 10:00-12:00'
);

select is(
  public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
    '2027-03-01 10:00+04', '2027-03-01 12:00+04', 'a1-key-000001'),
  (select id from public.vehicle_reservation where idempotency_key = 'a1-key-000001'),
  'retry with same key returns the same booking (T02)'
);
select is((select count(*) from public.vehicle_reservation), 1::bigint, 'retry did not create a second row');
select is((select count(*) from public.outing where reservation_id is not null), 1::bigint,
  'exactly one outing created with the booking');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');

select throws_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-03-01 11:00+04', '2027-03-01 13:00+04', 'a2-key-000001') $$,
  '23P01', 'reservation_conflict', 'overlapping booking is rejected (T01)'
);
select throws_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-03-01 09:00+04', '2027-03-01 14:00+04', 'a2-key-000002') $$,
  '23P01', 'reservation_conflict', 'enclosing booking is rejected'
);
select lives_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-03-01 12:00+04', '2027-03-01 14:00+04', 'a2-key-000003') $$,
  'back-to-back booking is allowed (half-open periods)'
);
select lives_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-03-01 23:00+04', '2027-03-02 01:00+04', 'a2-key-000004') $$,
  'cross-midnight booking is allowed'
);
select throws_ok(
  $$ select public.rpc_cancel_reservation(
       (select id from public.vehicle_reservation where idempotency_key = 'a1-key-000001')) $$,
  '42501', 'not_owner', 'a2 cannot cancel a1''s booking'
);

-- Validation
select throws_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       now() - interval '1 hour', now() + interval '1 hour', 'a2-key-000005') $$,
  '22023', 'starts_in_past', 'booking cannot start in the past'
);
select throws_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-03-05 12:00+04', '2027-03-05 10:00+04', 'a2-key-000006') $$,
  '22023', 'invalid_period', 'end before start is rejected'
);
select throws_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-03-05 10:00+04', '2027-03-25 10:00+04', 'a2-key-000007') $$,
  '22023', 'too_long', 'over-long booking is rejected'
);

-- Cancel releases the slot immediately.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  $$ select public.rpc_cancel_reservation(
       (select id from public.vehicle_reservation where idempotency_key = 'a1-key-000001')) $$,
  'a1 cancels own booking'
);
select is((select o.status::text from public.outing o join public.vehicle_reservation r on r.id = o.reservation_id
           where r.idempotency_key = 'a1-key-000001'), 'cancelled', 'linked outing is cancelled too');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-03-01 10:00+04', '2027-03-01 12:00+04', 'a2-key-000008') $$,
  'freed slot can be re-booked'
);

-- Maintenance (FR-V02): blocks new bookings and flags existing ones.
select lives_ok(
  $$ select public.rpc_add_unavailability('00000000-0000-0000-0000-0000000000ca',
       '2027-03-01 13:00+04', '2027-03-01 18:00+04', 'Service') $$,
  'any adult can add a maintenance window'
);
select is(
  (select needs_reconciliation from public.vehicle_reservation where idempotency_key = 'a2-key-000003'),
  true, 'overlapping booking is flagged for reconciliation, not cancelled'
);
select throws_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-03-01 15:00+04', '2027-03-01 16:00+04', 'a2-key-000009') $$,
  '23P01', 'vehicle_unavailable', 'cannot book during maintenance'
);

-- Last line of defence: the constraint holds even if an RPC is bypassed.
select pg_temp.logout();
select throws_ok(
  $$ insert into public.vehicle_reservation (group_id, vehicle_id, owner_id, period, idempotency_key)
     values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000ca',
             '00000000-0000-0000-0000-0000000000b1',
             tstzrange('2027-03-01 10:30+04', '2027-03-01 11:00+04', '[)'), 'raw-insert-01') $$,
  '23P01', null, 'exclusion constraint rejects a raw overlapping insert'
);

select * from finish();
rollback;
