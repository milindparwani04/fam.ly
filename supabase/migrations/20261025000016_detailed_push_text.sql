-- Lock-screen pushes say what happened (founder decision, 2026-10-25). This replaces FR-N04's generic
-- wording ("Family update in fam.ly"): the family wants to glance at the lock screen and see the task,
-- who left the house, the menu. Pushes still only go to the people they went to before (family members,
-- or the one recipient); only the words change.
--
--   "New task from Sam"            "Pick up the dry cleaning"
--   "Sam has left the house"       "Land Cruiser · has the house key"
--   "Sam has returned home"        "Land Cruiser is back"
--   "Sam proposed tomorrow's menu" "Lunch: dal, rice …"
--
-- Times are shown in the recipient's time zone. Bodies are cut to 180 characters.

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
  -- What an outing is about: the car, else the event's title.
  v_what := coalesce(d ->> 'vehicle_name', d ->> 'title');

  case
    -- Your own trip
    when p_outbox.event_type = 'prompt.departure_soon' then
      title := 'Leaving in 30 minutes';
      body := 'Your ' || coalesce(v_what || ' ', '') || 'trip starts at '
              || to_char((d ->> 'planned_start')::timestamptz at time zone v_tz, 'HH24:MI') || '. Ready to leave?';
    when p_outbox.event_type = 'prompt.departure' then
      title := 'Time to go';
      body := 'Your ' || coalesce(v_what || ' ', '') || 'trip starts now. Tap Left when you set off.';
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
      body := concat_ws(' · ', v_what,
                        case (d ->> 'has_house_key')::boolean when true then 'has the house key'
                                                              when false then 'doesn''t have the house key' end);
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
    when p_outbox.event_type = 'reservation.override' then
      title := v_who || ' cancelled a booking';
      body := concat_ws(' · ', d ->> 'vehicle_name', d ->> 'reason');

    -- Plans
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

-------------------------------------------------------------------------------
-- Dispatch: same claiming as migration 015; the wording now comes from app.push_text.
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

  return query
  select d.id, s.endpoint, s.p256dh, s.auth_secret,
         t.title, t.body,
         case when o.event_type like 'prompt.%' and o.data ? 'reservation_id' then '/bookings/' || (o.data ->> 'reservation_id')
              when o.event_type like 'prompt.%' then '/'
              when o.event_type like 'status.%' and o.data ? 'reservation_id' then '/bookings/' || (o.data ->> 'reservation_id')
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

revoke execute on function app.push_text(public.notification_outbox, uuid) from public, anon, authenticated;
