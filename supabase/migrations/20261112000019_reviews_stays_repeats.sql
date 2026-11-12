-- Founder requests (2026-11-12):
--   1. Meal reviews. At 22:00 (family time) on a menu's day, everyone who accepted that menu is pushed to
--      rate it: 1–5 stars and an optional comment, one review per person, final once sent. Reviews can be
--      sent until 48 hours after the prompt. Nobody who can still rate sees the others' ratings first (so
--      they aren't swayed): you see them once you've rated, if you weren't asked, or once the window shuts.
--   2. Stays. Family members (or other guests) staying with the family for a range of days, e.g. "Ben,
--      from London, 20 Nov – 7 Dec". Shown on the Plans calendar; new stays push to the family.
--   3. Repeating plans: daily, weekly, fortnightly or monthly, optionally until a date. Occurrences are
--      expanded by the client (packages/domain repeat.ts); the server stores the rule.
--   4. A 6 pm to-do reminder: once a day, everyone with open to-dos gets one push listing them.
--   5. I'm Leaving can name one of your plans; Today and the push show its "where" (or just "Out").

-------------------------------------------------------------------------------
-- 1. Meal reviews
-------------------------------------------------------------------------------
create table public.menu_review (
  group_id uuid not null,
  menu_id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  stars smallint not null check (stars between 1 and 5),
  comment text check (char_length(comment) between 1 and 500),
  created_at timestamptz not null default now(),
  primary key (menu_id, user_id),
  foreign key (group_id, menu_id) references public.family_menu (group_id, id) on delete cascade
);
create index menu_review_user_idx on public.menu_review (user_id);
create index menu_review_group_idx on public.menu_review (group_id);

alter table public.family_menu add column review_prompted_at timestamptz;

