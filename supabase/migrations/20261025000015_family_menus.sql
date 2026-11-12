-- Family menus (founder request, 2026-10-25). The cook comes every morning; the family agrees what
-- they'll make. Someone proposes a menu for a day; everyone else is notified (no invite list: a menu
-- is for the whole household) and either accepts it or modifies it. A modification is a new version:
-- everyone else is notified again and earlier acceptances no longer count. Whoever wrote the current
-- version counts as having accepted it. Everyone can see who has accepted the current version.
--
--   rpc_create_menu  ──▶ notify.menu_proposed  (push, whole family except the proposer)
--   rpc_modify_menu  ──▶ notify.menu_modified  (push, whole family except the modifier)
--   rpc_accept_menu  ──▶ nothing pushed; shown on the menu
--
-- Personal notices (notify.*) never enter the family feed (migration 012). Lock-screen text stays
-- generic (FR-N04): never the dishes.

create table public.family_menu (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_group (id) on delete cascade,
  created_by uuid references auth.users (id) on delete set null,
  menu_date date not null,
  items text not null check (char_length(items) between 1 and 2000),
  version int not null default 1,
  updated_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (group_id, id)
);
create index family_menu_group_idx on public.family_menu (group_id, menu_date desc);

-- One row per person: the latest version they accepted.
create table public.menu_acceptance (
  group_id uuid not null,
  menu_id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  version int not null,
  accepted_at timestamptz not null default now(),
  primary key (menu_id, user_id),
  foreign key (group_id, menu_id) references public.family_menu (group_id, id) on delete cascade
);
create index menu_acceptance_user_idx on public.menu_acceptance (user_id);

alter table public.family_menu enable row level security;
alter table public.menu_acceptance enable row level security;
revoke all on public.family_menu, public.menu_acceptance from anon, authenticated;
grant select on public.family_menu, public.menu_acceptance to authenticated;

create policy family_menu_select on public.family_menu for select to authenticated
  using (app.is_member(group_id));
create policy menu_acceptance_select on public.menu_acceptance for select to authenticated
  using (app.is_member(group_id));

