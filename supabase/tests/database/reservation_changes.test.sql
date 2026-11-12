-- P05: FR-V06 (owner edits, CAS), FR-V08/T15 (extend never moves others), T16 (override, flagged off),
-- audit immutability.
begin;
select plan(30);

\ir _fixtures.psql

-- Runs a statement that should fail and returns its DETAIL as jsonb.
create function pg_temp.error_detail(p_sql text) returns jsonb language plpgsql as $$
declare
  v_detail text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_detail = pg_exception_detail;
  return v_detail::jsonb;
end;
$$;

-- a1: 10-12, a2: 13-14 on 1 June.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.r1', public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  '2027-06-01 10:00+04', '2027-06-01 12:00+04', 'p05-a1-00001')::text, true);
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select set_config('t.r2', public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  '2027-06-01 13:00+04', '2027-06-01 14:00+04', 'p05-a2-00001')::text, true);

-------------------------------------------------------------------------------
-- Update (FR-V06)
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select is(public.rpc_update_reservation(current_setting('t.r1')::uuid, '2027-06-01 09:00+04', '2027-06-01 11:00+04', 1),
  2, 'owner moves their booking; version goes to 2');
select is((select planned_start from public.outing where reservation_id = current_setting('t.r1')::uuid),
  '2027-06-01 09:00+04'::timestamptz, 'linked outing follows the new schedule');
select lives_ok(
  format('select public.rpc_update_reservation(%L, %L, %L, 2)', current_setting('t.r1'),
         '2027-06-01 10:00+04', '2027-06-01 12:30+04'),
  'resizing over its own old window is fine');
select throws_ok(
  format('select public.rpc_update_reservation(%L, %L, %L, 1)', current_setting('t.r1'),
         '2027-06-01 08:00+04', '2027-06-01 09:00+04'),
  '55000', 'stale_version', 'an edit based on an old version is rejected (no lost updates)');
select throws_ok(
  format('select public.rpc_update_reservation(%L, %L, %L, 3)', current_setting('t.r1'),
         '2027-06-01 12:00+04', '2027-06-01 13:30+04'),
  '23P01', 'reservation_conflict', 'moving onto another booking is rejected');
select is(
  pg_temp.error_detail(format('select public.rpc_update_reservation(%L, %L, %L, 3)', current_setting('t.r1'),
         '2027-06-01 12:00+04', '2027-06-01 13:30+04')) ->> 'reservation_id',
  current_setting('t.r2'), 'the conflict names the clashing booking, so the app can say who and when');
select is((select starts_at from public.vehicle_reservation where id = current_setting('t.r1')::uuid),
  '2027-06-01 10:00+04'::timestamptz, 'rejected edit changed nothing');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(
  format('select public.rpc_update_reservation(%L, %L, %L, 3)', current_setting('t.r1'),
         '2027-06-01 07:00+04', '2027-06-01 08:00+04'),
  '42501', 'not_owner', 'someone else cannot edit your booking');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok(
  format('select public.rpc_update_reservation(%L, %L, %L, 3)', current_setting('t.r1'),
         '2027-06-01 07:00+04', '2027-06-01 08:00+04'),
  'P0002', 'not_found', 'another family cannot edit (or detect) the booking');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select public.rpc_add_unavailability('00000000-0000-0000-0000-0000000000ca',
                     '2027-06-02 08:00+04', '2027-06-02 18:00+04', 'Service') $$, 'maintenance on 2 June');
select throws_ok(
  format('select public.rpc_update_reservation(%L, %L, %L, 3)', current_setting('t.r1'),
         '2027-06-02 10:00+04', '2027-06-02 11:00+04'),
  '23P01', 'vehicle_unavailable', 'cannot move a booking into maintenance');
select throws_ok(
  format('select public.rpc_update_reservation(%L, %L, %L, 3)', current_setting('t.r1'),
         '2027-06-01 10:00+04', '2027-06-20 10:00+04'),
  '22023', 'too_long', 'edits obey the maximum length');

