import { addDays, dayBounds, occurrences, wallDate } from "@famly/domain";
import { useState } from "react";
import { useFamilyEvents } from "./queries";

export interface PlanTime {
  key: string;
  id: string;
  title: string;
  destination: string | null;
  startsAt: Date;
  endsAt: Date;
  createdBy: string | null;
  reservationId: string | null;
  outingId: string | null;
  people: Array<{ user_id: string; state: string }>;
}

/** Every plan time (repeating ones expanded) from now until the end of `days` days ahead, in time order. */
export function useUpcomingPlans(groupId: string, timeZone: string, days: number) {
  const [now] = useState(() => new Date());
  const today = wallDate(now, timeZone);
  const range = { startsAt: dayBounds(today, timeZone).start, endsAt: dayBounds(addDays(today, days - 1), timeZone).end };
  const events = useFamilyEvents(groupId, range.startsAt, range.endsAt);
  const plans: PlanTime[] = (events.data ?? [])
    .flatMap((e) =>
      occurrences({ startsAt: new Date(e.starts_at), endsAt: new Date(e.ends_at), repeat: e.repeat, repeatUntil: e.repeat_until }, range, timeZone)
        .map((o) => ({
          key: `${e.id}-${o.date}`, id: e.id, title: e.title, destination: e.destination, startsAt: o.startsAt, endsAt: o.endsAt,
          createdBy: e.created_by, reservationId: e.reservation_id, outingId: e.outing_id, people: e.event_participant,
        })))
    .filter((p) => p.endsAt > now)
    .sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime());
  return { plans, now, loading: events.isPending, error: events.error };
}

/** This person made the plan or is going (`orInvited`: or hasn't answered yet). */
export function isInPlan(p: PlanTime, userId: string, orInvited = false): boolean {
  if (p.createdBy === userId) return !p.people.some((x) => x.user_id === userId && x.state === "declined");
  return p.people.some((x) => x.user_id === userId && (x.state === "attending" || (orInvited && x.state === "invited")));
}
