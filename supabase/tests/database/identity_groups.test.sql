-- P03: FR-A02 (adult gate), FR-A03 (invites), FR-A04 (protected deletion), FR-A05 (multi-group),
-- FR-A06 / T19 (leave/remove reconciliation), sign-up hook.
begin;
select plan(40);

\ir _fixtures.psql

-- c1, d1: brand new accounts with no group. Fixture users a1, a2, b1 are attested adults.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000c1', 'c1@test.local', '{"display_name":"Cal"}'),
  ('00000000-0000-0000-0000-0000000000d1', 'd1@test.local', '{"display_name":"Dee"}');
update public.profile set adult_attested_at = now()
 where user_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2',
                   '00000000-0000-0000-0000-0000000000b1');

-------------------------------------------------------------------------------
-- Adult attestation (FR-A02)
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000c1');
select throws_ok($$ select public.rpc_create_group('C family') $$,
  '42501', 'adult_attestation_required', 'cannot create a group before attesting 18+');
select throws_ok($$ select public.rpc_attest_adult(false) $$,
  '42501', 'adult_attestation_required', 'declining the 18+ confirmation records nothing');
select is((select adult_attested_at from public.profile where user_id = '00000000-0000-0000-0000-0000000000c1'),
  null, 'no attestation stored after declining');
select lives_ok($$ select public.rpc_attest_adult(true) $$, 'attesting 18+ succeeds');
select lives_ok($$ select set_config('test.group_c', public.rpc_create_group('C family')::text, true) $$,
  'attested adult creates a group');
select is((select role::text from public.group_membership
            where group_id = current_setting('test.group_c')::uuid
              and user_id = '00000000-0000-0000-0000-0000000000c1'),
  'custodian', 'group creator is custodian');

-------------------------------------------------------------------------------
-- Invites (FR-A03)
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('test.inv1', public.rpc_create_invite('00000000-0000-0000-0000-00000000000a', 'for Cal')::text, true);
select set_config('test.inv2', public.rpc_create_invite('00000000-0000-0000-0000-00000000000a')::text, true);
select set_config('test.inv3', public.rpc_create_invite('00000000-0000-0000-0000-00000000000a')::text, true);
select ok(char_length(current_setting('test.inv1')::jsonb ->> 'token') >= 43, 'token carries 32 random bytes');
select is((select count(*) from public.invitation where note = 'for Cal'), 1::bigint,
  'members can list their group''s invites');
select throws_ok($$ select token_hash from public.invitation $$, '42501', null,
  'token hashes are not readable by clients');
select throws_ok($$ select public.rpc_create_invite('00000000-0000-0000-0000-00000000000a', null, 500) $$,
  '22023', 'invalid_ttl', 'invite lifetime is capped at 7 days');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok($$ select public.rpc_create_invite('00000000-0000-0000-0000-00000000000a') $$,
  'P0002', 'not_found', 'non-members cannot invite into a group');

select pg_temp.logout();
set local role anon;
select is(public.rpc_preview_invite(current_setting('test.inv1')::jsonb ->> 'token') ->> 'group_name',
  'Family A', 'preview works before sign-up');
select is(public.rpc_preview_invite('not-a-real-token') ->> 'reason', 'invite_invalid',
  'preview rejects unknown tokens');
reset role;

-- Sign-up hook
select ok(app.hook_before_user_created(
  '{"user":{"email":"stranger@test.local","user_metadata":{}}}') ? 'error',
  'hook rejects sign-up without invite');
select is(app.hook_before_user_created(jsonb_build_object('user', jsonb_build_object(
  'email', 'new@test.local',
  'user_metadata', jsonb_build_object('invite_token', current_setting('test.inv1')::jsonb ->> 'token')))),
  '{}'::jsonb, 'hook allows sign-up carrying a valid invite token');
insert into app.signup_allowlist (email) values ('pgtap-founder@test.local');
select is(app.hook_before_user_created('{"user":{"email":"PGTAP-Founder@test.local","user_metadata":{}}}'),
  '{}'::jsonb, 'hook allows allowlisted email (case-insensitive)');

-- Accept
select pg_temp.login_as('00000000-0000-0000-0000-0000000000d1');
select throws_ok(format('select public.rpc_accept_invite(%L)', current_setting('test.inv1')::jsonb ->> 'token'),
  '42501', 'adult_attestation_required', 'cannot join without attesting 18+');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000c1');
select is(public.rpc_accept_invite(current_setting('test.inv1')::jsonb ->> 'token'),
  '00000000-0000-0000-0000-00000000000a'::uuid, 'accepting joins exactly the inviting family');
select is((select count(*) from public.family_group), 2::bigint,
  'multi-group: c1 now sees both their groups (FR-A05)');
