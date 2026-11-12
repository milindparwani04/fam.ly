-- P09 Privacy & operations. FR-D01, FR-D03, FR-D04, NFR-06, NFR-09, T20.
-- Founder decisions: shared history kept 90 days (OP-04); audit trail kept 365 days.

alter table public.family_group
  add column audit_retention_days int not null default 365 check (audit_retention_days >= 30);

-------------------------------------------------------------------------------
-- Append-only triggers allow deletes only during sanctioned purges (retention, deletion).
-- `app.purge` is a transaction-local setting; clients cannot set it through the API.
-------------------------------------------------------------------------------
create or replace function app.audit_log_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and (current_setting('app.purge', true) = 'on'
     or not exists (select 1 from public.family_group where id = old.group_id)) then
    return old;
  end if;
  if tg_op = 'UPDATE' and old.actor_id is not null and new.actor_id is null
     and (to_jsonb(new) - 'actor_id') = (to_jsonb(old) - 'actor_id') then
    return new;
  end if;
  raise exception 'audit_log is append-only' using errcode = '42501';
end;
$$;

create or replace function app.status_report_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and (current_setting('app.purge', true) = 'on'
     or not exists (select 1 from public.outing where id = old.outing_id)) then
    return old;
  end if;
  if tg_op = 'UPDATE' and old.reported_by is not null and new.reported_by is null
     and (to_jsonb(new) - 'reported_by') = (to_jsonb(old) - 'reported_by') then
    return new;
  end if;
  raise exception 'status history is append-only' using errcode = '42501';
end;
$$;

-- Operational log for the operator: counts and outcomes only, never personal data.
create table app.ops_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  kind text not null,
  detail jsonb not null default '{}'
);

-------------------------------------------------------------------------------
-- P09-1 Retention (FR-D01, FR-D04, T20). Runs nightly. Never touches a car that is still out.
-------------------------------------------------------------------------------
create function app.purge_expired()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  g record;
  v_cut timestamptz;
  v_audit_cut timestamptz;
  v_n int;
  v_totals jsonb := '{}';
begin
  perform set_config('app.purge', 'on', true);

  for g in select id, retention_days, audit_retention_days from public.family_group loop
    v_cut := now() - make_interval(days => g.retention_days);
    v_audit_cut := now() - make_interval(days => g.audit_retention_days);

    -- Bookings that finished (or were never used) before the cutoff. Their outings, status history
    -- and prompts cascade; linked Family-calendar events lose the link.
    delete from public.vehicle_reservation
     where group_id = g.id and status in ('reserved', 'completed', 'cancelled') and upper(period) < v_cut;
    get diagnostics v_n = row_count;
    v_totals := jsonb_set(v_totals, '{bookings}', to_jsonb(coalesce((v_totals ->> 'bookings')::int, 0) + v_n));

    delete from public.outing
     where group_id = g.id and reservation_id is null and status <> 'departed' and planned_return < v_cut;
    get diagnostics v_n = row_count;
    v_totals := jsonb_set(v_totals, '{outings}', to_jsonb(coalesce((v_totals ->> 'outings')::int, 0) + v_n));

    delete from public.family_event where group_id = g.id and ends_at < v_cut;
    get diagnostics v_n = row_count;
    v_totals := jsonb_set(v_totals, '{events}', to_jsonb(coalesce((v_totals ->> 'events')::int, 0) + v_n));

    delete from public.vehicle_unavailability where group_id = g.id and upper(period) < v_cut;

    delete from public.invitation
     where group_id = g.id and (used_at < v_cut or revoked_at < v_cut or expires_at < v_cut);

    -- Feed rows go with their outbox rows (and deliveries).
    delete from public.notification_outbox where group_id = g.id and created_at < v_cut;
    get diagnostics v_n = row_count;
    v_totals := jsonb_set(v_totals, '{feed_events}', to_jsonb(coalesce((v_totals ->> 'feed_events')::int, 0) + v_n));

    delete from public.audit_log where group_id = g.id and at < v_audit_cut;
    get diagnostics v_n = row_count;
    v_totals := jsonb_set(v_totals, '{audit_rows}', to_jsonb(coalesce((v_totals ->> 'audit_rows')::int, 0) + v_n));
  end loop;

  -- Housekeeping not tied to a family.
  delete from public.notification_delivery where created_at < now() - interval '30 days';
  delete from public.device_subscription where revoked_at < now() - interval '30 days';
  delete from app.client_error where at < now() - interval '30 days';
  delete from app.ops_log where at < now() - interval '180 days';

  insert into app.ops_log (kind, detail) values ('retention', v_totals);
  return v_totals;