-- The review window: 22:00 on the menu's day (family time) for 48 hours.
create function app.menu_review_opens(p_menu_date date, p_group_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select (p_menu_date + time '22:00') at time zone g.time_zone from public.family_group g where g.id = p_group_id
$$;

-- Asked to rate: accepted the menu as it finally stood, and still in the family.
create function app.is_menu_reviewer(p_menu_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.family_menu m
      join public.menu_acceptance a on a.menu_id = m.id and a.version = m.version
      join public.group_membership gm on gm.group_id = m.group_id and gm.user_id = a.user_id and gm.left_at is null
     where m.id = p_menu_id and a.user_id = p_user_id)
$$;

-- Others' ratings show once you've rated, if you weren't asked, or once the window has shut.
create function app.can_see_menu_reviews(p_menu_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.family_menu m
     where m.id = p_menu_id and app.is_member(m.group_id)
       and (now() >= app.menu_review_opens(m.menu_date, m.group_id) + interval '48 hours'
            or exists (select 1 from public.menu_review r where r.menu_id = m.id and r.user_id = app.current_user_id())
            or not app.is_menu_reviewer(m.id, app.current_user_id())))
$$;

alter table public.menu_review enable row level security;
revoke all on public.menu_review from anon, authenticated;
grant select on public.menu_review to authenticated;
create policy menu_review_select on public.menu_review for select to authenticated
  using (app.is_member(group_id)
         and (user_id = app.current_user_id() or app.can_see_menu_reviews(menu_id)));

create function public.rpc_review_menu(p_menu_id uuid, p_stars int, p_comment text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_menu public.family_menu;
  v_opens timestamptz;
  v_comment text := nullif(btrim(coalesce(p_comment, '')), '');
begin
  select * into v_menu from public.family_menu where id = p_menu_id;
  if v_menu.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_menu.group_id);
  if p_stars is null or p_stars not between 1 and 5 then
    raise exception 'invalid_stars' using errcode = '22023';
  end if;
  if char_length(coalesce(v_comment, '')) > 500 then
    raise exception 'comment_too_long' using errcode = '22023';
  end if;
  v_opens := app.menu_review_opens(v_menu.menu_date, v_menu.group_id);
  if now() < v_opens then
    raise exception 'review_not_open' using errcode = '55000';
  end if;
  if now() >= v_opens + interval '48 hours' then
    raise exception 'review_closed' using errcode = '55000';
  end if;
  if not app.is_menu_reviewer(v_menu.id, v_uid) then
    raise exception 'not_reviewer' using errcode = '42501';
  end if;

  insert into public.menu_review (group_id, menu_id, user_id, stars, comment)
  values (v_menu.group_id, v_menu.id, v_uid, p_stars, v_comment)
  on conflict (menu_id, user_id) do nothing;
  if not found then
    raise exception 'already_reviewed' using errcode = '55000';
  end if;
  perform app.audit(v_menu.group_id, 'menu.review', 'family_menu', v_menu.id, null,
                    jsonb_build_object('stars', p_stars));
end;
$$;

-- Accepting stops once the review window opens: who rates is settled at 22:00.
create or replace function public.rpc_accept_menu(p_menu_id uuid, p_version int)
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
  if now() >= app.menu_review_opens(v_menu.menu_date, v_menu.group_id) then
    raise exception 'menu_past' using errcode = '55000';
  end if;
  if v_menu.version <> p_version then
    raise exception 'stale_version' using errcode = '55000';
  end if;
  insert into public.menu_acceptance (group_id, menu_id, user_id, version)
  values (v_menu.group_id, v_menu.id, v_uid, v_menu.version)
  on conflict (menu_id, user_id) do update set version = excluded.version, accepted_at = now()
    where public.menu_acceptance.version <> excluded.version;
end;
$$;

-- The 22:00 prompt: one personal push per reviewer, once per menu.
create function app.prompt_menu_reviews()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_menu public.family_menu;
  v_n int := 0;
begin
  for v_menu in
    select m.* from public.family_menu m
     where m.review_prompted_at is null
       and now() >= app.menu_review_opens(m.menu_date, m.group_id)
       and now() < app.menu_review_opens(m.menu_date, m.group_id) + interval '48 hours'
     for update of m skip locked
  loop
    perform app.emit(v_menu.group_id, 'notify.menu_review', null, v_menu.id,
                     'menu_review:' || v_menu.id || ':' || a.user_id, jsonb_build_object('version', v_menu.version),
                     true, a.user_id)
       from public.menu_acceptance a
      where a.menu_id = v_menu.id and app.is_menu_reviewer(v_menu.id, a.user_id)
        and not exists (select 1 from public.menu_review r where r.menu_id = v_menu.id and r.user_id = a.user_id);
    update public.family_menu set review_prompted_at = now() where id = v_menu.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
select cron.schedule('famly-menu-reviews', '*/5 * * * *', $$ select app.prompt_menu_reviews() $$);

-------------------------------------------------------------------------------
-- 2. Stays
-------------------------------------------------------------------------------
create table public.family_stay (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_group (id) on delete cascade,
  created_by uuid references auth.users (id) on delete set null,
  guest_ids uuid[] not null default '{}',
  -- Names as they were when saved, so a stay still reads "Ben" after a visiting member leaves the family.
  guest_names text[] not null default '{}',
  other_guests text check (char_length(other_guests) between 1 and 200),
  arrives date not null,
  leaves date not null,
  from_place text check (char_length(from_place) between 1 and 120),
  note text check (char_length(note) between 1 and 1000),
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (group_id, id),
  check (leaves >= arrives),
  check (cardinality(guest_ids) > 0 or other_guests is not null)
);
create index family_stay_group_idx on public.family_stay (group_id, arrives);

alter table public.family_stay enable row level security;
revoke all on public.family_stay from anon, authenticated;
grant select on public.family_stay to authenticated;
create policy family_stay_select on public.family_stay for select to authenticated
  using (app.is_member(group_id));

-- Validates a stay and returns the guests' current names (members only; duplicates removed).
create function app.check_stay(
  p_group_id uuid, p_guest_ids uuid[], p_other_guests text, p_arrives date, p_leaves date,
  p_from text, p_note text
)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
  v_names text[];
  v_ids uuid[] := coalesce((select array_agg(distinct x) from unnest(p_guest_ids) x where x is not null), '{}');
begin
  if cardinality(v_ids) = 0 and nullif(btrim(coalesce(p_other_guests, '')), '') is null then
    raise exception 'guest_required' using errcode = '22023';
  end if;
  if p_arrives is null or p_leaves is null or p_leaves < p_arrives then
    raise exception 'invalid_period' using errcode = '22023';
  end if;
  if p_leaves - p_arrives > 366 then
    raise exception 'stay_too_long' using errcode = '22023';
  end if;
  select time_zone into v_tz from public.family_group where id = p_group_id;
  if p_leaves < (now() at time zone v_tz)::date then
    raise exception 'ends_in_past' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_other_guests, ''))) > 200 or char_length(btrim(coalesce(p_from, ''))) > 120
     or char_length(btrim(coalesce(p_note, ''))) > 1000 then
    raise exception 'text_too_long' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_ids) x
              where not exists (select 1 from public.group_membership m
                                 where m.group_id = p_group_id and m.user_id = x and m.left_at is null)) then
    raise exception 'participant_not_member' using errcode = '22023';
  end if;
  select coalesce(array_agg(coalesce(nullif(btrim(p.display_name), ''), 'Someone') order by p.display_name), '{}')
    into v_names
    from unnest(v_ids) x left join public.profile p on p.user_id = x;
  return v_names;
