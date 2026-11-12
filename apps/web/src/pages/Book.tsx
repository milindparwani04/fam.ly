import {
  formatWindow,
  isFree,
  overlaps,
  QUARTER_HOUR,
  roundUpTo,
  suggestSlots,
  utcToWallTime,
  wallTimeToUtc,
  type Interval,
} from "@famly/domain";
import { useEffect, useMemo, useState, type FormEvent } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { busyFor, describeBookingError, newIdempotencyKey } from "../lib/cars";
import { bookingKeys, useAction, useCarActivity, useCurrentGroup, useMembers, useVehicles } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

export function Book() {
  const { group } = useCurrentGroup();
  return group ? <BookForm group={group} /> : null;
}

function toSlot(start: string, end: string, tz: string): Interval | null {
  try {
    const w = { startsAt: wallTimeToUtc(start, tz), endsAt: wallTimeToUtc(end, tz) };
    return w.endsAt > w.startsAt ? w : null;
  } catch {
    return null;
  }
}

function durationLabel(w: Interval): string {
  const mins = Math.round((w.endsAt.getTime() - w.startsAt.getTime()) / 60_000);
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return [h ? `${h} h` : "", m ? `${m} min` : ""].filter(Boolean).join(" ");
}

function BookForm({ group }: { group: Group }) {
  const tz = group.time_zone;
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const vehicles = useVehicles(group.id);
  const activity = useCarActivity(group.id);
  const members = useMembers(group.id);

  const [now] = useState(() => new Date());
  const firstStart = roundUpTo(now, QUARTER_HOUR);
  const [vehicleId, setVehicleId] = useState(params.get("vehicle") ?? "");
  const [start, setStart] = useState(() => utcToWallTime(firstStart, tz));
  const [end, setEnd] = useState(() => utcToWallTime(new Date(firstStart.getTime() + 3_600_000), tz));
  const [reviewing, setReviewing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per intended booking: a retried tap returns the same booking (T02); any edit is a new intent.
  const [idemKey, setIdemKey] = useState(newIdempotencyKey);
  useEffect(() => setIdemKey(newIdempotencyKey()), [vehicleId, start, end]);

  const activeCars = useMemo(() => vehicles.data?.filter((v) => v.active) ?? [], [vehicles.data]);
  useEffect(() => {
    if (!vehicleId && activeCars[0]) setVehicleId(activeCars[0].id);
  }, [activeCars, vehicleId]);

  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const nameOf = (id: string) => names.get(id) ?? "a former member";
  const car = activeCars.find((v) => v.id === vehicleId);

  const create = useAction(
    async () =>
      unwrap(
        await supabase.rpc("rpc_create_reservation", {
          p_vehicle_id: vehicleId,
          p_starts_at: slot!.startsAt.toISOString(),
          p_ends_at: slot!.endsAt.toISOString(),
          p_idempotency_key: idemKey,
        }),
      ),
    bookingKeys(group.id),
  );

  if (vehicles.isPending || activity.isPending) return <p>Loading…</p>;
  if (vehicles.isError) return <p className="error">{messageOf(vehicles.error)}</p>;
  if (activity.isError) return <p className="error">{messageOf(activity.error)}</p>;
  if (activeCars.length === 0) return <p>Add a car first, on the Cars tab.</p>;

  const slot = toSlot(start, end, tz);
  const busy = car ? busyFor(car.id, activity.data, now) : [];
  const free = slot ? isFree(busy, slot) : false;
  const startsInPast = slot ? slot.startsAt.getTime() < now.getTime() - 5 * 60_000 : false;

  const clashBooking = slot
    ? activity.data.bookings.find(
        (b) => b.vehicle_id === vehicleId && b.status !== "completed" &&
          overlaps({ startsAt: new Date(b.starts_at!), endsAt: new Date(b.ends_at!) }, slot),
      )
    : undefined;
  const clashMaintenance = slot
    ? activity.data.maintenance.find(
        (m) => m.vehicle_id === vehicleId &&
          overlaps({ startsAt: new Date(m.starts_at!), endsAt: new Date(m.ends_at!) }, slot),
      )
    : undefined;

  const suggestions = slot && !free ? suggestSlots(busy, slot, { notBefore: now }) : [];
  const otherFreeCars = slot && !free
    ? activeCars.filter((v) => v.id !== vehicleId && isFree(busyFor(v.id, activity.data, now), slot))
    : [];

  function pick(w: Interval) {
    setStart(utcToWallTime(w.startsAt, tz));
    setEnd(utcToWallTime(w.endsAt, tz));
    setError(null);
  }

  function onStartChange(value: string) {
    // Keep the same length when the start moves, so changing the day doesn't make end < start.
    const old = toSlot(start, end, tz);
    setStart(value);
    if (old && value) {
      try {
        const s = wallTimeToUtc(value, tz);
        setEnd(utcToWallTime(new Date(s.getTime() + (old.endsAt.getTime() - old.startsAt.getTime())), tz));
      } catch {
        // partial input while typing
      }
    }
  }

  function confirm() {
    setError(null);
    create.mutate(undefined, {
      onSuccess: (id) => navigate(`/bookings/${id}`, { replace: true }),
      onError: (err) => {
        setReviewing(false);
        setError(describeBookingError(err, { carName: car?.name ?? "This car", nameOf, now: new Date(), timeZone: tz }));
      },
    });
  }

  if (reviewing && slot && car) {
    return (
      <div className="stack">
        <h2>Check Your Booking</h2>
        <section className="card stack">
          <p className="big">{car.name}</p>
          <p>{formatWindow(slot.startsAt, slot.endsAt, now, tz)}</p>
          <p className="muted">{durationLabel(slot)} · visible to everyone in {group.name}</p>
        </section>
        <button onClick={confirm} disabled={create.isPending}>{create.isPending ? "Booking…" : "Confirm Booking"}</button>
        <button className="secondary" onClick={() => setReviewing(false)} disabled={create.isPending}>Change</button>
      </div>
    );
  }

  function submit(e: FormEvent) {
    e.preventDefault();
    if (slot && free && !startsInPast) setReviewing(true);
  }

  return (
    <form onSubmit={submit} className="stack">
      <h2>Book A Car</h2>

      <fieldset className="card stack">
        <legend>Car</legend>
        {activeCars.map((v) => (
          <label key={v.id} className="check">
            <input type="radio" name="car" value={v.id} checked={v.id === vehicleId}
                   onChange={() => { setVehicleId(v.id); setError(null); }} />
            {v.name}
          </label>
        ))}
      </fieldset>

      <fieldset className="card stack">
        <legend>When <span className="muted">({tz})</span></legend>
        <label>
          From
          <input type="datetime-local" required step={900} value={start} onChange={(e) => onStartChange(e.target.value)} />
        </label>
        <label>
          Until
          <input type="datetime-local" required step={900} value={end} min={start}
                 onChange={(e) => { setEnd(e.target.value); setError(null); }} />
        </label>
        {slot && <p className="muted">{formatWindow(slot.startsAt, slot.endsAt, now, tz)} · {durationLabel(slot)}</p>}
        {!slot && start && end && <p className="error">The end must be after the start.</p>}
        {startsInPast && <p className="error">That start time has already passed.</p>}
      </fieldset>

      {slot && !startsInPast && (free ? (
        <p className="chip ok" role="status"><span aria-hidden="true" className="glyph">✓</span> <strong>{car?.name} is free then</strong></p>
      ) : (
        <section className="card stack" role="status">
          <p className="warn-text">
            <span aria-hidden="true">⚠ </span>
            {clashBooking
              ? `${car?.name} is booked ${formatWindow(new Date(clashBooking.starts_at!), new Date(clashBooking.ends_at!), now, tz)} by ${nameOf(clashBooking.owner_id)}${clashBooking.status === "in_use_reported" ? " (and is out now)" : ""}.`
              : clashMaintenance
                ? `${car?.name} is in maintenance ${formatWindow(new Date(clashMaintenance.starts_at!), new Date(clashMaintenance.ends_at!), now, tz)}.`
                : `${car?.name} isn't free then.`}
          </p>
          {suggestions.length > 0 && (
            <>
              <h3>{car?.name} is free at</h3>
              <div className="row actions">
                {suggestions.map((s) => (
                  <button type="button" key={s.startsAt.toISOString()} className="secondary" onClick={() => pick(s)}>
                    {formatWindow(s.startsAt, s.endsAt, now, tz)}
                  </button>
                ))}
              </div>
            </>
          )}
          {otherFreeCars.length > 0 && (
            <>
              <h3>Free At The Time You Asked</h3>
              <div className="row actions">
                {otherFreeCars.map((v) => (
                  <button type="button" key={v.id} className="secondary" onClick={() => setVehicleId(v.id)}>
                    Use {v.name}
                  </button>
                ))}
              </div>
            </>
          )}
        </section>
      ))}

      {error && <p className="error" role="alert">{error}</p>}
      <button type="submit" disabled={!slot || !free || startsInPast}>Review Booking</button>
    </form>
  );
}
