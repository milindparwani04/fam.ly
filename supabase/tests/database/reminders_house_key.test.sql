-- 30-minute heads-up reminders before leaving and before getting home; "Left" records the house key.
begin;
select plan(23);

\ir _fixtures.psql

insert into public.device_subscription (id, user_id, endpoint, p256dh, auth_secret) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', 'https://push.test/a1', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a2', 'https://push.test/a2', 'k', 'a');

create function pg_temp.prompt_state(p_outing text, p_kind text) returns text language sql as $$
  select state from public.scheduled_prompt where outing_id = p_outing::uuid and kind = p_kind
$$;

-------------------------------------------------------------------------------
-- Planning
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.r1', public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  now() + interval '2 hours', now() + interval '4 hours', 'rem-a1-00001')::text, true);
select set_config('t.o1', (select id from public.outing where reservation_id = current_setting('t.r1')::uuid)::text, true);
-- Booked 10 minutes ahead: its heads-up time has already gone.
select set_config('t.r2', public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  now() + interval '10 minutes', now() + interval '1 hour', 'rem-a1-00002')::text, true);
select set_config('t.o2', (select id from public.outing where reservation_id = current_setting('t.r2')::uuid)::text, true);
select pg_temp.logout();

select is((select due_at from public.scheduled_prompt where outing_id = current_setting('t.o1')::uuid and kind = 'departure_soon'),
  now() + interval '90 minutes', 'a booking schedules a heads-up 30 minutes before it starts');
select is((select count(*) from public.scheduled_prompt where outing_id = current_setting('t.o1')::uuid and kind like 'return%'),
  0::bigint, 'no return reminder until they have left');

-------------------------------------------------------------------------------
-- Sending the departure heads-up
-------------------------------------------------------------------------------
update public.scheduled_prompt set due_at = now() - interval '1 minute'
 where outing_id = current_setting('t.o1')::uuid and kind = 'departure_soon';
select app.process_prompts(100);
select is(pg_temp.prompt_state(current_setting('t.o1'), 'departure_soon'), 'sent', 'a due heads-up is sent');
select is(pg_temp.prompt_state(current_setting('t.o1'), 'departure'), 'pending', 'the departure prompt itself is untouched');
select is(pg_temp.prompt_state(current_setting('t.o2'), 'departure_soon'), 'expired',
  'a heads-up that is already late (booked at the last minute) is expired, not sent');
select is((select recipient_id from public.notification_outbox where event_type = 'prompt.departure_soon'),
  '00000000-0000-0000-0000-0000000000a1'::uuid, 'the heads-up is for the person going out only');
select is((select count(*) from public.notification_outbox where event_type = 'prompt.departure_soon'), 1::bigint,
  'one heads-up, none for the late booking');

select app.process_outbox(100);
select is((select array_agg(d.user_id::text) from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
            where o.event_type = 'prompt.departure_soon'), array['00000000-0000-0000-0000-0000000000a1'], 'it pushes to their phone only');
select is((select count(*) from public.activity_feed where kind like 'prompt.%'), 0::bigint, 'it never enters the family feed');
select set_config('t.claim', (
  select row_to_json(c)::text from public.dispatch_claim_deliveries(50) c where c.tag = 'prompt.departure_soon'), true);
select is(current_setting('t.claim')::json ->> 'body',
  'Your Family A Car trip starts at ' || to_char((now() + interval '2 hours') at time zone 'Asia/Dubai', 'HH24:MI') || '. Ready to leave?',
  'the heads-up names the car and the time');
select is(current_setting('t.claim')::json ->> 'url', '/bookings/' || current_setting('t.r1'), 'tapping it opens the booking');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(format('select public.rpc_snooze_prompt((select id from public.scheduled_prompt where outing_id = %L and kind = ''departure_soon''))',
                        current_setting('t.o1')),
  '55000', 'invalid_state', 'a heads-up asks for nothing, so it cannot be snoozed');
select public.rpc_cancel_reservation(current_setting('t.r1')::uuid);
select pg_temp.logout();
select is(pg_temp.prompt_state(current_setting('t.o1'), 'departure_soon'), 'obsolete', 'cancelling the booking retires the heads-up');

-------------------------------------------------------------------------------
-- Left, with the house key
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.left', (public.rpc_report_left(current_setting('t.o2')::uuid, 'rem-left-0001', true) ->> 'report_id'), true);
select pg_temp.logout();
select is((select payload ->> 'has_house_key' from public.status_report where id = current_setting('t.left')::uuid), 'true',
  'Left records that they have the house key');
select is((select due_at from public.scheduled_prompt where outing_id = current_setting('t.o2')::uuid and kind = 'return_soon'),
  now() + interval '30 minutes', 'leaving schedules a reminder 30 minutes before they are due home');
select app.process_outbox(100);
select is((select data ->> 'has_house_key' from public.activity_feed where kind = 'status.left'), 'true',
  'the family feed carries the house key answer');

-- An outing without a car, reported by a phone on the old app (no key answer).
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select set_config('t.e3', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Walk',
  now() + interval '10 minutes', now() + interval '1 hour', null, null, '{}', true)::text, true);
select set_config('t.o3', (select outing_id from public.family_event where id = current_setting('t.e3')::uuid)::text, true);
select set_config('t.left3', (public.rpc_report_left(current_setting('t.o3')::uuid, 'rem-left-0003') ->> 'report_id'), true);
select pg_temp.logout();
select ok(not ((select payload from public.status_report where id = current_setting('t.left3')::uuid) ? 'has_house_key'),
  'without an answer, nothing is claimed about the key');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select public.rpc_correct_status(current_setting('t.o3')::uuid, 'left', 'Mistake', 'rem-undo-0003');
select set_config('t.left4', (public.rpc_report_left(current_setting('t.o3')::uuid, 'rem-left-0004', false) ->> 'report_id'), true);
select pg_temp.logout();
select is((select payload ->> 'has_house_key' from public.status_report where id = current_setting('t.left4')::uuid), 'false',
  'Left records that they do not have the house key');

-------------------------------------------------------------------------------
-- Return reminder
-------------------------------------------------------------------------------
update public.scheduled_prompt set due_at = now() - interval '1 minute'
 where outing_id = current_setting('t.o2')::uuid and kind = 'return_soon';
select app.process_prompts(100);
select is(pg_temp.prompt_state(current_setting('t.o2'), 'return_soon'), 'sent', 'the due-home reminder is sent');
select app.process_outbox(100);
create temp table claims2 as select * from public.dispatch_claim_deliveries(50);
select is((select c.title from claims2 c where c.tag = 'prompt.return_soon'), 'Due home in 30 minutes', 'the due-home reminder says so');
select ok(exists (select 1 from claims2 c where c.tag = 'status.left' and c.title = 'Asha has left the house'),
  'others see who left the house on their lock screen');
select ok((select bool_or(c.body like '%has the house key%') from claims2 c where c.tag = 'status.left'),
  'including whether they have the house key');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_confirm_home(current_setting('t.o2')::uuid, 'rem-home-0002');
select pg_temp.logout();
select is(pg_temp.prompt_state(current_setting('t.o2'), 'return_soon'), 'acted', 'getting home settles the reminder');

select * from finish();
rollback;
