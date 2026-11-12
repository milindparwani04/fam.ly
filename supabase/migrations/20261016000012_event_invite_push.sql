-- Event invitations and cancellations push to the people invited (founder request, 2026-10-16).
-- FR-F01, FR-N02, FR-N04. The family feed is unchanged: everyone already sees event.create /
-- event.cancel there. These are personal notices, so they push to one recipient and skip the feed.
--
--   event_participant insert (state invited) ──▶ notify.event_invite  (recipient = invitee)
--   family_event cancelled                    ──▶ notify.event_cancel  (recipient = each invitee not declined)
--
-- The actor never gets their own notice (process_outbox already skips the actor's devices).

-------------------------------------------------------------------------------
-- Triggers
-------------------------------------------------------------------------------
create function app.event_participant_to_outbox()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.family_event;
begin
  if new.state <> 'invited' then
    return new;    -- e.g. the trip owner, who is attending by definition
  end if;
  select * into v_event from public.family_event where id = new.event_id;
  if v_event.cancelled_at is not null or v_event.ends_at <= now() then
    return new;
  end if;
  -- txid in the key: one notice per invitation, and a fresh one if they're removed and re-invited later.
  perform app.emit(new.group_id, 'notify.event_invite', app.current_user_id(), new.event_id,
                   'event_invite:' || new.event_id || ':' || new.user_id || ':' || txid_current(),
                   '{}'::jsonb, true, new.user_id);
  return new;
end;
$$;
create trigger event_participant_outbox
  after insert on public.event_participant
  for each row execute function app.event_participant_to_outbox();

create function app.event_cancel_to_outbox()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  if old.cancelled_at is not null or new.cancelled_at is null or new.ends_at <= now() then
    return new;
  end if;
  for v_user in
    select p.user_id from public.event_participant p
     where p.event_id = new.id and p.state <> 'declined'
  loop
    perform app.emit(new.group_id, 'notify.event_cancel', app.current_user_id(), new.id,
                     'event_cancel:' || new.id || ':' || v_user, '{}'::jsonb, true, v_user);
  end loop;
  return new;
end;
$$;
create trigger family_event_cancel_outbox
  after update of cancelled_at on public.family_event
  for each row execute function app.event_cancel_to_outbox();

revoke all on function app.event_participant_to_outbox(), app.event_cancel_to_outbox() from public, anon, authenticated;

-------------------------------------------------------------------------------
-- Worker: personal notices (notify.*) push but never enter the family feed.
-------------------------------------------------------------------------------
create or replace function app.process_outbox(p_limit int default 200)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.notification_outbox;
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
        insert into public.notification_delivery (outbox_id, device_id, user_id, not_before)
        select v_row.id, d.id, d.user_id, coalesce(app.quiet_until(d.user_id, now()), now())
          from public.device_subscription d
          join public.group_membership m on m.user_id = d.user_id and m.group_id = v_row.group_id and m.left_at is null
          left join public.notification_setting s on s.user_id = d.user_id
         where d.revoked_at is null
           and coalesce(s.push_enabled, true)
           and (v_row.recipient_id is null or d.user_id = v_row.recipient_id)
           and d.user_id is distinct from v_row.actor_id      -- don't notify people about their own taps
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
-- Relevance at send time: an invite held by quiet hours is dropped if the event was cancelled,
-- the person was removed, or they've already answered.
-------------------------------------------------------------------------------
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
      -- a newer report about the same outing supersedes this one (e.g. "left" held overnight, now home)
      select 1 from public.status_report s
       where s.outing_id = p_outbox.subject_id and s.reported_at > p_outbox.created_at)
      and p_outbox.created_at > now() - interval '12 hours'
    when p_outbox.event_type = 'notify.event_invite' then exists (
      select 1 from public.family_event e
        join public.event_participant p on p.event_id = e.id and p.user_id = p_outbox.recipient_id
       where e.id = p_outbox.subject_id and e.cancelled_at is null and e.ends_at > now() and p.state = 'invited')
      and p_outbox.created_at > now() - interval '12 hours'
    else p_outbox.created_at > now() - interval '12 hours'
  end
$$;

-------------------------------------------------------------------------------
-- Dispatch: generic lock-screen wording (FR-N04: no title, place or people), deep link to the event.
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
         case when o.event_type like 'prompt.departure' then 'Please confirm your trip'
              when o.event_type like 'prompt.return' then 'Are you back? Please confirm'
              when o.event_type like 'test.%' then 'Test notification: push is working'
              when o.event_type = 'notify.event_invite' then 'You''re invited to a family plan'
              when o.event_type = 'notify.event_cancel' then 'A family plan you were invited to was cancelled'
              else 'Family update in fam.ly' end,
         case when o.event_type like 'prompt.%' and o.data ? 'reservation_id' then '/bookings/' || (o.data ->> 'reservation_id')
              when o.event_type like 'prompt.%' then '/'
              when o.event_type like 'notify.event_%' then '/family/events/' || o.subject_id
              else '/activity' end,
         o.event_type
    from public.notification_delivery d
    join public.device_subscription s on s.id = d.device_id
    join public.notification_outbox o on o.id = d.outbox_id
   where d.id = any (coalesce(v_ids, '{}'));
end;
$$;
