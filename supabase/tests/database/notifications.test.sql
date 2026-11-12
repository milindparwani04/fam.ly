-- P08: FR-S02/S03/S05, FR-N01–N07, T08, T09, T10, T17, T21. (now() is fixed for the whole test.)
begin;
select plan(51);

\ir _fixtures.psql

-- Devices: a1 has two, a2 one, b1 one.
insert into public.device_subscription (id, user_id, endpoint, p256dh, auth_secret) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', 'https://push.test/a1-phone', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a1', 'https://push.test/a1-laptop', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000a2', 'https://push.test/a2-phone', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-0000000000b1', 'https://push.test/b1-phone', 'k', 'a');

-------------------------------------------------------------------------------
-- Prompt planning (FR-S02)
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.r1', public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  now() + interval '30 minutes', now() + interval '2 hours', 'p08-a1-00001')::text, true);
select set_config('t.o1', (select id from public.outing where reservation_id = current_setting('t.r1')::uuid)::text, true);
select pg_temp.logout();

select is((select due_at from public.scheduled_prompt where outing_id = current_setting('t.o1')::uuid and kind = 'departure'),
  now() + interval '30 minutes', 'a booking schedules a departure prompt at its start');
select is((select count(*) from public.notification_outbox where event_type = 'reservation.create'), 1::bigint,
  'the booking is one outbox event');
select ok((select push from public.notification_outbox where event_type = 'reservation.create'),
  'a new booking pushes to the family, so nobody is surprised by what''s free (2026-11-07)');

-------------------------------------------------------------------------------
-- Departure → feed + pushes (FR-N01, FR-N02), quiet hours (T17)
-------------------------------------------------------------------------------
-- a2 is in quiet hours right now (an hour either side of now, in their zone).
insert into public.notification_setting (user_id, quiet_start, quiet_end)
values ('00000000-0000-0000-0000-0000000000a2',
        ((now() at time zone 'Asia/Dubai') - interval '1 hour')::time,
        ((now() at time zone 'Asia/Dubai') + interval '1 hour')::time);

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_report_left(current_setting('t.o1')::uuid, 'p08-left-0001');
select pg_temp.logout();

select is((select state from public.scheduled_prompt where outing_id = current_setting('t.o1')::uuid and kind = 'departure'),
  'acted', 'tapping Left settles the departure prompt');
select is((select due_at from public.scheduled_prompt where outing_id = current_setting('t.o1')::uuid and kind = 'return'),
  now() + interval '2 hours', 'and schedules a return prompt at the planned return (FR-S05)');
select ok((select push from public.notification_outbox where event_type = 'status.left'), 'a departure pushes');

select ok(app.process_outbox(100) >= 2, 'the worker processes the pending events');
select is((select count(*) from public.activity_feed where kind = 'status.left'), 1::bigint,
  'the departure is one feed record');
select is((select data ->> 'vehicle_name' from public.activity_feed where kind = 'status.left'), 'Family A Car',
  'the feed record carries context for the app');
select is(app.process_outbox(100), 0, 'running the worker again finds nothing to do');
select is((select count(*) from public.activity_feed where kind = 'status.left'), 1::bigint,
  'and still one feed record (T21)');

select is(
  (select array_agg(device_id::text order by device_id) from public.notification_delivery d
     join public.notification_outbox o on o.id = d.outbox_id where o.event_type = 'status.left'),
  array['00000000-0000-0000-0000-0000000000d3'],
  'pushes go to other family members only: not the actor, not another family');
select ok(
  (select d.not_before > now() + interval '50 minutes' from public.notification_delivery d
     join public.notification_outbox o on o.id = d.outbox_id
    where d.device_id = '00000000-0000-0000-0000-0000000000d3' and o.event_type = 'status.left'),
  'a member in quiet hours gets the push deferred until their quiet hours end (T17)');

-- Feed visibility (FR-N01)
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select is((select count(*) from public.activity_feed where kind = 'status.left'), 1::bigint,
  'the quiet-hours member still sees the feed record');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select is((select count(*) from public.activity_feed), 0::bigint, 'another family sees no feed records');
