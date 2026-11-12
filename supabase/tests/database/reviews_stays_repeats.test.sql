-- Migration 019: meal reviews, stays, repeating plans, the 6 pm to-do reminder.
-- (now() is fixed for the whole test; family A is on Asia/Dubai.)
begin;
select plan(54);

\ir _fixtures.psql

insert into public.device_subscription (id, user_id, endpoint, p256dh, auth_secret) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', 'https://push.test/a1', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a2', 'https://push.test/a2', 'k', 'a'),
  ('00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-0000000000b1', 'https://push.test/b1', 'k', 'a');

create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Asia/Dubai')::date $$;

-------------------------------------------------------------------------------
-- Meal reviews
-------------------------------------------------------------------------------
-- m1 yesterday (window open), both accepted. m2 tomorrow (not yet). m3 three days ago (shut).
-- m4 yesterday, only Asha accepted. m5 yesterday, changed to v2 which only Sam accepted.
insert into public.family_menu (id, group_id, created_by, menu_date, items, version, updated_by) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', pg_temp.today() - 1, E'Dal\nRice', 1, '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', pg_temp.today() + 1, 'Pasta', 1, '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', pg_temp.today() - 3, 'Soup', 1, '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000e4', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', pg_temp.today() - 1, 'Tacos', 1, '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000e5', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', pg_temp.today() - 1, 'Curry', 2, '00000000-0000-0000-0000-0000000000a2');
insert into public.menu_acceptance (group_id, menu_id, user_id, version) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000a1', 1),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000a2', 1),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000a1', 1),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000a1', 1),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000e4', '00000000-0000-0000-0000-0000000000a1', 1),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000e5', '00000000-0000-0000-0000-0000000000a1', 1),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000e5', '00000000-0000-0000-0000-0000000000a2', 2);

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.rpc_review_menu('00000000-0000-0000-0000-0000000000e2', 4) $$,
  '55000', 'review_not_open', 'reviews open at 22:00 on the day');
select throws_ok($$ select public.rpc_review_menu('00000000-0000-0000-0000-0000000000e3', 4) $$,
  '55000', 'review_closed', 'and shut 48 hours later');
select throws_ok($$ select public.rpc_review_menu('00000000-0000-0000-0000-0000000000e1', 6) $$,
  '22023', 'invalid_stars', 'stars are 1 to 5');
select throws_ok($$ select public.rpc_review_menu('00000000-0000-0000-0000-0000000000e1', 4, repeat('x', 501)) $$,
  '22023', 'comment_too_long', 'comments up to 500 characters');
select lives_ok($$ select public.rpc_review_menu('00000000-0000-0000-0000-0000000000e1', 4, '  Lovely dal  ') $$,
  'Asha rates yesterday''s food');
select throws_ok($$ select public.rpc_review_menu('00000000-0000-0000-0000-0000000000e1', 5) $$,
  '55000', 'already_reviewed', 'a review is final');
select is((select comment from public.menu_review where menu_id = '00000000-0000-0000-0000-0000000000e1'), 'Lovely dal',
  'comment trimmed; Asha sees her own review');
select throws_ok($$ select public.rpc_review_menu('00000000-0000-0000-0000-0000000000e5', 3) $$,
  '42501', 'not_reviewer', 'accepting an older version does not count');
select lives_ok($$ select public.rpc_review_menu('00000000-0000-0000-0000-0000000000e4', 5) $$, 'Asha rates the tacos');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select is((select count(*) from public.menu_review where menu_id = '00000000-0000-0000-0000-0000000000e1'), 0::bigint,
  'Sam cannot see ratings before rating');
select is((select count(*) from public.menu_review where menu_id = '00000000-0000-0000-0000-0000000000e4'), 1::bigint,
  'but sees ratings of a menu he was not asked about');
select throws_ok($$ select public.rpc_review_menu('00000000-0000-0000-0000-0000000000e4', 2) $$,
  '42501', 'not_reviewer', 'only people who accepted rate');
select throws_ok($$ select public.rpc_accept_menu('00000000-0000-0000-0000-0000000000e4', 1) $$,
  '55000', 'menu_past', 'no accepting once reviews have opened');
select lives_ok($$ select public.rpc_review_menu('00000000-0000-0000-0000-0000000000e1', 2) $$, 'Sam rates');
select is((select count(*) from public.menu_review where menu_id = '00000000-0000-0000-0000-0000000000e1'), 2::bigint,
  'and now sees everyone''s');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok($$ select public.rpc_review_menu('00000000-0000-0000-0000-0000000000e1', 5) $$,
  'P0002', 'not_found', 'another family cannot rate');