end;
$$;

-------------------------------------------------------------------------------
-- P09-3 Finish protected group deletions once the 7-day window has passed (FR-D03, T20).
-------------------------------------------------------------------------------
create function app.finalize_group_deletions()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  perform set_config('app.purge', 'on', true);
  delete from public.family_group where deletion_scheduled_for is not null and deletion_scheduled_for <= now();
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into app.ops_log (kind, detail) values ('group_deleted', jsonb_build_object('count', v_n));
  end if;
  return v_n;
end;
$$;

-------------------------------------------------------------------------------
-- P09-2 Data export and account deletion (FR-D03)
-------------------------------------------------------------------------------
create function public.rpc_export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  return jsonb_build_object(
    'exported_at', now(),
    'account', (select jsonb_build_object('id', u.id, 'email', u.email, 'created_at', u.created_at)
                  from auth.users u where u.id = v_uid),
    'profile', (select to_jsonb(p) from public.profile p where p.user_id = v_uid),
    'families', coalesce((select jsonb_agg(jsonb_build_object('family', g.name, 'role', m.role,
                                                             'joined_at', m.joined_at, 'left_at', m.left_at))
                            from public.group_membership m join public.family_group g on g.id = m.group_id
                           where m.user_id = v_uid), '[]'),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('car', v.name, 'starts_at', r.starts_at, 'ends_at', r.ends_at,
                                                             'status', r.status, 'returned_at', r.vehicle_returned_at)
                                           order by r.starts_at)
                            from public.vehicle_reservation r join public.vehicle v on v.id = r.vehicle_id
                           where r.owner_id = v_uid), '[]'),
    'outings', coalesce((select jsonb_agg(jsonb_build_object('planned_start', o.planned_start, 'planned_return', o.planned_return,
                                                            'status', o.status, 'left_at', o.departure_reported_at,
                                                            'home_at', o.home_reported_at, 'expected_return_at', o.expected_return_at)
                                          order by o.planned_start)
                           from public.outing o where o.owner_id = v_uid), '[]'),
    'status_reports', coalesce((select jsonb_agg(jsonb_build_object('kind', s.kind, 'at', s.reported_at, 'details', s.payload)
                                                 order by s.reported_at)
                                  from public.status_report s where s.reported_by = v_uid), '[]'),
    'events_created', coalesce((select jsonb_agg(jsonb_build_object('title', e.title, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
                                                                    'destination', e.destination, 'description', e.description,
                                                                    'cancelled_at', e.cancelled_at)
                                                 order by e.starts_at)
                                  from public.family_event e where e.created_by = v_uid), '[]'),
    'event_responses', coalesce((select jsonb_agg(jsonb_build_object('event', e.title, 'response', p.state, 'at', p.responded_at))
                                   from public.event_participant p join public.family_event e on e.id = p.event_id
                                  where p.user_id = v_uid), '[]'),
    'notification_settings', (select to_jsonb(n) - 'user_id' from public.notification_setting n where n.user_id = v_uid),
    'devices', coalesce((select jsonb_agg(jsonb_build_object('added', d.created_at, 'last_seen', d.last_seen_at,
                                                            'device', d.user_agent, 'removed', d.revoked_at))
                           from public.device_subscription d where d.user_id = v_uid), '[]'),
    'actions_in_audit_log', coalesce((select jsonb_agg(jsonb_build_object('action', a.action, 'at', a.at, 'reason', a.reason)
                                                       order by a.at)
                                        from public.audit_log a where a.actor_id = v_uid), '[]')
  );
end;
$$;

