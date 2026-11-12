-- Family tasks: assign, accept/decline, complete, cancel; who is notified; what the family feed shows.
begin;
select plan(36);

\ir _fixtures.psql

-- A third adult in Family A.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a3', 'a3@test.local', '{"display_name":"Ravi"}');
insert into public.group_membership (group_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'member');

insert into public.device_subscription (id, user_id, endpoint, p256dh, auth_secret) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', 'https://push.test/a1', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a2', 'https://push.test/a2', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000a3', 'https://push.test/a3', 'k', 'a');

create function pg_temp.deliveries(p_type text) returns text[] language sql as $$
  select coalesce(array_agg(d.user_id::text order by d.user_id), '{}')
    from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
   where o.event_type = p_type
$$;

-------------------------------------------------------------------------------
-- Validation
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.rpc_create_task('00000000-0000-0000-0000-00000000000a', 'Buy milk', null, '{}') $$,
  '22023', 'assignee_required', 'a task needs someone to do it');
select throws_ok($$ select public.rpc_create_task('00000000-0000-0000-0000-00000000000a', 'Buy milk', null,
  array['00000000-0000-0000-0000-0000000000a1']::uuid[]) $$,
  '22023', 'assignee_required', 'assigning only yourself is not assigning anyone');
select throws_ok($$ select public.rpc_create_task('00000000-0000-0000-0000-00000000000a', '  ', null,
  array['00000000-0000-0000-0000-0000000000a2']::uuid[]) $$,
  '22023', 'invalid_title', 'a task needs a title');
select throws_ok($$ select public.rpc_create_task('00000000-0000-0000-0000-00000000000a', 'Buy milk', null,
  array['00000000-0000-0000-0000-0000000000b1']::uuid[]) $$,
  '22023', 'participant_not_member', 'cannot assign someone from another family');
select throws_ok($$ select public.rpc_create_task('00000000-0000-0000-0000-00000000000b', 'Buy milk', null,
  array['00000000-0000-0000-0000-0000000000b1']::uuid[]) $$,
  'P0002', 'not_found', 'cannot create a task in another family');

-------------------------------------------------------------------------------
-- Create: a1 assigns a2 and a3. Each assignee is notified; the creator and the feed are not.
-------------------------------------------------------------------------------
select set_config('t.t1', public.rpc_create_task('00000000-0000-0000-0000-00000000000a', 'Pick Up Dry Cleaning',
  'Ticket is on the fridge', array['00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3']::uuid[])::text, true);
select pg_temp.logout();

select is((select count(*) from public.task_assignee where task_id = current_setting('t.t1')::uuid and state = 'pending'),
  2::bigint, 'both assignees start pending');
select is((select array_agg(recipient_id::text order by recipient_id) from public.notification_outbox where event_type = 'notify.task_assigned'),
  array['00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3'], 'one assignment notice per assignee');
select ok(app.process_outbox(100) >= 2, 'the worker processes them');
select is(pg_temp.deliveries('notify.task_assigned'),
  array['00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3'], 'each assignee''s phone gets it, not the creator''s');
select is((select count(*) from public.activity_feed where kind like 'notify.%' or kind like 'task.%'), 0::bigint,
  'creating a task does not enter the family feed');
select set_config('t.claim', (
  select row_to_json(c)::text from public.dispatch_claim_deliveries(50) c where c.tag = 'notify.task_assigned' limit 1), true);
select is(current_setting('t.claim')::json ->> 'url', '/family/tasks/' || current_setting('t.t1'), 'tapping opens the task');
select is(current_setting('t.claim')::json ->> 'title', 'New task from Asha', 'the lock screen says who the task is from');
select is(current_setting('t.claim')::json ->> 'body', E'Pick Up Dry Cleaning
Ticket is on the fridge', 'and what it is');

-- Everyone in the family can see it; other families can't.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a3');
select is((select count(*) from public.family_task), 1::bigint, 'family members see the task');
select pg_temp.logout();
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select is((select count(*) from public.family_task), 0::bigint, 'other families do not');
select throws_ok(format('select public.rpc_respond_task(%L, ''accepted'')', current_setting('t.t1')),
  'P0002', 'not_found', 'and cannot answer it');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Respond: a2 accepts, a3 declines. The creator hears about both.
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok(format('select public.rpc_respond_task(%L, ''accepted'')', current_setting('t.t1')), 'a2 accepts');
select lives_ok(format('select public.rpc_respond_task(%L, ''accepted'')', current_setting('t.t1')), 'accepting twice is a no-op');
select pg_temp.logout();
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a3');
select throws_ok(format('select public.rpc_complete_task(%L)', current_setting('t.t1')),
  '55000', 'not_assigned', 'an assignee who has not accepted cannot mark it done');
