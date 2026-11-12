import { formatMoment, formatTime, formatWindow, oldestReviewableDay, wallDate } from "@famly/domain";
import { useState, type ReactNode } from "react";
import { Link, useNavigate } from "react-router";
import { Avatar } from "../components/Avatar";
import { ExitIcon, XIcon } from "../components/Icons";
import { useUserId } from "../lib/auth";
import { carState, newIdempotencyKey, type Activity as CarActivity } from "../lib/cars";
import {
  hasAccepted,
  menusToRate,
  statusKeys,
  stillOpenToAccept,
  useAction,
  useCarActivity,
  useCurrentGroup,
  useFamilyMenus,
  useFamilyTasks,
  useMembers,
  useMenusToReview,
  useMyPrompts,
  useVehicles,
} from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { activityLabel, memberStatus, outLabel, usePresence, useWorkHours, type MemberStatus } from "../lib/status";
import { supabase } from "../lib/supabase";
import { useUI } from "../lib/ui";
import { menuDay, rateTitle } from "./MenuDetail";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

export function Today() {
  const { group } = useCurrentGroup();
  return group ? <TodayBody group={group} /> : null;
}

/** Today (Stickers board): date and who's where, what's waiting for you, the cars. Fits one screen. */
function TodayBody({ group }: { group: Group }) {
  const tz = group.time_zone;
  const now = new Date();
  const members = useMembers(group.id);
  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const dateLine = new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "short", day: "numeric", month: "long" })
    .format(now).replace(",", "").toUpperCase();

  return (
    <div className="tab-screen today">
      <WhoIsWhere group={group} dateLine={dateLine} />
      <Waiting group={group} names={names} />
      <CarTiles group={group} names={names} />
      {members.isError && <p className="error">{messageOf(members.error)}</p>}
    </div>
  );
}

/* ------------------------------------------------------------------ Who's where */

function WhoIsWhere({ group, dateLine }: { group: Group; dateLine: string }) {
  const tz = group.time_zone;
  const uid = useUserId();
  const ui = useUI();
  const members = useMembers(group.id);
  const activity = useCarActivity(group.id);
  const vehicles = useVehicles(group.id);
  const presence = usePresence(group.id);
  const ids = members.data?.map((m) => m.user_id) ?? [];
  const work = useWorkHours(ids);
  const now = new Date();

  const people = [...(members.data ?? [])]
    .sort((a, b) => (a.user_id === uid ? -1 : b.user_id === uid ? 1 : 0))
    .map((m) => ({
      ...m,
      status: memberStatus({
        userId: m.user_id, activity: activity.data, vehicles: vehicles.data ?? [],
        presence: presence.data?.find((p) => p.user_id === m.user_id),
        work: work.data?.find((w) => w.user_id === m.user_id), now, timeZone: tz,
      }),
    }));
  const out = people.filter((p) => p.status.kind === "car" || p.status.kind === "out").length;
  const atWork = people.filter((p) => p.status.kind === "work").length;
  const home = people.length - out - atWork;
  const me = people.find((p) => p.user_id === uid);

  return (
    <>
      <div className="date-row">
        <span>{dateLine}</span>
        <span className="counts">
          {home} HOME{atWork ? ` · ${atWork} WORK` : ""} · {out} OUT
        </span>
      </div>
      <section className="card who" aria-label="Who's where">
        <div className="who-grid" style={people.length === 5 ? { gridTemplateColumns: "repeat(5, minmax(0, 1fr))" } : undefined}>
          {people.map((p) => {
            const first = p.user_id === uid ? "You" : p.display_name.split(/\s+/)[0]!;
            const detail = describe(p.status, now, tz);
            const badge = p.status.kind === "car" || p.status.kind === "out" ? "OUT" : p.status.kind === "work" ? "WORK" : null;
            return (
              <button key={p.user_id} className="member" aria-label={`${first}: ${detail}`}
                      onClick={() => ui.open({ kind: "person", userId: p.user_id })}>
                <Avatar name={p.display_name} size="lg">
                  {badge && <span className={`state-badge${badge === "WORK" ? " work" : ""}`}>{badge}</span>}
                </Avatar>
                <span className="name">{first}</span>
                <span className="detail">{detail}</span>
              </button>
            );
          })}
        </div>
        {me && <LeaveButton group={group} status={me.status} />}
      </section>
    </>
  );
}

