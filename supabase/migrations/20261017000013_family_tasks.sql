-- Family tasks (founder request, 2026-10-17). A to-do list on the Family tab: someone creates a task
-- (title, optional description) and assigns it to one or more other members. Each assignee accepts or
-- declines in the app; an accepted assignee (or the creator) marks it done.
--
--   rpc_create_task      ──▶ notify.task_assigned   (push, recipient = each assignee)
--   rpc_respond_task     ──▶ notify.task_accepted / notify.task_declined (push, recipient = creator)
--   rpc_complete_task    ──▶ notify.task_completed  (push, recipient = creator)
--                        └─▶ task.complete          (family feed, no push)
--   rpc_cancel_task      ──▶ notify.task_cancel     (push, recipient = each assignee who hadn't declined)
--
-- Like events, every member can see every task (D04): the form shows the "visible to everyone" notice.
-- Personal notices (notify.*) never enter the family feed and never reach the person who acted.
-- Lock-screen text stays generic (FR-N04): no title or description.

create type public.task_assignee_state as enum ('pending', 'accepted', 'declined');

create table public.family_task (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_group (id) on delete cascade,
  created_by uuid references auth.users (id) on delete set null,
  title text not null check (char_length(title) between 1 and 120),
  description text check (char_length(description) <= 2000),
  completed_at timestamptz,
  completed_by uuid references auth.users (id) on delete set null,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (group_id, id),
  check (completed_at is null or cancelled_at is null)
);
create index family_task_group_idx on public.family_task (group_id, created_at desc);

create table public.task_assignee (
  group_id uuid not null,
  task_id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  state public.task_assignee_state not null default 'pending',
  responded_at timestamptz,
  primary key (task_id, user_id),
  foreign key (group_id, task_id) references public.family_task (group_id, id) on delete cascade
);
create index task_assignee_user_idx on public.task_assignee (user_id) where state = 'pending';

alter table public.family_task enable row level security;
alter table public.task_assignee enable row level security;
revoke all on public.family_task, public.task_assignee from anon, authenticated;
grant select on public.family_task, public.task_assignee to authenticated;

create policy family_task_select on public.family_task for select to authenticated
  using (app.is_member(group_id));
create policy task_assignee_select on public.task_assignee for select to authenticated
  using (app.is_member(group_id));

-------------------------------------------------------------------------------
-- rpc_create_task. Assignees must be other active members; at least one is required.
-------------------------------------------------------------------------------
create function public.rpc_create_task(
  p_group_id uuid,
  p_title text,
  p_description text default null,
  p_assignee_ids uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_ids uuid[];
  v_task public.family_task;
  v_user uuid;
begin
  perform app.assert_member(p_group_id);
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 120 then
    raise exception 'invalid_title' using errcode = '22023';
  end if;
  if char_length(coalesce(p_description, '')) > 2000 then
    raise exception 'text_too_long' using errcode = '22023';
  end if;

  v_ids := array(select distinct u from unnest(coalesce(p_assignee_ids, '{}')) u where u is not null and u <> v_uid);
  if cardinality(v_ids) = 0 then
    raise exception 'assignee_required' using errcode = '22023';
  end if;
  if exists (
    select 1 from unnest(v_ids) u
     where not exists (select 1 from public.group_membership m
                        where m.group_id = p_group_id and m.user_id = u and m.left_at is null)
  ) then
    raise exception 'participant_not_member' using errcode = '22023';
  end if;

  insert into public.family_task (group_id, created_by, title, description)
  values (p_group_id, v_uid, btrim(p_title), nullif(btrim(p_description), ''))
  returning * into v_task;

  foreach v_user in array v_ids loop
    insert into public.task_assignee (group_id, task_id, user_id) values (p_group_id, v_task.id, v_user);
    perform app.emit(p_group_id, 'notify.task_assigned', v_uid, v_task.id,
                     'task_assigned:' || v_task.id || ':' || v_user, '{}'::jsonb, true, v_user);
  end loop;

  perform app.audit(p_group_id, 'task.create', 'family_task', v_task.id, null,
                    jsonb_build_object('title', v_task.title, 'assignees', to_jsonb(v_ids)));
  return v_task.id;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_respond_task: only an assignee answers for themselves. They can change their mind while the
-- task is open; the creator is told each time the answer changes.
-------------------------------------------------------------------------------
create function public.rpc_respond_task(p_task_id uuid, p_state public.task_assignee_state)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_task public.family_task;
  v_old public.task_assignee_state;
begin
  select * into v_task from public.family_task where id = p_task_id;
  if v_task.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_task.group_id);
  if p_state not in ('accepted', 'declined') then
    raise exception 'invalid_state' using errcode = '22023';
  end if;
  if v_task.completed_at is not null or v_task.cancelled_at is not null then
    raise exception 'task_closed' using errcode = '55000';
  end if;

  select state into v_old from public.task_assignee
   where task_id = p_task_id and user_id = v_uid for update;
  if v_old is null then
    raise exception 'not_assigned' using errcode = '55000';
  end if;
  if v_old = p_state then
    return;
  end if;

  update public.task_assignee set state = p_state, responded_at = now()
   where task_id = p_task_id and user_id = v_uid;

  if v_task.created_by is not null then
    -- txid in the key: a fresh notice if they change their answer later.
    perform app.emit(v_task.group_id, 'notify.task_' || p_state::text, v_uid, v_task.id,
                     'task_' || p_state::text || ':' || v_task.id || ':' || v_uid || ':' || txid_current(),
                     '{}'::jsonb, true, v_task.created_by);
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_complete_task: an assignee who accepted, or the creator. Shows in the family feed.
-------------------------------------------------------------------------------
create function public.rpc_complete_task(p_task_id uuid)
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
  perform app.emit(v_task.group_id, 'task.complete', v_uid, v_task.id, 'task_complete:' || v_task.id,
                   jsonb_build_object('title', v_task.title, 'created_by', v_task.created_by), false);
  if v_task.created_by is not null then
    perform app.emit(v_task.group_id, 'notify.task_completed', v_uid, v_task.id,
                     'task_completed:' || v_task.id, '{}'::jsonb, true, v_task.created_by);
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_cancel_task: the creator deletes an open task. Assignees still in are told.
-------------------------------------------------------------------------------
create function public.rpc_cancel_task(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_task public.family_task;
  v_user uuid;
begin
  select * into v_task from public.family_task where id = p_task_id;
  if v_task.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_task.group_id);
  select * into v_task from public.family_task where id = p_task_id for update;
  if v_task.created_by is distinct from v_uid then
    raise exception 'not_task_creator' using errcode = '42501';
  end if;
  if v_task.cancelled_at is not null then
    return;
  end if;
  if v_task.completed_at is not null then
    raise exception 'task_closed' using errcode = '55000';
  end if;

  update public.family_task set cancelled_at = now(), updated_at = now() where id = p_task_id;
  for v_user in
    select user_id from public.task_assignee where task_id = p_task_id and state <> 'declined'
  loop
    perform app.emit(v_task.group_id, 'notify.task_cancel', v_uid, v_task.id,
                     'task_cancel:' || v_task.id || ':' || v_user, '{}'::jsonb, true, v_user);
  end loop;
  perform app.audit(v_task.group_id, 'task.cancel', 'family_task', v_task.id, null,
                    jsonb_build_object('title', v_task.title));
end;
$$;

-------------------------------------------------------------------------------
-- Relevance at send time: an assignment held by quiet hours is dropped if the task was closed or
-- they've already answered. (Adds task_assigned to the cases from migration 012.)
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
    when p_outbox.event_type = 'notify.task_assigned' then exists (
      select 1 from public.family_task t
        join public.task_assignee a on a.task_id = t.id and a.user_id = p_outbox.recipient_id
       where t.id = p_outbox.subject_id and t.cancelled_at is null and t.completed_at is null and a.state = 'pending')
      and p_outbox.created_at > now() - interval '12 hours'
    else p_outbox.created_at > now() - interval '12 hours'
  end
$$;

-------------------------------------------------------------------------------
-- Dispatch: generic lock-screen wording, deep link to the task. (Adds the task cases to migration 012.)
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
-- Retention (FR-D01): finished tasks follow the family's retention window. Open tasks are kept.
-------------------------------------------------------------------------------
create function app.purge_tasks()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  delete from public.family_task t
   using public.family_group g
   where g.id = t.group_id
     and coalesce(t.completed_at, t.cancelled_at) < now() - make_interval(days => g.retention_days);
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into app.ops_log (kind, detail) values ('retention_tasks', jsonb_build_object('tasks', v_n));
  end if;
  return v_n;
end;
$$;
select cron.schedule('famly-retention-tasks', '17 0 * * *', $$ select app.purge_tasks() $$);

-------------------------------------------------------------------------------
-- Data export (FR-D03): include tasks the person created and was given.
-------------------------------------------------------------------------------
create or replace function public.rpc_export_my_data()
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
    'tasks_created', coalesce((select jsonb_agg(jsonb_build_object('title', t.title, 'description', t.description,
                                                                   'created_at', t.created_at, 'completed_at', t.completed_at,
                                                                   'cancelled_at', t.cancelled_at)
                                                order by t.created_at)
                                 from public.family_task t where t.created_by = v_uid), '[]'),
    'tasks_assigned', coalesce((select jsonb_agg(jsonb_build_object('task', t.title, 'response', a.state, 'at', a.responded_at,
                                                                    'completed_by_you', t.completed_by = v_uid))
                                  from public.task_assignee a join public.family_task t on t.id = a.task_id
                                 where a.user_id = v_uid), '[]'),
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

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------
revoke execute on function app.purge_tasks() from public, anon, authenticated;

revoke execute on function
  public.rpc_create_task(uuid, text, text, uuid[]),
  public.rpc_respond_task(uuid, public.task_assignee_state),
  public.rpc_complete_task(uuid),
  public.rpc_cancel_task(uuid)
  from public, anon;
grant execute on function
  public.rpc_create_task(uuid, text, text, uuid[]),
  public.rpc_respond_task(uuid, public.task_assignee_state),
  public.rpc_complete_task(uuid),
  public.rpc_cancel_task(uuid)
  to authenticated;
