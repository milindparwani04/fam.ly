-- P07: FR-S01, FR-S06..S09, D05, T07, T11, T12, T13, T14.
begin;
select plan(40);

\ir _fixtures.psql

-- a1's booking starts in 30 minutes; the "Left" window is already open.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.r1', public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  now() + interval '30 minutes', now() + interval '3 hours', 'p07-a1-00001')::text, true);
select set_config('t.o1', (select id from public.outing where reservation_id = current_setting('t.r1')::uuid)::text, true);
select set_config('t.r_far', public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  now() + interval '2 days', now() + interval '2 days 2 hours', 'p07-a1-00002')::text, true);

-------------------------------------------------------------------------------
-- Who can report
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(format('select public.rpc_report_left(%L, %L)', current_setting('t.o1'), 'a2-left-0001'),
  '42501', 'not_owner', 'only the person going out reports for their outing');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok(format('select public.rpc_report_left(%L, %L)', current_setting('t.o1'), 'b1-left-0001'),
  'P0002', 'not_found', 'another family cannot report (or detect) the outing');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  format('select public.rpc_report_left((select id from public.outing where reservation_id = %L), %L)',
         current_setting('t.r_far'), 'a1-left-far1'),
  '55000', 'too_early', 'cannot report leaving more than an hour before the booking');
select throws_ok(format('select public.rpc_report_left(%L, %L)', current_setting('t.o1'), 'short'),
  '22023', 'invalid_idempotency_key', 'a retry key is required');

-------------------------------------------------------------------------------
-- Left (FR-S01) and repeat taps (T07)
-------------------------------------------------------------------------------
select set_config('t.left1', (public.rpc_report_left(current_setting('t.o1')::uuid, 'a1-left-0001') ->> 'report_id'), true);
select is((select status::text from public.outing where id = current_setting('t.o1')::uuid), 'departed',
  'outing is departed');
select is((select status::text from public.vehicle_reservation where id = current_setting('t.r1')::uuid),
  'in_use_reported', 'car is reported in use');
select ok((select departure_reported_at between now() - interval '1 minute' and now() + interval '1 minute'
             from public.outing where id = current_setting('t.o1')::uuid),
  'departure time is the server''s clock, early departure allowed');
select is(public.rpc_report_left(current_setting('t.o1')::uuid, 'a1-left-0001') ->> 'report_id',
  current_setting('t.left1'), 'repeating the same tap returns the same report (T07)');
select is(public.rpc_report_left(current_setting('t.o1')::uuid, 'a1-left-0002') ->> 'report_id',
  current_setting('t.left1'), 'a second device tapping Left gets the existing report');
select is((select count(*) from public.status_report where outing_id = current_setting('t.o1')::uuid and kind = 'left'),
  1::bigint, 'only one Left report exists');

-------------------------------------------------------------------------------
-- Running late / problem (FR-S08, T14)
-------------------------------------------------------------------------------
select lives_ok(
  format('select public.rpc_report_issue(%L, %L, now() + interval ''5 hours'', %L, %L)',
         current_setting('t.o1'), 'eta_update', 'Traffic', 'a1-eta-00001'),
  'owner updates their expected return');
select ok((select expected_return_at > now() + interval '4 hours' from public.outing where id = current_setting('t.o1')::uuid),
  'expected return is recorded');
select ok((select upper(period) < now() + interval '3 hours 1 minute' from public.vehicle_reservation
            where id = current_setting('t.r1')::uuid),
  'the booking period is NOT extended by a late ETA (T14, R3)');
select is((select possession_uncertain from public.vehicle_reservation where id = current_setting('t.r1')::uuid),
  false, 'running late alone does not mark the car uncertain');
select throws_ok(
  format('select public.rpc_report_issue(%L, %L, null, null, %L)', current_setting('t.o1'), 'eta_update', 'a1-eta-00002'),
  '22023', 'eta_required', 'an ETA update needs a time');
select lives_ok(
  format('select public.rpc_report_issue(%L, %L, null, %L, %L)', current_setting('t.o1'), 'issue', 'Flat tyre', 'a1-iss-00001'),
  'owner reports a problem');
select is((select possession_uncertain from public.vehicle_reservation where id = current_setting('t.r1')::uuid),
  true, 'a problem marks the car''s return as uncertain');

-------------------------------------------------------------------------------
-- I'm home — car returned (D05, T11, T12)
-------------------------------------------------------------------------------
select set_config('app.fault_inject', 'confirm_home_mid', true);
select throws_ok(format('select public.rpc_confirm_home(%L, %L)', current_setting('t.o1'), 'a1-home-0001'),
  'XX000', 'fault_injected', 'a failure half-way through "I''m home" ...');
select set_config('app.fault_inject', '', true);
select is((select status::text from public.outing where id = current_setting('t.o1')::uuid), 'departed',
  '... leaves the person NOT marked home (T12)');
select is((select status::text from public.vehicle_reservation where id = current_setting('t.r1')::uuid),
  'in_use_reported', '... and the car NOT marked returned');
select is((select count(*) from public.status_report where outing_id = current_setting('t.o1')::uuid
            and kind = 'home_and_car_returned'), 0::bigint, '... and no report recorded');

