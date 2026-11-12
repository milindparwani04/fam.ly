import { describe, expect, it } from "vitest";
import { formatMoment, formatWindow, nextBooking, vehicleState, type VehicleBooking } from "./vehicle.js";

const TZ = "Asia/Dubai";
const at = (iso: string) => new Date(iso);
const now = at("2027-05-01T12:00:00+04:00");

const booking = (over: Partial<VehicleBooking>): VehicleBooking => ({
  id: "b1",
  ownerId: "u1",
  status: "reserved",
  startsAt: at("2027-05-01T10:00:00+04:00"),
  endsAt: at("2027-05-01T14:00:00+04:00"),
  ...over,
});

describe("vehicleState", () => {
  it("is available with nothing going on", () => {
    expect(vehicleState({ active: true }, [], [], now).kind).toBe("available");
  });

  it("inactive wins over everything", () => {
    expect(vehicleState({ active: false }, [booking({ status: "in_use_reported" })], [], now).kind).toBe("inactive");
  });

  it("a car reported out is out, and overdue once its window has ended", () => {
    expect(vehicleState({ active: true }, [booking({ status: "in_use_reported" })], [], now).kind).toBe("out");
    const late = booking({ status: "in_use_reported", endsAt: at("2027-05-01T11:00:00+04:00") });
    expect(vehicleState({ active: true }, [late], [], now).kind).toBe("overdue");
  });

  it("being physically out beats a maintenance window", () => {
    const m = { id: "m", startsAt: at("2027-05-01T11:00:00+04:00"), endsAt: at("2027-05-01T18:00:00+04:00"), reason: null };
    expect(vehicleState({ active: true }, [booking({ status: "in_use_reported" })], [m], now).kind).toBe("out");
    expect(vehicleState({ active: true }, [], [m], now).kind).toBe("maintenance");
  });

  it("a booking covering now that hasn't been reported left is 'booked'", () => {
    expect(vehicleState({ active: true }, [booking({})], [], now).kind).toBe("booked");
  });

  it("a reserved booking whose window has passed doesn't block availability", () => {
    const past = booking({ endsAt: at("2027-05-01T11:00:00+04:00") });
    expect(vehicleState({ active: true }, [past], [], now).kind).toBe("available");
  });
});

describe("nextBooking", () => {
  it("picks the earliest live booking that hasn't ended", () => {
    const later = booking({ id: "later", startsAt: at("2027-05-02T10:00:00+04:00"), endsAt: at("2027-05-02T11:00:00+04:00") });
    const sooner = booking({ id: "sooner", startsAt: at("2027-05-01T15:00:00+04:00"), endsAt: at("2027-05-01T16:00:00+04:00") });
    const cancelled = booking({ id: "c", status: "cancelled", startsAt: at("2027-05-01T13:00:00+04:00") });
    expect(nextBooking([later, cancelled, sooner], now)?.id).toBe("sooner");
  });
});

describe("formatWindow", () => {
  it("same day", () => {
    expect(formatWindow(at("2027-05-01T14:00:00+04:00"), at("2027-05-01T16:00:00+04:00"), now, TZ)).toBe(
      "Today 14:00–16:00",
    );
  });
  it("tomorrow", () => {
    expect(formatWindow(at("2027-05-02T09:30:00+04:00"), at("2027-05-02T10:00:00+04:00"), now, TZ)).toBe(
      "Tomorrow 09:30–10:00",
    );
  });
  it("cross-midnight names both days", () => {
    expect(formatWindow(at("2027-05-01T23:00:00+04:00"), at("2027-05-02T01:00:00+04:00"), now, TZ)).toBe(
      "Today 23:00 – Tomorrow 01:00",
    );
  });
  it("uses the given time zone, not the machine's", () => {
    // 21:00 UTC on 1 May is already 2 May 01:00 in Dubai.
    expect(formatWindow(at("2027-05-01T21:00:00Z"), at("2027-05-01T22:00:00Z"), now, TZ)).toBe(
      "Tomorrow 01:00–02:00",
    );
  });
  it("further dates show weekday and date", () => {
    expect(formatWindow(at("2027-05-07T10:00:00+04:00"), at("2027-05-07T12:00:00+04:00"), now, TZ)).toBe(
      "Fri 7 May 10:00–12:00",
    );
  });
});

describe("formatMoment", () => {
  it("formats a single moment", () => {
    expect(formatMoment(at("2027-05-01T16:00:00+04:00"), now, TZ)).toBe("Today 16:00");
  });
});