select is((select count(*) from public.menu_review), 0::bigint, 'or see ratings');
select pg_temp.logout();

-- The 22:00 prompt
select app.prompt_menu_reviews();
select is((select array_agg(recipient_id::text) from public.notification_outbox where event_type = 'notify.menu_review'),
  array['00000000-0000-0000-0000-0000000000a2'],
  'only people asked and yet to rate are prompted (Sam, for the curry)');
select is((select subject_id from public.notification_outbox where event_type = 'notify.menu_review'),
  '00000000-0000-0000-0000-0000000000e5'::uuid, 'about the curry');
select is((select review_prompted_at is null from public.family_menu where id = '00000000-0000-0000-0000-0000000000e2'), true,
  'tomorrow''s menu is not prompted yet');
select app.prompt_menu_reviews();
select is((select count(*) from public.notification_outbox where event_type = 'notify.menu_review'), 1::bigint,
  'each menu is prompted once');
select app.process_outbox(100);
create temp table claimed as select * from public.dispatch_claim_deliveries(50);
select matches((select title from claimed where tag = 'notify.menu_review'), '^How was \w+''s food\?$', 'review title');
select is((select body from claimed where tag = 'notify.menu_review'), 'Rate it out of 5 · Curry', 'review body');
select is((select url from claimed where tag = 'notify.menu_review'),
  '/family/menus/00000000-0000-0000-0000-0000000000e5?rate=1', 'opens the rating');

-------------------------------------------------------------------------------
-- Stays
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.rpc_create_stay('00000000-0000-0000-0000-00000000000a', '{}', '  ', pg_temp.today(), pg_temp.today() + 3) $$,
  '22023', 'guest_required', 'a stay needs someone');
select throws_ok($$ select public.rpc_create_stay('00000000-0000-0000-0000-00000000000a', array['00000000-0000-0000-0000-0000000000b1']::uuid[], null, pg_temp.today(), pg_temp.today() + 3) $$,
  '22023', 'participant_not_member', 'guests chosen from the family');
select throws_ok($$ select public.rpc_create_stay('00000000-0000-0000-0000-00000000000a', '{}', 'Aunt May', pg_temp.today() + 3, pg_temp.today()) $$,
  '22023', 'invalid_period', 'leaving before arriving');
select throws_ok($$ select public.rpc_create_stay('00000000-0000-0000-0000-00000000000a', '{}', 'Aunt May', pg_temp.today() - 9, pg_temp.today() - 2) $$,
  '22023', 'ends_in_past', 'no stays that are already over');
select set_config('t.s1', public.rpc_create_stay('00000000-0000-0000-0000-00000000000a',
  array['00000000-0000-0000-0000-0000000000a2']::uuid[], 'Aunt May', pg_temp.today() + 3, pg_temp.today() + 10, 'London', null)::text, true);
select is((select guest_names from public.family_stay where id = current_setting('t.s1')::uuid), array['Sam'],
  'guest names are kept with the stay');
select lives_ok($$ select public.rpc_update_stay(current_setting('t.s1')::uuid, array['00000000-0000-0000-0000-0000000000a2']::uuid[], 'Aunt May', pg_temp.today() + 4, pg_temp.today() + 10, 'London', 'Flight lands 14:05') $$,
  'any member can change a stay');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select is((select count(*) from public.family_stay), 0::bigint, 'another family cannot see stays');
select throws_ok($$ select public.rpc_cancel_stay(current_setting('t.s1')::uuid) $$, 'P0002', 'not_found', 'or cancel them');
select pg_temp.logout();

select app.process_outbox(100);
select is((select array_agg(d.user_id::text) from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
            where o.event_type = 'stay.create'), array['00000000-0000-0000-0000-0000000000a2'],
  'a new stay pushes to the family, not whoever added it');
select is((select count(*) from public.activity_feed where kind in ('stay.create', 'stay.update')), 2::bigint,
  'new and changed stays are in the feed');
create temp table claimed2 as select * from public.dispatch_claim_deliveries(50);
select is((select title from claimed2 where tag = 'stay.create'), 'Asha added a stay', 'stay push title');
select matches((select body from claimed2 where tag = 'stay.create'), '^Sam, Aunt May · from London · ', 'stay push body');
select is((select url from claimed2 where tag = 'stay.create'), '/family?view=stays', 'opens the stays calendar');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok($$ select public.rpc_cancel_stay(current_setting('t.s1')::uuid) $$, 'cancelled');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Repeating plans
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.e1', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Padel',
  now() + interval '1 day', now() + interval '1 day 90 minutes')::text, true);
