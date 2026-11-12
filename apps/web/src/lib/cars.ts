import {
  dueBack,
  formatTime,
  wallDate,
  formatMoment,
  handoverRisk,
  errorMessage,
  formatWindow,
  nextBooking,
  vehicleState,
  type Interval,
  type MaintenanceWindow,
  type OutingInfo,
  type OutingStatus,
  type ReservationStatus,
  type VehicleBooking,
  type VehicleState,
} from "@famly/domain";
import type { useCarActivity } from "./queries";
import { AppError } from "./rpc";

export type Activity = NonNullable<ReturnType<typeof useCarActivity>["data"]>;
export type OutingRow = Activity["outings"][number];

/** A booking row plus its outing's self-reported ETA, as the domain sees it. */
export function toBooking(b: Activity["bookings"][number], activity: Activity): VehicleBooking {
  const outing = activity.outings.find((o) => o.reservation_id === b.id);
  return {
    id: b.id,
    ownerId: b.owner_id,
    status: b.status as ReservationStatus,
    startsAt: new Date(b.starts_at!),
    endsAt: new Date(b.ends_at!),
    expectedReturnAt: outing?.expected_return_at ? new Date(outing.expected_return_at) : null,
    possessionUncertain: b.possession_uncertain,
    vehicleReturnedAt: b.vehicle_returned_at ? new Date(b.vehicle_returned_at) : null,
  };
}

export function toOutingInfo(o: OutingRow, possessionUncertain = false): OutingInfo {
  return {
    status: o.status as OutingStatus,
    plannedStart: new Date(o.planned_start),
    plannedReturn: new Date(o.planned_return),
    expectedReturnAt: o.expected_return_at ? new Date(o.expected_return_at) : null,
    departureReportedAt: o.departure_reported_at ? new Date(o.departure_reported_at) : null,
    homeReportedAt: o.home_reported_at ? new Date(o.home_reported_at) : null,
    possessionUncertain,
  };
}

export interface CarView {
  state: VehicleState;
  next: VehicleBooking | null;
  bookings: VehicleBooking[];
  maintenance: MaintenanceWindow[];
  flaggedCount: number;
}

/** Joins one car's rows into domain types and derives its current state. */
export function carView(vehicle: { id: string; active: boolean }, activity: Activity, now: Date): CarView {
  const rows = activity.bookings.filter((b) => b.vehicle_id === vehicle.id);
  const bookings = rows.map((b) => toBooking(b, activity));
  const maintenance: MaintenanceWindow[] = activity.maintenance
    .filter((m) => m.vehicle_id === vehicle.id)
    .map((m) => ({ id: m.id, startsAt: new Date(m.starts_at!), endsAt: new Date(m.ends_at!), reason: m.reason }));
  return {
    state: vehicleState(vehicle, bookings, maintenance, now),
    next: nextBooking(bookings, now),
    bookings,
    maintenance,
    flaggedCount: rows.filter((b) => b.needs_reconciliation).length,
  };
}

/**
 * When a car can't be booked. A car reported out (even overdue) is busy until at least now:
 * it isn't physically back yet. `exceptBookingId` lets an edit ignore its own booking.
 */
export function busyFor(vehicleId: string, activity: Activity, now: Date, exceptBookingId?: string): Interval[] {
  const bookings = activity.bookings
    .filter((b) => b.vehicle_id === vehicleId && b.id !== exceptBookingId && b.status !== "completed")
    .map((b) => {
      const booking = toBooking(b, activity);
      if (b.status !== "in_use_reported") return booking;
      // Out with someone: busy until they're due back (booked end or later ETA), and at least until now.
      const due = dueBack(booking);
      return { startsAt: booking.startsAt, endsAt: due < now ? now : due };
    });
  const maintenance = activity.maintenance
    .filter((m) => m.vehicle_id === vehicleId)
    .map((m) => ({ startsAt: new Date(m.starts_at!), endsAt: new Date(m.ends_at!) }));
  return [...bookings, ...maintenance];
}

