-- Migration 021 (founder, 2026-11-26): the Family calendar shows all activity. Every car booking goes on
-- it by itself, so "I'm Leaving" can offer it. This replaces the opt-in "Add To Family Calendar" step
-- (FR-V09 / journey 8); the booking is still the only thing that occupies the car.
--   * A new booking gets its plan "<Car> trip", with the owner going. No extra push or feed row: the
--     booking already announces itself. The owner can add a place or invite people on the plan.
--   * Cancelling the booking (owner, override, or leaving the family) takes the plan off.
--   * The plan can't be removed while the booking stands.
--   * Existing bookings that aren't cancelled are added now.

create function app.add_booking_event(p_outing public.outing)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id uuid;
begin
  insert into public.family_event (group_id, created_by, title, starts_at, ends_at, outing_id, reservation_id,
                                   created_at)
  select r.group_id, r.owner_id, left(v.name || ' trip', 120), r.starts_at, r.ends_at, p_outing.id, r.id,
         -- The booking's own time, so the 12-hour plan reminder treats it as made when it was booked.
         r.created_at
    from public.vehicle_reservation r
    join public.vehicle v on v.id = r.vehicle_id
   where r.id = p_outing.reservation_id and r.status <> 'cancelled'
     and not exists (select 1 from public.family_event e where e.reservation_id = r.id and e.cancelled_at is null)
  returning id into v_event_id;

  if v_event_id is not null then
    insert into public.event_participant (group_id, event_id, user_id, state, responded_at)
    values (p_outing.group_id, v_event_id, p_outing.owner_id, 'attending', now());
  end if;
end;
$$;

-- A booking's outing is written right after the booking, so by now both exist.
create function app.outing_add_booking_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.add_booking_event(new);
  return new;
end;
$$;
create trigger outing_add_booking_event
  after insert on public.outing
  for each row when (new.reservation_id is not null)
  execute function app.outing_add_booking_event();

-- Invitees are told by the existing family_event_cancel_outbox trigger.
create function app.cancel_event_with_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.family_event
     set cancelled_at = now(), version = version + 1, updated_at = now()
   where reservation_id = new.id and cancelled_at is null;
  return new;
end;
$$;
create trigger vehicle_reservation_cancel_event
  after update of status on public.vehicle_reservation
  for each row when (new.status = 'cancelled' and old.status <> 'cancelled')
  execute function app.cancel_event_with_reservation();

-- A booking is always on the calendar now, so there's nothing to add by hand.
drop function public.rpc_add_booking_to_calendar(uuid, text, text, text, uuid[]);

-- rpc_cancel_event (migration 007) plus: a booking's plan only goes when the booking is cancelled.
create or replace function public.rpc_cancel_event(p_event_id uuid)
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
  if v_event.reservation_id is not null then
    raise exception 'cancel_the_booking' using errcode = '55000';
  end if;

  update public.family_event set cancelled_at = now(), version = version + 1, updated_at = now()
   where id = v_event.id;
  if v_event.outing_id is not null then
    update public.outing set status = 'cancelled', version = version + 1
     where id = v_event.outing_id and status = 'planned';
  end if;
  perform app.audit(v_event.group_id, 'event.cancel', 'family_event', v_event.id);
end;
$$;

-------------------------------------------------------------------------------
-- Existing data. Quietly: nobody is notified about this tidy-up.
-------------------------------------------------------------------------------
alter table public.family_event disable trigger family_event_cancel_outbox;
update public.family_event e
   set cancelled_at = now(), version = e.version + 1, updated_at = now()
  from public.vehicle_reservation r
 where r.id = e.reservation_id and r.status = 'cancelled' and e.cancelled_at is null;
alter table public.family_event enable trigger family_event_cancel_outbox;

select app.add_booking_event(o) from public.outing o where o.reservation_id is not null;

revoke execute on function
  app.add_booking_event(public.outing), app.outing_add_booking_event(), app.cancel_event_with_reservation()
  from public, anon, authenticated;
