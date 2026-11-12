import type { ReservationStatus } from "./status.js";

export interface VehicleBooking {
  id: string;
  ownerId: string;
  status: ReservationStatus;
  startsAt: Date;
  endsAt: Date;
  /** Self-reported forecast (FR-S08); never changes the booking itself. */
  expectedReturnAt?: Date | null;
  /** Owner reported a problem (car return uncertain). */
  possessionUncertain?: boolean;
  vehicleReturnedAt?: Date | null;
}

export interface MaintenanceWindow {
  id: string;
  startsAt: Date;
  endsAt: Date;
  reason: string | null;
}

/**
 * What a car is doing right now, derived from bookings and maintenance (R3, FR-S04, FR-S10).
 * "Out" and "overdue" come from self-reports; nonresponse never changes stored state.
 * Priority: inactive > physically away (out/overdue) > maintenance > booked > available.
 */
export type VehicleState =
  | { kind: "inactive" }
  | { kind: "overdue"; booking: VehicleBooking }
  | { kind: "out"; booking: VehicleBooking }
  | { kind: "maintenance"; window: MaintenanceWindow }
  | { kind: "booked"; booking: VehicleBooking }
  | { kind: "available"; lastReturn: VehicleBooking | null };

export function vehicleState(
  vehicle: { active: boolean },
  bookings: readonly VehicleBooking[],
  maintenance: readonly MaintenanceWindow[],
  now: Date,
): VehicleState {
  if (!vehicle.active) return { kind: "inactive" };

  // A car reported out stays out until someone reports it back, however late.
  const out = bookings.find((b) => b.status === "in_use_reported");
  // Overdue only once both the booked end and any later ETA the driver gave have passed.
  if (out) return dueBack(out) < now ? { kind: "overdue", booking: out } : { kind: "out", booking: out };

  const window = maintenance.find((m) => m.startsAt <= now && now < m.endsAt);
  if (window) return { kind: "maintenance", window };

  const booked = bookings.find((b) => b.status === "reserved" && b.startsAt <= now && now < b.endsAt);
  if (booked) return { kind: "booked", booking: booked };

  // "Confirmed back" (a self-report) is shown distinctly from merely "free on the schedule" (R3).
  const lastReturn =
    bookings
      .filter((b) => b.status === "completed" && b.vehicleReturnedAt)
      .sort((a, b) => b.vehicleReturnedAt!.getTime() - a.vehicleReturnedAt!.getTime())[0] ?? null;
  return { kind: "available", lastReturn };
}

/** Next live booking that hasn't ended yet, if any. */
export function nextBooking(bookings: readonly VehicleBooking[], now: Date): VehicleBooking | null {
  return (
    bookings
      .filter((b) => b.status === "reserved" && b.endsAt > now)
      .sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime())[0] ?? null
  );
}

function dayKey(d: Date, timeZone: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}

function dayLabel(d: Date, now: Date, timeZone: string): string {
  const key = dayKey(d, timeZone);
  if (key === dayKey(now, timeZone)) return "Today";
  if (key === dayKey(new Date(now.getTime() + 86_400_000), timeZone)) return "Tomorrow";
  if (key === dayKey(new Date(now.getTime() - 86_400_000), timeZone)) return "Yesterday";
  return new Intl.DateTimeFormat("en-GB", { timeZone, weekday: "short", day: "numeric", month: "short" }).format(d);
}

function time(d: Date, timeZone: string): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(d);
}

/**
 * Human window like "Today 14:00–16:00" or "Fri 18 Oct 23:00 – Sat 19 Oct 01:00".
 * Cross-midnight windows always name both days.
 */
export function formatWindow(start: Date, end: Date, now: Date, timeZone: string): string {
  const startDay = dayLabel(start, now, timeZone);
  if (dayKey(start, timeZone) === dayKey(end, timeZone)) {
    return `${startDay} ${time(start, timeZone)}–${time(end, timeZone)}`;
  }
  return `${startDay} ${time(start, timeZone)} – ${dayLabel(end, now, timeZone)} ${time(end, timeZone)}`;
}

/** A single moment like "Today 16:00" or "Fri 7 May 10:00". */
export function formatMoment(d: Date, now: Date, timeZone: string): string {
  return `${dayLabel(d, now, timeZone)} ${time(d, timeZone)}`;
}

/** "HH:mm" in the given zone. */
export function formatTime(d: Date, timeZone: string): string {
  return time(d, timeZone);
}

/** When the car is due back: the booked end, or a later ETA the driver reported. */
export function dueBack(b: Pick<VehicleBooking, "endsAt" | "expectedReturnAt">): Date {
  return b.expectedReturnAt && b.expectedReturnAt > b.endsAt ? b.expectedReturnAt : b.endsAt;
}

export type HandoverRisk =
  | { kind: "none" }
  | { kind: "late"; previous: VehicleBooking; dueBack: Date }
  | { kind: "overdue"; previous: VehicleBooking }
  | { kind: "problem"; previous: VehicleBooking };

/**
 * For the next booker (FR-S08, FR-S10): is the car still out with whoever had it before, in a way
 * that threatens my start? Never resolved by moving anyone's booking, only surfaced.
 */
export function handoverRisk(mine: VehicleBooking, carBookings: readonly VehicleBooking[], now: Date): HandoverRisk {
  const previous = carBookings.find(
    (b) => b.id !== mine.id && b.status === "in_use_reported" && b.endsAt <= mine.startsAt,
  );
  if (!previous || mine.endsAt <= now) return { kind: "none" };
  if (previous.possessionUncertain) return { kind: "problem", previous };
  const due = dueBack(previous);
  if (due < now) return { kind: "overdue", previous };
  if (due > mine.startsAt) return { kind: "late", previous, dueBack: due };
  return { kind: "none" };
}
