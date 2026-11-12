-- P08 Notification engine. FR-S02, FR-S03, FR-S05, FR-N01–N07, NFR-05, T08–T10, T17, T18, T21.
--
--   state change ──(same txn)──▶ notification_outbox (dedupe_key unique)
--        app.process_outbox()  ──▶ activity_feed (1 row per outbox row)       ← always (D11)
--                              └─▶ notification_delivery per eligible device  ← best effort (D12)
--   outing changes ──▶ scheduled_prompt (planned by trigger)
--        app.process_prompts() re-checks the outing at fire time, then emits a prompt outbox row
--   push-dispatch Edge Function claims deliveries, re-checks relevance, sends Web Push, records outcome

-------------------------------------------------------------------------------
-- Settings and devices
-------------------------------------------------------------------------------
create table app.config (
  key text primary key,
  value text not null
);
-- Local defaults; the hosted project overrides these during deployment.
insert into app.config (key, value) values
  ('push_dispatch_url', 'http://host.docker.internal:54321/functions/v1/push-dispatch'),
  ('push_dispatch_secret', encode(extensions.gen_random_bytes(24), 'hex'));

create table public.notification_setting (
  user_id uuid primary key references auth.users (id) on delete cascade,
  push_enabled boolean not null default true,
  quiet_start time,   -- in the user's profile.time_zone; both null = no quiet hours
  quiet_end time,
  updated_at timestamptz not null default now(),
  check ((quiet_start is null) = (quiet_end is null)),
  check (quiet_start is null or quiet_start <> quiet_end)
);

create table public.device_subscription (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  endpoint text not null unique check (endpoint like 'https://%' and char_length(endpoint) <= 1000),
  p256dh text not null check (char_length(p256dh) <= 200),
  auth_secret text not null check (char_length(auth_secret) <= 100),
  user_agent text check (char_length(user_agent) <= 300),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz
);
create index device_subscription_user_idx on public.device_subscription (user_id) where revoked_at is null;

-------------------------------------------------------------------------------
-- Outbox, feed, deliveries, prompts
-------------------------------------------------------------------------------
create table public.notification_outbox (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.family_group (id) on delete cascade,
  event_type text not null,
  actor_id uuid references auth.users (id) on delete set null,
  subject_id uuid,                 -- outing / reservation / event / member the event is about
  recipient_id uuid references auth.users (id) on delete cascade,  -- null = the whole family
  dedupe_key text not null unique, -- FR-N07 / T21: one logical event, however often it's processed
  data jsonb not null default '{}',
  push boolean not null default false,
  state text not null default 'pending' check (state in ('pending', 'processed', 'dead')),
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);
create index notification_outbox_due_idx on public.notification_outbox (next_attempt_at) where state = 'pending';

