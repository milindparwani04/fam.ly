import { formatTime, formatWindow } from "@famly/domain";
import { useState } from "react";
import { useUserId } from "../lib/auth";
import { newIdempotencyKey } from "../lib/cars";
import { statusKeys, useAction, useCarActivity, useVehicles } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { isInPlan, useUpcomingPlans, type PlanTime } from "../lib/plans";
import { ACTIVITIES, carNameFor, leavableOuting, type Activity } from "../lib/status";
import { supabase } from "../lib/supabase";
import { Sheet, ToggleRow, useUI } from "../lib/ui";

/**
 * "I'm Leaving" (founder, 2026-11-07): one tap on what you're off to and the family is told. If you have a
 * booking you can leave on now, "Taking <car>" is on, so the car is marked in use as before (rpc_report_left);
 * otherwise it's a plain departure (rpc_set_presence). The house key is mentioned only when you have it.
 */
export function LeaveSheet({ groupId, timeZone, outingId }: { groupId: string; timeZone: string; outingId?: string | undefined }) {
  const ui = useUI();
  const uid = useUserId();
  const activity = useCarActivity(groupId);
  const vehicles = useVehicles(groupId);
  const [now] = useState(() => new Date());
  const trip = outingId
    ? (activity.data?.outings.find((o) => o.id === outingId && o.status === "planned") ?? null)
    : leavableOuting(activity.data, uid, now);
  const carName = trip && activity.data ? carNameFor(trip, activity.data, vehicles.data ?? []) : null;
  const [withCar, setWithCar] = useState(true);
  const [hasKey, setHasKey] = useState(false);
  const [key] = useState(newIdempotencyKey);
  const taking = !!(trip && carName && withCar);
  // Your plans for the rest of today (founder, 2026-11-12): leave for one and the family sees its "where".
  const upcoming = useUpcomingPlans(groupId, timeZone, 1);
  const tripFor = (p: PlanTime) => activity.data?.outings.find((o) =>
    o.owner_id === uid && o.status === "planned" && ((p.outingId && o.id === p.outingId) || (p.reservationId && o.reservation_id === p.reservationId))) ?? null;
  // All of them (the sheet scrolls), except your own car trip once there's no trip left to leave on.
  const myPlans = upcoming.plans.filter(
    (p) => isInPlan(p, uid, true) && !(p.reservationId && p.createdBy === uid && !tripFor(p)),
  );
  const carOf = (p: PlanTime) => {
    const b = p.reservationId ? activity.data?.bookings.find((x) => x.id === p.reservationId) : undefined;
    return b ? (vehicles.data?.find((v) => v.id === b.vehicle_id)?.name ?? "Car") : null;
  };

  const leaveForPlan = useAction(
    async (p: PlanTime) => {
      const o = tripFor(p);
      if (o) {
        return unwrap(await supabase.rpc("rpc_report_left", {
          p_outing_id: o.id, p_idempotency_key: key, ...(hasKey ? { p_has_house_key: true } : {}),
        }));
      }
      return unwrap(await supabase.rpc("rpc_leave_for_plan", { p_event_id: p.id, ...(hasKey ? { p_has_house_key: true } : {}) }));
    },
    [...statusKeys(groupId), ["presence", groupId]],
  );

  const leave = useAction(
    async (a: Activity) => {
      if (taking && trip) {
        return unwrap(await supabase.rpc("rpc_report_left", {
          p_outing_id: trip.id, p_idempotency_key: key, p_activity: a, ...(hasKey ? { p_has_house_key: true } : {}),
        }));
      }
      return unwrap(await supabase.rpc("rpc_set_presence", {
        p_group_id: groupId, p_out: true, p_activity: a, ...(hasKey ? { p_has_house_key: true } : {}),
      }));
    },
    [...statusKeys(groupId), ["presence", groupId]],
  );

  function go(a: Activity) {
    leave.mutate(a, {
      onSuccess: () => {
        ui.close();
        ui.toast(taking ? `Family notified · you left in ${carName}` : "Family notified · you left");
      },
    });
  }

  return (
    <Sheet label="I'm Leaving" onClose={ui.close}>
      <h2>Where Are You Off To?</h2>
      <div className="toggles">
        {trip && carName && (
          <ToggleRow title={`Taking ${carName}`} on={withCar} onChange={setWithCar}
                     sub={`Your booking ${formatWindow(new Date(trip.planned_start), new Date(trip.planned_return), now, timeZone)}`} />
        )}
        <ToggleRow title="I have the house key" sub="Everyone sees it in the update" on={hasKey} onChange={setHasKey} />
      </div>
      {myPlans.length > 0 && (
        <>
          <span className="eyebrow">Your plans today</span>
          <div className="leave-plans">
            {myPlans.map((p) => {
              const car = carOf(p);
              return (
                <button key={p.key} className="leave-plan press" disabled={leaveForPlan.isPending || leave.isPending}
                        onClick={() => leaveForPlan.mutate(p, {
                          onSuccess: () => { ui.close(); ui.toast(`Family notified · ${p.destination ?? p.title}`); },
                        })}>
                  <span className="t">{formatTime(p.startsAt, timeZone)}</span>
                  <span className="mid">
                    <span className="title">{p.title}</span>
                    <span className="sub">{[p.destination ?? "No place given", car ? `Taking ${car}` : null].filter(Boolean).join(" · ")}</span>
                  </span>
                </button>
              );
            })}
          </div>
          <span className="eyebrow">Or something else</span>
        </>
      )}
      <div className="leave-grid">
        {ACTIVITIES.map(({ id, label, Icon }) => (
          <button key={id} className={`leave-opt press ${id}`} disabled={leave.isPending} onClick={() => go(id)}>
            <Icon />
            {label}
          </button>
        ))}
      </div>
      {(leave.error ?? leaveForPlan.error) && <p className="error" role="alert">{messageOf(leave.error ?? leaveForPlan.error)}</p>}
    </Sheet>
  );
}