select lives_ok(format('select public.rpc_respond_task(%L, ''declined'')', current_setting('t.t1')), 'a3 declines');
select pg_temp.logout();
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(format('select public.rpc_respond_task(%L, ''accepted'')', current_setting('t.t1')),
  '55000', 'not_assigned', 'the creator is not an assignee');
select pg_temp.logout();

select is((select count(*) from public.notification_outbox where event_type = 'notify.task_accepted'), 1::bigint,
  'one acceptance notice despite the repeat');
select is((select recipient_id::text from public.notification_outbox where event_type = 'notify.task_accepted'),
  '00000000-0000-0000-0000-0000000000a1', 'addressed to the creator');
select is((select recipient_id::text from public.notification_outbox where event_type = 'notify.task_declined'),
  '00000000-0000-0000-0000-0000000000a1', 'the creator is told about the decline too');
select app.process_outbox(100);
select is(pg_temp.deliveries('notify.task_accepted'), array['00000000-0000-0000-0000-0000000000a1'],
  'only the creator''s phone gets the acceptance');
select is((select title from public.dispatch_claim_deliveries(50) where tag = 'notify.task_accepted'),
  'Sam accepted your task', 'acceptance wording on the lock screen');

-------------------------------------------------------------------------------
-- Complete: a2 marks it done. The family feed shows it; the creator is notified.
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok(format('select public.rpc_complete_task(%L)', current_setting('t.t1')), 'the accepted assignee marks it done');
select lives_ok(format('select public.rpc_complete_task(%L)', current_setting('t.t1')), 'marking it done twice is a no-op');
select pg_temp.logout();
select is((select completed_by::text from public.family_task where id = current_setting('t.t1')::uuid),
  '00000000-0000-0000-0000-0000000000a2', 'records who did it');
select app.process_outbox(100);
select is((select count(*) from public.activity_feed where kind = 'task.complete'), 1::bigint,
  'the completion shows once in the family feed');
select is((select data ->> 'title' from public.activity_feed where kind = 'task.complete'), 'Pick Up Dry Cleaning',
  'with the task title');
select is(pg_temp.deliveries('notify.task_completed'), array['00000000-0000-0000-0000-0000000000a1'],
  'the creator''s phone is told it is done');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a3');
select throws_ok(format('select public.rpc_respond_task(%L, ''accepted'')', current_setting('t.t1')),
  '55000', 'task_closed', 'a finished task cannot be answered');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Cancel: only the creator; assignees still in are told.
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.t2', public.rpc_create_task('00000000-0000-0000-0000-00000000000a', 'Wash The Car', null,
  array['00000000-0000-0000-0000-0000000000a2']::uuid[])::text, true);
select pg_temp.logout();
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(format('select public.rpc_cancel_task(%L)', current_setting('t.t2')),
  '42501', 'not_task_creator', 'an assignee cannot delete the task');
select pg_temp.logout();
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_cancel_task(current_setting('t.t2')::uuid);
select pg_temp.logout();
select is((select array_agg(recipient_id::text) from public.notification_outbox
            where event_type = 'notify.task_cancel' and subject_id = current_setting('t.t2')::uuid),
  array['00000000-0000-0000-0000-0000000000a2'], 'the assignee is told it was cancelled');
select app.process_outbox(100);
select is((select count(*) from public.dispatch_claim_deliveries(50) where tag = 'notify.task_assigned'), 0::bigint,
  'an unsent assignment for a cancelled task is dropped');

select * from finish();
rollback;
