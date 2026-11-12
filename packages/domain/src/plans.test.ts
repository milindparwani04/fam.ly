import { describe, expect, it } from "vitest";
import { greeting, groupPlans, timeAgo, type PlanEntry } from "./plans.js";

const e = (kind: PlanEntry<string>["kind"], day: string, time: string | null, item: string): PlanEntry<string> => ({ kind, day, time, item });

describe("groupPlans", () => {
  const entries = [
    e("request", "2026-10-28", null, "groceries"),
    e("event", "2026-10-29", "10:00", "dentist"),
    e("meal", "2026-10-28", null, "menu"),
    e("event", "2026-10-28", "19:30", "dinner"),
    e("event", "2026-10-28", "08:00", "school run"),
  ];

  it("buckets by day, timed entries in order, then anytime ones in input order", () => {
    expect(groupPlans(entries, "all")).toEqual([
      { day: "2026-10-28", entries: [entries[4], entries[3], entries[0], entries[2]] },
      { day: "2026-10-29", entries: [entries[1]] },
    ]);
  });

  it("filters to one category and drops days left empty", () => {
    expect(groupPlans(entries, "meal")).toEqual([{ day: "2026-10-28", entries: [entries[2]] }]);
    expect(groupPlans(entries, "event").map((d) => d.entries.map((x) => x.item))).toEqual([["school run", "dinner"], ["dentist"]]);
  });

  it("returns nothing for no entries", () => {
    expect(groupPlans([], "all")).toEqual([]);
  });
});

describe("greeting", () => {
  // Asia/Dubai is UTC+4 all year.
  const at = (utc: string) => greeting(new Date(utc), "Asia/Dubai");

  it("follows the family's wall clock, not UTC", () => {
    expect(at("2026-10-28T01:00:00Z")).toBe("Good Morning"); // 05:00
    expect(at("2026-10-28T07:59:00Z")).toBe("Good Morning"); // 11:59
    expect(at("2026-10-28T08:00:00Z")).toBe("Good Afternoon"); // 12:00
    expect(at("2026-10-28T13:59:00Z")).toBe("Good Afternoon"); // 17:59
    expect(at("2026-10-28T14:00:00Z")).toBe("Good Evening"); // 18:00
    expect(at("2026-10-28T00:59:00Z")).toBe("Good Evening"); // 04:59
  });
});

describe("timeAgo", () => {
  const now = new Date("2026-10-28T15:00:00Z");
  const ago = (ms: number) => timeAgo(new Date(now.getTime() - ms), now);

  it("steps from minutes to hours to days", () => {
    expect(ago(20_000)).toBe("Just now");
    expect(ago(-5_000)).toBe("Just now"); // clock skew: a row stamped slightly in the future
    expect(ago(5 * 60_000)).toBe("5m ago");
    expect(ago(59 * 60_000)).toBe("59m ago");
    expect(ago(2 * 3_600_000)).toBe("2h ago");
    expect(ago(30 * 3_600_000)).toBe("Yesterday");
    expect(ago(3 * 86_400_000)).toBe("3d ago");
  });
});
