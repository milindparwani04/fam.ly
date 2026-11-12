import { DAY_MS, overlaps, QUARTER_HOUR, roundUpTo, type Interval } from "./time.js";

/** True if [start, end) is clear of every busy interval (half-open, like the database). */
export function isFree(busy: readonly Interval[], window: Interval): boolean {
  return !busy.some((b) => overlaps(b, window));
}

/**
 * Up to `count` free windows of the same length near the one asked for (P05-6), chronological.
 * Candidates: the requested start, right after each busy block, and just before each busy block,
 * rounded up to the quarter hour, no earlier than `notBefore`, within ±`horizonMs`.
 */
export function suggestSlots(
  busy: readonly Interval[],
  wanted: Interval,
  opts: { notBefore: Date; count?: number; horizonMs?: number },
): Interval[] {
  const count = opts.count ?? 3;
  const horizon = opts.horizonMs ?? 7 * DAY_MS;
  const duration = wanted.endsAt.getTime() - wanted.startsAt.getTime();
  const want = wanted.startsAt.getTime();
  const earliest = Math.max(opts.notBefore.getTime(), want - horizon);

  const starts = new Set<number>([want]);
  for (const b of busy) {
    starts.add(roundUpTo(b.endsAt, QUARTER_HOUR).getTime());
    starts.add(Math.floor((b.startsAt.getTime() - duration) / QUARTER_HOUR) * QUARTER_HOUR);
  }

  return [...starts]
    .filter((s) => s >= earliest && Math.abs(s - want) <= horizon)
    .map((s) => ({ startsAt: new Date(s), endsAt: new Date(s + duration) }))
    .filter((w) => isFree(busy, w))
    .sort((a, b) => Math.abs(a.startsAt.getTime() - want) - Math.abs(b.startsAt.getTime() - want))
    .slice(0, count)
    .sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime());
}
