import { QUARTER_HOUR, roundUpTo, utcToWallTime, wallTimeToUtc } from "@famly/domain";
import { useState } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { EventForm, type EventValues } from "../components/EventForm";
import { useUserId } from "../lib/auth";
import { describeBookingError } from "../lib/cars";
import { useAction, useBooking, useCurrentGroup, useMembers } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

export function NewEvent() {
  const { group } = useCurrentGroup();
  const [params] = useSearchParams();
  if (!group) return null;
  const reservationId = params.get("reservation");
  return reservationId
    ? <BookingToCalendar group={group} reservationId={reservationId} />
    : <PlainEvent group={group} />;
}

const familyKeys = (groupId: string) => [["family-events", groupId]];

function PlainEvent({ group }: { group: Group }) {
  const tz = group.time_zone;
  const me = useUserId();
  const navigate = useNavigate();
  const members = useMembers(group.id);
  const [error, setError] = useState<string | null>(null);
  const [start] = useState(() => roundUpTo(new Date(), QUARTER_HOUR));

  const create = useAction(
    async (v: EventValues) => {
      const id = unwrap(
        await supabase.rpc("rpc_create_event", {
          p_group_id: group.id,
          p_title: v.title,
          p_starts_at: wallTimeToUtc(v.start, tz).toISOString(),
          p_ends_at: wallTimeToUtc(v.end, tz).toISOString(),
          p_destination: v.destination,
          p_description: v.description,
          p_participant_ids: v.participantIds,
          p_track_outing: false,
        }),
      );
      if (v.repeat) {
        unwrap(await supabase.rpc("rpc_set_event_repeat", { p_event_id: id, p_repeat: v.repeat, ...(v.repeatUntil ? { p_until: v.repeatUntil } : {}) }));
      }
      return id;
    },
    familyKeys(group.id),
  );

  if (members.isPending) return <p>Loading…</p>;
  return (
    <EventForm
      heading="New Event"
      groupName={group.name}
      timeZone={tz}
      me={me}
      members={members.data ?? []}
      initial={{
        title: "",
        start: utcToWallTime(start, tz),
        end: utcToWallTime(new Date(start.getTime() + 3_600_000), tz),
        destination: "",
        description: "",
        participantIds: [],
        repeat: "",
        repeatUntil: "",
      }}
      submitLabel="Add To Family Calendar"
      busy={create.isPending}
      error={error}
      onSubmit={(v) => {
        setError(null);
        create.mutate(v, {
          onSuccess: (id) => navigate(`/family/events/${id}`, { replace: true }),
          onError: (err) => setError(messageOf(err)),
        });
      }}
      onCancel={() => navigate(-1)}
    />
  );
}

/** Journey 8: show an existing car booking on the Family calendar. Links it; never books again (FR-V09). */
function BookingToCalendar({ group, reservationId }: { group: Group; reservationId: string }) {
  const tz = group.time_zone;
  const me = useUserId();
  const navigate = useNavigate();
  const booking = useBooking(reservationId);
  const members = useMembers(group.id);
  const [error, setError] = useState<string | null>(null);

  const link = useAction(
    async (v: EventValues) =>
      unwrap(
        await supabase.rpc("rpc_add_booking_to_calendar", {
          p_reservation_id: reservationId,
          p_title: v.title,
          p_destination: v.destination,
          p_description: v.description,
          p_participant_ids: v.participantIds,
        }),
      ),
    [...familyKeys(group.id), ["family-event-for-booking", reservationId]],
  );

  if (booking.isPending || members.isPending) return <p>Loading…</p>;
  if (!booking.data) return <p className="error">That booking isn&apos;t available.</p>;
  const b = booking.data;
  const carName = b.vehicle?.name ?? "Car";

  return (
    <EventForm
      heading="Add Your Booking To The Family Calendar"
      groupName={group.name}
      timeZone={tz}
      me={me}
      members={members.data ?? []}
      lockTimes
      initial={{
        title: `${carName} trip`,
        start: utcToWallTime(new Date(b.starts_at!), tz),
        end: utcToWallTime(new Date(b.ends_at!), tz),
        destination: "",
        description: "",
        participantIds: [],
        repeat: "",
        repeatUntil: "",
      }}
      extra={<p className="muted">This uses your existing {carName} booking. No second booking is made.</p>}
      submitLabel="Add To Family Calendar"
      busy={link.isPending}
      error={error}
      onSubmit={(v) => {
        setError(null);
        link.mutate(v, {
          onSuccess: (id) => navigate(`/family/events/${id}`, { replace: true }),
          onError: (err) =>
            setError(describeBookingError(err, { carName, nameOf: () => "", now: new Date(), timeZone: tz })),
        });
      }}
      onCancel={() => navigate(-1)}
    />
  );
}
