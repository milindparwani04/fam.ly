// Mirrors the Postgres enums in supabase/migrations/*_reservations.sql. Keep in sync.
export const RESERVATION_STATUSES = ["reserved", "in_use_reported", "completed", "cancelled"] as const;
export type ReservationStatus = (typeof RESERVATION_STATUSES)[number];

export const OUTING_STATUSES = ["planned", "departed", "returned", "cancelled"] as const;
export type OutingStatus = (typeof OUTING_STATUSES)[number];

/** Statuses that occupy the car (the exclusion constraint's WHERE clause). */
export const OCCUPYING_STATUSES: readonly ReservationStatus[] = ["reserved", "in_use_reported"];

export type DisplayStatus =
  | "scheduled"
  | "reported_left"
  | "overdue_unconfirmed"
  | "reported_returned"
  | "cancelled";

/**
 * Derived display status (R3, FR-S04). Nonresponse never changes stored state:
 * "overdue" is computed from the schedule and the absence of a return report.
 */
export function displayStatus(
  r: { status: ReservationStatus; endsAt: Date; vehicleReturnedAt: Date | null },
  now: Date,
): DisplayStatus {
  switch (r.status) {
    case "cancelled":
      return "cancelled";
    case "completed":
      return "reported_returned";
    case "in_use_reported":
      return r.vehicleReturnedAt === null && r.endsAt < now ? "overdue_unconfirmed" : "reported_left";
    case "reserved":
      return r.vehicleReturnedAt === null && r.endsAt < now ? "overdue_unconfirmed" : "scheduled";
  }
}