select throws_ok($$ select * from public.notification_outbox $$, '42501', null, 'clients cannot read the outbox');
select throws_ok($$ select * from public.notification_delivery $$, '42501', null, 'clients cannot read deliveries');
select throws_ok($$ select * from public.dispatch_claim_deliveries(10) $$, '42501', null,
  'clients cannot claim deliveries');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Worker failure and retry (NFR-05, T21)
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_report_issue(current_setting('t.o1')::uuid, 'eta_update', now() + interval '3 hours', 'Traffic', 'p08-eta-00001');
select pg_temp.logout();
select set_config('app.fault_inject', 'outbox_fail', true);
select app.process_outbox(100);
select set_config('app.fault_inject', '', true);
select is((select attempts from public.notification_outbox where event_type = 'status.eta_update'), 1,
  'a failed attempt is counted');
select is((select count(*) from public.activity_feed where kind = 'status.eta_update'), 0::bigint,
  'a failed attempt leaves no partial feed record');
select is((select due_at from public.scheduled_prompt where outing_id = current_setting('t.o1')::uuid and kind = 'return'),
  now() + interval '3 hours', 'a later ETA moves the return prompt');
update public.notification_outbox set next_attempt_at = now() where event_type = 'status.eta_update';
select app.process_outbox(100);
select app.process_outbox(100);
select is((select count(*) from public.activity_feed where kind = 'status.eta_update'), 1::bigint,
  'the retry produces exactly one feed record (T21)');

-- Dead letter after repeated failure.
create function pg_temp.fail_until_dead(p_type text) returns text language plpgsql as $$
begin
  perform set_config('app.fault_inject', 'outbox_fail', true);
  for i in 1..6 loop
    update public.notification_outbox set next_attempt_at = now() where event_type = p_type and state = 'pending';
    perform app.process_outbox(100);
  end loop;
  perform set_config('app.fault_inject', '', true);
  return (select state from public.notification_outbox where event_type = p_type);
end;
$$;
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_report_issue(current_setting('t.o1')::uuid, 'issue', null, 'Flat', 'p08-iss-00001');
select pg_temp.logout();
select is(pg_temp.fail_until_dead('status.issue'), 'dead', 'an event that keeps failing is dead-lettered, not retried forever');

-------------------------------------------------------------------------------
-- Prompts at fire time (FR-N05, T09, T10)
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.e2', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Walk',
  now() + interval '10 minutes', now() + interval '1 hour', null, null, '{}', true)::text, true);
select set_config('t.o2', (select outing_id from public.family_event where id = current_setting('t.e2')::uuid)::text, true);
select set_config('t.r3', public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  now() + interval '3 hours', now() + interval '4 hours', 'p08-a1-00003')::text, true);
select set_config('t.o3', (select id from public.outing where reservation_id = current_setting('t.r3')::uuid)::text, true);
select pg_temp.logout();
update public.scheduled_prompt set due_at = now() - interval '1 minute'
 where outing_id in (current_setting('t.o2')::uuid, current_setting('t.o3')::uuid) and kind = 'departure';

-- T10: cancelled just before its prompt fires.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_cancel_reservation(current_setting('t.r3')::uuid);
select pg_temp.logout();
select is((select state from public.scheduled_prompt where outing_id = current_setting('t.o3')::uuid and kind = 'departure'),
  'obsolete', 'cancelling makes the queued prompt inert in the same transaction (T10)');

select ok(app.process_prompts(100) >= 1, 'the prompt worker runs');
select is((select state from public.scheduled_prompt where outing_id = current_setting('t.o2')::uuid and kind = 'departure'),
  'sent', 'a due prompt for a live outing is sent');
select is((select count(*) from public.notification_outbox where event_type = 'prompt.departure'), 1::bigint,
  'one prompt event, none for the cancelled booking (T10)');
select is((select recipient_id from public.notification_outbox where event_type = 'prompt.departure'),
  '00000000-0000-0000-0000-0000000000a1'::uuid, 'the prompt is for the person going out only');
select is((select status::text from public.outing where id = current_setting('t.o2')::uuid), 'planned',
  'an unanswered prompt never marks anyone as left (T09)');

select app.process_outbox(100);
select is((select count(*) from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
            where o.event_type = 'prompt.departure'), 2::bigint, 'the prompt goes to both of the owner''s devices');
select is((select count(*) from public.activity_feed where kind like 'prompt.%'), 0::bigint,
  'prompts are personal: they never appear in the family feed');