function describe(s: MemberStatus, now: Date, tz: string): string {
  const at = (d: Date) => (wallDate(d, tz) === wallDate(now, tz) ? formatTime(d, tz) : formatMoment(d, now, tz));
  switch (s.kind) {
    case "car": {
      const what = s.carName ? s.carName.split(/\s+/)[0]! : "Out";
      return s.overdue ? `${what} · was due ${at(s.dueBack)}` : `${what} · back ${at(s.dueBack)}`;
    }
    case "out":
      return `${outLabel(s)} · since ${at(s.since)}`;
    case "work":
      return `Work · till ${at(s.shift.endsAt)}`;
    case "home":
      return "Home";
  }
}

/** I'm Leaving opens the activity sheet; I'm Home answers whichever way you left. */
function LeaveButton({ group, status }: { group: Group; status: MemberStatus }) {
  const ui = useUI();
  const [key, setKey] = useState(newIdempotencyKey);
  const home = useAction(
    async () => {
      if (status.kind === "car") {
        return unwrap(await supabase.rpc("rpc_confirm_home", { p_outing_id: status.outing.id, p_idempotency_key: key }));
      }
      return unwrap(await supabase.rpc("rpc_set_presence", { p_group_id: group.id, p_out: false }));
    },
    [...statusKeys(group.id), ["presence", group.id]],
  );
  const out = status.kind === "car" || status.kind === "out";
  const label = status.kind === "car" && status.carName ? "I'm Home — Car Returned" : out ? "I'm Home" : "I'm Leaving";
  return (
    <>
      <button className="leave-btn" disabled={home.isPending}
              onClick={() => {
                if (!out) return ui.open({ kind: "leave" });
                home.mutate(undefined, {
                  onSuccess: () => {
                    setKey(newIdempotencyKey());
                    ui.toast(status.kind === "car" && status.carName ? `You're home · ${status.carName} is free` : "You're home");
                  },
                });
              }}>
        <ExitIcon />
        {home.isPending ? "Saving…" : label}
      </button>
      {home.error && <p className="error" role="alert">{messageOf(home.error)}</p>}
    </>
  );
}

/* ------------------------------------------------------------------ Waiting for you */

interface WaitItem {
  key: string;
  kind: "Trip" | "Request" | "Menu" | "Rate";
  cls: "trip" | "request" | "menu" | "rate";
  title: string;
  sub: string;
  to: string;
  primary: string;
  onPrimary: () => void;
  secondary?: { label: string; run: () => void };
}

