-- P06 Family calendar & outings. FR-F01–F03, FR-F05, FR-F06, FR-V09, T05.
-- Edit rights (interim, recorded in the P06 report):
--   * plain events: any adult member may edit/cancel (D09 routine admin parity), audited
--   * events tied to someone's trip (tracked outing or car booking): only that person
-- A booking-linked event follows the booking's times; removing the event never touches the booking.

create table public.family_event (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_group (id) on delete cascade,
  created_by uuid references auth.users (id) on delete set null,
  title text not null check (char_length(title) between 1 and 120),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  destination text check (char_length(destination) <= 200),
  description text check (char_length(description) <= 2000),
  outing_id uuid,
  reservation_id uuid,
  cancelled_at timestamptz,
  version int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (group_id, id),
  check (ends_at > starts_at),
  foreign key (group_id, outing_id) references public.outing (group_id, id) on delete set null (outing_id),
  foreign key (group_id, reservation_id) references public.vehicle_reservation (group_id, id)
    on delete set null (reservation_id)
);
create index family_event_group_time_idx on public.family_event (group_id, starts_at);
-- A booking appears on the Family calendar at most once (FR-V09, FR-F05).
create unique index family_event_one_per_reservation
  on public.family_event (reservation_id) where reservation_id is not null and cancelled_at is null;

create type public.participant_state as enum ('invited', 'attending', 'declined');

create table public.event_participant (
  group_id uuid not null,
  event_id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  state public.participant_state not null default 'invited',
  responded_at timestamptz,
  primary key (event_id, user_id),
  foreign key (group_id, event_id) references public.family_event (group_id, id) on delete cascade
);

alter table public.family_event enable row level security;
alter table public.event_participant enable row level security;
revoke all on public.family_event, public.event_participant from anon, authenticated;
grant select on public.family_event, public.event_participant to authenticated;

-- D04 / FR-F03 / T05: every member reads full details, invited or not. Nonmembers read nothing.
create policy family_event_select on public.family_event for select to authenticated
  using (app.is_member(group_id));
create policy event_participant_select on public.event_participant for select to authenticated
  using (app.is_member(group_id));

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
create function app.validate_event_fields(
  p_title text, p_starts_at timestamptz, p_ends_at timestamptz, p_destination text, p_description text
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 120 then
    raise exception 'invalid_title' using errcode = '22023';
  end if;
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'invalid_period' using errcode = '22023';
  end if;
  if p_ends_at - p_starts_at > interval '31 days' then
    raise exception 'too_long' using errcode = '22023';
  end if;
  if char_length(coalesce(p_destination, '')) > 200 or char_length(coalesce(p_description, '')) > 2000 then
    raise exception 'text_too_long' using errcode = '22023';
  end if;
end;
$$;

-- Replaces the participant list. Everyone must be an active member; the trip owner/creator stays
-- attending; existing people keep their response; new people start as invited (FR-F06).
create function app.set_participants(p_event public.family_event, p_user_ids uuid[], p_keep_attending uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids uuid[] := array(select distinct u from unnest(coalesce(p_user_ids, '{}') || p_keep_attending) u
                        where u is not null);
begin
  if exists (
    select 1 from unnest(v_ids) u
     where not exists (select 1 from public.group_membership m
                        where m.group_id = p_event.group_id and m.user_id = u and m.left_at is null)
  ) then
    raise exception 'participant_not_member' using errcode = '22023';
  end if;

  delete from public.event_participant
   where event_id = p_event.id and user_id <> all (v_ids);

  insert into public.event_participant (group_id, event_id, user_id, state, responded_at)
  select p_event.group_id, p_event.id, u,
         case when u = p_keep_attending then 'attending'::public.participant_state else 'invited' end,
         case when u = p_keep_attending then now() end
    from unnest(v_ids) u
  on conflict (event_id, user_id) do nothing;
end;
$$;

-- The person whose trip this event represents, or null for a plain shared event.
create function app.event_trip_owner(p_event public.family_event)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select owner_id from public.vehicle_reservation where id = p_event.reservation_id),
    (select owner_id from public.outing where id = p_event.outing_id))
$$;