-- Snooze (FR-S03, T08)
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(
  format('select public.rpc_snooze_prompt((select id from public.scheduled_prompt where outing_id = %L and kind = ''departure''))',
         current_setting('t.o2')),
  'P0002', 'not_found', 'another member cannot see or snooze my prompt');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.p2', (select id from public.scheduled_prompt where outing_id = current_setting('t.o2')::uuid and kind = 'departure')::text, true);
select is(public.rpc_snooze_prompt(current_setting('t.p2')::uuid), now() + interval '15 minutes', 'snooze moves the prompt 15 minutes');
select is((select snooze_count from public.scheduled_prompt where id = current_setting('t.p2')::uuid), 1, 'and counts it');
select pg_temp.logout();
update public.scheduled_prompt set state = 'sent', snooze_count = 4 where id = current_setting('t.p2')::uuid;
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(format('select public.rpc_snooze_prompt(%L)', current_setting('t.p2')),
  '55000', 'snooze_limit', 'snoozing past the family''s cap is refused (T08)');
select is((select public.rpc_report_left(current_setting('t.o2')::uuid, 'p08-left-0002') ->> 'kind'), 'left',
  'at the cap, the in-app action still works');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Dispatch: relevance, privacy, outcomes (FR-N04, FR-N05, FR-N06)
-------------------------------------------------------------------------------
select is((select count(*) from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
            where o.event_type = 'prompt.departure' and d.state = 'acted'), 2::bigint,
  'acting on the prompt marks its pushes as acted, so they are never sent late');

select app.process_outbox(100);
select is((select count(*) from public.dispatch_claim_deliveries(50)), 0::bigint,
  'nothing is sent to a member while their quiet hours last');
-- Quiet hours end.
update public.notification_delivery set not_before = now() where state = 'scheduled';
create temp table claimed as select * from public.dispatch_claim_deliveries(50);
select ok((select count(*) > 0 from claimed), 'the dispatcher claims due deliveries');
select ok((select count(*) from claimed where title like 'Asha %') > 0,
  'lock-screen text says who did what (founder decision 2026-10-25, replaces FR-N04)');
select is((select count(*) from public.notification_delivery where id in (select delivery_id from claimed) and state = 'dispatched'),
  (select count(*) from claimed), 'claimed deliveries are marked dispatched');
select is((select count(*) from public.dispatch_claim_deliveries(50)), 0::bigint,
  'a second dispatcher cannot claim the same deliveries');

select set_config('t.dl', (select min(delivery_id)::text from claimed), true);
select public.dispatch_complete_delivery(current_setting('t.dl')::bigint, 201);
select is((select state from public.notification_delivery where id = current_setting('t.dl')::bigint),
  'provider_accepted', 'HTTP 201 is recorded as accepted by the push service (not "read")');
select set_config('t.dl2', (select max(delivery_id)::text from claimed), true);
select public.dispatch_complete_delivery(current_setting('t.dl2')::bigint, 410, 'Gone');
select is((select state from public.notification_delivery where id = current_setting('t.dl2')::bigint), 'failed',
  'HTTP 410 fails the delivery');
select isnt((select revoked_at from public.device_subscription s join public.notification_delivery d on d.device_id = s.id
              where d.id = current_setting('t.dl2')::bigint), null, '...and retires the dead subscription');

-------------------------------------------------------------------------------
-- Devices and settings
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok($$ select public.rpc_register_device('https://push.test/a1-laptop', 'k2', 'a2', 'Safari') $$,
  'a browser that changes hands re-registers to the new person');
select throws_ok($$ select endpoint from public.device_subscription $$, '42501', null,
  'clients cannot read push endpoints, even their own');
select throws_ok($$ select public.rpc_register_device('http://insecure.test/x', 'k', 'a') $$,
  '22023', 'invalid_subscription', 'only https push endpoints are accepted');
select throws_ok($$ select public.rpc_update_notification_settings(true, '23:00', null) $$,
  '22023', 'invalid_quiet_hours', 'quiet hours need both a start and an end');
select is((select count(id) from public.device_subscription), 2::bigint, 'members only see their own devices (their phone + the laptop they took over)');
select pg_temp.logout();
select is((select user_id from public.device_subscription where endpoint = 'https://push.test/a1-laptop'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'the re-registered endpoint now belongs to the new person');

select * from finish();
rollback;