function Waiting({ group, names }: { group: Group; names: Map<string, string> }) {
  const tz = group.time_zone;
  const uid = useUserId();
  const ui = useUI();
  const navigate = useNavigate();
  const now = new Date();
  const today = wallDate(now, tz);
  const prompts = useMyPrompts();
  const activity = useCarActivity(group.id);
  const vehicles = useVehicles(group.id);
  const tasks = useFamilyTasks(group.id);
  const menus = useFamilyMenus(group.id, today);
  const toReview = useMenusToReview(group.id, oldestReviewableDay(today), today);
  const nameOf = (id: string | null | undefined) => (id === uid ? "you" : (id && names.get(id)?.split(/\s+/)[0]) || "a former member");
  const taskKeys = [["family-tasks", group.id], ["family-tasks", "mine", uid]];

  const respond = useAction(
    async (a: { id: string; state: "accepted" | "declined" }) =>
      unwrap(await supabase.rpc("rpc_respond_task", { p_task_id: a.id, p_state: a.state })),
    taskKeys,
  );
  const complete = useAction(async (id: string) => unwrap(await supabase.rpc("rpc_complete_task", { p_task_id: id })), taskKeys);
  const accept = useAction(
    async (m: { id: string; version: number }) => unwrap(await supabase.rpc("rpc_accept_menu", { p_menu_id: m.id, p_version: m.version })),
    [["family-menus", group.id]],
  );
  const snooze = useAction(async (id: string) => unwrap(await supabase.rpc("rpc_snooze_prompt", { p_prompt_id: id })), statusKeys(group.id));
  const [homeKey] = useState(newIdempotencyKey);
  const confirmHome = useAction(
    async (outingId: string) => unwrap(await supabase.rpc("rpc_confirm_home", { p_outing_id: outingId, p_idempotency_key: homeKey })),
    [...statusKeys(group.id), ["presence", group.id]],
  );
  const error = respond.error ?? complete.error ?? accept.error ?? snooze.error ?? confirmHome.error;

  const items: WaitItem[] = [];
  for (const p of prompts.data ?? []) {
    const o = activity.data?.outings.find((x) => x.id === p.outing_id);
    if (!o || !activity.data) continue;
    const car = carOf(o.reservation_id, activity.data, vehicles.data ?? []);
    const when = formatWindow(new Date(o.planned_start), new Date(o.planned_return), now, tz);
    const canSnooze = p.snooze_count < group.snooze_cap;
    const snoozeIt = canSnooze ? { label: "Remind me in 15 minutes", run: () => snooze.mutate(p.id, { onSuccess: () => ui.toast("Reminder in 15 minutes") }) } : undefined;
    items.push(p.kind === "departure"
      ? {
          key: p.id, kind: "Trip", cls: "trip", title: `Time To Go${car ? ` · ${car}` : ""}`, sub: when,
          to: o.reservation_id ? `/bookings/${o.reservation_id}` : "/", primary: "I'm Leaving",
          onPrimary: () => ui.open({ kind: "leave", outingId: o.id }), ...(snoozeIt ? { secondary: snoozeIt } : {}),
        }
      : {
          key: p.id, kind: "Trip", cls: "trip", title: `Are You Back?${car ? ` · ${car}` : ""}`, sub: when,
          to: o.reservation_id ? `/bookings/${o.reservation_id}` : "/", primary: "I'm Home",
          onPrimary: () => confirmHome.mutate(o.id, { onSuccess: () => ui.toast(car ? `You're home · ${car} is free` : "You're home") }),
          ...(snoozeIt ? { secondary: snoozeIt } : {}),
        });
  }
  const open = (tasks.data ?? []).filter((t) => !t.completed_at);
  for (const t of open.filter((t) => t.task_assignee.some((a) => a.user_id === uid && a.state === "pending"))) {
    items.push({
      key: t.id, kind: "Request", cls: "request", title: t.title, sub: `From ${cap(nameOf(t.created_by))}`, to: `/family/tasks/${t.id}`,
      primary: "Accept",
      onPrimary: () => respond.mutate({ id: t.id, state: "accepted" }, { onSuccess: () => ui.toast(`Accepted · ${t.title}`) }),
      secondary: {
        label: "Decline",
        run: () => respond.mutate({ id: t.id, state: "declined" }, { onSuccess: () => ui.toast(`Declined · ${cap(nameOf(t.created_by))} notified`) }),
      },
    });
  }
  for (const m of menusToRate(toReview.data, uid, now, tz)) {
    items.push({
      key: `rate-${m.id}`, kind: "Rate", cls: "rate", title: rateTitle(m.menu_date, today, tz),
      sub: m.items.split("\n").map((l) => l.trim()).filter(Boolean).join(", "),
      to: `/family/menus/${m.id}`, primary: "Rate",
      onPrimary: () => ui.open({ kind: "rate", menuId: m.id }),
    });
  }
  for (const m of (menus.data ?? []).filter((m) => !hasAccepted(m, uid) && stillOpenToAccept(m.menu_date, now, tz))) {
    items.push({
      key: m.id, kind: "Menu", cls: "menu", title: `${menuDay(m.menu_date, today, tz)}'s Menu`,
      sub: `${m.items.split("\n").map((l) => l.trim()).filter(Boolean).join(", ")} · by ${cap(nameOf(m.created_by))}`,
      to: `/family/menus/${m.id}`, primary: "Accept",
      onPrimary: () => accept.mutate({ id: m.id, version: m.version }, { onSuccess: () => ui.toast(`Accepted ${menuDay(m.menu_date, today, tz).toLowerCase()}'s menu`) }),
      secondary: { label: "Suggest a change", run: () => navigate(`/family/menus/${m.id}`) },
    });
  }
  for (const t of open.filter((t) => t.task_assignee.some((a) => a.user_id === uid && a.state === "accepted"))) {
    items.push({
      key: `${t.id}-done`, kind: "Request", cls: "request", title: t.title, sub: `You accepted · from ${nameOf(t.created_by)}`,
      to: `/family/tasks/${t.id}`, primary: "Mark Done",
      onPrimary: () => complete.mutate(t.id, { onSuccess: () => ui.toast(`Done · ${t.title}`) }),
    });
  }

  const busy = respond.isPending || complete.isPending || accept.isPending || snooze.isPending || confirmHome.isPending;
  const loading = tasks.isPending || menus.isPending || toReview.isPending;
  return (
    <section className="sec wait-sec" aria-label="Waiting for you">
      <div className="title-count">
        <h2>Waiting For You</h2>
        {items.length > 0 && <span className="count-badge">{items.length}</span>}
      </div>
      {items.slice(0, 2).map((w) => (
        <div key={w.key} className={`wait-card ${w.cls}`}>
          <Link to={w.to} className="wait-main">
            <span className="kind">{w.kind}</span>
            <span className="title">{w.title}</span>
            <span className="sub">{w.sub}</span>
          </Link>
          <div className="wait-actions">
            {w.secondary && (
              <button className="sq-btn" aria-label={w.secondary.label} disabled={busy} onClick={w.secondary.run}><XIcon /></button>
            )}
            <button className="wait-primary" disabled={busy} onClick={w.onPrimary}>{w.primary}</button>
          </div>
        </div>
      ))}
      {items.length > 2 && <Link to="/family?view=todos" className="more-link">{items.length - 2} more in Plans</Link>}
      {!loading && items.length === 0 && <div className="all-clear">All clear. Nothing needs you right now.</div>}
      {error && <p className="error" role="alert">{messageOf(error)}</p>}
      <Link to="/family/tasks/new" className="add-task"><span className="plus" aria-hidden="true">+</span>Add Task</Link>
    </section>
  );
}

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

