import { describe, expect, it } from "vitest";
import { activeShift, isoWeekday } from "./work.js";

const TZ = "Asia/Dubai"; // UTC+4, no DST
const at = (iso: string) => new Date(iso);

describe("isoWeekday", () => {
  it("counts Monday as 1 and Sunday as 7", () => {
    expect(isoWeekday("2026-11-09")).toBe(1);
    expect(isoWeekday("2026-11-08")).toBe(7);
  });
});

describe("activeShift", () => {
  const weekdays = { days: [1, 2, 3, 4, 5], starts: "09:00", ends: "17:30" };

  it("finds the shift during working hours on a working day", () => {
    const s = activeShift(weekdays, at("2026-11-09T08:00:00Z"), TZ); // Mon 12:00 Dubai
    expect(s?.startsAt.toISOString()).toBe("2026-11-09T05:00:00.000Z");
    expect(s?.endsAt.toISOString()).toBe("2026-11-09T13:30:00.000Z");
  });

  it("is null outside hours, on days off and with no schedule", () => {
    expect(activeShift(weekdays, at("2026-11-09T14:00:00Z"), TZ)).toBeNull(); // Mon 18:00
    expect(activeShift(weekdays, at("2026-11-07T08:00:00Z"), TZ)).toBeNull(); // Sat
    expect(activeShift({ days: [], starts: "09:00", ends: "17:00" }, at("2026-11-09T08:00:00Z"), TZ)).toBeNull();
    expect(activeShift(null, at("2026-11-09T08:00:00Z"), TZ)).toBeNull();
  });

  it("treats an end before the start as an overnight shift from the start day", () => {
    const nights = { days: [5], starts: "22:00:00", ends: "06:00:00" }; // Friday nights, seconds as Postgres sends them
    expect(activeShift(nights, at("2026-11-06T19:00:00Z"), TZ)).not.toBeNull(); // Fri 23:00
    expect(activeShift(nights, at("2026-11-06T23:00:00Z"), TZ)).not.toBeNull(); // Sat 03:00
    expect(activeShift(nights, at("2026-11-07T03:00:00Z"), TZ)).toBeNull(); // Sat 07:00
    expect(activeShift(nights, at("2026-11-07T19:00:00Z"), TZ)).toBeNull(); // Sat 23:00, not a working day
  });
});
