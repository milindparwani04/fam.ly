import { utcToWallTime } from "./time.js";

/** The Plans categories (Beige + Sage board): menus are Meals, tasks are Requests, family events are Events. */
export type PlanKind = "meal" | "request" | "event";
export type PlanFilter = PlanKind | "all";

export interface PlanEntry<T> {
  kind: PlanKind;
  /** Wall date (YYYY-MM-DD) in the family's time zone. */
  day: string;
  /** Wall time (HH:MM) the entry starts, or null for "Anytime" (menus, tasks, events running on from yesterday). */
  time: string | null;
  item: T;
}

export interface PlanDay<T> {
  day: string;
  entries: PlanEntry<T>[];
}

/**
 * Entries filtered by category and bucketed by day, earliest first. Within a day timed entries come
 * first in time order and "Anytime" ones last, keeping their input order (the board shows dinner at
 * 19:30 above an anytime request).
 */
export function groupPlans<T>(entries: readonly PlanEntry<T>[], filter: PlanFilter): PlanDay<T>[] {
  const kept = entries
    .map((e, i) => ({ e, i }))
    .filter(({ e }) => filter === "all" || e.kind === filter)
    .sort((a, b) => {
      if (a.e.day !== b.e.day) return a.e.day < b.e.day ? -1 : 1;
      if (a.e.time !== b.e.time) {
        if (a.e.time === null) return 1;
        if (b.e.time === null) return -1;
        return a.e.time < b.e.time ? -1 : 1;
      }
      return a.i - b.i;
    });
  const days: PlanDay<T>[] = [];
  for (const { e } of kept) {
    const last = days[days.length - 1];
    if (last && last.day === e.day) last.entries.push(e);
    else days.push({ day: e.day, entries: [e] });
  }
  return days;
}

/** "Good Morning" / "Good Afternoon" / "Good Evening" for the wall-clock hour in the family's time zone. */
export function greeting(now: Date, timeZone: string): string {
  const hour = Number(utcToWallTime(now, timeZone).slice(11, 13));
  if (hour >= 5 && hour < 12) return "Good Morning";
  if (hour >= 12 && hour < 18) return "Good Afternoon";
  return "Good Evening";
}

/** Compact age for feed rows: "Just now", "5m ago", "2h ago", "Yesterday", else "3d ago". Calendar-agnostic on purpose. */
export function timeAgo(then: Date, now: Date): string {
  const minutes = Math.floor((now.getTime() - then.getTime()) / 60_000);
  if (minutes < 1) return "Just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return days === 1 ? "Yesterday" : `${days}d ago`;
}