-- Deletes the caller's account. Applies the member-exit rules in every family first (OP-07: refused
-- while a car is out with them; future bookings cancelled). A family where they are the only member
-- is deleted with them. Shared history keeps the events but no longer identifies them.
create function public.rpc_delete_my_account(p_confirm text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  g record;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_confirm is distinct from 'DELETE' then
    raise exception 'confirm_required' using errcode = '22023';
  end if;
  if exists (select 1 from public.vehicle_reservation where owner_id = v_uid and status = 'in_use_reported') then
    raise exception 'has_car_in_use' using errcode = '55000';
  end if;

  perform set_config('app.purge', 'on', true);
  for g in
    select m.group_id,
           (select count(*) from public.group_membership x where x.group_id = m.group_id and x.left_at is null) as members
      from public.group_membership m
     where m.user_id = v_uid and m.left_at is null
  loop
    if g.members = 1 then
      delete from public.family_group where id = g.group_id;
    else
      perform app.exit_member(g.group_id, v_uid, 'member.leave', 'account deleted');
    end if;
  end loop;

  delete from auth.users where id = v_uid;   -- sessions, devices, profile cascade; history anonymised
  insert into app.ops_log (kind, detail) values ('account_deleted', '{}');
end;
$$;

-------------------------------------------------------------------------------
-- Client error reporting (NFR-09) without a third-party service. Capped and rate-limited.
-------------------------------------------------------------------------------
create table app.client_error (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  user_id uuid references auth.users (id) on delete set null,
  message text not null,
  stack text,
  path text,
  user_agent text
);

create function public.rpc_report_client_error(p_message text, p_stack text default null, p_path text default null, p_user_agent text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
begin
  if v_uid is null then
    return;
  end if;
  if (select count(*) from app.client_error where user_id = v_uid and at > now() - interval '1 hour') >= 20 then
    return;   -- quietly drop: a broken page must not flood the table
  end if;
  insert into app.client_error (user_id, message, stack, path, user_agent)
  values (v_uid, left(coalesce(p_message, '?'), 500), left(p_stack, 4000),
          -- keep only the route shape: ids are replaced so no record identifiers are stored
          left(regexp_replace(coalesce(p_path, ''), '[0-9a-f]{8}-[0-9a-f-]{27}', ':id', 'g'), 200),
          left(p_user_agent, 300));
end;
$$;

-------------------------------------------------------------------------------
-- P09-5 Health (NFR-09): a self-rolling-back synthetic journey plus queue and job checks.
-------------------------------------------------------------------------------
-- Creates a throwaway family, books a car, reports Left and home, checks the outbox and prompt rows,
-- then rolls everything back. Returns null when healthy, or what failed.
create function app.synthetic_check()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := gen_random_uuid();
  v_group uuid := gen_random_uuid();
  v_car uuid := gen_random_uuid();
  v_res uuid;
  v_outing uuid;
begin
  begin
    insert into auth.users (id, email) values (v_uid, 'synthetic-' || v_uid || '@invalid.local');
    insert into public.family_group (id, name) values (v_group, 'synthetic');
    insert into public.group_membership (group_id, user_id) values (v_group, v_uid);
    insert into public.vehicle (id, group_id, name) values (v_car, v_group, 'synthetic');
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

    v_res := public.rpc_create_reservation(v_car, now() + interval '10 minutes', now() + interval '1 hour', 'synthetic-' || v_uid);
    select id into v_outing from public.outing where reservation_id = v_res;
    if not exists (select 1 from public.scheduled_prompt where outing_id = v_outing and kind = 'departure' and state = 'pending') then
      raise exception 'synthetic_fail: no departure prompt';
    end if;
    perform public.rpc_report_left(v_outing, 'synthetic-left-' || v_uid);
    perform public.rpc_confirm_home(v_outing, 'synthetic-home-' || v_uid);
    if (select status from public.vehicle_reservation where id = v_res) <> 'completed' then
      raise exception 'synthetic_fail: booking not completed';
    end if;
    if (select count(*) from public.notification_outbox where group_id = v_group and event_type like 'status.%') <> 2 then
      raise exception 'synthetic_fail: expected 2 status events';
    end if;
    raise exception 'synthetic_ok';
  exception when others then
    perform set_config('request.jwt.claims', '', true);
    if sqlerrm = 'synthetic_ok' then
      return null;
    end if;
    return left(sqlerrm, 200);
  end;
end;
$$;

create function public.ops_health_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_problems text[] := '{}';
  v_synthetic text := app.synthetic_check();
  v_oldest_pending interval := (select now() - min(created_at) from public.notification_outbox where state = 'pending');
  v_dead int := (select count(*) from public.notification_outbox where state = 'dead' and created_at > now() - interval '24 hours');
  v_late_prompts int := (select count(*) from public.scheduled_prompt where state = 'pending' and due_at < now() - interval '5 minutes');
  v_failed int := (select count(*) from public.notification_delivery
                    where state = 'failed' and coalesce(provider_status, 0) not in (404, 410) and updated_at > now() - interval '24 hours');
  v_stuck int := (select count(*) from public.notification_delivery where state = 'dispatched' and lease_until < now() - interval '5 minutes');
  v_cron_failed int := (select count(*) from cron.job_run_details where status = 'failed' and start_time > now() - interval '1 hour');
  v_client_errors int := (select count(*) from app.client_error where at > now() - interval '24 hours');
begin
  if v_synthetic is not null then v_problems := v_problems || ('synthetic journey failed: ' || v_synthetic); end if;
  if v_oldest_pending > interval '5 minutes' then v_problems := v_problems || ('outbox lagging ' || v_oldest_pending::text); end if;
  if v_dead > 0 then v_problems := v_problems || (v_dead || ' dead-lettered events (24 h)'); end if;
  if v_late_prompts > 0 then v_problems := v_problems || (v_late_prompts || ' prompts overdue'); end if;
  if v_failed > 5 then v_problems := v_problems || (v_failed || ' push failures (24 h)'); end if;
  if v_stuck > 0 then v_problems := v_problems || (v_stuck || ' pushes stuck in dispatch'); end if;
  if v_cron_failed > 0 then v_problems := v_problems || (v_cron_failed || ' scheduled job failures (1 h)'); end if;
  return jsonb_build_object(
    'ok', cardinality(v_problems) = 0,
    'problems', to_jsonb(v_problems),
    'client_errors_24h', v_client_errors,
    'checked_at', now());
end;
$$;

-- Remembers the last reported state so alerts are sent on change, not every hour.
create function public.ops_swap_health_state(p_state text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev text;
begin
  select value into v_prev from app.config where key = 'health_state';
  insert into app.config (key, value) values ('health_state', p_state)
  on conflict (key) do update set value = excluded.value;
  insert into app.ops_log (kind, detail) values ('health', jsonb_build_object('state', p_state));
  return v_prev;
end;
$$;

insert into app.config (key, value) values
  ('health_check_url', 'http://host.docker.internal:54321/functions/v1/health-check')
on conflict (key) do nothing;

create function app.kick_health_check()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform net.http_post(
    url := (select value from app.config where key = 'health_check_url'),
    headers := jsonb_build_object('content-type', 'application/json',
                                  'x-dispatch-secret', (select value from app.config where key = 'push_dispatch_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
end;
$$;

select cron.schedule('famly-retention', '15 0 * * *', $$ select app.purge_expired() $$);
select cron.schedule('famly-finalize-deletions', '20 0 * * *', $$ select app.finalize_group_deletions() $$);
select cron.schedule('famly-health', '7 * * * *', $$ select app.kick_health_check() $$);

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------
revoke execute on function
  app.purge_expired(), app.finalize_group_deletions(), app.synthetic_check(), app.kick_health_check()
  from public, anon, authenticated;
revoke execute on function public.ops_health_snapshot(), public.ops_swap_health_state(text) from public, anon, authenticated;
grant execute on function public.ops_health_snapshot(), public.ops_swap_health_state(text) to service_role;

revoke execute on function
  public.rpc_export_my_data(), public.rpc_delete_my_account(text),
  public.rpc_report_client_error(text, text, text, text)
  from public, anon;
grant execute on function
  public.rpc_export_my_data(), public.rpc_delete_my_account(text),
  public.rpc_report_client_error(text, text, text, text)
  to authenticated;