-------------------------------------------------------------------------------
-- rpc_create_event (FR-F01, FR-F02). With p_track_outing, also creates a car-free outing owned by
-- the creator, so "Left" / "I'm home" work for it later (P07) without occupying any car.
-------------------------------------------------------------------------------
create function public.rpc_create_event(
  p_group_id uuid,
  p_title text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_destination text default null,
  p_description text default null,
  p_participant_ids uuid[] default '{}',
  p_track_outing boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_event public.family_event;
  v_outing_id uuid;
begin
  perform app.assert_member(p_group_id);
  perform app.validate_event_fields(p_title, p_starts_at, p_ends_at, p_destination, p_description);

  if p_track_outing then
    insert into public.outing (group_id, owner_id, planned_start, planned_return)
    values (p_group_id, v_uid, p_starts_at, p_ends_at)
    returning id into v_outing_id;
  end if;

  insert into public.family_event (group_id, created_by, title, starts_at, ends_at, destination, description, outing_id)
  values (p_group_id, v_uid, btrim(p_title), p_starts_at, p_ends_at,
          nullif(btrim(p_destination), ''), nullif(btrim(p_description), ''), v_outing_id)
  returning * into v_event;

  perform app.set_participants(v_event, p_participant_ids, v_uid);
  perform app.audit(p_group_id, 'event.create', 'family_event', v_event.id, null,
                    jsonb_build_object('title', v_event.title, 'starts_at', p_starts_at, 'ends_at', p_ends_at,
                                       'outing', v_outing_id is not null));
  return v_event.id;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_add_booking_to_calendar (FR-V09, journey 8): links the existing booking and its outing.
-- Never creates a reservation. Calling it again returns the existing event.
-------------------------------------------------------------------------------
create function public.rpc_add_booking_to_calendar(
  p_reservation_id uuid,
  p_title text,
  p_destination text default null,
  p_description text default null,
  p_participant_ids uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
  v_res public.vehicle_reservation;
  v_event public.family_event;
begin
  select * into v_res from public.vehicle_reservation where id = p_reservation_id;
  if v_res.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_res.group_id);
  select * into v_res from public.vehicle_reservation where id = p_reservation_id for update;
  if v_res.owner_id <> v_uid then
    raise exception 'not_owner' using errcode = '42501';
  end if;
  if v_res.status not in ('reserved', 'in_use_reported') then
    raise exception 'invalid_state' using errcode = '55000', detail = v_res.status::text;
  end if;

  select * into v_event from public.family_event
   where reservation_id = p_reservation_id and cancelled_at is null;
  if v_event.id is not null then
    return v_event.id;
  end if;

  perform app.validate_event_fields(p_title, v_res.starts_at, v_res.ends_at, p_destination, p_description);
  insert into public.family_event (group_id, created_by, title, starts_at, ends_at, destination, description,
                                   outing_id, reservation_id)
  values (v_res.group_id, v_uid, btrim(p_title), v_res.starts_at, v_res.ends_at,
          nullif(btrim(p_destination), ''), nullif(btrim(p_description), ''),
          (select id from public.outing where reservation_id = v_res.id), v_res.id)
  returning * into v_event;

  perform app.set_participants(v_event, p_participant_ids, v_uid);
  perform app.audit(v_res.group_id, 'event.create', 'family_event', v_event.id, null,
                    jsonb_build_object('title', v_event.title, 'reservation_id', v_res.id));
  return v_event.id;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_update_event (FR-F01). Times of a booking-linked event can't be edited here: change the booking.
-------------------------------------------------------------------------------
create function public.rpc_update_event(
  p_event_id uuid,
  p_title text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_destination text,
  p_description text,
  p_participant_ids uuid[],
  p_expected_version int
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.family_event;
  v_owner uuid;
begin
  select * into v_event from public.family_event where id = p_event_id;
  if v_event.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_event.group_id);
  select * into v_event from public.family_event where id = p_event_id for update;

  v_owner := app.event_trip_owner(v_event);
  if v_owner is not null and v_owner <> app.current_user_id() then
    raise exception 'not_owner' using errcode = '42501';
  end if;
  if v_event.cancelled_at is not null then
    raise exception 'invalid_state' using errcode = '55000', detail = 'cancelled';
  end if;
  if p_expected_version is null or v_event.version <> p_expected_version then
    raise exception 'stale_version' using errcode = '55000';
  end if;
  if v_event.reservation_id is not null
     and (p_starts_at is distinct from v_event.starts_at or p_ends_at is distinct from v_event.ends_at) then
    raise exception 'times_follow_booking' using errcode = '55000';
  end if;
  perform app.validate_event_fields(p_title, p_starts_at, p_ends_at, p_destination, p_description);

  update public.family_event
     set title = btrim(p_title), starts_at = p_starts_at, ends_at = p_ends_at,
         destination = nullif(btrim(p_destination), ''), description = nullif(btrim(p_description), ''),
         version = version + 1, updated_at = now()
   where id = v_event.id
  returning * into v_event;

  if v_event.outing_id is not null and v_event.reservation_id is null then
    update public.outing
       set planned_start = p_starts_at, planned_return = p_ends_at, version = version + 1
     where id = v_event.outing_id;
  end if;

  perform app.set_participants(v_event, p_participant_ids, coalesce(v_owner, v_event.created_by));
  perform app.audit(v_event.group_id, 'event.update', 'family_event', v_event.id, null,
                    jsonb_build_object('title', v_event.title, 'starts_at', p_starts_at, 'ends_at', p_ends_at));
  return v_event.version;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_cancel_event. A car-free outing is cancelled with it. A booking is never touched (FR-V09).
-------------------------------------------------------------------------------
create function public.rpc_cancel_event(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.family_event;
  v_owner uuid;
begin
  select * into v_event from public.family_event where id = p_event_id;
  if v_event.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_event.group_id);
  select * into v_event from public.family_event where id = p_event_id for update;

  v_owner := app.event_trip_owner(v_event);
  if v_owner is not null and v_owner <> app.current_user_id() then
    raise exception 'not_owner' using errcode = '42501';
  end if;
  if v_event.cancelled_at is not null then
    return;
  end if;

  update public.family_event set cancelled_at = now(), version = version + 1, updated_at = now()
   where id = v_event.id;
  if v_event.outing_id is not null and v_event.reservation_id is null then
    update public.outing set status = 'cancelled', version = version + 1
     where id = v_event.outing_id and status = 'planned';
  end if;
  perform app.audit(v_event.group_id, 'event.cancel', 'family_event', v_event.id);
end;
$$;

-- FR-F06: only the participant says whether they're coming.
create function public.rpc_respond_event(p_event_id uuid, p_state public.participant_state)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid;
begin
  select group_id into v_group from public.family_event where id = p_event_id;
  if v_group is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_group);
  if p_state not in ('attending', 'declined') then
    raise exception 'invalid_state' using errcode = '22023';
  end if;
  update public.event_participant set state = p_state, responded_at = now()
   where event_id = p_event_id and user_id = app.current_user_id();
  if not found then
    raise exception 'not_invited' using errcode = '55000';
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- Keep a booking-linked event's times in step with the booking, whichever path changed it.
-------------------------------------------------------------------------------
create function app.sync_event_with_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.family_event
     set starts_at = new.starts_at, ends_at = new.ends_at, version = version + 1, updated_at = now()
   where reservation_id = new.id and cancelled_at is null
     and (starts_at, ends_at) is distinct from (new.starts_at, new.ends_at);
  return new;
