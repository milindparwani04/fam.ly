-- P06: FR-F01..F03, FR-F05, FR-F06, FR-V09, T05.
begin;
select plan(39);

\ir _fixtures.psql

-------------------------------------------------------------------------------
-- Plain shared events
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok(
  $$ select set_config('t.e1', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Grandma''s birthday',
       '2027-07-01 18:00+04', '2027-07-01 22:00+04', 'Grandma''s house', 'Bring the cake',
       array['00000000-0000-0000-0000-0000000000a1']::uuid[])::text, true) $$,
  'a member creates a shared event with an invitee');
select is((select state::text from public.event_participant
            where event_id = current_setting('t.e1')::uuid and user_id = '00000000-0000-0000-0000-0000000000a2'),
  'attending', 'the creator is attending');
select is((select state::text from public.event_participant
            where event_id = current_setting('t.e1')::uuid and user_id = '00000000-0000-0000-0000-0000000000a1'),
  'invited', 'an invitee is only invited, not assumed attending (FR-F06)');
select is((select count(*) from public.vehicle_reservation), 0::bigint, 'a plain event occupies no car');

select throws_ok(
  $$ select public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'x', '2027-07-02 10:00+04',
       '2027-07-02 11:00+04', null, null, array['00000000-0000-0000-0000-0000000000b1']::uuid[]) $$,
  '22023', 'participant_not_member', 'cannot invite someone from another family');
select throws_ok(
  $$ select public.rpc_create_event('00000000-0000-0000-0000-00000000000a', '  ', '2027-07-02 10:00+04',
       '2027-07-02 11:00+04') $$,
  '22023', 'invalid_title', 'blank title is rejected');

-- Visibility (D04, FR-F03, T05)
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select is((select description from public.family_event where id = current_setting('t.e1')::uuid),
  'Bring the cake', 'any member reads full details');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select is((select count(*) from public.family_event), 0::bigint, 'another family sees no events');
select is((select count(*) from public.event_participant), 0::bigint, 'another family sees no participants');
select throws_ok(
  $$ select public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'x', '2027-07-02 10:00+04', '2027-07-02 11:00+04') $$,
  'P0002', 'not_found', 'another family cannot add events');
select throws_ok(format('select public.rpc_cancel_event(%L)', current_setting('t.e1')),
  'P0002', 'not_found', 'another family cannot cancel events');

-- Editing a plain event: any adult (D09), with optimistic versioning.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select is(public.rpc_update_event(current_setting('t.e1')::uuid, 'Grandma''s 80th', '2027-07-01 18:30+04',
            '2027-07-01 22:00+04', 'Grandma''s house', 'Bring the cake',
            array['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2']::uuid[], 1),
  2, 'a member who did not create a plain event can edit it');
select throws_ok(
  format('select public.rpc_update_event(%L, %L, %L, %L, null, null, null, 1)', current_setting('t.e1'),
         'x', '2027-07-01 18:00+04', '2027-07-01 19:00+04'),
  '55000', 'stale_version', 'editing from an old version is rejected');
select lives_ok(format('select public.rpc_respond_event(%L, %L)', current_setting('t.e1'), 'attending'),
  'an invitee can accept');
select is((select state::text from public.event_participant
            where event_id = current_setting('t.e1')::uuid and user_id = '00000000-0000-0000-0000-0000000000a1'),
  'attending', 'acceptance is recorded only when the invitee says so');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select set_config('t.e2', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Gym',
  '2027-07-03 07:00+04', '2027-07-03 08:00+04')::text, true);
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(format('select public.rpc_respond_event(%L, %L)', current_setting('t.e2'), 'attending'),
  '55000', 'not_invited', 'you can only respond to events you were invited to');

-------------------------------------------------------------------------------
-- Car-free outing (FR-F02)
-------------------------------------------------------------------------------
select lives_ok(
  $$ select set_config('t.e3', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Dinner out',
       '2027-07-04 19:00+04', '2027-07-04 23:00+04', 'Marina', null, '{}', true)::text, true) $$,
  'a member logs an outing with no car');
select is((select o.reservation_id from public.outing o join public.family_event e on e.outing_id = o.id
            where e.id = current_setting('t.e3')::uuid), null, 'the outing has no booking');
select is((select count(*) from public.vehicle_reservation), 0::bigint, '...and occupies no car');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(format('select public.rpc_cancel_event(%L)', current_setting('t.e3')),
  '42501', 'not_owner', 'only the person going out can cancel their outing');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  format('select public.rpc_update_event(%L, %L, %L, %L, %L, null, null, 1)', current_setting('t.e3'),
         'Dinner out', '2027-07-04 20:00+04', '2027-07-05 00:30+04', 'Marina'),
  'the owner moves their outing (crossing midnight)');