/** Error copy that names the car, the person and the time (P05-6, journey 2). */
export function describeBookingError(
  err: unknown,
  ctx: { carName: string; nameOf: (id: string) => string; now: Date; timeZone: string },
): string {
  if (!(err instanceof AppError)) return errorMessage("unknown");
  const c = err.rpc.conflict;
  if (err.rpc.code === "reservation_conflict" && c) {
    const when = formatWindow(new Date(c.starts_at), new Date(c.ends_at), ctx.now, ctx.timeZone);
    const who = c.owner_id ? ` by ${ctx.nameOf(c.owner_id)}` : "";
    return `${ctx.carName} is already booked ${when}${who}.`;
  }
  if (err.rpc.code === "vehicle_unavailable" && c) {
    const when = formatWindow(new Date(c.starts_at), new Date(c.ends_at), ctx.now, ctx.timeZone);
    return `${ctx.carName} is in maintenance ${when}.`;
  }
  return err.message;
}

export function newIdempotencyKey(): string {
  return crypto.randomUUID();
}

/**
 * Next-booker warning text (FR-S08): the previous driver still has the car in a way that threatens
 * this booking's start. Null when there's nothing to say.
 */
export function handoverWarning(
  bookingId: string,
  activity: Activity,
  ctx: { carName: string; nameOf: (id: string) => string; timeZone: string },
  now: Date,
): string | null {
  const row = activity.bookings.find((x) => x.id === bookingId);
  if (!row || row.status !== "reserved") return null;
  const carBookings = activity.bookings.filter((x) => x.vehicle_id === row.vehicle_id).map((x) => toBooking(x, activity));
  const risk = handoverRisk(toBooking(row, activity), carBookings, now);
  if (risk.kind === "none") return null;
  const who = ctx.nameOf(risk.previous.ownerId);
  const at = (d: Date) => formatMoment(d, now, ctx.timeZone);
  switch (risk.kind) {
    case "late":
      return `${who} still has ${ctx.carName} and expects to be back ${at(risk.dueBack)}, after this booking starts.`;
    case "overdue":
      return `${who} hasn't confirmed ${ctx.carName} is back (was due ${at(dueBack(risk.previous))}).`;
    case "problem":
      return `${who} reported a problem with ${ctx.carName}. It may not be back in time.`;
  }
}

/** Seats and class shown under the car name. The app stores only a name, so the model is recognised from it. */
export function carDetails(name: string): string | null {
  const n = name.toLowerCase();
  if (n.includes("sorento")) return "7 seats · Family SUV";
  if (/\bgx\s?\d*\b/.test(n)) return "7 seats · Luxury SUV";
  return null;
}

export type CarTileState = { cls: "free" | "out" | "mine" | "off"; label: string; line: string; mineBookingId?: string };

/** One word-labelled state per car, shared by Today and the Cars tab. */
export function carState(
  v: { id: string; active: boolean },
  activity: Activity,
  uid: string,
  firstName: (id: string) => string,
  now: Date,
  tz: string,
): CarTileState & { next: VehicleBooking | null; count: number } {
  const view = carView(v, activity, now);
  const at = (d: Date) => (wallDate(d, tz) === wallDate(now, tz) ? formatTime(d, tz) : formatMoment(d, now, tz));
  const s = view.state;
  const count = view.bookings.filter((b) => b.status !== "completed").length;
  const base = { next: view.next, count };
  switch (s.kind) {
    case "available": {
      const nx = view.next;
      return { ...base, cls: "free", label: "Available", line: nx && wallDate(nx.startsAt, tz) === wallDate(now, tz) ? `Free until ${formatTime(nx.startsAt, tz)}` : "Free right now" };
    }
    case "booked":
    case "out":
    case "overdue": {
      const b = s.booking;
      const mine = b.ownerId === uid;
      const back = s.kind === "booked" ? b.endsAt : (b.expectedReturnAt && b.expectedReturnAt > b.endsAt ? b.expectedReturnAt : b.endsAt);
      const line = s.kind === "overdue" ? `Was due ${at(back)} · not confirmed back`
        : s.kind === "booked" ? `Booked until ${at(back)} · not left yet`
        : `Back around ${at(back)}${b.possessionUncertain ? " · problem reported" : ""}`;
      if (mine) return { ...base, cls: "mine", label: s.kind === "booked" ? "Yours · Booked" : "Yours Now", line, mineBookingId: b.id };
      const who = firstName(b.ownerId);
      return { ...base, cls: "out", label: s.kind === "overdue" ? `Overdue · ${who}` : s.kind === "booked" ? `Booked · ${who}` : `Out · ${who}`, line };
    }
    case "maintenance":
      return { ...base, cls: "off", label: "Maintenance", line: `Until ${at(s.window.endsAt)}${s.window.reason ? ` · ${s.window.reason}` : ""}` };
    case "inactive":
      return { ...base, cls: "off", label: "Inactive", line: "Not in use" };
  }
}
