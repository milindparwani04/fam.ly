-- Stickers redesign, founder requests (2026-11-07):
--
--   1. "I'm Leaving" is a one-tap toggle that doesn't need a booking. The person says what they're off to
--      (Drive, Gym, Padel, Errand); everyone is pushed. Stored as one presence row per member per family.
--      Leaving in a booked car still goes through rpc_report_left (the car must become "in use"), which
--      now also records the activity.
--   2. Work hours: working days + start/end time per person. Today shows "Work" during them. Clients
--      derive it; the server only stores the schedule (visible to the people you share a family with).
--   3. New bookings, booking changes and new plans push to the whole family, so nobody is surprised by
--      what's free. A plan's invitees get "X invited you" in that same push instead of a second notice.
--   4. Per-category push switches in Settings: departures & returns, car bookings, plans, requests.
--   5. To-Dos can be unticked: rpc_reopen_task. Completing again is a fresh feed row and notice.

-------------------------------------------------------------------------------
-- 1. Presence
-------------------------------------------------------------------------------
create table public.member_presence (
  group_id uuid not null references public.family_group (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  state text not null check (state in ('out', 'home')),
  activity text check (activity in ('drive', 'gym', 'padel', 'errand')),
  has_house_key boolean,
  changed_at timestamptz not null default now(),
  primary key (group_id, user_id),
  check (state = 'out' or activity is null)
);

alter table public.member_presence enable row level security;
revoke all on public.member_presence from anon, authenticated;
grant select on public.member_presence to authenticated;
create policy member_presence_select on public.member_presence for select to authenticated
  using (app.is_member(group_id));

create function app.check_activity(p_activity text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_activity is not null and p_activity not in ('drive', 'gym', 'padel', 'errand') then
    raise exception 'invalid_activity' using errcode = '22023';
  end if;
end;
$$;

-- Out or home, for the caller in one family. Asking for the state you're already in changes nothing
-- and tells nobody (double taps, two devices). Switching activity while out is a quiet update.
create function public.rpc_set_presence(
  p_group_id uuid, p_out boolean, p_activity text default null, p_has_house_key boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_old public.member_presence;
  v_new public.member_presence;
begin
  perform app.assert_member(p_group_id);
  if p_out is null then
    raise exception 'invalid_state' using errcode = '22023';
  end if;
  perform app.check_activity(p_activity);
  if p_out and p_activity is null then
    raise exception 'activity_required' using errcode = '22023';
  end if;

  select * into v_old from public.member_presence where group_id = p_group_id and user_id = v_uid for update;

  if not p_out and (v_old.user_id is null or v_old.state = 'home') then
    return jsonb_build_object('state', 'home', 'changed_at', v_old.changed_at);
  end if;
  if p_out and v_old.state = 'out' then
    update public.member_presence set activity = p_activity, has_house_key = p_has_house_key
     where group_id = p_group_id and user_id = v_uid
    returning * into v_new;
    return jsonb_build_object('state', 'out', 'changed_at', v_new.changed_at);
  end if;

  insert into public.member_presence (group_id, user_id, state, activity, has_house_key, changed_at)
  values (p_group_id, v_uid, case when p_out then 'out' else 'home' end,
          case when p_out then p_activity end, case when p_out then p_has_house_key end, now())
  on conflict (group_id, user_id) do update
    set state = excluded.state, activity = excluded.activity, has_house_key = excluded.has_house_key,
        changed_at = excluded.changed_at
  returning * into v_new;

  perform app.emit(p_group_id, case when p_out then 'presence.left' else 'presence.home' end, v_uid, v_uid,
                   'presence:' || gen_random_uuid(),
                   jsonb_strip_nulls(jsonb_build_object(
                     'activity', coalesce(p_activity, v_old.activity),
                     'has_house_key', case when p_out then p_has_house_key end,
                     'left_at', case when not p_out then v_old.changed_at end)),
                   true);
  return jsonb_build_object('state', v_new.state, 'changed_at', v_new.changed_at);
end;
$$;

-------------------------------------------------------------------------------
-- 2. Work hours (per person, shared with the families they're in)
-------------------------------------------------------------------------------
create table public.member_work (
  user_id uuid primary key references auth.users (id) on delete cascade,
  days smallint[] not null default '{}' check (days <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]),  -- ISO: 1 = Monday
  starts time,
  ends time,
  updated_at timestamptz not null default now(),
  check ((starts is null) = (ends is null)),
  check (starts is null or starts <> ends),
  check (cardinality(days) = 0 or starts is not null)
);

alter table public.member_work enable row level security;
revoke all on public.member_work from anon, authenticated;
grant select on public.member_work to authenticated;
create policy member_work_select on public.member_work for select to authenticated
  using (
    user_id = app.current_user_id()
    or exists (
      select 1 from public.group_membership m
       where m.user_id = member_work.user_id and m.left_at is null and app.is_member(m.group_id)
    )
  );

-- Empty days = doesn't work set hours. Times are wall-clock in the family's time zone; an end before
-- the start means an overnight shift.
create function public.rpc_set_work_hours(p_days smallint[], p_starts time, p_ends time)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_days smallint[] := array(select distinct d from unnest(coalesce(p_days, '{}')) d order by d);
begin
  if app.current_user_id() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not (v_days <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]) then
    raise exception 'invalid_work_days' using errcode = '22023';
  end if;
  if (p_starts is null) <> (p_ends is null) or (p_starts is not null and p_starts = p_ends)
     or (cardinality(v_days) > 0 and p_starts is null) then
    raise exception 'invalid_work_hours' using errcode = '22023';
  end if;
  insert into public.member_work (user_id, days, starts, ends)
  values (app.current_user_id(), v_days, p_starts, p_ends)
  on conflict (user_id) do update
    set days = excluded.days, starts = excluded.starts, ends = excluded.ends, updated_at = now();
end;
$$;

-------------------------------------------------------------------------------
-- 4. Notification categories
-------------------------------------------------------------------------------
alter table public.notification_setting
  add column notify_moves boolean not null default true,     -- left / home / late / problems
  add column notify_bookings boolean not null default true,  -- car bookings and maintenance
  add column notify_plans boolean not null default true,     -- events, invites, menus
  add column notify_tasks boolean not null default true;     -- requests

create function app.notify_category(p_event_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_event_type like 'status.%' or p_event_type like 'presence.%' then 'moves'
    when p_event_type like 'reservation.%' or p_event_type like 'vehicle.%' then 'bookings'
    when p_event_type like 'event.%' or p_event_type like 'notify.event_%' or p_event_type like 'notify.menu_%' then 'plans'
    when p_event_type like 'notify.task_%' then 'tasks'
    else null    -- your own trip prompts and test pushes always come through
  end
$$;

create function public.rpc_update_notification_categories(
  p_moves boolean, p_bookings boolean, p_plans boolean, p_tasks boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.current_user_id() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  insert into public.notification_setting (user_id, notify_moves, notify_bookings, notify_plans, notify_tasks)
  values (app.current_user_id(), coalesce(p_moves, true), coalesce(p_bookings, true),
          coalesce(p_plans, true), coalesce(p_tasks, true))
  on conflict (user_id) do update
    set notify_moves = excluded.notify_moves, notify_bookings = excluded.notify_bookings,
        notify_plans = excluded.notify_plans, notify_tasks = excluded.notify_tasks, updated_at = now();
end;
$$;

-- Same worker as migration 012, plus the category switches.
create or replace function app.process_outbox(p_limit int default 200)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.notification_outbox;
  v_cat text;
  v_done int := 0;
begin
  for v_row in
    select * from public.notification_outbox
     where state = 'pending' and next_attempt_at <= now()
     order by id
     limit p_limit
     for update skip locked
  loop
    begin
      if current_setting('app.fault_inject', true) = 'outbox_fail' then
        raise exception 'fault_injected';
      end if;

      -- Family-visible events go to the feed exactly once (unique outbox_id).
      if v_row.event_type not like 'prompt.%' and v_row.event_type not like 'test.%'
         and v_row.event_type not like 'notify.%' then
        insert into public.activity_feed (group_id, outbox_id, kind, actor_id, subject_id, data, created_at)
        values (v_row.group_id, v_row.id, v_row.event_type, v_row.actor_id, v_row.subject_id, v_row.data, v_row.created_at)
        on conflict (outbox_id) do nothing;
      end if;

      if v_row.push then
        v_cat := app.notify_category(v_row.event_type);
        insert into public.notification_delivery (outbox_id, device_id, user_id, not_before)
        select v_row.id, d.id, d.user_id, coalesce(app.quiet_until(d.user_id, now()), now())
          from public.device_subscription d
          join public.group_membership m on m.user_id = d.user_id and m.group_id = v_row.group_id and m.left_at is null
          left join public.notification_setting s on s.user_id = d.user_id
         where d.revoked_at is null
           and coalesce(s.push_enabled, true)
           and (v_row.recipient_id is null or d.user_id = v_row.recipient_id)
           and d.user_id is distinct from v_row.actor_id      -- don't notify people about their own taps
           and case v_cat
                 when 'moves' then coalesce(s.notify_moves, true)
                 when 'bookings' then coalesce(s.notify_bookings, true)
                 when 'plans' then coalesce(s.notify_plans, true)
                 when 'tasks' then coalesce(s.notify_tasks, true)
                 else true
               end
        on conflict (outbox_id, device_id) do nothing;
      end if;

      update public.notification_outbox set state = 'processed', processed_at = now(), attempts = attempts + 1
       where id = v_row.id;
    exception when others then
      update public.notification_outbox
         set attempts = attempts + 1,
             last_error = left(sqlerrm, 500),
             state = case when attempts + 1 >= 6 then 'dead' else 'pending' end,
             next_attempt_at = now() + make_interval(secs => 15 * power(2, attempts))
       where id = v_row.id;
    end;
    v_done := v_done + 1;
  end loop;
  return v_done;
end;
$$;

-------------------------------------------------------------------------------
-- 3. New bookings, booking changes and new plans push to the family
-------------------------------------------------------------------------------
create or replace function app.audit_to_outbox()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_data jsonb := jsonb_strip_nulls(jsonb_build_object('before', new.before, 'after', new.after, 'reason', new.reason));
begin
  if new.action not in (
    'reservation.create', 'reservation.update', 'reservation.extend', 'reservation.cancel',
    'reservation.cancel_on_exit', 'reservation.override', 'event.create', 'event.cancel',
    'member.join', 'member.leave', 'member.remove', 'vehicle.unavailability.add'
  ) then
    return new;
  end if;

  if new.target_type = 'vehicle_reservation' then
    v_data := v_data || coalesce((
      select jsonb_build_object('vehicle_name', v.name, 'starts_at', r.starts_at, 'ends_at', r.ends_at,
                                'owner_id', r.owner_id)
        from public.vehicle_reservation r join public.vehicle v on v.id = r.vehicle_id
       where r.id = new.target_id), '{}');
  elsif new.target_type = 'family_event' then
    v_data := v_data || coalesce((
      select jsonb_build_object('title', e.title, 'starts_at', e.starts_at, 'ends_at', e.ends_at)
        from public.family_event e where e.id = new.target_id), '{}');
  elsif new.target_type = 'vehicle_unavailability' then
    v_data := v_data || coalesce((
      select jsonb_build_object('vehicle_name', v.name)
        from public.vehicle_unavailability u join public.vehicle v on v.id = u.vehicle_id
       where u.id = new.target_id), '{}');
  end if;

  perform app.emit(new.group_id, new.action, new.actor_id, new.target_id, 'audit:' || new.id, v_data,
                   new.action in ('reservation.override', 'reservation.create', 'reservation.update',
                                  'reservation.extend', 'event.create'));
  return new;
end;
$$;

-- Invites made while creating the plan ride on the family-wide "event.create" push (worded "invited you"
-- for them). People added to an existing plan still get their own notice.
create or replace function app.event_participant_to_outbox()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.family_event;
begin
  if new.state <> 'invited' then
    return new;
  end if;
  select * into v_event from public.family_event where id = new.event_id;
  if v_event.cancelled_at is not null or v_event.ends_at <= now() then
    return new;
  end if;
  if v_event.version = 1 and v_event.created_at = now() then
    return new;    -- being created right now (an edit bumps the version before re-inviting)
  end if;
  perform app.emit(new.group_id, 'notify.event_invite', app.current_user_id(), new.event_id,
                   'event_invite:' || new.event_id || ':' || new.user_id || ':' || txid_current(),
                   '{}'::jsonb, true, new.user_id);
  return new;
end;
$$;

-------------------------------------------------------------------------------
-- 1b. Leaving in a booked car also says what for. Replaces the three-argument version (migration 014).
-------------------------------------------------------------------------------
drop function public.rpc_report_left(uuid, text, boolean);

create function public.rpc_report_left(
  p_outing_id uuid, p_idempotency_key text, p_has_house_key boolean default null, p_activity text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing public.outing;
  v_report public.status_report;
  v_res_ends timestamptz;
begin
  perform app.require_key(p_idempotency_key);
  perform app.check_activity(p_activity);
  v_report := app.replayed_report(p_idempotency_key);
  if v_report.id is not null then
    return app.report_result(v_report);
  end if;

  v_outing := app.lock_own_outing(p_outing_id);

  if v_outing.status = 'departed' then
    select * into v_report from public.status_report
     where outing_id = v_outing.id and kind = 'left' order by reported_at desc limit 1;
    return app.report_result(v_report);
  end if;
  if v_outing.status <> 'planned' then
    raise exception 'invalid_state' using errcode = '55000', detail = v_outing.status::text;
  end if;
  if now() < app.left_window_opens(v_outing.planned_start) then
    raise exception 'too_early' using errcode = '55000',
      detail = jsonb_build_object('opens_at', app.left_window_opens(v_outing.planned_start))::text;
  end if;
  if v_outing.reservation_id is not null then
    select ends_at into v_res_ends from public.vehicle_reservation where id = v_outing.reservation_id;
    if now() >= v_res_ends then
      raise exception 'booking_ended' using errcode = '55000';
    end if;
  end if;

  update public.outing
     set status = 'departed', departure_reported_at = now(), version = version + 1
   where id = v_outing.id;
  if v_outing.reservation_id is not null then
    update public.vehicle_reservation
       set status = 'in_use_reported', version = version + 1, updated_at = now()
     where id = v_outing.reservation_id;
  end if;

  insert into public.status_report (group_id, outing_id, kind, reported_by, idempotency_key, payload)
  values (v_outing.group_id, v_outing.id, 'left', app.current_user_id(), p_idempotency_key,
          jsonb_strip_nulls(jsonb_build_object('planned_start', v_outing.planned_start,
                                               'has_house_key', p_has_house_key,
                                               'activity', p_activity)))
  returning * into v_report;
  return app.report_result(v_report);
end;
$$;

-------------------------------------------------------------------------------
-- 5. Untick a done task. Completing again is a new feed row and a new notice (keys carry the txid).
-------------------------------------------------------------------------------
create or replace function public.rpc_complete_task(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_task public.family_task;
begin
  select * into v_task from public.family_task where id = p_task_id;
  if v_task.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_task.group_id);
  select * into v_task from public.family_task where id = p_task_id for update;
  if v_task.completed_at is not null then
    return;
  end if;
  if v_task.cancelled_at is not null then
    raise exception 'task_closed' using errcode = '55000';
  end if;
  if v_task.created_by is distinct from v_uid and not exists (
    select 1 from public.task_assignee where task_id = p_task_id and user_id = v_uid and state = 'accepted'
  ) then
    raise exception 'not_assigned' using errcode = '55000';
  end if;

  update public.family_task set completed_at = now(), completed_by = v_uid, updated_at = now()
   where id = p_task_id;

  perform app.audit(v_task.group_id, 'task.complete', 'family_task', v_task.id, null,
                    jsonb_build_object('title', v_task.title));
  perform app.emit(v_task.group_id, 'task.complete', v_uid, v_task.id,
                   'task_complete:' || v_task.id || ':' || txid_current(),
                   jsonb_build_object('title', v_task.title, 'created_by', v_task.created_by), false);
  if v_task.created_by is not null then
    perform app.emit(v_task.group_id, 'notify.task_completed', v_uid, v_task.id,
                     'task_completed:' || v_task.id || ':' || txid_current(), '{}'::jsonb, true, v_task.created_by);
  end if;
end;
$$;

-- Whoever finished it, or whoever asked for it, can open it again. Shown in the feed, not pushed.
create function public.rpc_reopen_task(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_task public.family_task;
begin
  select * into v_task from public.family_task where id = p_task_id;
  if v_task.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_task.group_id);
  select * into v_task from public.family_task where id = p_task_id for update;
  if v_task.cancelled_at is not null then
    raise exception 'task_closed' using errcode = '55000';
  end if;
  if v_task.completed_at is null then
    return;
  end if;
  if v_uid is distinct from v_task.completed_by and v_uid is distinct from v_task.created_by then
    raise exception 'not_assigned' using errcode = '55000';
  end if;

  update public.family_task set completed_at = null, completed_by = null, updated_at = now() where id = p_task_id;
  perform app.audit(v_task.group_id, 'task.reopen', 'family_task', v_task.id, null,
                    jsonb_build_object('title', v_task.title));
  perform app.emit(v_task.group_id, 'task.reopen', v_uid, v_task.id,
                   'task_reopen:' || v_task.id || ':' || txid_current(),
                   jsonb_build_object('title', v_task.title), false);
end;
$$;

-------------------------------------------------------------------------------
-- Lock-screen wording for the new pushes (same as migration 016 plus presence, bookings and plans).
-------------------------------------------------------------------------------
create function app.activity_label(p_activity text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_activity when 'drive' then 'Drive' when 'gym' then 'Gym' when 'padel' then 'Padel'
                         when 'errand' then 'Errand' end
$$;

-- "Sat 07 Nov, 15:00 – 18:30", or with both dates when it spans days.
create function app.fmt_window(p_start timestamptz, p_end timestamptz, p_tz text)
returns text
language sql
stable
set search_path = ''
as $$
  select to_char(p_start at time zone p_tz, 'Dy DD Mon, HH24:MI') || ' – '
         || case when (p_start at time zone p_tz)::date = (p_end at time zone p_tz)::date
                 then to_char(p_end at time zone p_tz, 'HH24:MI')
                 else to_char(p_end at time zone p_tz, 'Dy DD Mon, HH24:MI') end
$$;

create or replace function app.push_text(p_outbox public.notification_outbox, p_user_id uuid, out title text, out body text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  d jsonb := p_outbox.data;
  v_who text;
  v_tz text;
  v_what text;
  v_task public.family_task;
  v_event public.family_event;
  v_menu public.family_menu;
  v_day text;
begin
  select coalesce(nullif(btrim(p.display_name), ''), 'Someone') into v_who from public.profile p where p.user_id = p_outbox.actor_id;
  v_who := coalesce(v_who, 'Someone');
  select coalesce(p.time_zone, g.time_zone, 'Asia/Dubai') into v_tz
    from public.family_group g left join public.profile p on p.user_id = p_user_id
   where g.id = p_outbox.group_id;
  v_tz := coalesce(v_tz, 'Asia/Dubai');
  v_what := coalesce(d ->> 'vehicle_name', d ->> 'title');

  case
    -- Your own trip
    when p_outbox.event_type = 'prompt.departure_soon' then
      title := 'Leaving in 30 minutes';
      body := 'Your ' || coalesce(v_what || ' ', '') || 'trip starts at '
              || to_char((d ->> 'planned_start')::timestamptz at time zone v_tz, 'HH24:MI') || '. Ready to leave?';
    when p_outbox.event_type = 'prompt.departure' then
      title := 'Time to go';
      body := 'Your ' || coalesce(v_what || ' ', '') || 'trip starts now. Tap I''m Leaving when you set off.';
    when p_outbox.event_type = 'prompt.return_soon' then
      title := 'Due home in 30 minutes';
      body := 'You''re due back at ' || to_char((d ->> 'planned_return')::timestamptz at time zone v_tz, 'HH24:MI')
              || coalesce(' with the ' || (d ->> 'vehicle_name'), '') || '.';
    when p_outbox.event_type = 'prompt.return' then
      title := 'Are you back?';
      body := 'You were due home at ' || to_char((d ->> 'planned_return')::timestamptz at time zone v_tz, 'HH24:MI')
              || '. Tap I''m Home when you''re back.';

    -- Someone else's comings and goings
    when p_outbox.event_type = 'status.left' then
      title := v_who || ' has left the house';
      body := concat_ws(' · ', app.activity_label(d ->> 'activity'), v_what,
                        case (d ->> 'has_house_key')::boolean when true then 'has the house key'
                                                              when false then 'doesn''t have the house key' end);
    when p_outbox.event_type = 'presence.left' then
      title := v_who || ' has left the house';
      body := concat_ws(' · ', app.activity_label(d ->> 'activity'),
                        case when (d ->> 'has_house_key')::boolean then 'has the house key' end);
    when p_outbox.event_type = 'presence.home' then
      title := v_who || ' is home';
      body := case d ->> 'activity' when 'drive' then 'Back from a drive' when 'gym' then 'Back from the gym'
                                    when 'padel' then 'Back from padel' when 'errand' then 'Back from an errand'
                                    else 'Back home' end;
    when p_outbox.event_type = 'status.home' then
      title := v_who || ' has returned home';
      body := v_what;
    when p_outbox.event_type = 'status.home_and_car_returned' then
      title := v_who || ' has returned home';
      body := coalesce(d ->> 'vehicle_name', 'The car') || ' is back';
    when p_outbox.event_type = 'status.eta_update' then
      title := v_who || ' is running late';
      body := concat_ws(' · ', 'Expected back ' || to_char((d ->> 'expected_return_at')::timestamptz at time zone v_tz, 'HH24:MI'),
                        d ->> 'note');
    when p_outbox.event_type = 'status.issue' then
      title := v_who || ' reported a problem';
      body := concat_ws(' · ', d ->> 'vehicle_name', d ->> 'note');

    -- Car bookings
    when p_outbox.event_type = 'reservation.create' then
      title := v_who || ' booked ' || coalesce(d ->> 'vehicle_name', 'a car');
      body := app.fmt_window((d ->> 'starts_at')::timestamptz, (d ->> 'ends_at')::timestamptz, v_tz);
    when p_outbox.event_type = 'reservation.update' then
      title := v_who || ' moved their ' || coalesce(d ->> 'vehicle_name', 'car') || ' booking';
      body := 'Now ' || app.fmt_window((d ->> 'starts_at')::timestamptz, (d ->> 'ends_at')::timestamptz, v_tz);
    when p_outbox.event_type = 'reservation.extend' then
      title := v_who || ' extended their ' || coalesce(d ->> 'vehicle_name', 'car') || ' booking';
      body := 'Now until ' || to_char((d ->> 'ends_at')::timestamptz at time zone v_tz, 'Dy DD Mon, HH24:MI');
    when p_outbox.event_type = 'reservation.override' then
      title := v_who || ' cancelled a booking';
      body := concat_ws(' · ', d ->> 'vehicle_name', d ->> 'reason');

    -- Plans
    when p_outbox.event_type = 'event.create' then
      select * into v_event from public.family_event where id = p_outbox.subject_id;
      title := v_who || case when exists (select 1 from public.event_participant p
                                           where p.event_id = v_event.id and p.user_id = p_user_id and p.state = 'invited')
                             then ' invited you' else ' made a plan' end;
      body := concat_ws(' · ', v_event.title,
                        to_char(v_event.starts_at at time zone v_tz, 'Dy DD Mon, HH24:MI'), v_event.destination);
    when p_outbox.event_type in ('notify.event_invite', 'notify.event_cancel') then
      select * into v_event from public.family_event where id = p_outbox.subject_id;
      title := v_who || case when p_outbox.event_type = 'notify.event_invite' then ' invited you' else ' cancelled a plan' end;
      body := concat_ws(' · ', v_event.title,
                        to_char(v_event.starts_at at time zone v_tz, 'Dy DD Mon, HH24:MI'), v_event.destination);

    -- Tasks
    when p_outbox.event_type like 'notify.task_%' then
      select * into v_task from public.family_task where id = p_outbox.subject_id;
      title := case p_outbox.event_type
                 when 'notify.task_assigned' then 'New task from ' || v_who
                 when 'notify.task_accepted' then v_who || ' accepted your task'
                 when 'notify.task_declined' then v_who || ' declined your task'
                 when 'notify.task_completed' then v_who || ' finished your task'
                 when 'notify.task_cancel' then v_who || ' cancelled a task'
                 else 'Family task' end;
      body := case when p_outbox.event_type = 'notify.task_assigned'
                   then concat_ws(E'\n', v_task.title, v_task.description)
                   else v_task.title end;

    -- Menus
    when p_outbox.event_type like 'notify.menu_%' then
      select * into v_menu from public.family_menu where id = p_outbox.subject_id;
      v_day := case v_menu.menu_date - (now() at time zone v_tz)::date
                 when 0 then 'today''s'
                 when 1 then 'tomorrow''s'
                 else to_char(v_menu.menu_date, 'Dy DD Mon') || '''s' end;
      title := v_who || case when p_outbox.event_type = 'notify.menu_proposed' then ' proposed ' else ' changed ' end
               || v_day || ' menu';
      body := v_menu.items;

    when p_outbox.event_type like 'test.%' then
      title := 'fam.ly';
      body := 'Test notification: push is working';
    else
      title := 'fam.ly';
      body := 'Family update in fam.ly';
  end case;

  title := left(coalesce(nullif(title, ''), 'fam.ly'), 80);
  body := coalesce(nullif(body, ''), 'Open fam.ly for details');
  if char_length(body) > 180 then
    body := left(body, 179) || '…';
  end if;
end;
$$;

-- Relevance at send time (migration 015 plus): a presence push held by quiet hours is dropped once they've
-- changed again; booking and plan pushes are dropped if the booking or plan is gone or over.
create or replace function app.delivery_relevant(p_outbox public.notification_outbox)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_outbox.event_type like 'prompt.%' then exists (
      select 1 from public.scheduled_prompt p
       where p.id = (p_outbox.data ->> 'prompt_id')::uuid and p.state = 'sent')
    when p_outbox.event_type like 'status.%' then not exists (
      select 1 from public.status_report s
       where s.outing_id = p_outbox.subject_id and s.reported_at > p_outbox.created_at)
      and p_outbox.created_at > now() - interval '12 hours'
    when p_outbox.event_type like 'presence.%' then not exists (
      select 1 from public.member_presence p
       where p.group_id = p_outbox.group_id and p.user_id = p_outbox.subject_id and p.changed_at > p_outbox.created_at)
      and p_outbox.created_at > now() - interval '12 hours'
    when p_outbox.event_type in ('reservation.create', 'reservation.update', 'reservation.extend') then exists (
      select 1 from public.vehicle_reservation r
       where r.id = p_outbox.subject_id and r.status in ('reserved', 'in_use_reported') and r.ends_at > now())
      and p_outbox.created_at > now() - interval '12 hours'
    when p_outbox.event_type = 'event.create' then exists (
      select 1 from public.family_event e
       where e.id = p_outbox.subject_id and e.cancelled_at is null and e.ends_at > now())
      and p_outbox.created_at > now() - interval '12 hours'
    when p_outbox.event_type = 'notify.event_invite' then exists (
      select 1 from public.family_event e
        join public.event_participant p on p.event_id = e.id and p.user_id = p_outbox.recipient_id
       where e.id = p_outbox.subject_id and e.cancelled_at is null and e.ends_at > now() and p.state = 'invited')
      and p_outbox.created_at > now() - interval '12 hours'
    when p_outbox.event_type = 'notify.task_assigned' then exists (
      select 1 from public.family_task t
        join public.task_assignee a on a.task_id = t.id and a.user_id = p_outbox.recipient_id
       where t.id = p_outbox.subject_id and t.cancelled_at is null and t.completed_at is null and a.state = 'pending')
      and p_outbox.created_at > now() - interval '12 hours'
    when p_outbox.event_type like 'notify.menu_%' then exists (
      select 1 from public.family_menu m
       where m.id = p_outbox.subject_id and m.version = (p_outbox.data ->> 'version')::int)
      and p_outbox.created_at > now() - interval '12 hours'
    else p_outbox.created_at > now() - interval '12 hours'
  end
$$;

-- Dispatch (migration 016) with deep links for bookings, new plans and presence.
create or replace function public.dispatch_claim_deliveries(p_limit int default 50)
returns table (
  delivery_id bigint, endpoint text, p256dh text, auth_secret text,
  title text, body text, url text, tag text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids bigint[];
begin
  update public.notification_delivery d
     set state = 'obsolete', updated_at = now()
    from public.notification_outbox o
   where o.id = d.outbox_id and d.state = 'scheduled' and d.not_before <= now()
     and not app.delivery_relevant(o);

  update public.notification_delivery set state = 'scheduled', lease_until = null
   where state = 'dispatched' and lease_until < now() and provider_status is null;

  select array_agg(id) into v_ids from (
    select id from public.notification_delivery
     where state = 'scheduled' and not_before <= now()
     order by not_before
     limit p_limit
     for update skip locked) c;

  update public.notification_delivery
     set state = 'dispatched', lease_until = now() + interval '2 minutes', attempts = attempts + 1, updated_at = now()
   where id = any (coalesce(v_ids, '{}'));

  return query
  select d.id, s.endpoint, s.p256dh, s.auth_secret,
         t.title, t.body,
         case when o.event_type like 'prompt.%' and o.data ? 'reservation_id' then '/bookings/' || (o.data ->> 'reservation_id')
              when o.event_type like 'prompt.%' then '/'
              when o.event_type like 'status.%' and o.data ? 'reservation_id' then '/bookings/' || (o.data ->> 'reservation_id')
              when o.event_type like 'presence.%' then '/'
              when o.event_type like 'reservation.%' then '/bookings/' || o.subject_id
              when o.event_type = 'event.create' then '/family/events/' || o.subject_id
              when o.event_type like 'notify.event_%' then '/family/events/' || o.subject_id
              when o.event_type like 'notify.task_%' then '/family/tasks/' || o.subject_id
              when o.event_type like 'notify.menu_%' then '/family/menus/' || o.subject_id
              else '/activity' end,
         o.event_type
    from public.notification_delivery d
    join public.device_subscription s on s.id = d.device_id
    join public.notification_outbox o on o.id = d.outbox_id
    cross join lateral app.push_text(o, d.user_id) t
   where d.id = any (coalesce(v_ids, '{}'));
end;
$$;

-------------------------------------------------------------------------------
-- Data export (FR-D03): the migration 015 export plus presence and work hours.
-------------------------------------------------------------------------------
alter function public.rpc_export_my_data() set schema app;
alter function app.rpc_export_my_data() rename to export_my_data_015;

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
  return app.export_my_data_015() || jsonb_build_object(
    'presence', coalesce((select jsonb_agg(jsonb_build_object('family', g.name, 'state', p.state, 'activity', p.activity,
                                                             'has_house_key', p.has_house_key, 'since', p.changed_at))
                            from public.member_presence p join public.family_group g on g.id = p.group_id
                           where p.user_id = v_uid), '[]'),
    'work_hours', (select jsonb_build_object('days', w.days, 'starts', w.starts, 'ends', w.ends)
                     from public.member_work w where w.user_id = v_uid)
  );
end;
$$;

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------
revoke execute on function
  app.check_activity(text), app.notify_category(text), app.activity_label(text),
  app.fmt_window(timestamptz, timestamptz, text), app.export_my_data_015()
  from public, anon, authenticated;

revoke execute on function
  public.rpc_set_presence(uuid, boolean, text, boolean),
  public.rpc_set_work_hours(smallint[], time, time),
  public.rpc_update_notification_categories(boolean, boolean, boolean, boolean),
  public.rpc_report_left(uuid, text, boolean, text),
  public.rpc_reopen_task(uuid),
  public.rpc_export_my_data()
  from public, anon;
grant execute on function
  public.rpc_set_presence(uuid, boolean, text, boolean),
  public.rpc_set_work_hours(smallint[], time, time),
  public.rpc_update_notification_categories(boolean, boolean, boolean, boolean),
  public.rpc_report_left(uuid, text, boolean, text),
  public.rpc_reopen_task(uuid),
  public.rpc_export_my_data()
  to authenticated;