select set_config('t.e2', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Camping',
  now() + interval '1 day', now() + interval '4 days')::text, true);
select throws_ok($$ select public.rpc_set_event_repeat(current_setting('t.e1')::uuid, 'yearly') $$,
  '22023', 'invalid_repeat', 'daily, weekly, fortnightly or monthly');
select throws_ok($$ select public.rpc_set_event_repeat(current_setting('t.e2')::uuid, 'daily') $$,
  '22023', 'repeat_too_long', 'a 3-day plan cannot repeat daily');
select throws_ok($$ select public.rpc_set_event_repeat(current_setting('t.e1')::uuid, 'weekly', pg_temp.today() - 1) $$,
  '22023', 'invalid_period', 'the end date is after the first time');
select lives_ok($$ select public.rpc_set_event_repeat(current_setting('t.e1')::uuid, 'weekly', pg_temp.today() + 60) $$,
  'padel every week for two months');
select lives_ok($$ select public.rpc_set_event_repeat(current_setting('t.e1')::uuid, null, pg_temp.today() + 60) $$,
  'and back to a one-off');
select is((select row(repeat, repeat_until)::text from public.family_event where id = current_setting('t.e1')::uuid), '(,)',
  'clearing the rule clears its end date');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- 6 pm to-do reminder (family B moved to a zone where it is now evening, family A to morning)
-------------------------------------------------------------------------------
update public.family_group set time_zone = (select name from pg_timezone_names
  where (now() at time zone name)::time between '18:30' and '21:30' order by name limit 1)
 where id = '00000000-0000-0000-0000-00000000000b';
update public.family_group set time_zone = (select name from pg_timezone_names
  where (now() at time zone name)::time between '08:00' and '12:00' order by name limit 1)
 where id = '00000000-0000-0000-0000-00000000000a';
insert into public.family_task (id, group_id, created_by, title, completed_at) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000b1', 'Buy milk', null),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000b1', 'Call plumber', null),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000b1', 'Done already', now()),
  ('00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'Morning task', null);
insert into public.task_assignee (group_id, task_id, user_id, state) values
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1', 'accepted'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000b1', 'pending'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000b1', 'accepted'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-0000000000a2', 'accepted');
select is(app.prompt_task_reminders(), 1, 'one reminder: Bea, whose evening it is');
select is(app.prompt_task_reminders(), 0, 'once a day');
select is((select (data ->> 'count')::int from public.notification_outbox where event_type = 'notify.task_reminder'), 2,
  'counts her two open to-dos, not the finished one');
select app.process_outbox(100);
create temp table claimed3 as select * from public.dispatch_claim_deliveries(50);
select is((select row(title, body, url)::text from claimed3 where tag = 'notify.task_reminder'),
  '("You have 2 to-dos waiting","Buy milk · Call plumber",/family/todos)', 'reminder wording and link');

-------------------------------------------------------------------------------
-- Leaving for a plan
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.e3', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Sunday roast',
  now() + interval '1 hour', now() + interval '3 hours', 'Nana''s house', null,
  array['00000000-0000-0000-0000-0000000000a2']::uuid[])::text, true);
select set_config('t.e4', public.rpc_create_event('00000000-0000-0000-0000-00000000000a', 'Dentist',
  now() + interval '1 hour', now() + interval '2 hours', 'High Street', null, '{}', true)::text, true);
select throws_ok($$ select public.rpc_leave_for_plan(current_setting('t.e4')::uuid) $$,
  '55000', 'use_trip', 'your own tracked trip is left through the trip');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok($$ select public.rpc_leave_for_plan(current_setting('t.e3')::uuid) $$, 'P0002', 'not_found',
  'not another family''s plan');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select is((public.rpc_leave_for_plan(current_setting('t.e3')::uuid, true)) ->> 'state', 'out', 'Sam leaves for the roast');
select is((select row(activity, plan_title, place)::text from public.member_presence
            where user_id = '00000000-0000-0000-0000-0000000000a2'), '(,"Sunday roast","Nana''s house")',
  'the plan and its where are on the presence row');
select pg_temp.logout();
select app.process_outbox(100);
create temp table claimed4 as select * from public.dispatch_claim_deliveries(50);
select is((select body from claimed4 where tag = 'presence.left'), 'Sunday roast · Nana''s house · has the house key',
  'the family is told where');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select public.rpc_set_presence('00000000-0000-0000-0000-00000000000a', false);
select is((select row(state, plan_title, place)::text from public.member_presence
            where user_id = '00000000-0000-0000-0000-0000000000a2'), '(home,,)', 'home forgets the plan');
select pg_temp.logout();

select * from finish();
rollback;
