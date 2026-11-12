import {
  addDays,
  dueBack,
  formatTime,
  formatWindow,
  isFree,
  overlaps,
  QUARTER_HOUR,
  roundUpTo,
  utcToWallTime,
  wallDate,
  wallTimeToUtc,
  type Interval,
} from "@famly/domain";
import { useEffect, useMemo, useState, type FormEvent } from "react";
import { Link, useNavigate } from "react-router";
import { useUserId } from "../lib/auth";
import { busyFor, carView, describeBookingError, newIdempotencyKey } from "../lib/cars";
import { bookingKeys, useAction, useCarActivity, useMembers, useVehicles } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";
import { Sheet, useUI } from "../lib/ui";
import { Avatar } from "./Avatar";

const FIVE_MIN = 5 * 60_000;

interface Preset {
  id: "now" | "tonight" | "tomorrow";
  label: string;
  window: Interval | null;
}

/** Quick times (Stickers board): now for two hours, tonight 18:00–21:00, tomorrow morning 09:00–13:00. */
function presetsFor(now: Date, tz: string): Preset[] {
  const today = wallDate(now, tz);
  const start = roundUpTo(now, FIVE_MIN);
  const tonight = { startsAt: wallTimeToUtc(`${today}T18:00`, tz), endsAt: wallTimeToUtc(`${today}T21:00`, tz) };
  const tomorrow = addDays(today, 1);
  return [
    { id: "now", label: "Now", window: { startsAt: start, endsAt: roundUpTo(new Date(start.getTime() + 2 * 3_600_000), QUARTER_HOUR) } },
    { id: "tonight", label: "Tonight", window: tonight.startsAt.getTime() > now.getTime() - FIVE_MIN ? tonight : null },
    { id: "tomorrow", label: "Tomorrow", window: { startsAt: wallTimeToUtc(`${tomorrow}T09:00`, tz), endsAt: wallTimeToUtc(`${tomorrow}T13:00`, tz) } },
  ];
}

/** Custom day + from/until (founder, 2026-11-07). An end at or before the start runs into the next day. */
function customWindow(day: string, from: string, until: string, tz: string): Interval | null {
  if (!day || !from || !until) return null;
  try {
    const startsAt = wallTimeToUtc(`${day}T${from}`, tz);
    const endsAt = wallTimeToUtc(`${until <= from ? addDays(day, 1) : day}T${until}`, tz);
    return endsAt > startsAt ? { startsAt, endsAt } : null;
  } catch {
    return null;
  }
}

