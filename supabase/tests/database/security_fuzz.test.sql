-- P09-7 / T22 / NFR-01: every client RPC, called by another family with this family's ids, is refused,
-- and nothing changes. New rpc_* functions are picked up automatically.
begin;
select plan(9);

\ir _fixtures.psql
update public.profile set adult_attested_at = now();

-- Give family A one of everything an id can point at.
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('f.res', public.rpc_create_reservation('00000000-0000-0000-0000-0000000000ca',
  now() + interval '20 minutes', now() + interval '2 hours', 'fuzz-a1-0001')::text, true);
select set_config('f.outing', (select id from public.outing where reservation_id = current_setting('f.res')::uuid)::text, true);
select set_config('f.event', (select id::text from public.family_event where reservation_id = current_setting('f.res')::uuid), true);
select set_config('f.unav', public.rpc_add_unavailability('00000000-0000-0000-0000-0000000000ca',
  now() + interval '3 days', now() + interval '4 days', 'Service')::text, true);
select set_config('f.invite', (public.rpc_create_invite('00000000-0000-0000-0000-00000000000a') ->> 'invitation_id'), true);
select set_config('f.task', public.rpc_create_task('00000000-0000-0000-0000-00000000000a', 'Task', null,
  array['00000000-0000-0000-0000-0000000000a2']::uuid[])::text, true);
select set_config('f.menu', public.rpc_create_menu('00000000-0000-0000-0000-00000000000a', current_date + 1, 'Dal, rice')::text, true);
select pg_temp.logout();
update public.scheduled_prompt set state = 'sent' where outing_id = current_setting('f.outing')::uuid;
select set_config('f.prompt', (select id from public.scheduled_prompt where outing_id = current_setting('f.outing')::uuid and kind = 'departure')::text, true);

-- Fingerprint of everything family A owns.
create function pg_temp.family_a_fingerprint() returns text language sql as $$
  select md5(string_agg(t, '|' order by t)) from (
    select to_jsonb(x)::text t from public.family_group x where id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.group_membership x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.vehicle x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.vehicle_reservation x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.vehicle_unavailability x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.outing x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.family_event x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.event_participant x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.invitation x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.scheduled_prompt x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.status_report x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.family_task x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.task_assignee x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.family_menu x where group_id = '00000000-0000-0000-0000-00000000000a'
    union all select to_jsonb(x)::text from public.menu_acceptance x where group_id = '00000000-0000-0000-0000-00000000000a'
  ) s
$$;
select set_config('f.before', pg_temp.family_a_fingerprint(), true);

