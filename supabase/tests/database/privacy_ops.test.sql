-- P09: FR-D01, FR-D03, FR-D04, NFR-06, NFR-09, T20.
begin;
select plan(32);

\ir _fixtures.psql

update public.profile set adult_attested_at = now();

-------------------------------------------------------------------------------
-- Retention (FR-D01, FR-D04, T20). Group A keeps 90 days of history and 365 of audit.
-------------------------------------------------------------------------------
-- Old finished booking with history, a recent one, and an old booking whose car is STILL out.
insert into public.vehicle_reservation (id, group_id, vehicle_id, owner_id, period, status, idempotency_key) values
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000ca',
   '00000000-0000-0000-0000-0000000000a1', tstzrange(now() - interval '100 days', now() - interval '99 days'), 'completed', 'ret-old-0001'),
  ('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000ca',
   '00000000-0000-0000-0000-0000000000a1', tstzrange(now() - interval '10 days', now() - interval '9 days'), 'completed', 'ret-new-0001'),
  ('00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000ca',
   '00000000-0000-0000-0000-0000000000a2', tstzrange(now() - interval '98 days', now() - interval '97 days'), 'in_use_reported', 'ret-out-0001');
insert into public.outing (id, group_id, owner_id, reservation_id, planned_start, planned_return, status) values
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-000000000101', now() - interval '100 days', now() - interval '99 days', 'returned');
insert into public.status_report (group_id, outing_id, kind, reported_by, reported_at) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000201', 'home_and_car_returned',
   '00000000-0000-0000-0000-0000000000a1', now() - interval '99 days');
insert into public.family_event (group_id, created_by, title, starts_at, ends_at) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'Old dinner', now() - interval '120 days', now() - interval '119 days'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'Recent dinner', now() - interval '5 days', now() - interval '4 days');
insert into public.notification_outbox (group_id, event_type, dedupe_key, state, created_at) values
  ('00000000-0000-0000-0000-00000000000a', 'status.left', 'ret-feed-old', 'processed', now() - interval '95 days'),
  ('00000000-0000-0000-0000-00000000000a', 'status.left', 'ret-feed-new', 'processed', now() - interval '3 days');
insert into public.activity_feed (group_id, outbox_id, kind, created_at)
select group_id, id, event_type, created_at from public.notification_outbox where dedupe_key like 'ret-feed-%';
insert into public.audit_log (group_id, action, target_type, at) values
  ('00000000-0000-0000-0000-00000000000a', 'test.old', 'x', now() - interval '400 days'),
  ('00000000-0000-0000-0000-00000000000a', 'test.mid', 'x', now() - interval '100 days');

select throws_ok($$ delete from public.audit_log where action = 'test.old' $$, '42501', 'audit_log is append-only',
  'outside the nightly purge, the audit log stays append-only');

select ok((app.purge_expired() ->> 'bookings')::int >= 1, 'the nightly purge runs');
select is((select count(*) from public.vehicle_reservation where idempotency_key = 'ret-old-0001'), 0::bigint,
  'a booking finished over 90 days ago is deleted');
select is((select count(*) from public.status_report where outing_id = '00000000-0000-0000-0000-000000000201'), 0::bigint,
  '...with its status history');
select is((select count(*) from public.vehicle_reservation where idempotency_key = 'ret-new-0001'), 1::bigint,
  'a recent booking is kept');
select is((select count(*) from public.vehicle_reservation where idempotency_key = 'ret-out-0001'), 1::bigint,
  'a car that is still out is never purged, however old');
select is((select array_agg(title) from public.family_event), array['Recent dinner'], 'only events older than 90 days go');
select is((select count(*) from public.activity_feed where created_at < now() - interval '90 days'), 0::bigint,
  'old feed records go');
select is((select count(*) from public.activity_feed where created_at > now() - interval '90 days'), 1::bigint,
  'recent feed records stay');
select is((select array_agg(action order by action) from public.audit_log where action like 'test.%'), array['test.mid'],
  'audit rows are kept 365 days, not 90');
select ok(exists (select 1 from app.ops_log where kind = 'retention'), 'the purge logs counts for the operator');

