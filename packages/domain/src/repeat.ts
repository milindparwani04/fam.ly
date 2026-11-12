import { addDays, utcToWallTime, wallTimeToUtc, type Interval } from "./time.js";
import { isoWeekday } from "./work.js";

export type Repeat = "daily" | "weekly" | "fortnightly" | "monthly";
export const REPEATS: readonly Repeat[] = ["daily", "weekly", "fortnightly", "monthly"];

export interface Repeatable extends Interval {
  repeat?: string | null;
  repeatUntil?: string | null; // "YYYY-MM-DD", inclusive
}

export interface Occurrence<T> extends Interval {
  item: T;
  /** Wall date (family zone) this occurrence starts on; unique per item. */
  date: string;
}

const STEP_DAYS: Record<Exclude<Repeat, "monthly">, number> = { daily: 1, weekly: 7, fortnightly: 14 };

function dayDiff(a: string, b: string): number {
  return Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);
}

/** The n-th month after `date` on the same day of the month, or null when that month is too short. */
function addMonths(date: string, n: number): string | null {
  const [y, m, d] = date.split("-").map(Number) as [number, number, number];
  const t = new Date(Date.UTC(y, m - 1 + n, d));
  return t.getUTCDate() === d ? t.toISOString().slice(0, 10) : null;
}

/**
 * Every time a plan happens that overlaps `range`. A repeating plan keeps its wall-clock start time in the
 * family's zone (07:00 stays 07:00 across a DST change) and its length. Monthly plans on the 31st skip
 * shorter months. One-off plans give one occurrence if they overlap.
 */
export function occurrences<T extends Repeatable>(item: T, range: Interval, timeZone: string, max = 400): Occurrence<T>[] {
  const firstWall = utcToWallTime(item.startsAt, timeZone);
  const firstDate = firstWall.slice(0, 10);
  const time = firstWall.slice(11, 16);
  const length = item.endsAt.getTime() - item.startsAt.getTime();
  const repeat = REPEATS.includes(item.repeat as Repeat) ? (item.repeat as Repeat) : null;
  const out: Occurrence<T>[] = [];
  const push = (date: string, startsAt: Date) => {
    const endsAt = new Date(startsAt.getTime() + length);
    if (endsAt > range.startsAt && startsAt < range.endsAt) out.push({ item, date, startsAt, endsAt });
  };

  if (!repeat) {
    push(firstDate, item.startsAt);
    return out;
  }

  // Skip straight to just before the range rather than walking from the first time.
  const rangeDate = utcToWallTime(range.startsAt, timeZone).slice(0, 10);
  const behind = Math.max(0, dayDiff(firstDate, rangeDate) - 31);
  let n = repeat === "monthly" ? Math.floor(behind / 31) : Math.floor(behind / STEP_DAYS[repeat]);
  for (let guard = 0; guard < max + 62; guard++, n++) {
    const date = repeat === "monthly" ? addMonths(firstDate, n) : addDays(firstDate, n * STEP_DAYS[repeat]);
    if (date === null) continue;
    if (item.repeatUntil && date > item.repeatUntil) break;
    const startsAt = wallTimeToUtc(`${date}T${time}`, timeZone);
    if (startsAt >= range.endsAt) break;
    push(date, startsAt);
    if (out.length >= max) break;
  }
  return out;
}

const WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

function ordinal(n: number): string {
  const s = n % 100 >= 11 && n % 100 <= 13 ? "th" : ({ 1: "st", 2: "nd", 3: "rd" } as Record<number, string>)[n % 10] ?? "th";
  return `${n}${s}`;
}

/** "Every Tuesday", "Every other Friday", "Monthly on the 3rd", "Every day"; with " until 7 Dec" when it ends. */
export function repeatLabel(repeat: string | null | undefined, firstDate: string, until?: string | null): string | null {
  if (!REPEATS.includes(repeat as Repeat)) return null;
  const day = WEEKDAYS[isoWeekday(firstDate) - 1]!;
  const base = repeat === "daily" ? "Every day"
    : repeat === "weekly" ? `Every ${day}`
    : repeat === "fortnightly" ? `Every other ${day}`
    : `Monthly on the ${ordinal(Number(firstDate.slice(8, 10)))}`;
  if (!until) return base;
  const [y, m, d] = until.split("-").map(Number) as [number, number, number];
  const label = new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", day: "numeric", month: "short" }).format(new Date(Date.UTC(y, m - 1, d)));
  return `${base} until ${label}`;
}
