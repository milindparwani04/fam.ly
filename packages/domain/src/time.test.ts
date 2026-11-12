import { describe, expect, it } from "vitest";
import { isFree, suggestSlots } from "./slots.js";
import { addDays, dayBounds, segmentsForDay, utcToWallTime, wallTimeToUtc } from "./time.js";

const iso = (d: Date) => d.toISOString();
const at = (s: string) => new Date(s);

describe("wallTimeToUtc (T03)", () => {
  it("Asia/Dubai has no DST: always UTC+4", () => {
    expect(iso(wallTimeToUtc("2027-01-15T10:00", "Asia/Dubai"))).toBe("2027-01-15T06:00:00.000Z");
    expect(iso(wallTimeToUtc("2027-07-15T23:30", "Asia/Dubai"))).toBe("2027-07-15T19:30:00.000Z");
  });

  it("Europe/London winter and summer offsets", () => {
    expect(iso(wallTimeToUtc("2027-01-15T10:00", "Europe/London"))).toBe("2027-01-15T10:00:00.000Z");
    expect(iso(wallTimeToUtc("2027-07-15T10:00", "Europe/London"))).toBe("2027-07-15T09:00:00.000Z");
  });

  it("London spring-forward gap (28 Mar 2027 01:00→02:00): 01:30 moves forward to 02:30 BST", () => {
    expect(iso(wallTimeToUtc("2027-03-28T01:30", "Europe/London"))).toBe("2027-03-28T01:30:00.000Z");
    expect(utcToWallTime(wallTimeToUtc("2027-03-28T01:30", "Europe/London"), "Europe/London")).toBe(
      "2027-03-28T02:30",
    );
  });

  it("London fall-back overlap (31 Oct 2027 01:00–02:00 happens twice): takes the earlier", () => {
    expect(iso(wallTimeToUtc("2027-10-31T01:30", "Europe/London"))).toBe("2027-10-31T00:30:00.000Z");
  });

  it("New York gap and overlap", () => {
    // 14 Mar 2027 02:00→03:00 EDT; 7 Nov 2027 01:00–02:00 repeats.
    expect(iso(wallTimeToUtc("2027-03-14T02:30", "America/New_York"))).toBe("2027-03-14T07:30:00.000Z");
    expect(iso(wallTimeToUtc("2027-11-07T01:30", "America/New_York"))).toBe("2027-11-07T05:30:00.000Z");
  });

  it("round-trips ordinary times", () => {
    for (const tz of ["Asia/Dubai", "Europe/London", "America/New_York"]) {
      expect(utcToWallTime(wallTimeToUtc("2027-05-01T08:45", tz), tz)).toBe("2027-05-01T08:45");
    }
  });

  it("rejects malformed input", () => {
    expect(() => wallTimeToUtc("2027-05-01 08:45", "Asia/Dubai")).toThrow(RangeError);
  });
});

describe("dayBounds", () => {
  it("is 24h in Dubai, 23h and 25h on London's change days", () => {
    const len = (date: string, tz: string) => {
      const b = dayBounds(date, tz);
      return (b.end.getTime() - b.start.getTime()) / 3_600_000;
    };
    expect(len("2027-03-28", "Asia/Dubai")).toBe(24);
    expect(len("2027-03-28", "Europe/London")).toBe(23);
    expect(len("2027-10-31", "Europe/London")).toBe(25);
  });

  it("addDays crosses month and year ends", () => {
    expect(addDays("2027-12-31", 1)).toBe("2028-01-01");
    expect(addDays("2028-03-01", -1)).toBe("2028-02-29");
  });
});

describe("segmentsForDay", () => {
  const tz = "Asia/Dubai";
  const booking = { startsAt: at("2027-05-01T23:00:00+04:00"), endsAt: at("2027-05-02T01:00:00+04:00") };

  it("splits a cross-midnight booking across both days", () => {
    const [d1] = segmentsForDay([booking], dayBounds("2027-05-01", tz));
    const [d2] = segmentsForDay([booking], dayBounds("2027-05-02", tz));
    expect(d1).toMatchObject({ continuesFromPreviousDay: false, continuesToNextDay: true });
    expect(d1!.from).toBeCloseTo(23 / 24);
    expect(d1!.to).toBe(1);
    expect(d2).toMatchObject({ continuesFromPreviousDay: true, continuesToNextDay: false, from: 0 });
    expect(d2!.to).toBeCloseTo(1 / 24);
  });

  it("ignores bookings on other days and positions by real time on a 25h day", () => {
    expect(segmentsForDay([booking], dayBounds("2027-05-03", tz))).toEqual([]);
    const london = dayBounds("2027-10-31", "Europe/London");
    const evening = { startsAt: wallTimeToUtc("2027-10-31T12:00", "Europe/London"), endsAt: london.end };
    expect(segmentsForDay([evening], london)[0]!.from).toBeCloseTo(13 / 25);
  });
});

describe("suggestSlots / isFree (P05-6)", () => {
  const busy = [
    { startsAt: at("2027-05-01T10:00:00Z"), endsAt: at("2027-05-01T12:00:00Z") },
    { startsAt: at("2027-05-01T13:00:00Z"), endsAt: at("2027-05-01T14:00:00Z") },
  ];

  it("half-open: back-to-back is free", () => {
    expect(isFree(busy, { startsAt: at("2027-05-01T12:00:00Z"), endsAt: at("2027-05-01T13:00:00Z") })).toBe(true);
    expect(isFree(busy, { startsAt: at("2027-05-01T11:59:00Z"), endsAt: at("2027-05-01T13:00:00Z") })).toBe(false);
  });

  it("offers the closest free windows of the same length, never overlapping, never in the past", () => {
    const wanted = { startsAt: at("2027-05-01T11:00:00Z"), endsAt: at("2027-05-01T12:00:00Z") };
    const slots = suggestSlots(busy, wanted, { notBefore: at("2027-05-01T08:00:00Z") });
    expect(slots.map((s) => iso(s.startsAt))).toEqual([
      "2027-05-01T09:00:00.000Z",
      "2027-05-01T12:00:00.000Z",
      "2027-05-01T14:00:00.000Z",
    ]);
    for (const s of slots) expect(isFree(busy, s)).toBe(true);

    const later = suggestSlots(busy, wanted, { notBefore: at("2027-05-01T09:30:00Z") });
    expect(later.every((s) => s.startsAt >= at("2027-05-01T09:30:00Z"))).toBe(true);
  });
});
