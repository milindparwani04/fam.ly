-- Heads-up reminders and the house key (founder request, 2026-10-25).
--
-- 1. Two gentle reminders per outing, 30 minutes ahead, for the person going out only:
--      departure_soon  due planned_start - 30 min   "Your trip starts in 30 minutes. Ready to leave?"
--      return_soon     due return time   - 30 min   "You're due home in 30 minutes"
--    They ride the existing prompt pipeline (scheduled_prompt → process_prompts → outbox → push), so a
--    cancel, a reschedule or a status report makes them inert in the same transaction (FR-N07, T10).
--    Unlike the departure/return prompts they ask for nothing: no snooze, no badge. A reminder that
--    is already more than 5 minutes late when the worker sees it (e.g. a booking made 10 minutes
--    before it starts) is expired rather than sent.
--
-- 2. "Left" records whether the person has the house key. The app requires the choice; the server
--    accepts null so a phone still running the previous version of the app isn't locked out.
--    The answer goes in the status report payload, so the family feed shows it.

-------------------------------------------------------------------------------
-- Reminder kinds
-------------------------------------------------------------------------------
alter table public.scheduled_prompt drop constraint scheduled_prompt_kind_check;
alter table public.scheduled_prompt add constraint scheduled_prompt_kind_check
  check (kind in ('departure', 'return', 'departure_soon', 'return_soon'));

create function app.reminder_lead()
returns interval
language sql
immutable
set search_path = ''
as $$
  select interval '30 minutes'
$$;

-- Same shape as migration 009, plus the reminders alongside each prompt.
create or replace function app.sync_prompts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_return_due timestamptz := greatest(new.planned_return, coalesce(new.expected_return_at, new.planned_return));
begin
  if new.status = 'planned' then
    insert into public.scheduled_prompt (group_id, outing_id, kind, due_at)
    values (new.group_id, new.id, 'departure', new.planned_start),
           (new.group_id, new.id, 'departure_soon', new.planned_start - app.reminder_lead())
    on conflict (outing_id, kind) do update
      set due_at = excluded.due_at, state = 'pending', sent_at = null, updated_at = now()
      where public.scheduled_prompt.due_at is distinct from excluded.due_at
         or public.scheduled_prompt.state in ('acted', 'obsolete');   -- e.g. "Left" undone
    update public.scheduled_prompt set state = 'obsolete', updated_at = now()
     where outing_id = new.id and kind in ('return', 'return_soon') and state in ('pending', 'sent');
  elsif new.status = 'departed' then
    update public.scheduled_prompt set state = 'acted', updated_at = now()
     where outing_id = new.id and kind in ('departure', 'departure_soon') and state in ('pending', 'sent');
    insert into public.scheduled_prompt (group_id, outing_id, kind, due_at)
    values (new.group_id, new.id, 'return', v_return_due),
           (new.group_id, new.id, 'return_soon', v_return_due - app.reminder_lead())
    on conflict (outing_id, kind) do update
      set due_at = excluded.due_at, state = 'pending', sent_at = null, updated_at = now()
      where public.scheduled_prompt.due_at is distinct from excluded.due_at
         or public.scheduled_prompt.state in ('acted', 'obsolete');   -- e.g. "home" undone, or a new ETA
  elsif new.status = 'returned' then
    update public.scheduled_prompt set state = 'acted', updated_at = now()
     where outing_id = new.id and state in ('pending', 'sent');
  else -- cancelled
    update public.scheduled_prompt set state = 'obsolete', updated_at = now()
     where outing_id = new.id and state in ('pending', 'sent');
  end if;
  return new;
end;
$$;

-- Backfill reminders for outings that are still ahead.
insert into public.scheduled_prompt (group_id, outing_id, kind, due_at)
select group_id, id, 'departure_soon', planned_start - app.reminder_lead()
  from public.outing where status = 'planned' and planned_start - app.reminder_lead() > now()
on conflict do nothing;
insert into public.scheduled_prompt (group_id, outing_id, kind, due_at)
select group_id, id, 'return_soon', greatest(planned_return, coalesce(expected_return_at, planned_return)) - app.reminder_lead()
  from public.outing
 where status = 'departed'
   and greatest(planned_return, coalesce(expected_return_at, planned_return)) - app.reminder_lead() > now()
on conflict do nothing;

-- Same as migration 009, with the reminder kinds.
create or replace function app.process_prompts(p_limit int default 100)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prompt public.scheduled_prompt;
  v_outing public.outing;
  v_res_status public.reservation_status;
  v_res_ends timestamptz;
  v_eligible boolean;
  v_done int := 0;
begin
  for v_prompt in
    select * from public.scheduled_prompt
     where state = 'pending' and due_at <= now()
     order by due_at
     limit p_limit
     for update skip locked
  loop
    select * into v_outing from public.outing where id = v_prompt.outing_id for update skip locked;
    continue when v_outing.id is null;

    select status, ends_at into v_res_status, v_res_ends
      from public.vehicle_reservation where id = v_outing.reservation_id;

    if v_prompt.kind in ('departure', 'departure_soon') then
      v_eligible := v_outing.status = 'planned'
                    and (v_outing.reservation_id is null or v_res_status = 'reserved');
      -- A departure prompt after the booking has ended would ask about the past: expire it.
      if v_eligible and v_res_ends is not null and v_res_ends <= now() then
        update public.scheduled_prompt set state = 'expired', updated_at = now() where id = v_prompt.id;
        v_done := v_done + 1;
        continue;
      end if;
    else
      v_eligible := v_outing.status = 'departed';
    end if;

    -- A heads-up that's already late is no longer a heads-up.
    if v_eligible and v_prompt.kind in ('departure_soon', 'return_soon')
       and v_prompt.due_at < now() - interval '5 minutes' then
      update public.scheduled_prompt set state = 'expired', updated_at = now() where id = v_prompt.id;
      v_done := v_done + 1;
      continue;
    end if;

    if not v_eligible then
      update public.scheduled_prompt set state = 'obsolete', updated_at = now() where id = v_prompt.id;
    else
      update public.scheduled_prompt set state = 'sent', sent_at = now(), updated_at = now() where id = v_prompt.id;
      perform app.emit(v_prompt.group_id, 'prompt.' || v_prompt.kind, null, v_outing.id,
                       'prompt:' || v_prompt.id || ':' || v_prompt.snooze_count,
                       app.outing_context(v_outing.id) || jsonb_build_object('prompt_id', v_prompt.id),
                       true, v_outing.owner_id);
    end if;
    v_done := v_done + 1;
  end loop;
  return v_done;