-- Value for each parameter: family A's id for id parameters, something plausible otherwise.
create function pg_temp.arg_for(p_name text, p_type text) returns text language sql as $$
  select case
    when p_name = 'p_group_id' then quote_literal('00000000-0000-0000-0000-00000000000a') || '::uuid'
    when p_name = 'p_vehicle_id' then quote_literal('00000000-0000-0000-0000-0000000000ca') || '::uuid'
    when p_name = 'p_reservation_id' then quote_literal(current_setting('f.res')) || '::uuid'
    when p_name = 'p_outing_id' then quote_literal(current_setting('f.outing')) || '::uuid'
    when p_name = 'p_event_id' then quote_literal(current_setting('f.event')) || '::uuid'
    when p_name = 'p_unavailability_id' then quote_literal(current_setting('f.unav')) || '::uuid'
    when p_name = 'p_invitation_id' then quote_literal(current_setting('f.invite')) || '::uuid'
    when p_name = 'p_prompt_id' then quote_literal(current_setting('f.prompt')) || '::uuid'
    when p_name = 'p_task_id' then quote_literal(current_setting('f.task')) || '::uuid'
    when p_name = 'p_menu_id' then quote_literal(current_setting('f.menu')) || '::uuid'
    when p_name = 'p_user_id' then quote_literal('00000000-0000-0000-0000-0000000000a1') || '::uuid'
    when p_type = 'uuid' then quote_literal('00000000-0000-0000-0000-00000000000a') || '::uuid'
    when p_type = 'uuid[]' then quote_literal('{00000000-0000-0000-0000-0000000000a1}') || '::uuid[]'
    when p_type = 'date' then 'current_date + 1'
    when p_type like 'timestamp%' then 'now() + interval ''1 day'''
    when p_type in ('integer', 'bigint') then '1'
    when p_type = 'boolean' then 'false'
    when p_type like 'time%' then '''10:00''::time'
    when p_type = 'participant_state' then '''attending''::public.participant_state'
    when p_type = 'task_assignee_state' then '''accepted''::public.task_assignee_state'
    when p_type = 'status_report_kind' then '''issue''::public.status_report_kind'
    when p_type = 'membership_role' then '''custodian''::public.membership_role'
    else quote_literal('fuzz-value-1234')
  end
$$;

-- Calls every rpc_* that takes at least one id, as b1. Returns each function with 'ok' (got through)
-- or the SQLSTATE it was refused with, so a malformed call can't masquerade as a refusal.
create function pg_temp.fuzz() returns table (fn text, outcome text) language plpgsql as $$
declare
  f record;
  v_sql text;
begin
  for f in
    select p.oid, p.proname,
           array(select pg_temp.arg_for(n, format_type(t, null))
                   from unnest(p.proargnames, p.proargtypes::oid[]) as a(n, t)) as args
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname like 'rpc\_%'
       and exists (select 1 from unnest(p.proargtypes::oid[]) t where t in ('uuid'::regtype, 'uuid[]'::regtype))
  loop
    v_sql := format('select public.%I(%s)', f.proname, array_to_string(f.args, ', '));
    begin
      perform pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
      execute v_sql;
      perform pg_temp.logout();
      fn := f.proname; outcome := 'ok'; return next;   -- a cross-family call got through
    exception when others then
      perform pg_temp.logout();
      fn := f.proname; outcome := sqlstate; return next;
    end;
  end loop;
end;
$$;

select ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'rpc\_%') >= 30,
  'the fuzzer sees the full RPC surface');
create temp table fuzz_results as select * from pg_temp.fuzz();
select ok((select count(*) from fuzz_results) >= 25, 'the fuzzer calls every RPC that takes an id');
select is_empty($$ select fn from fuzz_results where outcome = 'ok' $$,
  'every RPC refuses another family''s ids (T22)');
-- Refusals must be real ones: not found / not allowed / invalid input / wrong state, never a broken call.
select is_empty($$ select fn || ' ' || outcome from fuzz_results where outcome not in ('P0002', '42501', '22023', '55000', '28000') $$,
  'every refusal is a genuine access or validation error, not a malformed call');
select is(pg_temp.family_a_fingerprint(), current_setting('f.before'),
  'family A''s data is byte-for-byte unchanged after the fuzz run');

-- Grants and definer hygiene across the whole API surface (NFR-01).
select is_empty($$
  select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not in ('rpc_preview_invite')
     and p.prokind = 'f' and p.proname not like 'pgtap%' and p.proname not like '\_%'
     and p.proowner <> 'supabase_admin'::regrole $$,
  'anonymous visitors can only preview an invite');
select is_empty($$
  select n.nspname || '.' || p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app') and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%') $$,
  'every SECURITY DEFINER function pins its search_path');
select is_empty($$
  select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and (p.proname like 'dispatch\_%' or p.proname like 'ops\_%')
     and has_function_privilege('authenticated', p.oid, 'execute') $$,
  'operator and dispatch functions are not callable by signed-in users');
select is_empty($$
  select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'app' and c.relkind = 'r'
     and (has_table_privilege('authenticated', c.oid, 'select') or has_table_privilege('anon', c.oid, 'select')) $$,
  'internal app.* tables (config, secrets, logs) are not readable by clients');

select * from finish();
rollback;
