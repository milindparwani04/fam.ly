import { addDays, wallDate, wallTimeToUtc, type Interval } from "./time.js";

/** Someone's usual working hours. Days are ISO weekdays (1 = Monday); times are "HH:MM" wall-clock. */
export interface WorkHours {
  days: readonly number[];
  starts: string;
  ends: string;
}

/** ISO weekday (1 = Monday … 7 = Sunday) of a "YYYY-MM-DD" date. */
export function isoWeekday(date: string): number {
  const d = new Date(`${date}T12:00:00Z`).getUTCDay();
  return d === 0 ? 7 : d;
}

/**
 * The shift covering `now`, if any, in the family's time zone. An end at or before the start is an
 * overnight shift, which belongs to the day it starts on (a Friday 22:00–06:00 shift covers Saturday 03:00).
 */
export function activeShift(w: WorkHours | null | undefined, now: Date, timeZone: string): Interval | null {
  if (!w || w.days.length === 0) return null;
  const starts = w.starts.slice(0, 5);
  const ends = w.ends.slice(0, 5);
  const today = wallDate(now, timeZone);
  for (const date of [today, addDays(today, -1)]) {
    if (!w.days.includes(isoWeekday(date))) continue;
    const startsAt = wallTimeToUtc(`${date}T${starts}`, timeZone);
    const endsAt = wallTimeToUtc(`${ends <= starts ? addDays(date, 1) : date}T${ends}`, timeZone);
    if (now >= startsAt && now < endsAt) return { startsAt, endsAt };
  }
  return null;
}