end;
$$;

create function public.rpc_create_stay(
  p_group_id uuid, p_guest_ids uuid[], p_other_guests text, p_arrives date, p_leaves date,
  p_from text default null, p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_names text[];
  v_stay public.family_stay;
begin
  perform app.assert_member(p_group_id);
  v_names := app.check_stay(p_group_id, p_guest_ids, p_other_guests, p_arrives, p_leaves, p_from, p_note);
  insert into public.family_stay (group_id, created_by, guest_ids, guest_names, other_guests, arrives, leaves,
                                  from_place, note)
  values (p_group_id, v_uid,
          coalesce((select array_agg(distinct x) from unnest(p_guest_ids) x where x is not null), '{}'),
          v_names, nullif(btrim(coalesce(p_other_guests, '')), ''), p_arrives, p_leaves,
          nullif(btrim(coalesce(p_from, '')), ''), nullif(btrim(coalesce(p_note, '')), ''))
  returning * into v_stay;
  perform app.emit(p_group_id, 'stay.create', v_uid, v_stay.id, 'stay.create:' || v_stay.id,
                   app.stay_data(v_stay), true);
  perform app.audit(p_group_id, 'stay.create', 'family_stay', v_stay.id, null, app.stay_data(v_stay));
  return v_stay.id;
end;
$$;

create function public.rpc_update_stay(
  p_stay_id uuid, p_guest_ids uuid[], p_other_guests text, p_arrives date, p_leaves date,
  p_from text default null, p_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_names text[];
  v_stay public.family_stay;
begin
  select * into v_stay from public.family_stay where id = p_stay_id;
  if v_stay.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_stay.group_id);
  if v_stay.cancelled_at is not null then
    raise exception 'invalid_state' using errcode = '55000', detail = 'cancelled';
  end if;
  v_names := app.check_stay(v_stay.group_id, p_guest_ids, p_other_guests, p_arrives, p_leaves, p_from, p_note);
  update public.family_stay
     set guest_ids = coalesce((select array_agg(distinct x) from unnest(p_guest_ids) x where x is not null), '{}'),
         guest_names = v_names, other_guests = nullif(btrim(coalesce(p_other_guests, '')), ''),
         arrives = p_arrives, leaves = p_leaves, from_place = nullif(btrim(coalesce(p_from, '')), ''),
         note = nullif(btrim(coalesce(p_note, '')), ''), updated_at = now()
   where id = p_stay_id
  returning * into v_stay;
  perform app.emit(v_stay.group_id, 'stay.update', v_uid, v_stay.id, 'stay.update:' || v_stay.id || ':' || txid_current(),
                   app.stay_data(v_stay), false);
  perform app.audit(v_stay.group_id, 'stay.update', 'family_stay', v_stay.id, null, app.stay_data(v_stay));
end;
$$;

create function public.rpc_cancel_stay(p_stay_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_stay public.family_stay;
begin
  select * into v_stay from public.family_stay where id = p_stay_id;
  if v_stay.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_stay.group_id);
  if v_stay.cancelled_at is not null then
    return;
  end if;
  update public.family_stay set cancelled_at = now(), updated_at = now() where id = p_stay_id returning * into v_stay;
  perform app.emit(v_stay.group_id, 'stay.cancel', v_uid, v_stay.id, 'stay.cancel:' || v_stay.id,
                   app.stay_data(v_stay), false);
  perform app.audit(v_stay.group_id, 'stay.cancel', 'family_stay', v_stay.id, null, app.stay_data(v_stay));
end;
$$;

-- Feed / push context for a stay ("Ben · from London").
create function app.stay_data(p_stay public.family_stay)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'guests', array_to_string(p_stay.guest_names || coalesce(array[p_stay.other_guests], '{}'), ', '),
    'arrives', p_stay.arrives, 'leaves', p_stay.leaves, 'from_place', p_stay.from_place))