function carOf(reservationId: string | null, activity: CarActivity, vehicles: Array<{ id: string; name: string }>) {
  const b = reservationId ? activity.bookings.find((x) => x.id === reservationId) : undefined;
  return b ? (vehicles.find((v) => v.id === b.vehicle_id)?.name ?? null) : null;
}

/* ------------------------------------------------------------------ Cars */

function CarTiles({ group, names }: { group: Group; names: Map<string, string> }) {
  const uid = useUserId();
  const ui = useUI();
  const vehicles = useVehicles(group.id);
  const activity = useCarActivity(group.id);
  if (!vehicles.data || !activity.data) return null;
  const now = new Date();
  const firstName = (id: string) => names.get(id)?.split(/\s+/)[0] ?? "Someone";
  const cars = vehicles.data.filter((v) => v.active).map((v) => ({ v, st: carState(v, activity.data!, uid, firstName, now, group.time_zone) }));
  const free = cars.filter((c) => c.st.cls === "free").length;
  let body: ReactNode;
  if (cars.length === 0) {
    body = <Link to="/cars" className="all-clear" style={{ textDecoration: "none" }}>No cars yet. Add one on the Cars tab.</Link>;
  } else {
    body = (
      <div className="car-tiles">
        {cars.map(({ v, st }) => (
          <div key={v.id} className="card car-tile">
            <span className={`pill ${st.cls}`}>{st.label}</span>
            <span className="name">{v.name}</span>
            <span className="line">{st.line}</span>
            {st.cls === "free" ? (
              <button className="tile-btn free" onClick={() => ui.open({ kind: "book", vehicleId: v.id })}>Book Now</button>
            ) : st.cls === "mine" && st.mineBookingId ? (
              <Link className="tile-btn mine" to={`/bookings/${st.mineBookingId}`}>My Booking</Link>
            ) : (
              <button className="tile-btn out" onClick={() => ui.open({ kind: "schedule", vehicleId: v.id })}>Schedule</button>
            )}
          </div>
        ))}
      </div>
    );
  }
  return (
    <section className="sec cars-sec" aria-label="Cars">
      <div className="sec-head">
        <h2>Cars</h2>
        {cars.length > 0 && <span className="summary">{free === 0 ? "No cars free" : free === 1 ? "1 car free" : `${free} cars free`}</span>}
      </div>
      {body}
    </section>
  );
}