end;
$$;

-- Reminders can't be snoozed: they ask for nothing.
create or replace function public.rpc_snooze_prompt(p_prompt_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prompt public.scheduled_prompt;
  v_group uuid;
  v_owner uuid;
  v_cap int;
begin
  select p.group_id, o.owner_id into v_group, v_owner
    from public.scheduled_prompt p join public.outing o on o.id = p.outing_id
   where p.id = p_prompt_id;
  if v_group is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_group);
  if v_owner <> app.current_user_id() then
    raise exception 'not_owner' using errcode = '42501';
  end if;

  select * into v_prompt from public.scheduled_prompt where id = p_prompt_id for update;
  if v_prompt.state <> 'sent' or v_prompt.kind not in ('departure', 'return') then
    raise exception 'invalid_state' using errcode = '55000', detail = v_prompt.state;
  end if;
  select snooze_cap into v_cap from public.family_group where id = v_prompt.group_id;
  if v_prompt.snooze_count >= v_cap then
    raise exception 'snooze_limit' using errcode = '55000', detail = v_cap::text;
  end if;

  update public.scheduled_prompt
     set state = 'pending', due_at = now() + interval '15 minutes', snooze_count = snooze_count + 1,
         updated_at = now()
   where id = p_prompt_id
  returning due_at into v_prompt.due_at;
  return v_prompt.due_at;
end;
$$;

-------------------------------------------------------------------------------
-- Dispatch: reminder wording. (Same as migration 013 plus the two reminder cases.)
-------------------------------------------------------------------------------
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
  -- Mark irrelevant ones first so they never reach a phone.
  update public.notification_delivery d
     set state = 'obsolete', updated_at = now()
    from public.notification_outbox o
   where o.id = d.outbox_id and d.state = 'scheduled' and d.not_before <= now()
     and not app.delivery_relevant(o);

  -- Claim with a lease; a crashed dispatcher's claims return to the queue when the lease expires.
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

  -- FR-N04: lock-screen text is generic. Details are only shown in the app after sign-in.
  return query
  select d.id, s.endpoint, s.p256dh, s.auth_secret,
         'fam.ly'::text,
         case when o.event_type = 'prompt.departure_soon' then 'Your trip starts in 30 minutes. Ready to leave?'
              when o.event_type = 'prompt.return_soon' then 'You''re due home in 30 minutes'
              when o.event_type like 'prompt.departure' then 'Please confirm your trip'
              when o.event_type like 'prompt.return' then 'Are you back? Please confirm'
              when o.event_type like 'test.%' then 'Test notification: push is working'
              when o.event_type = 'notify.event_invite' then 'You''re invited to a family plan'
              when o.event_type = 'notify.event_cancel' then 'A family plan you were invited to was cancelled'
              when o.event_type = 'notify.task_assigned' then 'You''ve been given a family task. Please accept or decline'
              when o.event_type = 'notify.task_accepted' then 'Your family task was accepted'
              when o.event_type = 'notify.task_declined' then 'Your family task was declined'
              when o.event_type = 'notify.task_completed' then 'Your family task is done'
              when o.event_type = 'notify.task_cancel' then 'A family task you were given was cancelled'
              else 'Family update in fam.ly' end,
         case when o.event_type like 'prompt.%' and o.data ? 'reservation_id' then '/bookings/' || (o.data ->> 'reservation_id')
              when o.event_type like 'prompt.%' then '/'
              when o.event_type like 'notify.event_%' then '/family/events/' || o.subject_id
              when o.event_type like 'notify.task_%' then '/family/tasks/' || o.subject_id
              else '/activity' end,
         o.event_type
    from public.notification_delivery d
    join public.device_subscription s on s.id = d.device_id
    join public.notification_outbox o on o.id = d.outbox_id
   where d.id = any (coalesce(v_ids, '{}'));
end;
$$;

-------------------------------------------------------------------------------
-- rpc_report_left with the house key. Replaces the two-argument version from migration 008.
-------------------------------------------------------------------------------
drop function public.rpc_report_left(uuid, text);

create function public.rpc_report_left(p_outing_id uuid, p_idempotency_key text, p_has_house_key boolean default null)
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
  v_report := app.replayed_report(p_idempotency_key);
  if v_report.id is not null then
    return app.report_result(v_report);
  end if;

  v_outing := app.lock_own_outing(p_outing_id);

  if v_outing.status = 'departed' then
    -- Already reported (e.g. tapped on two devices): return that report rather than adding another.
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
                                               'has_house_key', p_has_house_key)))
  returning * into v_report;
  return app.report_result(v_report);
end;
$$;

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------
revoke execute on function app.reminder_lead() from public, anon, authenticated;
revoke execute on function public.rpc_report_left(uuid, text, boolean) from public, anon;
grant execute on function public.rpc_report_left(uuid, text, boolean) to authenticated;
