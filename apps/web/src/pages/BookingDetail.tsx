import { displayStatus, formatMoment, formatWindow, utcToWallTime, wallTimeToUtc, type ReservationStatus } from "@famly/domain";
import { useState, type FormEvent } from "react";
import { Link, useParams } from "react-router";
import { useUserId } from "../lib/auth";
import { StatusActions, StatusHistory } from "../components/StatusActions";
import { describeBookingError, handoverWarning } from "../lib/cars";
import {
  bookingKeys,
  useAction,
  useBooking,
  useBookingHistory,
  useCarActivity,
  useCurrentGroup,
  useEventForBooking,
  useMembers,
  useOutingForBooking,
} from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;
type Booking = NonNullable<NonNullable<ReturnType<typeof useBooking>["data"]>>;

const STATUS_WORDS: Record<ReturnType<typeof displayStatus>, string> = {
  scheduled: "Scheduled",
  reported_left: "Reported left",
  overdue_unconfirmed: "Overdue · not confirmed back",
  reported_returned: "Reported returned",
  cancelled: "Cancelled",
};

export function BookingDetail() {
  const { group } = useCurrentGroup();
  return group ? <BookingBody group={group} /> : null;
}

function BookingBody({ group }: { group: Group }) {
  const { bookingId = "" } = useParams();
  const uid = useUserId();
  const booking = useBooking(bookingId);
  const members = useMembers(group.id);

  if (booking.isPending) return <p>Loading…</p>;
  if (booking.isError) return <p className="error">{messageOf(booking.error)}</p>;
  if (!booking.data) {
    return (
      <div className="stack">
        <p>That booking doesn&apos;t exist, or isn&apos;t in {group.name}.</p>
        <Link to="/cars">Back To Cars</Link>
      </div>
    );
  }

  const b = booking.data;
  const tz = group.time_zone;
  const now = new Date();
  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const nameOf = (id: string | null) => (id ? (names.get(id) ?? "a former member") : "someone");
  const carName = b.vehicle?.name ?? "Car";
  const startsAt = new Date(b.starts_at!);
  const endsAt = new Date(b.ends_at!);
  const status = displayStatus(
    { status: b.status as ReservationStatus, endsAt, vehicleReturnedAt: null },
    now,
  );
  const mine = b.owner_id === uid;
  const ctx = { carName, nameOf: (id: string) => nameOf(id), now, timeZone: tz };

  return (
    <div className="stack">
      <section className="card stack">
        <h2>{carName}</h2>
        <p className="big">{formatWindow(startsAt, endsAt, now, tz)}</p>
        <p>
          Booked by <strong>{mine ? "you" : nameOf(b.owner_id)}</strong> · <span>{STATUS_WORDS[status]}</span>
        </p>
        {b.needs_reconciliation && b.status !== "cancelled" && (
          <p className="warn-text">
            <span aria-hidden="true">⚠ </span>
            This booking clashes with maintenance or the car being inactive.
            {mine ? " Please move or cancel it." : ` ${nameOf(b.owner_id)} has been asked to move or cancel it.`}
          </p>
        )}
      </section>

      <BookingStatus booking={b} group={group} mine={mine} carName={carName} nameOf={nameOf} />
      <OnFamilyCalendar bookingId={b.id} canAdd={mine && (b.status === "reserved" || b.status === "in_use_reported")} />
      {mine && b.status === "reserved" && <EditTimes booking={b} group={group} ctx={ctx} />}
      {mine && (b.status === "reserved" || b.status === "in_use_reported") && (
        <Extend booking={b} group={group} ctx={ctx} />
      )}
      {mine && b.status === "reserved" && <Cancel booking={b} group={group} />}

      <History bookingId={b.id} nameOf={nameOf} tz={tz} now={now} />
    </div>
  );
}

type Ctx = { carName: string; nameOf: (id: string) => string; now: Date; timeZone: string };

/** Owner's Left / I'm home buttons, the next-booker warning, and the self-reported history. */
function BookingStatus(props: {
  booking: Booking;
  group: Group;
  mine: boolean;
  carName: string;
  nameOf: (id: string | null) => string;
}) {
  const { booking: b, group } = props;
  const outing = useOutingForBooking(b.id);
  const activity = useCarActivity(group.id);
  const warning = activity.data
    ? handoverWarning(b.id, activity.data,
        { carName: props.carName, nameOf: (id) => props.nameOf(id), timeZone: group.time_zone }, new Date())
    : null;

  return (
    <>
      {warning && (
        <p className="warn-text" role="status"><span aria-hidden="true">⚠ </span>{warning} Your booking hasn&apos;t changed.</p>
      )}
      {props.mine && outing.data && (b.status === "reserved" || b.status === "in_use_reported" || b.status === "completed") && (
        <StatusActions outing={outing.data} groupId={group.id} timeZone={group.time_zone} carName={props.carName}
                       bookingEndsAt={new Date(b.ends_at!)} />
      )}
      <StatusHistory outingId={outing.data?.id ?? null} nameOf={props.nameOf} timeZone={group.time_zone} />
    </>
  );
}

/** Journey 8: the booking's Family-calendar entry, or a way to add one (linked, never duplicated). */
function OnFamilyCalendar({ bookingId, canAdd }: { bookingId: string; canAdd: boolean }) {
  const linked = useEventForBooking(bookingId);
  if (linked.isPending) return null;
  if (linked.data) {
    return (
      <p className="notice">
        On the Family calendar as <Link to={`/family/events/${linked.data.id}`}>{linked.data.title}</Link>
      </p>
    );
  }
  return canAdd ? (
    <Link className="button secondary-link" to={`/family/new?reservation=${bookingId}`}>Add To Family Calendar</Link>
  ) : null;
}