select is((select count(*) from public.vehicle where group_id = '00000000-0000-0000-0000-00000000000a'), 1::bigint,
  'new member sees the family''s cars');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok(format('select public.rpc_accept_invite(%L)', current_setting('test.inv1')::jsonb ->> 'token'),
  '22023', 'invite_used', 'a used invite cannot be reused');

select pg_temp.logout();
update public.invitation set created_at = now() - interval '2 hours', expires_at = now() - interval '1 second'
 where id = (current_setting('test.inv2')::jsonb ->> 'invitation_id')::uuid;
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok(format('select public.rpc_revoke_invite(%L)', current_setting('test.inv3')::jsonb ->> 'invitation_id'),
  'any member can revoke an invite');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok(format('select public.rpc_accept_invite(%L)', current_setting('test.inv2')::jsonb ->> 'token'),
  '22023', 'invite_expired', 'an expired invite is rejected');
select throws_ok(format('select public.rpc_accept_invite(%L)', current_setting('test.inv3')::jsonb ->> 'token'),
  '22023', 'invite_revoked', 'a revoked invite is rejected');
select throws_ok($$ select public.rpc_accept_invite('garbage') $$,
  '22023', 'invite_invalid', 'an unknown token is rejected');

-------------------------------------------------------------------------------
-- Leaving and removal (FR-A06, OP-07 interim)
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  '2027-04-01 10:00+04', '2027-04-01 12:00+04', 'a2-leave-00001');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000c1');
select public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  '2027-04-02 10:00+04', '2027-04-02 12:00+04', 'c1-inuse-00001');
select pg_temp.logout();
update public.vehicle_reservation set status = 'in_use_reported' where idempotency_key = 'c1-inuse-00001';

select pg_temp.login_as('00000000-0000-0000-0000-0000000000c1');
select throws_ok($$ select public.rpc_leave_group('00000000-0000-0000-0000-00000000000a') $$,
  '55000', 'has_car_in_use', 'cannot leave while a car is reported in use');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok($$ select public.rpc_leave_group('00000000-0000-0000-0000-00000000000a') $$,
  'member with only future bookings can leave');
select is((select count(*) from public.vehicle_reservation), 0::bigint,
  'after leaving, the family''s data is no longer visible');
select pg_temp.logout();
select is((select status::text from public.vehicle_reservation where idempotency_key = 'a2-leave-00001'),
  'cancelled', 'leaver''s future booking is cancelled, not orphaned');
select ok(exists (select 1 from public.audit_log where action = 'reservation.cancel_on_exit'),
  'the cancellation is audited');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok($$ select public.rpc_leave_group('00000000-0000-0000-0000-00000000000b') $$,
  '55000', 'last_member', 'the last member cannot leave (delete the group instead)');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.rpc_remove_member('00000000-0000-0000-0000-00000000000a',
                    '00000000-0000-0000-0000-0000000000c1', '  ') $$,
  '22023', 'reason_required', 'removing someone requires a reason');

-- Custodian succession: a1 (only custodian of A) leaves; c1 is the remaining member.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000c1');
select throws_ok($$ select public.rpc_set_member_role('00000000-0000-0000-0000-00000000000a',
                    '00000000-0000-0000-0000-0000000000c1', 'custodian') $$,
  '42501', 'custodian_required', 'only custodians can grant the custodian role');
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select public.rpc_leave_group('00000000-0000-0000-0000-00000000000a') $$,
  'custodian can leave');
select pg_temp.logout();
select is((select role::text from public.group_membership
            where group_id = '00000000-0000-0000-0000-00000000000a'
              and user_id = '00000000-0000-0000-0000-0000000000c1'),
  'custodian', 'remaining member inherits custodian so the group is never unmanaged');

-------------------------------------------------------------------------------
-- Protected deletion (FR-A04, OP-06 interim) on group C: c1 custodian, b1 member.
-------------------------------------------------------------------------------
insert into public.group_membership (group_id, user_id)
values (current_setting('test.group_c')::uuid, '00000000-0000-0000-0000-0000000000b1');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select throws_ok(format('select public.rpc_request_group_deletion(%L, %L)', current_setting('test.group_c'), 'C family'),
  '42501', 'custodian_required', 'a non-custodian cannot start deletion');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000c1');
select throws_ok(format('select public.rpc_request_group_deletion(%L, %L)', current_setting('test.group_c'), 'c family'),
  '22023', 'confirm_name_mismatch', 'deletion needs the exact group name typed');
select ok(public.rpc_request_group_deletion(current_setting('test.group_c')::uuid, 'C family')
            between now() + interval '7 days' - interval '1 minute' and now() + interval '7 days' + interval '1 minute',
  'deletion is scheduled 7 days out, not immediate');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select lives_ok(format('select public.rpc_cancel_group_deletion(%L)', current_setting('test.group_c')),
  'any adult can cancel a pending deletion');
select is((select deletion_requested_at from public.family_group where id = current_setting('test.group_c')::uuid),
  null, 'group is back to normal after cancellation');

select * from finish();
rollback;
