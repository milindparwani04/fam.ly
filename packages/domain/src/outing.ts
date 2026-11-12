import type { OutingStatus } from "./status.js";

export interface OutingInfo {
  status: OutingStatus;
  plannedStart: Date;
  plannedReturn: Date;
  expectedReturnAt: Date | null;
  departureReportedAt: Date | null;
  homeReportedAt: Date | null;
  possessionUncertain?: boolean;
}

/**
 * What everyone sees about someone's outing (P07-5). All of it is self-reported; nonresponse never
 * changes stored state (FR-S04), it only shows up here as "not reported" or "overdue".
 */
export type OutingDisplay =
  | { kind: "scheduled" }
  | { kind: "not_reported" } // start has passed but nobody tapped "Left"
  | { kind: "left"; at: Date; dueBack: Date; problem: boolean }
  | { kind: "expected_back"; at: Date; expectedBack: Date; problem: boolean } // running late, gave an ETA
  | { kind: "overdue"; dueBack: Date; problem: boolean } // past plan and any ETA, not confirmed back
  | { kind: "returned"; at: Date }
  | { kind: "cancelled" };

export function outingDisplay(o: OutingInfo, now: Date): OutingDisplay {
  const problem = !!o.possessionUncertain;
  switch (o.status) {
    case "cancelled":
      return { kind: "cancelled" };
    case "returned":
      return { kind: "returned", at: o.homeReportedAt ?? now };
    case "planned":
      return o.plannedStart <= now ? { kind: "not_reported" } : { kind: "scheduled" };
    case "departed": {
      const at = o.departureReportedAt ?? o.plannedStart;
      const late = o.expectedReturnAt && o.expectedReturnAt > o.plannedReturn ? o.expectedReturnAt : null;
      const due = late ?? o.plannedReturn;
      if (due < now) return { kind: "overdue", dueBack: due, problem };
      if (late) return { kind: "expected_back", at, expectedBack: late, problem };
      return { kind: "left", at, dueBack: due, problem };
    }
  }
}

/** Which big button to offer the owner right now (P07-6), or none. */
export function nextAction(
  o: Pick<OutingInfo, "status" | "plannedStart">,
  now: Date,
  bookingEndsAt: Date | null,
): "left" | "home" | null {
  if (o.status === "departed") return "home";
  if (o.status !== "planned") return null;
  if (now.getTime() < o.plannedStart.getTime() - 60 * 60_000) return null; // matches the server's window
  if (bookingEndsAt && now >= bookingEndsAt) return "home"; // too late to "leave"; can still confirm home
  return "left";
}