create table public.activity_feed (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.family_group (id) on delete cascade,
  outbox_id bigint not null unique references public.notification_outbox (id) on delete cascade,
  kind text not null,
  actor_id uuid references auth.users (id) on delete set null,
  subject_id uuid,
  data jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index activity_feed_group_idx on public.activity_feed (group_id, created_at desc);

-- FR-N06: what actually happened to each push. There is deliberately no "read" state.
create table public.notification_delivery (
  id bigint generated always as identity primary key,
  outbox_id bigint not null references public.notification_outbox (id) on delete cascade,
  device_id uuid not null references public.device_subscription (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  state text not null default 'scheduled'
    check (state in ('scheduled', 'dispatched', 'provider_accepted', 'failed', 'obsolete', 'acted')),
  not_before timestamptz not null default now(),   -- quiet hours defer (OP-09)
  lease_until timestamptz,
  attempts int not null default 0,
  provider_status int,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (outbox_id, device_id)
);
create index notification_delivery_due_idx on public.notification_delivery (not_before) where state = 'scheduled';

create table public.scheduled_prompt (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_group (id) on delete cascade,
  outing_id uuid not null references public.outing (id) on delete cascade,
  kind text not null check (kind in ('departure', 'return')),
  due_at timestamptz not null,
  snooze_count int not null default 0,
  state text not null default 'pending' check (state in ('pending', 'sent', 'acted', 'obsolete', 'expired')),
  sent_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (outing_id, kind)
);
create index scheduled_prompt_due_idx on public.scheduled_prompt (due_at) where state = 'pending';

-------------------------------------------------------------------------------
-- RLS
-------------------------------------------------------------------------------
alter table public.notification_setting enable row level security;
alter table public.device_subscription enable row level security;
alter table public.notification_outbox enable row level security;
alter table public.activity_feed enable row level security;
alter table public.notification_delivery enable row level security;
alter table public.scheduled_prompt enable row level security;

revoke all on public.notification_setting, public.device_subscription, public.notification_outbox,
  public.activity_feed, public.notification_delivery, public.scheduled_prompt from anon, authenticated;
grant select on public.notification_setting, public.activity_feed, public.scheduled_prompt to authenticated;
grant select (id, user_agent, created_at, last_seen_at, revoked_at) on public.device_subscription to authenticated;

create policy notification_setting_own on public.notification_setting for select to authenticated
  using (user_id = app.current_user_id());
create policy device_subscription_own on public.device_subscription for select to authenticated
  using (user_id = app.current_user_id());
-- FR-N01: every member sees every family activity record; other families see none.
create policy activity_feed_member on public.activity_feed for select to authenticated
  using (app.is_member(group_id));
-- Prompts are personal pending actions: only the person going out sees theirs.
create policy scheduled_prompt_own on public.scheduled_prompt for select to authenticated
  using (exists (select 1 from public.outing o where o.id = outing_id and o.owner_id = app.current_user_id()));
-- Outbox and deliveries are server-side only (no client policies).

-- Live Activity tab.
alter publication supabase_realtime add table public.activity_feed;

-------------------------------------------------------------------------------
-- Emitting events (transactional outbox, FR-N07)
-------------------------------------------------------------------------------
create function app.emit(
  p_group_id uuid, p_event_type text, p_actor_id uuid, p_subject_id uuid, p_dedupe_key text,
  p_data jsonb, p_push boolean, p_recipient_id uuid default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.notification_outbox (group_id, event_type, actor_id, subject_id, dedupe_key, data, push, recipient_id)
  values (p_group_id, p_event_type, p_actor_id, p_subject_id, p_dedupe_key, coalesce(p_data, '{}'), p_push, p_recipient_id)
  on conflict (dedupe_key) do nothing
$$;

-- Context for an outing: car name and event title, for the feed (never for lock-screen text).
create function app.outing_context(p_outing_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'outing_id', o.id,
    'reservation_id', o.reservation_id,
    'vehicle_name', v.name,
    'title', (select e.title from public.family_event e where e.outing_id = o.id and e.cancelled_at is null limit 1),
    'planned_start', o.planned_start,
    'planned_return', o.planned_return))
  from public.outing o
  left join public.vehicle_reservation r on r.id = o.reservation_id
  left join public.vehicle v on v.id = r.vehicle_id
  where o.id = p_outing_id
$$;

-- Every self-report is a family activity event (D11). Departures/returns/late/problems also push.
create function app.status_report_to_outbox()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.emit(new.group_id, 'status.' || new.kind::text, new.reported_by, new.outing_id,
                   'status:' || new.id, app.outing_context(new.outing_id) || new.payload,
                   new.kind <> 'correction');
  return new;
end;
$$;
create trigger status_report_outbox
  after insert on public.status_report
  for each row execute function app.status_report_to_outbox();

-- Audited actions worth telling the family about. Feed only (no push) except overrides,
-- which cancel someone else's plans.
create function app.audit_to_outbox()
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
                   new.action = 'reservation.override');
  return new;
end;
$$;
create trigger audit_log_outbox
  after insert on public.audit_log
  for each row execute function app.audit_to_outbox();

-------------------------------------------------------------------------------
-- Prompt planning (FR-S02, FR-S05). Recomputed from the outing on every change, so a cancel,
-- a return or a reschedule makes stale prompts inert in the same transaction (FR-N07, T10).
-------------------------------------------------------------------------------
create function app.sync_prompts()
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
    values (new.group_id, new.id, 'departure', new.planned_start)
    on conflict (outing_id, kind) do update
      set due_at = excluded.due_at, state = 'pending', sent_at = null, updated_at = now()
      where public.scheduled_prompt.due_at is distinct from excluded.due_at
         or public.scheduled_prompt.state in ('acted', 'obsolete');   -- e.g. "Left" undone
    update public.scheduled_prompt set state = 'obsolete', updated_at = now()
     where outing_id = new.id and kind = 'return' and state in ('pending', 'sent');
  elsif new.status = 'departed' then
    update public.scheduled_prompt set state = 'acted', updated_at = now()
     where outing_id = new.id and kind = 'departure' and state in ('pending', 'sent');
    insert into public.scheduled_prompt (group_id, outing_id, kind, due_at)
    values (new.group_id, new.id, 'return', v_return_due)
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
create trigger outing_sync_prompts
  after insert or update of status, planned_start, planned_return, expected_return_at on public.outing
  for each row execute function app.sync_prompts();

-- Backfill for outings that existed before this migration.
insert into public.scheduled_prompt (group_id, outing_id, kind, due_at)
select group_id, id, 'departure', planned_start from public.outing where status = 'planned'
on conflict do nothing;
insert into public.scheduled_prompt (group_id, outing_id, kind, due_at)
select group_id, id, 'return', greatest(planned_return, coalesce(expected_return_at, planned_return))
  from public.outing where status = 'departed'
on conflict do nothing;

-------------------------------------------------------------------------------
-- Prompt worker (FR-N05, T09, T10). Never waits on a locked outing: if the owner is writing to
-- it right now, the prompt is reconsidered on the next tick. That also rules out deadlocks.
-------------------------------------------------------------------------------
create function app.process_prompts(p_limit int default 100)
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

    if v_prompt.kind = 'departure' then
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

-- FR-S03, T08: snooze 15 minutes, capped per family; at the cap the in-app action stays available.
create function public.rpc_snooze_prompt(p_prompt_id uuid)
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
  if v_prompt.state <> 'sent' then
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
-- Outbox worker (FR-N01, FR-N02, T21). Retries with backoff; dead-letters after 6 attempts.
-------------------------------------------------------------------------------
-- When quiet hours end for this user, if they're in quiet hours at p_at (OP-09: defer).
create function app.quiet_until(p_user_id uuid, p_at timestamptz)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_set public.notification_setting;
  v_tz text;
  v_local timestamp;
  v_t time;
  v_day date;
begin
  select * into v_set from public.notification_setting where user_id = p_user_id;
  if v_set.quiet_start is null then
    return null;
  end if;
  select coalesce(time_zone, 'Asia/Dubai') into v_tz from public.profile where user_id = p_user_id;
  v_local := p_at at time zone v_tz;
  v_t := v_local::time;
  v_day := v_local::date;

  if v_set.quiet_start < v_set.quiet_end then
    if v_t >= v_set.quiet_start and v_t < v_set.quiet_end then
      return (v_day + v_set.quiet_end) at time zone v_tz;
    end if;
  else -- overnight, e.g. 23:00–07:00
    if v_t >= v_set.quiet_start then
      return (v_day + 1 + v_set.quiet_end) at time zone v_tz;
    elsif v_t < v_set.quiet_end then
      return (v_day + v_set.quiet_end) at time zone v_tz;
    end if;
  end if;
  return null;
end;
$$;

create function app.process_outbox(p_limit int default 200)
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
      if v_row.event_type not like 'prompt.%' and v_row.event_type not like 'test.%' then
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
-- Dispatch API for the push-dispatch Edge Function (service role only).
-------------------------------------------------------------------------------
-- Is this delivery still worth sending? (FR-N05, T10, OP-09 "drop if obsolete")
create function app.delivery_relevant(p_outbox public.notification_outbox)
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
    else p_outbox.created_at > now() - interval '12 hours'
  end
$$;

create function public.dispatch_claim_deliveries(p_limit int default 50)
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
              else 'Family update in fam.ly' end,
         case when o.event_type like 'prompt.%' and o.data ? 'reservation_id' then '/bookings/' || (o.data ->> 'reservation_id')
              when o.event_type like 'prompt.%' then '/'
              else '/activity' end,
         o.event_type
    from public.notification_delivery d
    join public.device_subscription s on s.id = d.device_id
    join public.notification_outbox o on o.id = d.outbox_id
   where d.id = any (coalesce(v_ids, '{}'));
end;
$$;

-- FR-N06: record the push service's answer. 201/202 = accepted (not "read"). 404/410 = the
-- subscription is gone. Other failures retry with backoff, up to 5 attempts.
create function public.dispatch_complete_delivery(p_delivery_id bigint, p_status int, p_error text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_d public.notification_delivery;
begin
  select * into v_d from public.notification_delivery where id = p_delivery_id for update;
  if v_d.id is null then
    return;
  end if;
  if p_status between 200 and 299 then
    update public.notification_delivery
       set state = 'provider_accepted', provider_status = p_status, lease_until = null, last_error = null, updated_at = now()
     where id = p_delivery_id;
  elsif p_status in (404, 410) then
    update public.notification_delivery
       set state = 'failed', provider_status = p_status, lease_until = null, last_error = left(p_error, 500), updated_at = now()
     where id = p_delivery_id;
    update public.device_subscription set revoked_at = now() where id = v_d.device_id and revoked_at is null;
  else
    update public.notification_delivery
       set state = case when v_d.attempts >= 5 then 'failed' else 'scheduled' end,
           provider_status = p_status, lease_until = null, last_error = left(p_error, 500),
           not_before = now() + make_interval(secs => 30 * power(2, v_d.attempts)), updated_at = now()
     where id = p_delivery_id;
  end if;
end;
$$;

-- When the person acts on a prompt, its pushes count as acted (FR-N06).
create function app.mark_prompt_deliveries_acted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.state = 'acted' and old.state is distinct from 'acted' then
    update public.notification_delivery d
       set state = 'acted', updated_at = now()
      from public.notification_outbox o
     where o.id = d.outbox_id and o.event_type like 'prompt.%' and (o.data ->> 'prompt_id')::uuid = new.id
       and d.state in ('provider_accepted', 'dispatched', 'scheduled');
  end if;
  return new;
end;
$$;
create trigger scheduled_prompt_acted
  after update of state on public.scheduled_prompt
  for each row execute function app.mark_prompt_deliveries_acted();

-------------------------------------------------------------------------------
-- Client RPCs: devices, settings, test push
-------------------------------------------------------------------------------
create function public.rpc_register_device(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_endpoint is null or p_endpoint not like 'https://%' or p_p256dh is null or p_auth is null then
    raise exception 'invalid_subscription' using errcode = '22023';
  end if;
  -- The same browser re-subscribing (or a phone changing hands) moves the endpoint to this user.
  insert into public.device_subscription (user_id, endpoint, p256dh, auth_secret, user_agent)
  values (v_uid, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update
    set user_id = v_uid, p256dh = excluded.p256dh, auth_secret = excluded.auth_secret,
        user_agent = excluded.user_agent, last_seen_at = now(), revoked_at = null
  returning id into v_id;
  return v_id;
end;
$$;

create function public.rpc_unregister_device(p_endpoint text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.device_subscription set revoked_at = now()
   where endpoint = p_endpoint and user_id = app.current_user_id() and revoked_at is null
$$;

create function public.rpc_update_notification_settings(p_push_enabled boolean, p_quiet_start time, p_quiet_end time)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.current_user_id() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if (p_quiet_start is null) <> (p_quiet_end is null) or (p_quiet_start is not null and p_quiet_start = p_quiet_end) then
    raise exception 'invalid_quiet_hours' using errcode = '22023';
  end if;
  insert into public.notification_setting (user_id, push_enabled, quiet_start, quiet_end)
  values (app.current_user_id(), coalesce(p_push_enabled, true), p_quiet_start, p_quiet_end)
  on conflict (user_id) do update
    set push_enabled = excluded.push_enabled, quiet_start = excluded.quiet_start,
        quiet_end = excluded.quiet_end, updated_at = now();
end;
$$;

-- Sends a test push to the caller's own devices (ignores quiet hours: they asked for it).
create function public.rpc_send_test_push()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_group uuid;
  v_outbox bigint;
begin
  select group_id into v_group from public.group_membership where user_id = v_uid and left_at is null limit 1;
  if v_group is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  insert into public.notification_outbox (group_id, event_type, actor_id, dedupe_key, push, recipient_id, state, processed_at)
  values (v_group, 'test.push', null, 'test:' || gen_random_uuid(), true, v_uid, 'processed', now())
  returning id into v_outbox;
  insert into public.notification_delivery (outbox_id, device_id, user_id)
  select v_outbox, id, user_id from public.device_subscription where user_id = v_uid and revoked_at is null;
end;
$$;

-------------------------------------------------------------------------------
-- Scheduling (pg_cron + pg_net). Sub-minute ticks keep "Sam left" close to real time.
-------------------------------------------------------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create function app.kick_push_dispatch()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.notification_delivery where state = 'scheduled' and not_before <= now()) then
    perform net.http_post(
      url := (select value from app.config where key = 'push_dispatch_url'),
      headers := jsonb_build_object('content-type', 'application/json',
                                    'x-dispatch-secret', (select value from app.config where key = 'push_dispatch_secret')),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000);
  end if;
end;
$$;

select cron.schedule('famly-process-prompts', '30 seconds', $$ select app.process_prompts(100) $$);
select cron.schedule('famly-process-outbox', '10 seconds', $$ select app.process_outbox(200) $$);
select cron.schedule('famly-push-dispatch', '10 seconds', $$ select app.kick_push_dispatch() $$);

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------
revoke execute on function
  app.emit(uuid, text, uuid, uuid, text, jsonb, boolean, uuid), app.outing_context(uuid),
  app.status_report_to_outbox(), app.audit_to_outbox(), app.sync_prompts(), app.process_prompts(int),
  app.quiet_until(uuid, timestamptz), app.process_outbox(int), app.delivery_relevant(public.notification_outbox),
  app.mark_prompt_deliveries_acted(), app.kick_push_dispatch()
  from public, anon, authenticated;

revoke execute on function public.dispatch_claim_deliveries(int), public.dispatch_complete_delivery(bigint, int, text)
  from public, anon, authenticated;
grant execute on function public.dispatch_claim_deliveries(int), public.dispatch_complete_delivery(bigint, int, text)
  to service_role;

revoke execute on function
  public.rpc_snooze_prompt(uuid), public.rpc_register_device(text, text, text, text),
  public.rpc_unregister_device(text), public.rpc_update_notification_settings(boolean, time, time),
  public.rpc_send_test_push()
  from public, anon;
grant execute on function
  public.rpc_snooze_prompt(uuid), public.rpc_register_device(text, text, text, text),
  public.rpc_unregister_device(text), public.rpc_update_notification_settings(boolean, time, time),
  public.rpc_send_test_push()
  to authenticated;