$$;

-- Retention: stays follow the family's window, counted from the day they leave.
create function app.purge_stays()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  delete from public.family_stay s
   using public.family_group g
   where g.id = s.group_id and s.leaves < current_date - g.retention_days;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into app.ops_log (kind, detail) values ('retention_stays', jsonb_build_object('stays', v_n));
  end if;
  return v_n;
end;
$$;
select cron.schedule('famly-retention-stays', '21 0 * * *', $$ select app.purge_stays() $$);

-------------------------------------------------------------------------------
-- 3. Repeating plans
-------------------------------------------------------------------------------
alter table public.family_event
  add column repeat text check (repeat in ('daily', 'weekly', 'fortnightly', 'monthly')),
  add column repeat_until date,
  add constraint family_event_repeat_until check (repeat_until is null or repeat is not null);

-- Any member can set or clear the rule (same as editing a plan). Car trips don't repeat: each trip is
-- its own booking.
create function public.rpc_set_event_repeat(p_event_id uuid, p_repeat text, p_until date default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.family_event;
  v_tz text;
  v_gap interval;
begin
  select * into v_event from public.family_event where id = p_event_id;
  if v_event.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_event.group_id);
  select * into v_event from public.family_event where id = p_event_id for update;
  if v_event.cancelled_at is not null then
    raise exception 'invalid_state' using errcode = '55000', detail = 'cancelled';
  end if;
  if p_repeat is not distinct from v_event.repeat and p_until is not distinct from v_event.repeat_until then
    return;
  end if;
  if p_repeat is not null then
    if p_repeat not in ('daily', 'weekly', 'fortnightly', 'monthly') then
      raise exception 'invalid_repeat' using errcode = '22023';
    end if;
    if v_event.outing_id is not null or v_event.reservation_id is not null then
      raise exception 'repeat_not_allowed' using errcode = '55000';
    end if;
    -- One occurrence must finish before the next starts.
    v_gap := (array[interval '1 day', interval '7 days', interval '14 days', interval '28 days'])
             [array_position(array['daily', 'weekly', 'fortnightly', 'monthly'], p_repeat)];
    if v_event.ends_at - v_event.starts_at > v_gap then
      raise exception 'repeat_too_long' using errcode = '22023';
    end if;
    select time_zone into v_tz from public.family_group where id = v_event.group_id;
    if p_until is not null and p_until < (v_event.starts_at at time zone v_tz)::date then
      raise exception 'invalid_period' using errcode = '22023';
    end if;
  end if;

  update public.family_event
     set repeat = p_repeat, repeat_until = case when p_repeat is null then null else p_until end,
         version = version + 1, updated_at = now()
   where id = p_event_id;
  perform app.audit(v_event.group_id, 'event.repeat', 'family_event', v_event.id, null,
                    jsonb_build_object('repeat', p_repeat, 'until', p_until));
end;
$$;

-- "every Tuesday", for push text.
create function app.repeat_label(p_repeat text, p_starts timestamptz, p_tz text)
returns text
language sql
stable
set search_path = ''
as $$
  select case p_repeat
    when 'daily' then 'every day'
    when 'weekly' then 'every ' || to_char(p_starts at time zone p_tz, 'FMDay')
    when 'fortnightly' then 'every other ' || to_char(p_starts at time zone p_tz, 'FMDay')
    when 'monthly' then 'monthly on the ' || to_char(p_starts at time zone p_tz, 'FMDDth')
  end
$$;

