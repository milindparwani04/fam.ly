-- T04, T22, NFR-02: deny by default; group B can neither see nor touch group A.
begin;
select plan(14);

\ir _fixtures.psql

select is_empty(
  $$ select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity $$,
  'every public table has RLS enabled'
);

select is_empty(
  $$ select table_name || ':' || privilege_type from information_schema.role_table_grants
     where table_schema = 'public' and grantee in ('anon', 'authenticated')
       and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE') $$,
  'clients have no direct write grants on any public table'
);

-- Seed one booking in A as a1.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-03-01 10:00+04', '2027-03-01 12:00+04', 'seed-key-0001') $$,
  'a1 books group A car'
);

-- b1 sees nothing of group A.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select is((select count(*) from public.family_group where id = '00000000-0000-0000-0000-00000000000a'), 0::bigint,
  'b1 cannot see group A');
select is((select count(*) from public.group_membership where group_id = '00000000-0000-0000-0000-00000000000a'), 0::bigint,
  'b1 cannot see group A members');
select is((select count(*) from public.vehicle where group_id = '00000000-0000-0000-0000-00000000000a'), 0::bigint,
  'b1 cannot see group A cars');
select is((select count(*) from public.vehicle_reservation where group_id = '00000000-0000-0000-0000-00000000000a'), 0::bigint,
  'b1 cannot see group A bookings');
select is((select count(*) from public.outing where group_id = '00000000-0000-0000-0000-00000000000a'), 0::bigint,
  'b1 cannot see group A outings');
select is((select count(*) from public.profile where user_id = '00000000-0000-0000-0000-0000000000a1'), 0::bigint,
  'b1 cannot see group A profiles');

-- b1 cannot act on group A through RPCs; error is identical to "does not exist".
select throws_ok(
  $$ select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
       '2027-03-02 10:00+04', '2027-03-02 12:00+04', 'foreign-key-001') $$,
  'P0002', 'not_found', 'b1 cannot book group A car'
);
select throws_ok(
  $$ select public.rpc_cancel_reservation(
       (select id from public.vehicle_reservation limit 1)) $$,
  'P0002', 'not_found', 'b1 cannot cancel a booking they cannot see'
);
select throws_ok(
  $$ insert into public.vehicle (group_id, name) values ('00000000-0000-0000-0000-00000000000b', 'Sneaky') $$,
  '42501', null, 'direct table writes are denied even in own group'
);

-- a2 (same group) sees the booking.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select is((select count(*) from public.vehicle_reservation), 1::bigint, 'a2 sees group A booking');

-- anon sees nothing.
select pg_temp.logout();
set local role anon;
select throws_ok($$ select count(*) from public.vehicle_reservation $$, '42501', null,
  'anon has no access at all');

select * from finish();
rollback;
