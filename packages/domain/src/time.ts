// Wall-clock ⇄ instant conversion in a named IANA zone, without a date library (T03).
// Families book in their own zone ("Asia/Dubai"), whatever zone the phone happens to be in.

const MINUTE = 60_000;
export const DAY_MS = 86_400_000;

const formatters = new Map<string, Intl.DateTimeFormat>();
function partsFormatter(timeZone: string): Intl.DateTimeFormat {
  let f = formatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
    formatters.set(timeZone, f);
  }
  return f;
}

/** The wall-clock reading in `timeZone` at instant `ms`, expressed as if it were UTC. */
function wallAsUtcMs(ms: number, timeZone: string): number {
  const p: Record<string, number> = {};
  for (const { type, value } of partsFormatter(timeZone).formatToParts(new Date(ms))) {
    if (type !== "literal") p[type] = Number(value);
  }
  return Date.UTC(p.year!, p.month! - 1, p.day!, p.hour!, p.minute!, p.second!);
}

function offsetMs(ms: number, timeZone: string): number {
  return wallAsUtcMs(Math.floor(ms / 1000) * 1000, timeZone) - Math.floor(ms / 1000) * 1000;
}

const WALL_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/;

/**
 * "2027-03-28T01:30" in `timeZone` → instant. Matches Temporal's "compatible" disambiguation:
 * a time skipped by a DST jump moves forward by the gap; a repeated time takes the earlier instant.
 */
export function wallTimeToUtc(wall: string, timeZone: string): Date {
  const m = WALL_RE.exec(wall);
  if (!m) throw new RangeError(`Invalid wall time: ${wall}`);
  const target = Date.UTC(+m[1]!, +m[2]! - 1, +m[3]!, +m[4]!, +m[5]!);

  const before = offsetMs(target - DAY_MS, timeZone);
  const after = offsetMs(target + DAY_MS, timeZone);
  const matches = [target - before, target - after].filter((t) => wallAsUtcMs(t, timeZone) === target);
  if (matches.length > 0) return new Date(Math.min(...matches));
  // In a gap: interpret with the pre-transition offset, which lands just after the jump.
  return new Date(target - before);
}

/** Instant → "YYYY-MM-DDTHH:mm" wall time in `timeZone` (for prefilling inputs). */
export function utcToWallTime(d: Date, timeZone: string): string {
  return new Date(wallAsUtcMs(d.getTime(), timeZone)).toISOString().slice(0, 16);
}

/** "YYYY-MM-DD" of the instant in `timeZone`. */
export function wallDate(d: Date, timeZone: string): string {
  return utcToWallTime(d, timeZone).slice(0, 10);
}

/** Calendar arithmetic on "YYYY-MM-DD" (zone-free). */
export function addDays(date: string, days: number): string {
  const [y, m, d] = date.split("-").map(Number) as [number, number, number];
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

/** [start, end) of a local calendar day. 23 or 25 hours long on DST change days. */
export function dayBounds(date: string, timeZone: string): { start: Date; end: Date } {
  return {
    start: wallTimeToUtc(`${date}T00:00`, timeZone),
    end: wallTimeToUtc(`${addDays(date, 1)}T00:00`, timeZone),
  };
}

export interface Interval {
  startsAt: Date;
  endsAt: Date;
}

export interface DaySegment<T extends Interval> {
  item: T;
  start: Date;
  end: Date;
  /** Position within the day, 0..1, measured in real elapsed time. */
  from: number;
  to: number;
  continuesFromPreviousDay: boolean;
  continuesToNextDay: boolean;
}

/** Clips items to one day, so a cross-midnight booking shows on both days it touches. */
export function segmentsForDay<T extends Interval>(items: readonly T[], day: { start: Date; end: Date }): DaySegment<T>[] {
  const span = day.end.getTime() - day.start.getTime();
  return items
    .filter((it) => it.startsAt < day.end && it.endsAt > day.start)
    .sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime())
    .map((item) => {
      const start = item.startsAt < day.start ? day.start : item.startsAt;
      const end = item.endsAt > day.end ? day.end : item.endsAt;
      return {
        item,
        start,
        end,
        from: (start.getTime() - day.start.getTime()) / span,
        to: (end.getTime() - day.start.getTime()) / span,
        continuesFromPreviousDay: item.startsAt < day.start,
        continuesToNextDay: item.endsAt > day.end,
      };
    });
}

export function overlaps(a: Interval, b: Interval): boolean {
  return a.startsAt < b.endsAt && b.startsAt < a.endsAt;
}

export function roundUpTo(d: Date, stepMs: number): Date {
  return new Date(Math.ceil(d.getTime() / stepMs) * stepMs);
}

export const QUARTER_HOUR = 15 * MINUTE;
