-- Family menus: propose, everyone notified, accept or modify, acceptances reset on a new version.
begin;
select plan(26);

\ir _fixtures.psql

-- A third adult in Family A.
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
-- Who has accepted the menu's current version.
create function pg_temp.accepted(p_menu text) returns text[] language sql as $$
  select coalesce(array_agg(a.user_id::text order by a.user_id), '{}')
    from public.menu_acceptance a join public.family_menu m on m.id = a.menu_id and a.version = m.version
   where m.id = p_menu::uuid
$$;

-------------------------------------------------------------------------------
-- Validation
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.rpc_create_menu('00000000-0000-0000-0000-00000000000a', current_date + 1, '   ') $$,
  '22023', 'menu_required', 'a menu needs something on it');
select throws_ok($$ select public.rpc_create_menu('00000000-0000-0000-0000-00000000000a', current_date - 2, 'Dal') $$,
  '22023', 'ends_in_past', 'a menu cannot be for a day that has gone');
select throws_ok($$ select public.rpc_create_menu('00000000-0000-0000-0000-00000000000b', current_date + 1, 'Dal') $$,
  'P0002', 'not_found', 'cannot propose a menu to another family');

-------------------------------------------------------------------------------
-- Propose: everyone else is notified; nothing in the family feed
-------------------------------------------------------------------------------
select set_config('t.m1', public.rpc_create_menu('00000000-0000-0000-0000-00000000000a', current_date + 1,
  '  Lunch: dal, rice. Dinner: paneer tikka  ')::text, true);
select pg_temp.logout();

select is((select items from public.family_menu where id = current_setting('t.m1')::uuid),
  'Lunch: dal, rice. Dinner: paneer tikka', 'the menu is saved, trimmed');
select is(pg_temp.accepted(current_setting('t.m1')), array['00000000-0000-0000-0000-0000000000a1'],
  'the proposer counts as having accepted it');
select is((select recipient_id from public.notification_outbox where event_type = 'notify.menu_proposed'), null::uuid,
  'the notice is for the whole family, not an invite list');
select ok(app.process_outbox(100) >= 1, 'the worker processes it');
select is(pg_temp.deliveries('notify.menu_proposed'),
  array['00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3'],
  'everyone in the family is pushed except the proposer, and no other family');
select is((select count(*) from public.activity_feed where kind like 'notify.%' or kind like 'menu.%'), 0::bigint,
  'menus stay out of the family feed');

-------------------------------------------------------------------------------
-- Accept
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok(format('select public.rpc_accept_menu(%L, 1)', current_setting('t.m1')), 'a2 accepts');
select lives_ok(format('select public.rpc_accept_menu(%L, 1)', current_setting('t.m1')), 'accepting twice is harmless');
select pg_temp.logout();
select is(pg_temp.accepted(current_setting('t.m1')),
  array['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2'], 'the creator can see who has accepted');

-------------------------------------------------------------------------------
-- Modify: new version, everyone else notified, earlier acceptances no longer count
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a3');
select is(public.rpc_modify_menu(current_setting('t.m1')::uuid, 'Lunch: dal, rice. Dinner: biryani', 1), 2,
  'a3 modifies it: version 2');
select pg_temp.logout();
select is(pg_temp.accepted(current_setting('t.m1')), array['00000000-0000-0000-0000-0000000000a3'],
  'only the modifier has accepted the new version');
select is((select updated_by from public.family_menu where id = current_setting('t.m1')::uuid),
  '00000000-0000-0000-0000-0000000000a3'::uuid, 'and is recorded as its author');
select app.process_outbox(100);
select is(pg_temp.deliveries('notify.menu_modified'),
  array['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2'],
  'everyone else, including the original proposer, is told about the change');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(format('select public.rpc_accept_menu(%L, 1)', current_setting('t.m1')),
  '55000', 'stale_version', 'accepting the old version is refused: they have to look at the new one');
select throws_ok(format('select public.rpc_modify_menu(%L, %L, 1)', current_setting('t.m1'), 'Pasta'),
  '55000', 'stale_version', 'modifying from an old version cannot overwrite someone else''s change');
select lives_ok(format('select public.rpc_accept_menu(%L, 2)', current_setting('t.m1')), 'accepting the new version works');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Dispatch: superseded notices are dropped; generic wording; deep link
-------------------------------------------------------------------------------
create temp table claims as select * from public.dispatch_claim_deliveries(50);
select is((select count(*) from claims where tag = 'notify.menu_proposed'), 0::bigint,
  'a notice about an older version is dropped, not sent');
select is((select distinct title from claims where tag = 'notify.menu_modified'), 'Ravi changed tomorrow''s menu',
  'the lock screen says who changed which menu');
select is((select distinct body from claims where tag = 'notify.menu_modified'), 'Lunch: dal, rice. Dinner: biryani',
  'and shows the dishes');
select is((select distinct url from claims where tag = 'notify.menu_modified'), '/family/menus/' || current_setting('t.m1'),
  'tapping it opens the menu');

-------------------------------------------------------------------------------
-- Privacy
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select is((select count(*) from public.family_menu), 0::bigint, 'another family cannot see the menu');
select throws_ok(format('select public.rpc_accept_menu(%L, 2)', current_setting('t.m1')),
  'P0002', 'not_found', 'or accept it');
select pg_temp.logout();

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select is(jsonb_array_length(public.rpc_export_my_data() -> 'menus_proposed'), 1, 'menus are in the proposer''s data export');
select pg_temp.logout();

select * from finish();
rollback;