export function BookSheet({ groupId, timeZone: tz, vehicleId }: { groupId: string; timeZone: string; vehicleId?: string | undefined }) {
  const ui = useUI();
  const vehicles = useVehicles(groupId);
  const activity = useCarActivity(groupId);
  const members = useMembers(groupId);
  const [now] = useState(() => new Date());
  const active = useMemo(() => vehicles.data?.filter((v) => v.active) ?? [], [vehicles.data]);
  const [carId, setCarId] = useState(vehicleId ?? "");
  useEffect(() => {
    if (!carId && active[0]) setCarId(active[0].id);
  }, [active, carId]);
  const car = active.find((v) => v.id === carId);

  const presets = useMemo(() => presetsFor(now, tz), [now, tz]);
  const firstStart = roundUpTo(now, QUARTER_HOUR);
  const [choice, setChoice] = useState<Preset["id"] | "custom" | null>(null);
  const [day, setDay] = useState(() => wallDate(firstStart, tz));
  const [from, setFrom] = useState(() => utcToWallTime(firstStart, tz).slice(11, 16));
  const [until, setUntil] = useState(() => utcToWallTime(new Date(firstStart.getTime() + 3_600_000), tz).slice(11, 16));
  const [error, setError] = useState<string | null>(null);
  const [idemKey, setIdemKey] = useState(newIdempotencyKey);

  const busy = car && activity.data ? busyFor(car.id, activity.data, now) : [];
  const freeAt = (w: Interval | null) => !!w && isFree(busy, w);
  // Start on the first quick time that's free for this car.
  const picked = choice ?? presets.find((p) => freeAt(p.window))?.id ?? "custom";
  const slot = picked === "custom" ? customWindow(day, from, until, tz) : presets.find((p) => p.id === picked)?.window ?? null;
  const inPast = !!slot && slot.startsAt.getTime() < now.getTime() - FIVE_MIN;
  const free = freeAt(slot) && !inPast;
  useEffect(() => setIdemKey(newIdempotencyKey()), [carId, slot?.startsAt.getTime(), slot?.endsAt.getTime()]);

  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const nameOf = (id: string) => names.get(id) ?? "a former member";
  const clash = slot && car && activity.data
    ? activity.data.bookings.find((b) => b.vehicle_id === car.id && b.status !== "completed"
        && overlaps({ startsAt: new Date(b.starts_at!), endsAt: new Date(b.ends_at!) }, slot))
    : undefined;

  const create = useAction(
    async () =>
      unwrap(await supabase.rpc("rpc_create_reservation", {
        p_vehicle_id: carId,
        p_starts_at: slot!.startsAt.toISOString(),
        p_ends_at: slot!.endsAt.toISOString(),
        p_idempotency_key: idemKey,
      })),
    bookingKeys(groupId),
  );

  function confirm() {
    if (!slot || !car || !free) return;
    setError(null);
    create.mutate(undefined, {
      onSuccess: () => {
        ui.close();
        ui.toast(`Booked ${car.name} · ${formatWindow(slot.startsAt, slot.endsAt, new Date(), tz)}`);
      },
      onError: (err) => setError(describeBookingError(err, { carName: car.name, nameOf, now: new Date(), timeZone: tz })),
    });
  }

  let status: string | null = null;
  if (picked === "custom") {
    if (!slot) status = "Choose a day and times.";
    else if (inPast) status = "That start time has already passed.";
    else if (!free) {
      status = clash
        ? `${car?.name} is booked ${formatWindow(new Date(clash.starts_at!), new Date(clash.ends_at!), now, tz)} by ${nameOf(clash.owner_id)}.`
        : `${car?.name} isn't free then.`;
    } else status = `${formatWindow(slot.startsAt, slot.endsAt, now, tz)} · free`;
  }

  return (
    <Sheet label="Book A Car" onClose={ui.close}>
      <h2>Book A Car</h2>
      {active.length === 0 ? (
        <p>Add a car first, on the Cars tab.</p>
      ) : (
        <>
          <div className="choices" role="group" aria-label="Car">
            {active.map((v) => (
              <button key={v.id} type="button" className="choice" aria-pressed={v.id === carId}
                      onClick={() => { setCarId(v.id); setChoice(null); setError(null); }}>
                {v.name}
              </button>
            ))}
          </div>
          <div className="choices three" role="group" aria-label="When">
            {presets.map((p) => {
              const ok = freeAt(p.window);
              return (
                <button key={p.id} type="button" className="choice tall"
                        aria-pressed={picked === p.id} disabled={!ok} onClick={() => { setChoice(p.id); setError(null); }}>
                  <span className="big-l">{p.label}</span>
                  <span className="note">
                    {!p.window ? "Passed" : !ok ? "Taken"
                      : p.id === "now" ? `until ${formatTime(p.window.endsAt, tz)}`
                      : `${formatTime(p.window.startsAt, tz)} – ${formatTime(p.window.endsAt, tz)}`}
                  </span>
                </button>
              );
            })}
          </div>
          <p className="label sub-label">Or Pick A Time</p>
          <div className="time-grid" onFocus={() => setChoice("custom")}>
            <label>Day<input type="date" value={day} min={wallDate(now, tz)} onChange={(e) => { setDay(e.target.value); setChoice("custom"); }} /></label>
            <label>From<input type="time" step={900} value={from} onChange={(e) => { setFrom(e.target.value); setChoice("custom"); }} /></label>
            <label>Until<input type="time" step={900} value={until} onChange={(e) => { setUntil(e.target.value); setChoice("custom"); }} /></label>
          </div>
          {status && <p className={free ? "muted" : "error"} role="status">{status}</p>}
          {error && <p className="error" role="alert">{error}</p>}
          <button className="confirm-btn press" disabled={!free || create.isPending} onClick={confirm}>
            {create.isPending ? "Booking…" : "Confirm Booking"}
          </button>
        </>
      )}
    </Sheet>
  );
}