create function app.check_menu_items(p_items text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if char_length(btrim(coalesce(p_items, ''))) = 0 then
    raise exception 'menu_required' using errcode = '22023';
  end if;
  if char_length(btrim(p_items)) > 2000 then
    raise exception 'text_too_long' using errcode = '22023';
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_create_menu
-------------------------------------------------------------------------------
create function public.rpc_create_menu(p_group_id uuid, p_menu_date date, p_items text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_tz text;
  v_menu public.family_menu;
begin
  perform app.assert_member(p_group_id);
  perform app.check_menu_items(p_items);
  select time_zone into v_tz from public.family_group where id = p_group_id;
  if p_menu_date is null or p_menu_date < (now() at time zone v_tz)::date then
    raise exception 'ends_in_past' using errcode = '22023';
  end if;
  if p_menu_date > (now() at time zone v_tz)::date + 30 then
    raise exception 'menu_too_far' using errcode = '22023';
  end if;

  insert into public.family_menu (group_id, created_by, menu_date, items, updated_by)
  values (p_group_id, v_uid, p_menu_date, btrim(p_items), v_uid)
  returning * into v_menu;
  insert into public.menu_acceptance (group_id, menu_id, user_id, version)
  values (p_group_id, v_menu.id, v_uid, 1);

  perform app.emit(p_group_id, 'notify.menu_proposed', v_uid, v_menu.id, 'menu_proposed:' || v_menu.id,
                   jsonb_build_object('version', 1), true);
  perform app.audit(p_group_id, 'menu.create', 'family_menu', v_menu.id, null,
                    jsonb_build_object('menu_date', v_menu.menu_date));
  return v_menu.id;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_modify_menu: any member. p_version is the version they were looking at, so two people
-- editing at once can't silently overwrite each other (stale_version).
-------------------------------------------------------------------------------
create function public.rpc_modify_menu(p_menu_id uuid, p_items text, p_version int)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_menu public.family_menu;
  v_tz text;
begin
  select * into v_menu from public.family_menu where id = p_menu_id;
  if v_menu.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_menu.group_id);
  perform app.check_menu_items(p_items);
  select * into v_menu from public.family_menu where id = p_menu_id for update;
  select time_zone into v_tz from public.family_group where id = v_menu.group_id;
  if v_menu.menu_date < (now() at time zone v_tz)::date then
    raise exception 'menu_past' using errcode = '55000';
  end if;
  if v_menu.version <> p_version then
    raise exception 'stale_version' using errcode = '55000';
  end if;
  if btrim(p_items) = v_menu.items then
    return v_menu.version;
  end if;

  update public.family_menu
     set items = btrim(p_items), version = version + 1, updated_by = v_uid, updated_at = now()
   where id = p_menu_id
  returning * into v_menu;
  insert into public.menu_acceptance (group_id, menu_id, user_id, version)
  values (v_menu.group_id, v_menu.id, v_uid, v_menu.version)
  on conflict (menu_id, user_id) do update set version = excluded.version, accepted_at = now();

  perform app.emit(v_menu.group_id, 'notify.menu_modified', v_uid, v_menu.id,
                   'menu_modified:' || v_menu.id || ':' || v_menu.version,
                   jsonb_build_object('version', v_menu.version), true);
  perform app.audit(v_menu.group_id, 'menu.modify', 'family_menu', v_menu.id, null,
                    jsonb_build_object('version', v_menu.version));
  return v_menu.version;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_accept_menu: accept the version you were shown. If it has changed since, you're asked to
-- look again (stale_version) rather than accepting something you haven't seen.
-------------------------------------------------------------------------------
create function public.rpc_accept_menu(p_menu_id uuid, p_version int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_menu public.family_menu;
begin
  select * into v_menu from public.family_menu where id = p_menu_id;
  if v_menu.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_menu.group_id);
  select * into v_menu from public.family_menu where id = p_menu_id for share;
  if v_menu.version <> p_version then
    raise exception 'stale_version' using errcode = '55000';
  end if;
  insert into public.menu_acceptance (group_id, menu_id, user_id, version)
  values (v_menu.group_id, v_menu.id, v_uid, v_menu.version)
  on conflict (menu_id, user_id) do update set version = excluded.version, accepted_at = now()
    where public.menu_acceptance.version <> excluded.version;
end;
$$;

-------------------------------------------------------------------------------
-- Relevance at send time: a menu notice held by quiet hours is dropped once a newer version
-- exists (that one has its own notice). (Adds the menu case to migration 013.)
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
    when p_outbox.event_type like 'notify.menu_%' then exists (
      select 1 from public.family_menu m
       where m.id = p_outbox.subject_id and m.version = (p_outbox.data ->> 'version')::int)
      and p_outbox.created_at > now() - interval '12 hours'
    else p_outbox.created_at > now() - interval '12 hours'
  end
$$;

-------------------------------------------------------------------------------
-- Dispatch: menu wording and deep link. (Same as migration 014 plus the menu cases.)
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
              when o.event_type = 'notify.menu_proposed' then 'A menu has been proposed. Accept or modify it'
              when o.event_type = 'notify.menu_modified' then 'The menu was changed. Accept or modify it'
              else 'Family update in fam.ly' end,
         case when o.event_type like 'prompt.%' and o.data ? 'reservation_id' then '/bookings/' || (o.data ->> 'reservation_id')
              when o.event_type like 'prompt.%' then '/'
              when o.event_type like 'notify.event_%' then '/family/events/' || o.subject_id
              when o.event_type like 'notify.task_%' then '/family/tasks/' || o.subject_id
              when o.event_type like 'notify.menu_%' then '/family/menus/' || o.subject_id
              else '/activity' end,
         o.event_type
    from public.notification_delivery d
    join public.device_subscription s on s.id = d.device_id
    join public.notification_outbox o on o.id = d.outbox_id
   where d.id = any (coalesce(v_ids, '{}'));
end;
$$;

-------------------------------------------------------------------------------
-- Retention (FR-D01): menus follow the family's retention window, counted from the menu's day.
-------------------------------------------------------------------------------
create function app.purge_menus()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  delete from public.family_menu m
   using public.family_group g
   where g.id = m.group_id
     and m.menu_date < current_date - g.retention_days;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into app.ops_log (kind, detail) values ('retention_menus', jsonb_build_object('menus', v_n));
  end if;
  return v_n;
end;
$$;
select cron.schedule('famly-retention-menus', '19 0 * * *', $$ select app.purge_menus() $$);

-------------------------------------------------------------------------------
-- Data export (FR-D03): menus the person proposed and the ones they accepted.
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
    'menus_proposed', coalesce((select jsonb_agg(jsonb_build_object('for', m.menu_date, 'menu', m.items,
                                                                    'version', m.version, 'created_at', m.created_at)
                                                 order by m.menu_date)
                                  from public.family_menu m where m.created_by = v_uid), '[]'),
    'menus_accepted', coalesce((select jsonb_agg(jsonb_build_object('for', m.menu_date, 'version', a.version, 'at', a.accepted_at)
                                                 order by m.menu_date)
                                  from public.menu_acceptance a join public.family_menu m on m.id = a.menu_id
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
revoke execute on function app.purge_menus(), app.check_menu_items(text) from public, anon, authenticated;

revoke execute on function
  public.rpc_create_menu(uuid, date, text),
  public.rpc_modify_menu(uuid, text, int),
  public.rpc_accept_menu(uuid, int)
  from public, anon;
grant execute on function
  public.rpc_create_menu(uuid, date, text),
  public.rpc_modify_menu(uuid, text, int),
  public.rpc_accept_menu(uuid, int)
  to authenticated;
