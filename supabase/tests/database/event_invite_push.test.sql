-- Event invite / cancel pushes go to invitees only (FR-F01, FR-N02, FR-N04). (now() is fixed for the whole test.)
begin;
select plan(18);

\ir _fixtures.psql

-- A third adult in Family A, so there's someone left out of the invite.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a3', 'a3@test.local', '{"display_name":"Ravi"}');
insert into public.group_membership (group_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'member');

insert into public.device_subscription (id, user_id, endpoint, p256dh, auth_secret) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', 'https://push.test/a1', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a2', 'https://push.test/a2', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000a3', 'https://push.test/a3', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-0000000000b1', 'https://push.test/b1', 'k', 'a');

create function pg_temp.deliveries(p_type text) returns text[] language sql as $$
  select coalesce(array_agg(d.user_id::text order by d.user_id), '{}')
    from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
   where o.event_type = p_type
$$;

-------------------------------------------------------------------------------
-- Invite: a1 creates an event inviting a2 (and lists themselves); a3 is not invited.
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.e1', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Dinner At Chinese Village',
  now() + interval '1 day', now() + interval '1 day 2 hours', 'Chinese Village', null,
  array['00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a1']::uuid[], false)::text, true);
select pg_temp.logout();

-- 2026-11-07: a new plan pushes to the whole family; invitees get "invited you" in that one push,
-- so there is no second, separate invite notice at creation.
select is((select count(*) from public.notification_outbox where event_type = 'notify.event_invite'), 0::bigint,
  'no separate invite notice while creating the plan');
select ok((select push from public.notification_outbox where event_type = 'event.create'),
  'the new plan pushes to the family');

select ok(app.process_outbox(100) >= 1, 'the worker processes it');
select is(pg_temp.deliveries('event.create'),
  array['00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3'],
  'everyone in the family but the creator is told (not Family B)');
select is((select count(*) from public.activity_feed where kind = 'event.create'), 1::bigint,
  'everyone still sees the event in the feed');
select is((select count(*) from public.activity_feed where kind like 'notify.%'), 0::bigint,
  'personal notices never enter the family feed');

create temp table claimed as select * from public.dispatch_claim_deliveries(50) where tag = 'event.create';
select is((select c.title from claimed c join public.notification_delivery d on d.id = c.delivery_id
            where d.user_id = '00000000-0000-0000-0000-0000000000a2'), 'Asha invited you', 'the invitee reads "invited you"');
select is((select c.title from claimed c join public.notification_delivery d on d.id = c.delivery_id
            where d.user_id = '00000000-0000-0000-0000-0000000000a3'), 'Asha made a plan', 'everyone else reads "made a plan"');
select ok((select bool_and(body like '%Chinese%') from claimed), 'the lock screen names the plan');
select is((select min(url) from claimed), '/family/events/' || current_setting('t.e1'), 'tapping opens the event');

-------------------------------------------------------------------------------
-- Adding someone later: editing the event to invite a3 notifies only a3.
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_update_event(current_setting('t.e1')::uuid, 'Dinner At Chinese Village',
  now() + interval '1 day', now() + interval '1 day 2 hours', 'Chinese Village', null,
  array['00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3']::uuid[],
  (select version from public.family_event where id = current_setting('t.e1')::uuid));
select pg_temp.logout();
select is((select array_agg(recipient_id::text) from public.notification_outbox where event_type = 'notify.event_invite'),
  array['00000000-0000-0000-0000-0000000000a3'],
  'a newly added invitee gets one notice; the existing invitee is not re-notified');

-------------------------------------------------------------------------------
-- Cancel: invitees who haven't declined are told; the canceller and decliners are not.
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a3');
select public.rpc_respond_event(current_setting('t.e1')::uuid, 'declined');
select pg_temp.logout();

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_cancel_event(current_setting('t.e1')::uuid);
select public.rpc_cancel_event(current_setting('t.e1')::uuid);   -- second cancel is a no-op
select pg_temp.logout();

select is((select array_agg(recipient_id::text order by recipient_id) from public.notification_outbox where event_type = 'notify.event_cancel'),
  array['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2'],
  'cancel notices for everyone still in (a3 declined), queued once despite the repeat cancel');
select ok(app.process_outbox(100) >= 1, 'the worker processes the cancel');
select is(pg_temp.deliveries('notify.event_cancel'), array['00000000-0000-0000-0000-0000000000a2'],
  'only a2''s phone buzzes: the canceller (a1) is never notified about their own action');
select is((select title from public.dispatch_claim_deliveries(50) where tag = 'notify.event_cancel'),
  'Asha cancelled a plan', 'cancel wording on the lock screen');

-------------------------------------------------------------------------------
-- A new-plan push held overnight is dropped if the plan is cancelled before it would be sent.
-------------------------------------------------------------------------------
update public.notification_delivery set state = 'obsolete' where state = 'scheduled';
insert into public.notification_setting (user_id, quiet_start, quiet_end)
values ('00000000-0000-0000-0000-0000000000a2',
        ((now() at time zone 'Asia/Dubai') - interval '1 hour')::time,
        ((now() at time zone 'Asia/Dubai') + interval '1 hour')::time);

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.e2', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Cinema',
  now() + interval '2 days', now() + interval '2 days 3 hours', null, null,
  array['00000000-0000-0000-0000-0000000000a2']::uuid[], false)::text, true);
select pg_temp.logout();
select app.process_outbox(100);
select ok((select d.not_before > now() from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
            where o.event_type = 'event.create' and o.subject_id = current_setting('t.e2')::uuid
              and d.user_id = '00000000-0000-0000-0000-0000000000a2'),
  'quiet hours hold the new-plan push');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_cancel_event(current_setting('t.e2')::uuid);
select pg_temp.logout();
update public.notification_delivery d set not_before = now()
  from public.notification_outbox o where o.id = d.outbox_id and o.subject_id = current_setting('t.e2')::uuid;
select is((select count(*) from public.dispatch_claim_deliveries(50) where tag = 'event.create'), 0::bigint,
  'once quiet hours end, the stale new-plan push is not sent');
select is((select d.state from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
            where o.event_type = 'event.create' and o.subject_id = current_setting('t.e2')::uuid
              and d.user_id = '00000000-0000-0000-0000-0000000000a2'),
  'obsolete', 'it is marked obsolete instead');

select * from finish();
rollback;
