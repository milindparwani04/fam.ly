import { describe, expect, it } from "vitest";
import { displayStatus, parseRpcError } from "./index.js";

const now = new Date("2027-03-01T12:00:00Z");

describe("displayStatus", () => {
  it("is overdue only when past end with no return report", () => {
    const endsAt = new Date("2027-03-01T11:00:00Z");
    expect(displayStatus({ status: "in_use_reported", endsAt, vehicleReturnedAt: null }, now)).toBe(
      "overdue_unconfirmed",
    );
    expect(displayStatus({ status: "completed", endsAt, vehicleReturnedAt: now }, now)).toBe(
      "reported_returned",
    );
  });
  it("is scheduled/left before the end", () => {
    const endsAt = new Date("2027-03-01T13:00:00Z");
    expect(displayStatus({ status: "reserved", endsAt, vehicleReturnedAt: null }, now)).toBe("scheduled");
    expect(displayStatus({ status: "in_use_reported", endsAt, vehicleReturnedAt: null }, now)).toBe(
      "reported_left",
    );
  });
});

describe("parseRpcError", () => {
  it("extracts conflict details", () => {
    const e = parseRpcError({
      message: "reservation_conflict",
      details: JSON.stringify({ starts_at: "2027-03-01T10:00:00+04:00", ends_at: "2027-03-01T12:00:00+04:00" }),
    });
    expect(e.code).toBe("reservation_conflict");
    expect(e.conflict?.starts_at).toContain("10:00");
  });
  it("maps unknown messages to unknown", () => {
    expect(parseRpcError({ message: "boom" })).toEqual({ code: "unknown" });
  });
});
