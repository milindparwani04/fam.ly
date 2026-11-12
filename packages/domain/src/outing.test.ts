import { describe, expect, it } from "vitest";
import { nextAction, outingDisplay, type OutingInfo } from "./outing.js";
import { handoverRisk, vehicleState, type VehicleBooking } from "./vehicle.js";

const at = (s: string) => new Date(s);
const now = at("2027-05-01T12:00:00Z");

const outing = (over: Partial<OutingInfo>): OutingInfo => ({
  status: "planned",
  plannedStart: at("2027-05-01T10:00:00Z"),
  plannedReturn: at("2027-05-01T14:00:00Z"),
  expectedReturnAt: null,
  departureReportedAt: null,
  homeReportedAt: null,
  ...over,
});

describe("outingDisplay (P07-5)", () => {
  it("scheduled before start; 'not reported' after start without a Left tap (never assumed)", () => {
    expect(outingDisplay(outing({ plannedStart: at("2027-05-01T13:00:00Z") }), now).kind).toBe("scheduled");
    expect(outingDisplay(outing({}), now).kind).toBe("not_reported");
  });

  it("left, then overdue once the planned return passes", () => {
    const left = outing({ status: "departed", departureReportedAt: at("2027-05-01T10:05:00Z") });
    expect(outingDisplay(left, now)).toMatchObject({ kind: "left", problem: false });
    expect(outingDisplay(left, at("2027-05-01T14:30:00Z")).kind).toBe("overdue");
  });

  it("a later ETA shows 'expected back' until the ETA itself passes", () => {
    const late = outing({ status: "departed", plannedReturn: at("2027-05-01T11:00:00Z"), expectedReturnAt: at("2027-05-01T13:00:00Z") });
    expect(outingDisplay(late, now)).toMatchObject({ kind: "expected_back", expectedBack: at("2027-05-01T13:00:00Z") });
    expect(outingDisplay(late, at("2027-05-01T13:01:00Z")).kind).toBe("overdue");
  });

  it("returned and cancelled", () => {
    expect(outingDisplay(outing({ status: "returned", homeReportedAt: now }), now).kind).toBe("returned");
    expect(outingDisplay(outing({ status: "cancelled" }), now).kind).toBe("cancelled");
  });

  it("carries a reported problem", () => {
    const o = outing({ status: "departed", possessionUncertain: true });
    expect(outingDisplay(o, now)).toMatchObject({ problem: true });
  });
});

describe("nextAction (P07-6)", () => {
  it("offers Left from an hour before start, Home once departed, nothing when done", () => {
    expect(nextAction({ status: "planned", plannedStart: at("2027-05-01T13:30:00Z") }, now, null)).toBe(null);
    expect(nextAction({ status: "planned", plannedStart: at("2027-05-01T12:45:00Z") }, now, null)).toBe("left");
    expect(nextAction({ status: "departed", plannedStart: at("2027-05-01T10:00:00Z") }, now, null)).toBe("home");
    expect(nextAction({ status: "returned", plannedStart: at("2027-05-01T10:00:00Z") }, now, null)).toBe(null);
  });
  it("after a booking has ended, only 'home' remains (matches the server)", () => {
    expect(nextAction({ status: "planned", plannedStart: at("2027-05-01T09:00:00Z") }, now, at("2027-05-01T11:00:00Z"))).toBe("home");
  });
});

const b = (over: Partial<VehicleBooking>): VehicleBooking => ({
  id: "x",
  ownerId: "u",
  status: "reserved",
  startsAt: at("2027-05-01T10:00:00Z"),
  endsAt: at("2027-05-01T11:00:00Z"),
  ...over,
});

describe("vehicleState with self-reports", () => {
  it("an ETA after the booked end keeps the car 'out', not 'overdue', until the ETA", () => {
    const out = b({ status: "in_use_reported", expectedReturnAt: at("2027-05-01T13:00:00Z") });
    expect(vehicleState({ active: true }, [out], [], now).kind).toBe("out");
    expect(vehicleState({ active: true }, [out], [], at("2027-05-01T13:05:00Z")).kind).toBe("overdue");
  });
  it("available shows the latest confirmed return (R3: confirmed back vs just free)", () => {
    const back = b({ id: "back", status: "completed", vehicleReturnedAt: at("2027-05-01T10:50:00Z") });
    const state = vehicleState({ active: true }, [back], [], now);
    expect(state.kind === "available" && state.lastReturn?.id).toBe("back");
    expect(vehicleState({ active: true }, [], [], now)).toEqual({ kind: "available", lastReturn: null });
  });
});

describe("handoverRisk (next booker warning)", () => {
  const mine = b({ id: "mine", startsAt: at("2027-05-01T12:30:00Z"), endsAt: at("2027-05-01T14:00:00Z") });

  it("none when the previous driver is due back before I start", () => {
    const prev = b({ id: "p", status: "in_use_reported", endsAt: at("2027-05-01T12:15:00Z") });
    expect(handoverRisk(mine, [prev, mine], now).kind).toBe("none");
  });
  it("late when their ETA runs into my start", () => {
    const prev = b({ id: "p", status: "in_use_reported", endsAt: at("2027-05-01T12:15:00Z"), expectedReturnAt: at("2027-05-01T13:00:00Z") });
    expect(handoverRisk(mine, [prev, mine], now)).toMatchObject({ kind: "late", dueBack: at("2027-05-01T13:00:00Z") });
  });
  it("overdue when they're past due and not confirmed back", () => {
    const prev = b({ id: "p", status: "in_use_reported", endsAt: at("2027-05-01T11:00:00Z") });
    expect(handoverRisk(mine, [prev, mine], now).kind).toBe("overdue");
  });
  it("problem when they reported an issue", () => {
    const prev = b({ id: "p", status: "in_use_reported", endsAt: at("2027-05-01T12:15:00Z"), possessionUncertain: true });
    expect(handoverRisk(mine, [prev, mine], now).kind).toBe("problem");
  });
  it("returned cars are no risk", () => {
    const prev = b({ id: "p", status: "completed", endsAt: at("2027-05-01T11:00:00Z") });
    expect(handoverRisk(mine, [prev, mine], now).kind).toBe("none");
  });
});