select set_config('t.home1', (public.rpc_confirm_home(current_setting('t.o1')::uuid, 'a1-home-0002') ->> 'report_id'), true);
select is((select status::text from public.outing where id = current_setting('t.o1')::uuid), 'returned',
  'person is home');
select is((select status::text from public.vehicle_reservation where id = current_setting('t.r1')::uuid),
  'completed', 'and the car is returned, in the same step (T11)');
select ok((select vehicle_returned_at is not null and not possession_uncertain
             from public.vehicle_reservation where id = current_setting('t.r1')::uuid),
  'return time recorded and uncertainty cleared');
select is((select kind::text from public.status_report where id = current_setting('t.home1')::uuid),
  'home_and_car_returned', 'the report records both assertions');
select is(public.rpc_confirm_home(current_setting('t.o1')::uuid, 'a1-home-0003') ->> 'report_id',
  current_setting('t.home1'), 'tapping again returns the same report (T07)');

-- Early return frees the rest of the window (R3).
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       now() + interval '1 hour', now() + interval '2 hours', 'p07-a2-00001') $$,
  'after an early return, someone else can book the rest of the window');

-- Correcting "I'm home" now would put the car back in use over a2's booking.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  format('select public.rpc_correct_status(%L, %L, %L, %L)', current_setting('t.o1'), 'home', 'Tapped by mistake', 'a1-cor-00001'),
  '23P01', 'cannot_undo_slot_taken', 'undoing "home" is refused once the freed time is booked');

-------------------------------------------------------------------------------
-- Corrections append, never erase (FR-S09) — on a car-free outing
-------------------------------------------------------------------------------
select set_config('t.e2', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Walk',
  now() + interval '10 minutes', now() + interval '1 hour', null, null, '{}', true)::text, true);
select set_config('t.o2', (select outing_id from public.family_event where id = current_setting('t.e2')::uuid)::text, true);
select public.rpc_report_left(current_setting('t.o2')::uuid, 'a1-left-0101');
select throws_ok(
  format('select public.rpc_correct_status(%L, %L, %L, %L)', current_setting('t.o2'), 'left', '  ', 'a1-cor-00101'),
  '22023', 'reason_required', 'a correction needs a reason');
select lives_ok(
  format('select public.rpc_correct_status(%L, %L, %L, %L)', current_setting('t.o2'), 'left', 'Not yet, sorry', 'a1-cor-00102'),
  'owner undoes a mistaken Left');
select is((select status::text from public.outing where id = current_setting('t.o2')::uuid), 'planned',
  'outing is back to planned');
select is((select array_agg(kind::text order by reported_at, kind) from public.status_report
            where outing_id = current_setting('t.o2')::uuid),
  array['left', 'correction'], 'the original Left stays in history, followed by the correction');

-- Forgot to tap Left: "I'm home" still works (car-free => plain "home").
select is(public.rpc_confirm_home(current_setting('t.o2')::uuid, 'a1-home-0101') ->> 'kind', 'home',
  'a car-free outing records plain "home"');
select is((select (payload ->> 'skipped_left')::boolean from public.status_report
            where outing_id = current_setting('t.o2')::uuid and kind = 'home'),
  true, 'the report notes that Left was never tapped');

-------------------------------------------------------------------------------
-- Late departure on an ended booking is refused
-------------------------------------------------------------------------------
select pg_temp.logout();
insert into public.vehicle_reservation (id, group_id, vehicle_id, owner_id, period, idempotency_key)
values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000000a',
        '00000000-0000-0000-0000-0000000000ca', '00000000-0000-0000-0000-0000000000a1',
        tstzrange(now() - interval '3 hours', now() - interval '1 hour', '[)'), 'p07-past-0001');
insert into public.outing (id, group_id, owner_id, reservation_id, planned_start, planned_return)
values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a',
        '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000e1',
        now() - interval '3 hours', now() - interval '1 hour');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.rpc_report_left('00000000-0000-0000-0000-0000000000f1', 'a1-left-past1') $$,
  '55000', 'booking_ended', 'cannot report leaving after the booking has ended');
select lives_ok($$ select public.rpc_confirm_home('00000000-0000-0000-0000-0000000000f1', 'a1-home-past1') $$,
  'but you can still confirm you are home and the car is back');

-------------------------------------------------------------------------------
-- Nonresponse changes nothing (FR-S04) and history is append-only
-------------------------------------------------------------------------------
select is((select status::text from public.vehicle_reservation where id = current_setting('t.r_far')::uuid),
  'reserved', 'a booking nobody reported on stays as booked');
select pg_temp.logout();
select throws_ok($$ update public.status_report set kind = 'home' where kind = 'left' $$,
  '42501', 'status history is append-only', 'status reports cannot be edited');
select throws_ok($$ delete from public.status_report $$,
  '42501', 'status history is append-only', 'status reports cannot be deleted');
select lives_ok($$ delete from public.family_group where id = '00000000-0000-0000-0000-00000000000a' $$,
  'deleting the whole family still removes its history');

select * from finish();
rollback;
