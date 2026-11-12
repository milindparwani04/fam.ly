import { formatMoment, formatTime, wallDate } from "@famly/domain";
import { Link } from "react-router";
import { useUserId } from "../lib/auth";
import { useCarActivity, useMembers, useVehicles } from "../lib/queries";
import { isInPlan, useUpcomingPlans } from "../lib/plans";
import { memberStatus, outLabel, usePresence, useWorkHours, type MemberStatus } from "../lib/status";
import { Sheet, useUI } from "../lib/ui";
import { Avatar } from "./Avatar";

const DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/** "Mon–Fri", "Mon, Wed, Fri", "Every day" from ISO weekdays (1 = Monday). */
export function workDays(days: readonly number[]): string {
  const d = [...days].sort((a, b) => a - b);
  if (d.length === 7) return "Every day";
  const run = d.length > 2 && d.every((x, i) => i === 0 || x === d[i - 1]! + 1);
  return run ? `${DAY_NAMES[d[0]! - 1]}–${DAY_NAMES[d[d.length - 1]! - 1]}` : d.map((x) => DAY_NAMES[x - 1]).join(", ");
}

/**
 * Tap someone on Today (founder, 2026-11-12): home or out (with the plan's "where", or just "Out"), their work
 * hours, and their plans for the next week with the car they're taking. Everything here is already visible to
 * the family elsewhere; this gathers it in one place.
 */
export function PersonSheet({ groupId, timeZone, userId }: { groupId: string; timeZone: string; userId: string }) {
  const ui = useUI();
  const me = useUserId();
  const members = useMembers(groupId);
  const activity = useCarActivity(groupId);
  const vehicles = useVehicles(groupId);
  const presence = usePresence(groupId);
  const work = useWorkHours([userId]);
  const { plans, now } = useUpcomingPlans(groupId, timeZone, 7);
  const person = members.data?.find((m) => m.user_id === userId);
  const w = work.data?.find((x) => x.user_id === userId);
  const status = memberStatus({
    userId, activity: activity.data, vehicles: vehicles.data ?? [], presence: presence.data?.find((x) => x.user_id === userId),
    work: w, now, timeZone,
  });
  const carFor = (reservationId: string | null) => {
    const b = reservationId ? activity.data?.bookings.find((x) => x.id === reservationId) : undefined;
    return b ? (vehicles.data?.find((v) => v.id === b.vehicle_id)?.name ?? "A car") : null;
  };
  const theirs = plans.filter((p) => isInPlan(p, userId)).slice(0, 5);
  const name = person?.display_name ?? "Former member";
  const first = userId === me ? "You" : name.split(/\s+/)[0]!;
  const when = (d: Date) => (wallDate(d, timeZone) === wallDate(now, timeZone) ? `Today ${formatTime(d, timeZone)}` : formatMoment(d, now, timeZone));

  return (
    <Sheet label={`${name}`} onClose={ui.close}>
      <div className="person-head">
        <Avatar name={name} size="lg" />
        <span className="who-text">
          <span className="n">{name}{userId === me ? " (you)" : ""}</span>
          <StatusLine status={status} timeZone={timeZone} now={now} />
        </span>
      </div>
      <div className="person-facts">
        <span className="k">WORK HOURS</span>
        <span>{w && w.days.length && w.starts && w.ends ? `${workDays(w.days)} · ${w.starts.slice(0, 5)}–${w.ends.slice(0, 5)}` : "No set hours"}</span>
      </div>
      <span className="eyebrow">{first === "You" ? "Your" : `${first}'s`} plans this week</span>
      <div className="person-plans">
        {theirs.length === 0 && <p className="muted">Nothing planned.</p>}
        {theirs.map((p) => {
          const car = carFor(p.reservationId);
          return (
            <Link key={p.key} to={`/family/events/${p.id}`} className="person-plan" onClick={ui.close}>
              <span className="t">{when(p.startsAt)}</span>
              <span className="mid">
                <span className="title">{p.title}</span>
                {(p.destination || car) && (
                  <span className="sub">{[p.destination, car ? `Taking ${car}` : null].filter(Boolean).join(" · ")}</span>
                )}
              </span>
            </Link>
          );
        })}
      </div>
    </Sheet>
  );
}

function StatusLine({ status, timeZone, now }: { status: MemberStatus; timeZone: string; now: Date }) {
  const at = (d: Date) => (wallDate(d, timeZone) === wallDate(now, timeZone) ? formatTime(d, timeZone) : formatMoment(d, now, timeZone));
  switch (status.kind) {
    case "home":
      return <span className="pill free">Home</span>;
    case "work":
      return <span className="pill work-pill">At work · till {at(status.shift.endsAt)}</span>;
    case "out":
      return <span className="pill out">{status.plan ? `${status.plan.title} · ${outLabel(status)}` : outLabel(status)} · since {at(status.since)}</span>;
    case "car": {
      const plan = status.outing.family_event.find((e) => !e.cancelled_at);
      const where = plan ? (plan.destination ?? plan.title) : null;
      return (
        <span className="pill out">
          {[status.carName ?? "Out", where].filter(Boolean).join(" · ")} · {status.overdue ? "was due" : "back"} {at(status.dueBack)}
        </span>
      );
    }
  }
}