-------------------------------------------------------------------------------
-- Extend (FR-V08, T15)
-------------------------------------------------------------------------------
select is(public.rpc_extend_reservation(current_setting('t.r1')::uuid, '2027-06-01 13:00+04', 3),
  4, 'extending up to the next booking is fine (half-open)');
select throws_ok(
  format('select public.rpc_extend_reservation(%L, %L, 4)', current_setting('t.r1'), '2027-06-01 13:30+04'),
  '23P01', 'reservation_conflict', 'extending into the next booking is rejected (T15)');
select is((select starts_at from public.vehicle_reservation where id = current_setting('t.r2')::uuid),
  '2027-06-01 13:00+04'::timestamptz, 'the next booking was not moved');
select throws_ok(
  format('select public.rpc_extend_reservation(%L, %L, 4)', current_setting('t.r1'), '2027-06-01 12:00+04'),
  '22023', 'invalid_period', 'extend cannot shorten');

-- A car that's out can still be extended; it can't be moved.
select pg_temp.logout();
update public.vehicle_reservation set status = 'in_use_reported' where id = current_setting('t.r2')::uuid;
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok(
  format('select public.rpc_extend_reservation(%L, %L, 1)', current_setting('t.r2'), '2027-06-01 15:00+04'),
  'a booking in use can be extended');
select throws_ok(
  format('select public.rpc_update_reservation(%L, %L, %L, 2)', current_setting('t.r2'),
         '2027-06-01 16:00+04', '2027-06-01 17:00+04'),
  '55000', 'invalid_state', 'a booking in use cannot be moved');
select throws_ok(
  format('select public.rpc_cancel_reservation(%L)', current_setting('t.r2')),
  '55000', 'invalid_state', 'a booking in use cannot be cancelled');

-------------------------------------------------------------------------------
-- Override (T16): off by default; when on, needs a reason and is audited.
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(
  format('select public.rpc_override_reservation(%L, %L)', current_setting('t.r1'), 'Hospital run'),
  '55000', 'feature_disabled', 'override is disabled until OP-05 is decided');

select pg_temp.logout();
update app.feature_flag set enabled = true where name = 'booking_override';
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok(
  format('select public.rpc_override_reservation(%L, %L)', current_setting('t.r1'), 'x'),
  'P0002', 'not_found', 'another family cannot override');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(
  format('select public.rpc_override_reservation(%L, %L)', current_setting('t.r1'), '   '),
  '22023', 'reason_required', 'override needs a reason');
select lives_ok(
  format('select public.rpc_override_reservation(%L, %L)', current_setting('t.r1'), 'Hospital run'),
  'override with a reason works when enabled');
select is((select status::text from public.vehicle_reservation where id = current_setting('t.r1')::uuid),
  'cancelled', 'overridden booking is cancelled');
select is((select reason from public.audit_log where action = 'reservation.override'),
  'Hospital run', 'override reason is in the audit log');
select is((select actor_id from public.audit_log where action = 'reservation.override'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'audit records who overrode');

-------------------------------------------------------------------------------
-- Audit log is append-only
-------------------------------------------------------------------------------
select pg_temp.logout();
select throws_ok($$ update public.audit_log set reason = 'edited' where action = 'reservation.override' $$,
  '42501', 'audit_log is append-only', 'audit rows cannot be edited, even by the owner role');
select throws_ok($$ delete from public.audit_log where action = 'reservation.override' $$,
  '42501', 'audit_log is append-only', 'audit rows cannot be deleted while the family exists');
select lives_ok($$ delete from auth.users where id = '00000000-0000-0000-0000-0000000000a2' $$,
  'deleting an account still works (actor is anonymised)');
select is((select actor_id from public.audit_log where action = 'reservation.override'),
  null, 'deleted account no longer identified in audit rows');

select * from finish();
rollback;
