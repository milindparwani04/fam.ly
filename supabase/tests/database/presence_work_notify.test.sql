-- Migration 018: I'm Leaving presence, work hours, notification categories, booking pushes, reopening tasks.
-- (now() is fixed for the whole test.)
begin;
select plan(35);

\ir _fixtures.psql

insert into public.device_subscription (id, user_id, endpoint, p256dh, auth_secret) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', 'https://push.test/a1', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a2', 'https://push.test/a2', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-0000000000b1', 'https://push.test/b1', 'k', 'a');

create function pg_temp.deliveries(p_type text) returns text[] language sql as $$
  select coalesce(array_agg(d.user_id::text order by d.user_id), '{}')
    from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
   where o.event_type = p_type
$$;

-------------------------------------------------------------------------------
-- I'm Leaving / I'm Home
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.rpc_set_presence('00000000-0000-0000-0000-00000000000a', true) $$,
  '22023', 'activity_required', 'leaving needs to say what for');
select throws_ok($$ select public.rpc_set_presence('00000000-0000-0000-0000-00000000000a', true, 'cinema') $$,
  '22023', 'invalid_activity', 'only Drive, Gym, Padel or Errand');
select throws_ok($$ select public.rpc_set_presence('00000000-0000-0000-0000-00000000000b', true, 'gym') $$,
  'P0002', 'not_found', 'not in another family');
select is((public.rpc_set_presence('00000000-0000-0000-0000-00000000000a', true, 'gym', true)) ->> 'state', 'out',
  'Asha leaves for the gym');
select is((public.rpc_set_presence('00000000-0000-0000-0000-00000000000a', true, 'padel')) ->> 'state', 'out',
  'a second tap while out is a quiet update');
select pg_temp.logout();

select is((select count(*) from public.notification_outbox where event_type = 'presence.left'), 1::bigint,
  'one departure event, however many taps');
select is((select activity from public.member_presence where user_id = '00000000-0000-0000-0000-0000000000a1'), 'padel',
  'the activity can be corrected while out');
select app.process_outbox(100);
select is(pg_temp.deliveries('presence.left'), array['00000000-0000-0000-0000-0000000000a2'],
  'the family is pushed, not the person leaving, not another family');
select is((select count(*) from public.activity_feed where kind = 'presence.left'), 1::bigint, 'it is in the family feed');
create temp table claimed as select * from public.dispatch_claim_deliveries(50);
select is((select title from claimed where tag = 'presence.left'), 'Asha has left the house', 'lock-screen title');
select is((select body from claimed where tag = 'presence.left'), 'Gym · has the house key', 'lock-screen body');
select is((select url from claimed where tag = 'presence.left'), '/', 'tapping opens Today');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select is((select state from public.member_presence where user_id = '00000000-0000-0000-0000-0000000000a1'), 'out',
  'family members can see who is out');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select is((select count(*) from public.member_presence), 0::bigint, 'another family cannot');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select is((public.rpc_set_presence('00000000-0000-0000-0000-00000000000a', false)) ->> 'state', 'home', 'Asha is home');
select lives_ok($$ select public.rpc_set_presence('00000000-0000-0000-0000-00000000000a', false) $$, 'home twice is fine');
select pg_temp.logout();
select is((select count(*) from public.notification_outbox where event_type = 'presence.home'), 1::bigint,
  'and announced once');
select is((select activity from public.member_presence where user_id = '00000000-0000-0000-0000-0000000000a1'), null,
  'home clears the activity');
select app.process_outbox(100);
select is((select body from public.dispatch_claim_deliveries(50) where tag = 'presence.home'), 'Back from padel',
  'the home push says where they were');

-------------------------------------------------------------------------------
-- Leaving in a booked car records the activity too
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.r1', public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  now() + interval '10 minutes', now() + interval '2 hours', 'pwn-a1-00001')::text, true);
select set_config('t.o1', (select id from public.outing where reservation_id = current_setting('t.r1')::uuid)::text, true);
select throws_ok(format('select public.rpc_report_left(%L, %L, null, %L)', current_setting('t.o1'), 'pwn-left-0001', 'cinema'),
  '22023', 'invalid_activity', 'activity is checked');
select is((select public.rpc_report_left(current_setting('t.o1')::uuid, 'pwn-left-0002', true, 'errand') ->> 'kind'), 'left',
  'left with the car for an errand');
select pg_temp.logout();
select is((select payload ->> 'activity' from public.status_report where outing_id = current_setting('t.o1')::uuid), 'errand',
  'the activity is in the report');

-------------------------------------------------------------------------------
-- New bookings push, worded with the car and the time
-------------------------------------------------------------------------------
select app.process_outbox(100);
select is(pg_temp.deliveries('reservation.create'), array['00000000-0000-0000-0000-0000000000a2'],
  'a new booking pushes to the rest of the family');
create temp table claimed2 as select * from public.dispatch_claim_deliveries(50);
select is((select title from claimed2 where tag = 'reservation.create'), 'Asha booked Family A Car', 'booking title');
select is((select url from claimed2 where tag = 'reservation.create'), '/bookings/' || current_setting('t.r1'),
  'tapping opens the booking');
select is((select body from claimed2 where tag = 'status.left'), 'Errand · Family A Car · has the house key',
  'the departure push names the activity and the car');

-------------------------------------------------------------------------------
-- Categories
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok($$ select public.rpc_update_notification_categories(true, false, true, true) $$, 'a2 mutes car bookings');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  now() + interval '1 day', now() + interval '1 day 1 hour', 'pwn-a1-00002');
select public.rpc_set_presence('00000000-0000-0000-0000-00000000000a', true, 'drive');
select pg_temp.logout();
select app.process_outbox(100);
select is(pg_temp.deliveries('reservation.create'), array['00000000-0000-0000-0000-0000000000a2'],
  'muted: no push for the second booking');
select is(pg_temp.deliveries('presence.left'), array['00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2'],
  'departures still come through');

-------------------------------------------------------------------------------
-- Work hours
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok($$ select public.rpc_set_work_hours(array[1,8]::smallint[], '09:00', '17:00') $$,
  '22023', 'invalid_work_days', 'days are 1 to 7');
select throws_ok($$ select public.rpc_set_work_hours(array[1]::smallint[], null, null) $$,
  '22023', 'invalid_work_hours', 'working days need hours');
select lives_ok($$ select public.rpc_set_work_hours(array[5,1,2,1]::smallint[], '09:00', '17:30') $$, 'Sam sets work hours');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select is((select days from public.member_work where user_id = '00000000-0000-0000-0000-0000000000a2'), array[1,2,5]::smallint[],
  'the family can see them, tidied');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select is((select count(*) from public.member_work), 0::bigint, 'another family cannot');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Reopening a task
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.t1', public.rpc_create_task('00000000-0000-0000-0000-00000000000a', 'Water the plants', null,
  array['00000000-0000-0000-0000-0000000000a2']::uuid[])::text, true);
select public.rpc_complete_task(current_setting('t.t1')::uuid);
select public.rpc_reopen_task(current_setting('t.t1')::uuid);
select is((select completed_at from public.family_task where id = current_setting('t.t1')::uuid), null, 'unticking reopens it');
select pg_temp.logout();
select * from finish();
rollback;