/** One car's live and upcoming bookings and maintenance, newest plans last. */
export function ScheduleSheet({ groupId, timeZone: tz, vehicleId }: { groupId: string; timeZone: string; vehicleId: string }) {
  const ui = useUI();
  const uid = useUserId();
  const navigate = useNavigate();
  const vehicles = useVehicles(groupId);
  const activity = useCarActivity(groupId);
  const members = useMembers(groupId);
  const car = vehicles.data?.find((v) => v.id === vehicleId);
  if (!car || !activity.data) return null;
  const now = new Date();
  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const view = carView(car, activity.data, now);
  const rows = [
    ...view.bookings.filter((b) => b.status !== "completed").map((b) => ({
      key: b.id,
      start: b.startsAt,
      to: `/bookings/${b.id}`,
      who: names.get(b.ownerId) ?? "Former member",
      label: b.ownerId === uid ? "You" : (names.get(b.ownerId) ?? "Former member"),
      text: formatWindow(b.startsAt, b.endsAt, now, tz)
        + (b.status === "in_use_reported" ? (dueBack(b) < now ? " · overdue" : ` · out now, back ${formatTime(dueBack(b), tz)}`) : ""),
    })),
    ...view.maintenance.map((m) => ({
      key: m.id, start: m.startsAt, to: `/cars/${car.id}`, who: "", label: "Maintenance",
      text: formatWindow(m.startsAt, m.endsAt, now, tz) + (m.reason ? ` · ${m.reason}` : ""),
    })),
  ].sort((a, b) => a.start.getTime() - b.start.getTime());

  return (
    <Sheet label={`${car.name} Schedule`} onClose={ui.close}>
      <div className="sheet-head">
        <h2>{car.name} Schedule</h2>
        <button className="sheet-link" onClick={() => navigate("/calendar")}>Calendar</button>
      </div>
      <div className="sched-list">
        {rows.length === 0 && <p className="sched-empty">No upcoming bookings.</p>}
        {rows.map((r) => (
          <Link key={r.key} to={r.to} className="sched-row">
            {r.who ? <Avatar name={r.who} size="md" /> : <span className="avatar md" style={{ background: "var(--off)" }} aria-hidden="true">—</span>}
            <span className="text"><span className="who">{r.label}</span><span className="when">{r.text}</span></span>
          </Link>
        ))}
      </div>
      <button className="press" style={{ height: 50 }} onClick={() => ui.open({ kind: "book", vehicleId: car.id })}>Book {car.name}</button>
    </Sheet>
  );
}

export function AddCarSheet({ groupId }: { groupId: string }) {
  const ui = useUI();
  const [name, setName] = useState("");
  const add = useAction(
    async () => unwrap(await supabase.rpc("rpc_upsert_vehicle", { p_group_id: groupId, p_name: name })),
    [["vehicles", groupId]],
  );
  function submit(e: FormEvent) {
    e.preventDefault();
    add.mutate(undefined, {
      onSuccess: () => {
        ui.close();
        ui.toast(`Added ${name.trim()}`);
      },
    });
  }
  return (
    <Sheet label="Add A Car" onClose={ui.close}>
      <h2>Add A Car</h2>
      <form onSubmit={submit} className="stack">
        <label>
          Name
          <input required maxLength={60} placeholder="e.g. White Corolla" value={name} autoFocus onChange={(e) => setName(e.target.value)} />
        </label>
        <p className="muted">A name is enough, no plate needed.</p>
        {add.error && <p className="error" role="alert">{messageOf(add.error)}</p>}
        <button type="submit" className="confirm-btn press" disabled={add.isPending || !name.trim()}>Add Car</button>
      </form>
    </Sheet>
  );
}