function EditTimes({ booking, group, ctx }: { booking: Booking; group: Group; ctx: Ctx }) {
  const tz = group.time_zone;
  const [open, setOpen] = useState(false);
  const [start, setStart] = useState(utcToWallTime(new Date(booking.starts_at!), tz));
  const [end, setEnd] = useState(utcToWallTime(new Date(booking.ends_at!), tz));
  const [error, setError] = useState<string | null>(null);
  const update = useAction(
    async () =>
      unwrap(
        await supabase.rpc("rpc_update_reservation", {
          p_reservation_id: booking.id,
          p_starts_at: wallTimeToUtc(start, tz).toISOString(),
          p_ends_at: wallTimeToUtc(end, tz).toISOString(),
          p_expected_version: booking.version,
        }),
      ),
    bookingKeys(group.id, booking.id),
  );

  function submit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    update.mutate(undefined, {
      onSuccess: () => setOpen(false),
      onError: (err) => setError(describeBookingError(err, ctx)),
    });
  }

  if (!open) return <button className="secondary" onClick={() => setOpen(true)}>Change Time</button>;
  return (
    <form onSubmit={submit} className="card stack">
      <h2>Change Time</h2>
      <label>
        From
        <input type="datetime-local" required step={900} value={start} onChange={(e) => setStart(e.target.value)} />
      </label>
      <label>
        Until
        <input type="datetime-local" required step={900} value={end} min={start} onChange={(e) => setEnd(e.target.value)} />
      </label>
      {error && <p className="error" role="alert">{error}</p>}
      <div className="row">
        <button type="submit" disabled={update.isPending}>Save</button>
        <button type="button" className="link" onClick={() => setOpen(false)}>Cancel</button>
      </div>
    </form>
  );
}

function Extend({ booking, group, ctx }: { booking: Booking; group: Group; ctx: Ctx }) {
  const [error, setError] = useState<string | null>(null);
  const extend = useAction(
    async (minutes: number) =>
      unwrap(
        await supabase.rpc("rpc_extend_reservation", {
          p_reservation_id: booking.id,
          p_ends_at: new Date(new Date(booking.ends_at!).getTime() + minutes * 60_000).toISOString(),
          p_expected_version: booking.version,
        }),
      ),
    bookingKeys(group.id, booking.id),
  );
  function go(minutes: number) {
    setError(null);
    extend.mutate(minutes, { onError: (err) => setError(describeBookingError(err, ctx)) });
  }
  return (
    <section className="card stack">
      <h2>Need It Longer?</h2>
      <div className="row actions">
        {[30, 60, 120].map((m) => (
          <button key={m} className="secondary" disabled={extend.isPending} onClick={() => go(m)}>
            +{m < 60 ? `${m} Min` : `${m / 60} h`}
          </button>
        ))}
      </div>
      <p className="muted">Extending never moves anyone else&apos;s booking.</p>
      {error && <p className="error" role="alert">{error}</p>}
    </section>
  );
}

function Cancel({ booking, group }: { booking: Booking; group: Group }) {
  const [confirming, setConfirming] = useState(false);
  const cancel = useAction(
    async () =>
      unwrap(
        await supabase.rpc("rpc_cancel_reservation", {
          p_reservation_id: booking.id,
          p_expected_version: booking.version,
        }),
      ),
    bookingKeys(group.id, booking.id),
  );
  if (!confirming) {
    return <button className="link danger" onClick={() => setConfirming(true)}>Cancel Booking…</button>;
  }
  return (
    <section className="card stack">
      <p>Cancel this booking? The time becomes free for everyone straight away.</p>
      {cancel.error && <p className="error" role="alert">{messageOf(cancel.error)}</p>}
      <div className="row">
        <button className="danger" disabled={cancel.isPending} onClick={() => cancel.mutate(undefined)}>
          Cancel Booking
        </button>
        <button className="link" onClick={() => setConfirming(false)}>Keep It</button>
      </div>
    </section>
  );
}

function History(props: { bookingId: string; nameOf: (id: string | null) => string; tz: string; now: Date }) {
  const history = useBookingHistory(props.bookingId);
  if (!history.data || history.data.length === 0) return null;

  const when = (v: unknown) => (typeof v === "string" ? formatMoment(new Date(v), props.now, props.tz) : "?");
  const describe = (h: (typeof history.data)[number]): string => {
    const before = (h.before ?? {}) as Record<string, unknown>;
    const after = (h.after ?? {}) as Record<string, unknown>;
    switch (h.action) {
      case "reservation.create":
        return "Booked";
      case "reservation.update":
        return `Changed from ${when(before.starts_at)}–${when(before.ends_at)} to ${when(after.starts_at)}–${when(after.ends_at)}`;
      case "reservation.extend":
        return `Extended to ${when(after.ends_at)}`;
      case "reservation.cancel":
        return "Cancelled";
      case "reservation.cancel_on_exit":
        return `Cancelled because the owner left the family`;
      case "reservation.override":
        return `Cancelled by ${props.nameOf(h.actor_id)}${h.reason ? `: “${h.reason}”` : ""}`;
      default:
        return h.action;
    }
  };

  return (
    <section className="card stack">
      <h2>Changes To This Booking</h2>
      <ul className="list">
        {history.data.map((h) => (
          <li key={h.id}>
            {describe(h)}
            <span className="muted">
              {" "}· {props.nameOf(h.actor_id)}, {formatMoment(new Date(h.at), props.now, props.tz)}
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}