-------------------------------------------------------------------------------
-- Finishing protected deletions (FR-D03, T20)
-------------------------------------------------------------------------------
insert into public.family_group (id, name, deletion_requested_at, deletion_scheduled_for) values
  ('00000000-0000-0000-0000-0000000000c0', 'Due', now() - interval '8 days', now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000000c1', 'Not yet', now() - interval '2 days', now() + interval '5 days');
insert into public.audit_log (group_id, action, target_type) values ('00000000-0000-0000-0000-0000000000c0', 'test.x', 'x');
select is(app.finalize_group_deletions(), 1, 'one family is past its 7-day window');
select is((select array_agg(name) from public.family_group where id in ('00000000-0000-0000-0000-0000000000c0',
  '00000000-0000-0000-0000-0000000000c1')), array['Not yet'], 'only that family is deleted');
select is((select count(*) from public.audit_log where group_id = '00000000-0000-0000-0000-0000000000c0'), 0::bigint,
  'its history goes with it');

-------------------------------------------------------------------------------
-- Export (FR-D03)
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.export', public.rpc_export_my_data()::text, true);
select is((current_setting('t.export')::jsonb -> 'account' ->> 'email'), 'a1@test.local', 'export includes the account');
select is(jsonb_array_length(current_setting('t.export')::jsonb -> 'bookings'), 1, 'export includes my remaining bookings');
select ok(current_setting('t.export') not like '%ret-out%' and current_setting('t.export') not like '%a2@test.local%',
  'export contains nothing of other people''s');

-------------------------------------------------------------------------------
-- Account deletion (FR-D03)
-------------------------------------------------------------------------------
select throws_ok($$ select public.rpc_delete_my_account('yes') $$, '22023', 'confirm_required',
  'deleting needs an explicit confirmation');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok($$ select public.rpc_delete_my_account('DELETE') $$, '55000', 'has_car_in_use',
  'cannot delete your account while a car is out with you');
select pg_temp.logout();
update public.vehicle_reservation set status = 'completed' where idempotency_key = 'ret-out-0001';
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca', now() + interval '1 day',
  now() + interval '1 day 1 hour', 'del-a2-00001');
select lives_ok($$ select public.rpc_delete_my_account('DELETE') $$, 'a member deletes their account');
select pg_temp.logout();
select is((select count(*) from auth.users where id = '00000000-0000-0000-0000-0000000000a2'), 0::bigint, 'the account is gone');
select is((select count(*) from public.profile where user_id = '00000000-0000-0000-0000-0000000000a2'), 0::bigint, '...and the profile');
select is((select count(*) from public.vehicle_reservation where idempotency_key = 'del-a2-00001'), 0::bigint,
  '...and their bookings');
select is((select count(*) from public.family_group where id = '00000000-0000-0000-0000-00000000000a'), 1::bigint,
  'the family they shared remains');
select ok(exists (select 1 from public.audit_log where action = 'member.leave' and actor_id is null),
  'shared history keeps the event but no longer identifies them');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select public.rpc_delete_my_account('DELETE');
select pg_temp.logout();
select is((select count(*) from public.family_group where id = '00000000-0000-0000-0000-00000000000b'), 0::bigint,
  'a family whose only member deletes their account is deleted with them');

-------------------------------------------------------------------------------
-- Client errors and health (NFR-09)
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select public.rpc_report_client_error('TypeError: x is undefined', 'at foo', '/bookings/00000000-0000-0000-0000-000000000102', 'UA');
select pg_temp.logout();
select is((select path from app.client_error), '/bookings/:id', 'stored error paths carry no record ids');
create function pg_temp.flood() returns void language plpgsql as $$
begin
  perform pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
  for i in 1..30 loop perform public.rpc_report_client_error('boom'); end loop;
  perform pg_temp.logout();
end;
$$;
select pg_temp.flood();
select is((select count(*) from app.client_error), 20::bigint, 'error reports are capped at 20 per person per hour');

select is(app.synthetic_check(), null, 'the synthetic journey (book, Left, home) passes');
select is((select count(*) from auth.users where email like 'synthetic-%'), 0::bigint, '...and leaves nothing behind');
select ok((public.ops_health_snapshot() ->> 'ok')::boolean, 'health snapshot reports ok');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.ops_health_snapshot() $$, '42501', null, 'family members cannot call operator functions');

select * from finish();
rollback;