select is((select planned_return from public.outing o join public.family_event e on e.outing_id = o.id
            where e.id = current_setting('t.e3')::uuid),
  '2027-07-05 00:30+04'::timestamptz, 'the outing''s planned return follows');
select lives_ok(format('select public.rpc_cancel_event(%L)', current_setting('t.e3')), 'owner cancels the outing');
select is((select o.status::text from public.outing o join public.family_event e on e.outing_id = o.id
            where e.id = current_setting('t.e3')::uuid), 'cancelled', 'the car-free outing is cancelled with it');

-------------------------------------------------------------------------------
-- Every booking is on the Family calendar (migration 021)
-------------------------------------------------------------------------------
select set_config('t.r1', public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  '2027-07-10 09:00+04', '2027-07-10 13:00+04', 'p06-a1-00001')::text, true);
select set_config('t.e4', (select id::text from public.family_event
  where reservation_id = current_setting('t.r1')::uuid and cancelled_at is null), true);
select is((select title from public.family_event where id = current_setting('t.e4')::uuid),
  'Family A Car trip', 'booking a car puts it on the Family calendar by itself');
select results_eq(
  format('select user_id, state::text from public.event_participant where event_id = %L', current_setting('t.e4')),
  $$ values ('00000000-0000-0000-0000-0000000000a1'::uuid, 'attending') $$,
  'the booker is going, and nobody else is invited yet');
select is((select e.outing_id from public.family_event e where e.id = current_setting('t.e4')::uuid),
  (select id from public.outing where reservation_id = current_setting('t.r1')::uuid),
  'the plan is linked to the booking''s trip, so I''m Leaving can use it');
select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  '2027-07-10 09:00+04', '2027-07-10 13:00+04', 'p06-a1-00001');
select is((select count(*) from public.family_event where reservation_id = current_setting('t.r1')::uuid), 1::bigint,
  'a retried booking is on the calendar once');
select pg_temp.logout();
select is((select count(*) from public.notification_outbox where subject_id = current_setting('t.e4')::uuid), 0::bigint,
  'the automatic plan sends no push of its own (the booking already does)');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_update_reservation(current_setting('t.r1')::uuid, '2027-07-10 10:00+04', '2027-07-10 14:00+04', 1);
select is((select starts_at from public.family_event where id = current_setting('t.e4')::uuid),
  '2027-07-10 10:00+04'::timestamptz, 'moving the booking moves its calendar event');
select throws_ok(
  format('select public.rpc_update_event(%L, %L, %L, %L, null, null, null, 2)', current_setting('t.e4'),
         'Beach day', '2027-07-10 08:00+04', '2027-07-10 14:00+04'),
  '55000', 'times_follow_booking', 'a linked event''s times can only change via the booking');
select lives_ok(
  format('select public.rpc_update_event(%L, %L, %L, %L, %L, null, %L, 2)', current_setting('t.e4'),
         'Beach day', '2027-07-10 10:00+04', '2027-07-10 14:00+04', 'Jumeirah',
         '{00000000-0000-0000-0000-0000000000a2}'),
  'the booker names the trip, adds a place and invites someone');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(format('select public.rpc_cancel_event(%L)', current_setting('t.e4')),
  '42501', 'not_owner', 'someone else cannot remove the trip');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(format('select public.rpc_cancel_event(%L)', current_setting('t.e4')),
  '55000', 'cancel_the_booking', 'a booking can''t be taken off the calendar by itself');

select public.rpc_cancel_reservation(current_setting('t.r1')::uuid);
select isnt((select cancelled_at from public.family_event where id = current_setting('t.e4')::uuid), null,
  'cancelling the booking takes it off the calendar');
select pg_temp.logout();
select ok(exists (select 1 from public.notification_outbox
   where subject_id = current_setting('t.e4')::uuid and event_type = 'notify.event_cancel'
     and recipient_id = '00000000-0000-0000-0000-0000000000a2'),
  '...and tells the person invited');

-------------------------------------------------------------------------------
-- Leaving cancels your planned car-free outings (FR-A06 / T19)
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select set_config('t.e5', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Run',
  '2027-07-20 06:00+04', '2027-07-20 07:00+04', null, null, '{}', true)::text, true);
select public.rpc_leave_group('00000000-0000-0000-0000-00000000000a');
select pg_temp.logout();
select is((select o.status::text from public.outing o join public.family_event e on e.outing_id = o.id
            where e.id = current_setting('t.e5')::uuid), 'cancelled', 'a leaver''s planned outing is cancelled');
select isnt((select cancelled_at from public.family_event where id = current_setting('t.e5')::uuid), null,
  '...and its Family calendar entry too');
select is((select cancelled_at from public.family_event where id = current_setting('t.e1')::uuid), null,
  'shared events they took part in are untouched');

select * from finish();
rollback;