-------------------------------------------------------------------------------
-- 4. The 6 pm to-do reminder
-------------------------------------------------------------------------------
-- From 18:00 family time, once per person per family per day: their open to-dos (given to them and
-- not declined, not done, not deleted). Late deploys or outages catch up until 22:00, never later.
create function app.prompt_task_reminders()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  with due as (
    select g.id as group_id, a.user_id, (now() at time zone g.time_zone)::date as day,
           count(*) as n, array_agg(t.title order by t.created_at) as titles
      from public.family_group g
      join public.family_task t on t.group_id = g.id and t.completed_at is null and t.cancelled_at is null
      join public.task_assignee a on a.task_id = t.id and a.state in ('pending', 'accepted')
      join public.group_membership m on m.group_id = g.id and m.user_id = a.user_id and m.left_at is null
     where (now() at time zone g.time_zone)::time >= time '18:00'
       and (now() at time zone g.time_zone)::time < time '22:00'
     group by g.id, a.user_id, g.time_zone
  ), sent as (
    insert into public.notification_outbox (group_id, event_type, actor_id, subject_id, dedupe_key, data, push, recipient_id)
    select group_id, 'notify.task_reminder', null, user_id, 'task_reminder:' || group_id || ':' || user_id || ':' || day,
           jsonb_build_object('count', n, 'titles', to_jsonb(titles[1:3])), true, user_id
      from due
    on conflict (dedupe_key) do nothing
    returning 1
  )
  select count(*) into v_n from sent;
  return v_n;
end;
$$;
select cron.schedule('famly-task-reminders', '*/5 * * * *', $$ select app.prompt_task_reminders() $$);

-------------------------------------------------------------------------------
-- 5. Leaving for a plan
-------------------------------------------------------------------------------
-- I'm Leaving can name one of your plans instead of Drive / Gym / Padel / Errand. Its title and "where"
-- are kept on the presence row (as they were when you left), so Today and the push can say
-- "Alex has left the house · Sunday roast · Nana's house". A plan with your own booked trip is left
-- through rpc_report_left instead, so the car shows as in use.
alter table public.member_presence
  add column plan_id uuid,
  add column plan_title text check (char_length(plan_title) <= 120),
  add column place text check (char_length(place) <= 200);

-- Going home, or switching to Drive / Gym / Padel / Errand, forgets the plan.
create function app.presence_clear_plan()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.state = 'home' or new.activity is not null then
    new.plan_id := null;
    new.plan_title := null;
    new.place := null;
  end if;
  return new;
end;
$$;
create trigger member_presence_clear_plan
  before insert or update on public.member_presence
  for each row execute function app.presence_clear_plan();

create function public.rpc_leave_for_plan(p_event_id uuid, p_has_house_key boolean default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_event public.family_event;
  v_old public.member_presence;
  v_new public.member_presence;
begin
  select * into v_event from public.family_event where id = p_event_id;
  if v_event.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_event.group_id);
  if v_event.cancelled_at is not null then
    raise exception 'invalid_state' using errcode = '55000', detail = 'cancelled';
  end if;
  if v_event.created_by is distinct from v_uid and not exists (
       select 1 from public.event_participant p
        where p.event_id = v_event.id and p.user_id = v_uid and p.state <> 'declined') then
    raise exception 'not_invited' using errcode = '42501';
  end if;
  if app.event_trip_owner(v_event) = v_uid then
    raise exception 'use_trip' using errcode = '55000';
  end if;

  select * into v_old from public.member_presence where group_id = v_event.group_id and user_id = v_uid for update;
  insert into public.member_presence (group_id, user_id, state, activity, has_house_key, plan_id, plan_title, place, changed_at)
  values (v_event.group_id, v_uid, 'out', null, p_has_house_key, v_event.id, v_event.title, v_event.destination, now())
  on conflict (group_id, user_id) do update
    set state = 'out', activity = null, has_house_key = excluded.has_house_key, plan_id = excluded.plan_id,
        plan_title = excluded.plan_title, place = excluded.place,
        changed_at = case when public.member_presence.state = 'out' then public.member_presence.changed_at else now() end
  returning * into v_new;

  -- Already out: a quiet correction, like switching activity.
  if v_old.state is distinct from 'out' then
    perform app.emit(v_event.group_id, 'presence.left', v_uid, v_uid, 'presence:' || gen_random_uuid(),
                     jsonb_strip_nulls(jsonb_build_object('plan_title', v_event.title, 'place', v_event.destination,
                                                          'event_id', v_event.id, 'has_house_key', p_has_house_key)),
                     true);
  end if;
  return jsonb_build_object('state', 'out', 'changed_at', v_new.changed_at);
end;
$$;

