import { activeShift, dueBack, nextAction, type Interval } from "@famly/domain";
import { useQuery } from "@tanstack/react-query";
import type { ComponentType } from "react";
import { BagIcon, CarIcon, DumbbellIcon, RacketIcon } from "../components/Icons";
import { toBooking, type Activity as CarActivity, type OutingRow } from "./cars";
import { unwrap } from "./rpc";
import { supabase } from "./supabase";

/** What "I'm Leaving" is for (founder, 2026-11-07). */
export type Activity = "drive" | "gym" | "padel" | "errand";
export const ACTIVITIES: Array<{ id: Activity; label: string; Icon: ComponentType<{ className?: string }> }> = [
  { id: "drive", label: "Drive", Icon: CarIcon },
  { id: "gym", label: "Gym", Icon: DumbbellIcon },
  { id: "padel", label: "Padel", Icon: RacketIcon },
  { id: "errand", label: "Errand", Icon: BagIcon },
];
export const activityLabel = (a: string | null | undefined) => ACTIVITIES.find((x) => x.id === a)?.label ?? null;

/** Everyone's I'm Leaving / I'm Home state in one family. Refreshed by the feed's realtime channel. */
export function usePresence(groupId: string) {
  return useQuery({
    queryKey: ["presence", groupId],
    enabled: !!groupId,
    refetchInterval: 60_000,
    queryFn: async () =>
      unwrap(
        await supabase
          .from("member_presence")
          .select("user_id, state, activity, has_house_key, changed_at, plan_id, plan_title, place")
          .eq("group_id", groupId),
      ),
  });
}

/** Work hours for these people (whoever shares a family with you). */
export function useWorkHours(userIds: string[]) {
  const ids = [...userIds].sort();
  return useQuery({
    queryKey: ["work-hours", ids.join(",")],
    enabled: ids.length > 0,
    queryFn: async () =>
      unwrap(await supabase.from("member_work").select("user_id, days, starts, ends").in("user_id", ids)),
  });
}

export type Presence = NonNullable<ReturnType<typeof usePresence>["data"]>[number];
export type WorkRow = NonNullable<ReturnType<typeof useWorkHours>["data"]>[number];

export type MemberStatus =
  | { kind: "car"; outing: OutingRow; carName: string | null; dueBack: Date; overdue: boolean }
  | { kind: "out"; activity: Activity | null; plan: { id: string | null; title: string; place: string | null } | null; since: Date; hasKey: boolean }
  | { kind: "work"; shift: Interval }
  | { kind: "home" };

/**
 * Where someone is, from what they've said (never tracked): out on a trip they reported leaving for,
 * out after I'm Leaving, at work during their hours (unless they've said they're home since it began),
 * otherwise home.
 */
export function memberStatus(args: {
  userId: string;
  activity: CarActivity | undefined;
  vehicles: Array<{ id: string; name: string }>;
  presence: Presence | undefined;
  work: WorkRow | undefined;
  now: Date;
  timeZone: string;
}): MemberStatus {
  const { userId, activity, now } = args;
  const outing = activity?.outings.find((o) => o.owner_id === userId && o.status === "departed");
  if (outing && activity) {
    const row = outing.reservation_id ? activity.bookings.find((b) => b.id === outing.reservation_id) : undefined;
    const carName = row ? (args.vehicles.find((v) => v.id === row.vehicle_id)?.name ?? "Car") : null;
    const due = row
      ? dueBack(toBooking(row, activity))
      : new Date(outing.expected_return_at ?? outing.planned_return);
    return { kind: "car", outing, carName, dueBack: due, overdue: due < now };
  }
  const p = args.presence;
  if (p?.state === "out" && (p.activity || p.plan_title)) {
    return {
      kind: "out", activity: (p.activity as Activity | null) ?? null,
      plan: p.plan_title ? { id: p.plan_id, title: p.plan_title, place: p.place } : null,
      since: new Date(p.changed_at), hasKey: !!p.has_house_key,
    };
  }
  const shift = args.work?.starts && args.work.ends
    ? activeShift({ days: args.work.days, starts: args.work.starts, ends: args.work.ends }, now, args.timeZone)
    : null;
  if (shift) {
    const homeTimes = [
      p?.state === "home" ? new Date(p.changed_at).getTime() : 0,
      ...(activity?.outings ?? [])
        .filter((o) => o.owner_id === userId && o.home_reported_at)
        .map((o) => new Date(o.home_reported_at!).getTime()),
    ];
    if (Math.max(...homeTimes) < shift.startsAt.getTime()) return { kind: "work", shift };
  }
  return { kind: "home" };
}

/** The signed-in person's booked trip they can say they're leaving on right now, if any. */
export function leavableOuting(activity: CarActivity | undefined, uid: string, now: Date): OutingRow | null {
  if (!activity) return null;
  return activity.outings.find((o) => {
    if (o.owner_id !== uid || o.status !== "planned") return false;
    const b = o.reservation_id ? activity.bookings.find((x) => x.id === o.reservation_id) : undefined;
    if (o.reservation_id && !b) return false;
    return nextAction({ status: "planned", plannedStart: new Date(o.planned_start) }, now, b ? new Date(b.ends_at!) : null) === "left";
  }) ?? null;
}

export function carNameFor(o: OutingRow, activity: CarActivity, vehicles: Array<{ id: string; name: string }>): string | null {
  const b = o.reservation_id ? activity.bookings.find((x) => x.id === o.reservation_id) : undefined;
  return b ? (vehicles.find((v) => v.id === b.vehicle_id)?.name ?? "Car") : null;
}

/** What Today shows for someone who's out: the activity, or for a plan its "where" (else just "Out"). */
export function outLabel(s: Extract<MemberStatus, { kind: "out" }>): string {
  return s.plan ? (s.plan.place ?? "Out") : (activityLabel(s.activity) ?? "Out");
}