end;
$$;
create trigger vehicle_reservation_sync_event
  after update of period on public.vehicle_reservation
  for each row execute function app.sync_event_with_reservation();

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------
revoke execute on function
  app.validate_event_fields(text, timestamptz, timestamptz, text, text),
  app.set_participants(public.family_event, uuid[], uuid),
  app.event_trip_owner(public.family_event),
  app.sync_event_with_reservation()
  from public, anon, authenticated;

revoke execute on function
  public.rpc_create_event(uuid, text, timestamptz, timestamptz, text, text, uuid[], boolean),
  public.rpc_add_booking_to_calendar(uuid, text, text, text, uuid[]),
  public.rpc_update_event(uuid, text, timestamptz, timestamptz, text, text, uuid[], int),
  public.rpc_cancel_event(uuid),
  public.rpc_respond_event(uuid, public.participant_state)
  from public, anon;
grant execute on function
  public.rpc_create_event(uuid, text, timestamptz, timestamptz, text, text, uuid[], boolean),
  public.rpc_add_booking_to_calendar(uuid, text, text, text, uuid[]),
  public.rpc_update_event(uuid, text, timestamptz, timestamptz, text, text, uuid[], int),
  public.rpc_cancel_event(uuid),
  public.rpc_respond_event(uuid, public.participant_state)
  to authenticated;

-------------------------------------------------------------------------------
-- FR-A06 / T19 for outings: when someone leaves, their planned car-free outings (and the
-- events that represent them) are cancelled too, so nothing is left prompting a non-member.
-- Car bookings are already handled by app.exit_member.
-------------------------------------------------------------------------------
create function app.cancel_outings_on_exit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  with cancelled as (
    update public.outing
       set status = 'cancelled', version = version + 1
     where group_id = new.group_id and owner_id = new.user_id
       and reservation_id is null and status = 'planned'
    returning id
  )
  update public.family_event
     set cancelled_at = now(), version = version + 1, updated_at = now()
   where outing_id in (select id from cancelled) and cancelled_at is null;
  return new;
end;
$$;
create trigger group_membership_cancel_outings_on_exit
  after update of left_at on public.group_membership
  for each row when (old.left_at is null and new.left_at is not null)
  execute function app.cancel_outings_on_exit();
revoke execute on function app.cancel_outings_on_exit() from public, anon, authenticated;
