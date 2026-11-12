import { describe, expect, it } from "vitest";
import { averageStars, reviewPhase, stayOverlaps } from "./meals.js";
import { occurrences, repeatLabel } from "./repeat.js";
import { dayBounds, utcToWallTime } from "./time.js";

const DXB = "Asia/Dubai";
const LDN = "Europe/London";
const range = (from: string, to: string, tz: string) => ({ startsAt: dayBounds(from, tz).start, endsAt: dayBounds(to, tz).end });
/** Times are UTC; each case keeps the same calendar date in the family's zone. */
const plan = (start: string, end: string, repeat: string | null = null, repeatUntil: string | null = null) => ({
  startsAt: new Date(`${start}:00Z`),
  endsAt: new Date(`${end}:00Z`),
  repeat,
  repeatUntil,
});

describe("occurrences", () => {
  it("gives a one-off plan once, if it overlaps", () => {
    const p = plan("2026-11-17T14:00", "2026-11-17T15:00");
    expect(occurrences(p, range("2026-11-16", "2026-11-22", DXB), DXB)).toHaveLength(1);
    expect(occurrences(p, range("2026-11-18", "2026-11-22", DXB), DXB)).toHaveLength(0);
  });

  it("repeats weekly on the same weekday and stops at the end date", () => {
    const p = plan("2026-11-17T14:00", "2026-11-17T15:30", "weekly", "2026-12-08");
    const got = occurrences(p, range("2026-11-01", "2026-12-31", DXB), DXB);
    expect(got.map((o) => o.date)).toEqual(["2026-11-17", "2026-11-24", "2026-12-01", "2026-12-08"]);
    expect(got[1]!.endsAt.getTime() - got[1]!.startsAt.getTime()).toBe(90 * 60_000);
  });

  it("finds far-future occurrences without listing every earlier one", () => {
    const p = plan("2026-01-05T04:00", "2026-01-05T05:00", "daily");
    const got = occurrences(p, range("2028-03-01", "2028-03-03", DXB), DXB);
    expect(got.map((o) => o.date)).toEqual(["2028-03-01", "2028-03-02", "2028-03-03"]);
  });

  it("keeps the wall-clock time across a DST change", () => {
    // 09:00 London: 09:00Z in winter, 08:00Z in summer.
    const p = plan("2027-03-21T09:00", "2027-03-21T10:00", "weekly");
    const got = occurrences(p, range("2027-03-20", "2027-04-01", LDN), LDN);
    expect(got.map((o) => utcToWallTime(o.startsAt, LDN))).toEqual(["2027-03-21T09:00", "2027-03-28T09:00"]);
  });

  it("skips months without the day for monthly plans", () => {
    const p = plan("2027-01-31T06:00", "2027-01-31T07:00", "monthly");
    const got = occurrences(p, range("2027-01-01", "2027-05-31", DXB), DXB);
    expect(got.map((o) => o.date)).toEqual(["2027-01-31", "2027-03-31", "2027-05-31"]);
  });

  it("fortnightly", () => {
    const p = plan("2026-11-13T15:00", "2026-11-13T16:00", "fortnightly");
    const got = occurrences(p, range("2026-11-13", "2026-12-15", DXB), DXB);
    expect(got.map((o) => o.date)).toEqual(["2026-11-13", "2026-11-27", "2026-12-11"]);
  });
});

describe("repeatLabel", () => {
  it("names the rule", () => {
    expect(repeatLabel("weekly", "2026-11-17")).toBe("Every Tuesday");
    expect(repeatLabel("fortnightly", "2026-11-13", "2026-12-25")).toBe("Every other Friday until 25 Dec");
    expect(repeatLabel("monthly", "2026-11-03")).toBe("Monthly on the 3rd");
    expect(repeatLabel("daily", "2026-11-03")).toBe("Every day");
    expect(repeatLabel(null, "2026-11-03")).toBeNull();
  });
});

describe("meal reviews", () => {
  it("open at 22:00 family time for 48 hours", () => {
    // 22:00 Dubai = 18:00Z
    expect(reviewPhase("2026-11-12", new Date("2026-11-12T17:59:00Z"), DXB)).toBe("before");
    expect(reviewPhase("2026-11-12", new Date("2026-11-12T18:00:00Z"), DXB)).toBe("open");
    expect(reviewPhase("2026-11-12", new Date("2026-11-14T17:59:00Z"), DXB)).toBe("open");
    expect(reviewPhase("2026-11-12", new Date("2026-11-14T18:00:00Z"), DXB)).toBe("closed");
  });
  it("averages to one decimal", () => {
    expect(averageStars([4, 5, 4])).toBe(4.3);
    expect(averageStars([])).toBeNull();
  });
});

describe("stayOverlaps", () => {
  it("is inclusive at both ends", () => {
    const s = { arrives: "2026-11-20", leaves: "2026-12-07" };
    expect(stayOverlaps(s, "2026-12-07", "2026-12-09")).toBe(true);
    expect(stayOverlaps(s, "2026-11-01", "2026-11-20")).toBe(true);
    expect(stayOverlaps(s, "2026-12-08", "2026-12-09")).toBe(false);
  });
});
