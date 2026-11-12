import { addDays, wallTimeToUtc } from "./time.js";

/** Reviews open at 22:00 (family time) on the menu's day and stay open for 48 hours. Matches migration 019. */
export const REVIEW_OPENS_AT = "22:00";
export const REVIEW_OPEN_HOURS = 48;

export type ReviewPhase = "before" | "open" | "closed";

export function reviewWindow(menuDate: string, timeZone: string): { opens: Date; closes: Date } {
  const opens = wallTimeToUtc(`${menuDate}T${REVIEW_OPENS_AT}`, timeZone);
  return { opens, closes: new Date(opens.getTime() + REVIEW_OPEN_HOURS * 3_600_000) };
}

export function reviewPhase(menuDate: string, now: Date, timeZone: string): ReviewPhase {
  const { opens, closes } = reviewWindow(menuDate, timeZone);
  return now < opens ? "before" : now < closes ? "open" : "closed";
}

/** The earliest menu day whose review window can still be open (for queries). */
export function oldestReviewableDay(today: string): string {
  return addDays(today, -2);
}

/** Mean of 1–5 star ratings to one decimal, or null with none. */
export function averageStars(stars: readonly number[]): number | null {
  if (stars.length === 0) return null;
  return Math.round((stars.reduce((a, b) => a + b, 0) / stars.length) * 10) / 10;
}

/** A stay overlaps the inclusive day range [from, to] ("YYYY-MM-DD"). */
export function stayOverlaps(stay: { arrives: string; leaves: string }, from: string, to: string): boolean {
  return stay.arrives <= to && stay.leaves >= from;
}