-------------------------------------------------------------------------------
-- Notifications: categories, wording, relevance, deep links
-------------------------------------------------------------------------------
create or replace function app.notify_category(p_event_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_event_type like 'status.%' or p_event_type like 'presence.%' then 'moves'
    when p_event_type like 'reservation.%' or p_event_type like 'vehicle.%' then 'bookings'
    when p_event_type like 'event.%' or p_event_type like 'notify.event_%' or p_event_type like 'notify.menu_%'
      or p_event_type like 'stay.%' then 'plans'
    when p_event_type like 'notify.task_%' then 'tasks'
    else null
  end
$$;

alter function app.push_text(public.notification_outbox, uuid) rename to push_text_018;

create function app.push_text(p_outbox public.notification_outbox, p_user_id uuid, out title text, out body text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  d jsonb := p_outbox.data;
  v_who text;
  v_tz text;
  v_menu public.family_menu;
  v_event public.family_event;
  v_n int;
begin
  select coalesce(p.time_zone, g.time_zone, 'Asia/Dubai') into v_tz
    from public.family_group g left join public.profile p on p.user_id = p_user_id
   where g.id = p_outbox.group_id;
  v_tz := coalesce(v_tz, 'Asia/Dubai');

  if p_outbox.event_type = 'notify.menu_review' then
    select * into v_menu from public.family_menu where id = p_outbox.subject_id;
    title := 'How was ' || case when v_menu.menu_date = (now() at time zone v_tz)::date then 'tonight''s'
                                else to_char(v_menu.menu_date, 'FMDay') || '''s' end || ' food?';
    body := 'Rate it out of 5 · ' || replace(btrim(v_menu.items), E'\n', ', ');
  elsif p_outbox.event_type = 'notify.task_reminder' then
    v_n := coalesce((d ->> 'count')::int, 1);
    title := case when v_n = 1 then 'You have a to-do waiting' else 'You have ' || v_n || ' to-dos waiting' end;
    body := (select string_agg(x, ' · ') from jsonb_array_elements_text(d -> 'titles') x)
            || case when v_n > 3 then ' · and ' || (v_n - 3) || ' more' else '' end;
  elsif p_outbox.event_type = 'stay.create' then
    select coalesce(nullif(btrim(p.display_name), ''), 'Someone') into v_who from public.profile p where p.user_id = p_outbox.actor_id;
    title := coalesce(v_who, 'Someone') || ' added a stay';
    body := concat_ws(' · ', d ->> 'guests', 'from ' || (d ->> 'from_place'),
                      to_char((d ->> 'arrives')::date, 'Dy DD Mon') || ' – ' || to_char((d ->> 'leaves')::date, 'Dy DD Mon'));
  elsif p_outbox.event_type = 'presence.left' and d ? 'plan_title' then
    select coalesce(nullif(btrim(p.display_name), ''), 'Someone') into v_who from public.profile p where p.user_id = p_outbox.actor_id;
    title := coalesce(v_who, 'Someone') || ' has left the house';
    body := concat_ws(' · ', d ->> 'plan_title', d ->> 'place',
                      case when (d ->> 'has_house_key')::boolean then 'has the house key' end);
  else
    select t.title, t.body into title, body from app.push_text_018(p_outbox, p_user_id) t;
    -- Leaving on a booked plan: add the plan's "where".
    if p_outbox.event_type = 'status.left' then
      select * into v_event from public.family_event
       where outing_id = p_outbox.subject_id and cancelled_at is null and destination is not null limit 1;
      if v_event.id is not null then
        body := concat_ws(' · ', nullif(body, ''), v_event.destination);
      end if;
    end if;
    if p_outbox.event_type = 'event.create' then
      select * into v_event from public.family_event where id = p_outbox.subject_id;
      if v_event.repeat is not null then
        body := body || ' · ' || app.repeat_label(v_event.repeat, v_event.starts_at, v_tz);
      end if;
    end if;
  end if;

  title := left(coalesce(nullif(title, ''), 'fam.ly'), 80);
  body := coalesce(nullif(body, ''), 'Open fam.ly for details');
  if char_length(body) > 180 then
    body := left(body, 179) || '…';
  end if;
end;
$$;

alter function app.delivery_relevant(public.notification_outbox) rename to delivery_relevant_018;

-- A review prompt stays relevant until you've rated or the window shuts (quiet hours may hold it till
-- morning); a to-do reminder until the evening is over; a stay while it's on and not over.
create function app.delivery_relevant(p_outbox public.notification_outbox)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_outbox.event_type = 'notify.menu_review' then exists (
      select 1 from public.family_menu m
       where m.id = p_outbox.subject_id
         and now() < app.menu_review_opens(m.menu_date, m.group_id) + interval '48 hours'
         and not exists (select 1 from public.menu_review r where r.menu_id = m.id and r.user_id = p_outbox.recipient_id))
    when p_outbox.event_type = 'notify.task_reminder' then
      p_outbox.created_at > now() - interval '6 hours'
    when p_outbox.event_type = 'stay.create' then exists (
      select 1 from public.family_stay s join public.family_group g on g.id = s.group_id
       where s.id = p_outbox.subject_id and s.cancelled_at is null and s.leaves >= (now() at time zone g.time_zone)::date)
      and p_outbox.created_at > now() - interval '12 hours'
    else app.delivery_relevant_018(p_outbox)
  end
$$;

-- Dispatch (migration 018) with deep links for review prompts, to-do reminders and stays.
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
              when o.event_type = 'notify.task_reminder' then '/family/todos'
              when o.event_type like 'notify.task_%' then '/family/tasks/' || o.subject_id
              when o.event_type = 'notify.menu_review' then '/family/menus/' || o.subject_id || '?rate=1'
              when o.event_type like 'notify.menu_%' then '/family/menus/' || o.subject_id
              when o.event_type like 'stay.%' then '/family?view=stays'
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
-- Data export (FR-D03): the migration 018 export plus your meal reviews and stays you're in or added.
-------------------------------------------------------------------------------
alter function public.rpc_export_my_data() set schema app;
alter function app.rpc_export_my_data() rename to export_my_data_018;

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
  return app.export_my_data_018() || jsonb_build_object(
    'menu_reviews', coalesce((select jsonb_agg(jsonb_build_object('menu_date', m.menu_date, 'stars', r.stars,
                                                                  'comment', r.comment, 'at', r.created_at))
                                from public.menu_review r join public.family_menu m on m.id = r.menu_id
                               where r.user_id = v_uid), '[]'),
    'stays', coalesce((select jsonb_agg(jsonb_build_object('family', g.name, 'guests', s.guest_names,
                                                           'other_guests', s.other_guests, 'arrives', s.arrives,
                                                           'leaves', s.leaves, 'from', s.from_place, 'note', s.note))
                         from public.family_stay s join public.family_group g on g.id = s.group_id
                        where (v_uid = any (s.guest_ids) or s.created_by = v_uid) and s.cancelled_at is null), '[]')
  );
end;
$$;

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------
revoke execute on function
  app.menu_review_opens(date, uuid), app.is_menu_reviewer(uuid, uuid), app.prompt_menu_reviews(),
  app.check_stay(uuid, uuid[], text, date, date, text, text), app.stay_data(public.family_stay), app.purge_stays(),
  app.repeat_label(text, timestamptz, text), app.prompt_task_reminders(), app.push_text_018(public.notification_outbox, uuid),
  app.delivery_relevant_018(public.notification_outbox), app.export_my_data_018(), app.presence_clear_plan()
  from public, anon, authenticated;
-- Used inside the menu_review row policy, so the reader needs it.
revoke execute on function app.can_see_menu_reviews(uuid) from public, anon;
grant execute on function app.can_see_menu_reviews(uuid) to authenticated;

revoke execute on function
  public.rpc_review_menu(uuid, int, text),
  public.rpc_accept_menu(uuid, int),
  public.rpc_create_stay(uuid, uuid[], text, date, date, text, text),
  public.rpc_update_stay(uuid, uuid[], text, date, date, text, text),
  public.rpc_cancel_stay(uuid),
  public.rpc_set_event_repeat(uuid, text, date),
  public.rpc_leave_for_plan(uuid, boolean),
  public.rpc_export_my_data()
  from public, anon;
grant execute on function
  public.rpc_review_menu(uuid, int, text),
  public.rpc_accept_menu(uuid, int),
  public.rpc_create_stay(uuid, uuid[], text, date, date, text, text),
  public.rpc_update_stay(uuid, uuid[], text, date, date, text, text),
  public.rpc_cancel_stay(uuid),
  public.rpc_set_event_repeat(uuid, text, date),
  public.rpc_leave_for_plan(uuid, boolean),
  public.rpc_export_my_data()
  to authenticated;
