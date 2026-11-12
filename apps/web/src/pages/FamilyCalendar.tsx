import { addDays, dayBounds, formatTime, occurrences, repeatLabel, segmentsForDay, wallDate } from "@famly/domain";
import { Link, useNavigate, useSearchParams } from "react-router";
import { AvatarStack } from "../components/Avatar";
import { StayCalendar } from "../components/StayCalendar";
import { CheckIcon, PlusIcon } from "../components/Icons";
import { useUserId } from "../lib/auth";
import {
  hasAccepted, stillOpenToAccept, useAction, useCurrentGroup, useFamilyEvents, useFamilyMenus, useFamilyTasks, useMembers, useStays,
} from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";
import { useUI } from "../lib/ui";
import { menuDay } from "./MenuDetail";
import { nights, stayGuests } from "./Stays";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;
type Filter = "all" | "event" | "meal";
const DAYS = 14;
const PREVIEW = 4;
const FILTERS: Array<{ id: Filter; label: string }> = [
  { id: "all", label: "All" },
  { id: "event", label: "Events" },
  { id: "meal", label: "Meals" },
];

interface PlanRow {
  key: string;
  day: string;
  sort: string;
  t: string;
  kind: "event" | "meal" | "stay";
  title: string;
  sub: string;
  needs: string | null;
  people: string[];
  to: string;
}

/** Events (one row per day they touch) and menus for the next two weeks, in day and time order. */
function usePlans(group: Group) {
  const tz = group.time_zone;
  const uid = useUserId();
  const today = wallDate(new Date(), tz);
  const days = Array.from({ length: DAYS }, (_, i) => addDays(today, i));
  const events = useFamilyEvents(group.id, dayBounds(today, tz).start, dayBounds(days[DAYS - 1]!, tz).end);
  const menus = useFamilyMenus(group.id, today);
  const stays = useStays(group.id, today);
  const members = useMembers(group.id);
  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const nameOf = (id: string) => names.get(id) ?? "Former member";

  const rows: PlanRow[] = [];
  // Repeating plans become one item per time they happen in the two weeks.
  const twoWeeks = { startsAt: dayBounds(today, tz).start, endsAt: dayBounds(days[DAYS - 1]!, tz).end };
  const items = (events.data ?? []).flatMap((e) =>
    occurrences({ ...e, startsAt: new Date(e.starts_at), endsAt: new Date(e.ends_at), repeatUntil: e.repeat_until }, twoWeeks, tz)
      .map((o) => ({ ...e, startsAt: o.startsAt, endsAt: o.endsAt, occurrence: o.date })));
  for (const d of days) {
    for (const s of segmentsForDay(items, dayBounds(d, tz))) {
      const e = s.item;
      const me = e.event_participant.find((p) => p.user_id === uid);
      rows.push({
        key: `e-${e.id}-${e.occurrence}-${d}`, day: d, sort: s.continuesFromPreviousDay ? "00:00" : formatTime(s.start, tz),
        t: s.continuesFromPreviousDay ? "Cont." : formatTime(s.start, tz), kind: "event", title: e.title,
        sub: [e.destination ?? e.description, e.reservation_id ? "Car booked" : null,
              e.repeat ? `↻ ${repeatLabel(e.repeat, wallDate(new Date(e.starts_at), tz))}` : null,
              s.continuesToNextDay ? "Continues tomorrow" : s.continuesFromPreviousDay ? `Until ${formatTime(s.end, tz)}` : null]
          .filter(Boolean).join(" · "),
        needs: me?.state === "invited" ? "You're invited" : null,
        people: e.event_participant.filter((p) => p.state === "attending").map((p) => nameOf(p.user_id)),
        to: `/family/events/${e.id}`,
      });
    }
  }
  for (const m of menus.data ?? []) {
    if (m.menu_date > days[DAYS - 1]!) continue;
    rows.push({
      key: `m-${m.id}`, day: m.menu_date, sort: "99:99", t: "Menu", kind: "meal",
      title: `${menuDay(m.menu_date, today, tz)}'s Menu`,
      sub: m.items.split("\n").map((l) => l.trim()).filter(Boolean).join(", "),
      needs: hasAccepted(m, uid) || !stillOpenToAccept(m.menu_date, new Date(), tz) ? null : "Needs your OK",
      people: m.menu_acceptance.filter((a) => a.version === m.version).map((a) => nameOf(a.user_id)),
      to: `/family/menus/${m.id}`,
    });
  }
  // Stays: a row on the day they arrive and the day they leave.
  for (const st of stays.data ?? []) {
    const who = stayGuests(st);
    const n = nights(st.arrives, st.leaves);
    const people = st.guest_names;
    const many = st.guest_names.length + (st.other_guests ? 1 : 0) > 1 || /,| and |&/.test(st.other_guests ?? "");
    if (st.arrives >= today && st.arrives <= days[DAYS - 1]!) {
      rows.push({
        key: `s-${st.id}-a`, day: st.arrives, sort: "00:01", t: "Arrive", kind: "stay",
        title: `${who} ${st.arrives === st.leaves ? (many ? "visit" : "visits") : many ? "arrive" : "arrives"}`,
        sub: [st.from_place ? `From ${st.from_place}` : null, n ? `Staying ${n} night${n === 1 ? "" : "s"}` : null].filter(Boolean).join(" · "),
        needs: null, people, to: `/family/stays/${st.id}`,
      });
    }
    if (st.leaves !== st.arrives && st.leaves >= today && st.leaves <= days[DAYS - 1]!) {
      rows.push({
        key: `s-${st.id}-l`, day: st.leaves, sort: "00:02", t: "Leave", kind: "stay", title: `${who} ${many ? "leave" : "leaves"}`,
        sub: st.from_place ? `Back to ${st.from_place}` : "", needs: null, people, to: `/family/stays/${st.id}`,
      });
    }
  }
  rows.sort((a, b) => (a.day + a.sort).localeCompare(b.day + b.sort));
  return {
    rows, today, days,
    loading: events.isPending || menus.isPending || stays.isPending,
    error: events.error ?? menus.error ?? stays.error,
  };
}

function dayName(day: string, today: string, tz: string) {
  if (day === today) return "Today";
  if (day === addDays(today, 1)) return "Tomorrow";
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "long" }).format(dayBounds(day, tz).start);
}
function dayDate(day: string, tz: string) {
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "short", day: "numeric", month: "short" })
    .format(dayBounds(day, tz).start).replace(",", "");
}

function PlanRowView({ r }: { r: PlanRow }) {
  return (
    <Link to={r.to} className="plan-row">
      <span className="t">{r.t}</span>
      <span className="mid">
        <span className="tags">
          <span className={`tag tag-${r.kind}`}>{r.kind === "meal" ? "Meal" : r.kind === "stay" ? "Stay" : "Event"}</span>
          {r.needs && <span className="needs">{r.needs}</span>}
        </span>
        <span className="title">{r.title}</span>
        {r.sub && <span className="sub">{r.sub}</span>}
      </span>
      <AvatarStack names={r.people} />
    </Link>
  );
}

/* ------------------------------------------------------------------ To-dos */

interface TodoRow {
  id: string;
  title: string;
  fromLine: string;
  people: string[];
  done: boolean;
  mine: boolean;
  tick: () => void;
}

function useTodos(group: Group) {
  const uid = useUserId();
  const ui = useUI();
  const tasks = useFamilyTasks(group.id);
  const members = useMembers(group.id);
  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const first = (id: string | null) => (id === uid ? "you" : (id && names.get(id)?.split(/\s+/)[0]) || "a former member");
  const keys = [["family-tasks", group.id], ["family-tasks", "mine", uid]];

  const complete = useAction(async (a: { id: string; acceptFirst: boolean }) => {
    if (a.acceptFirst) unwrap(await supabase.rpc("rpc_respond_task", { p_task_id: a.id, p_state: "accepted" }));
    return unwrap(await supabase.rpc("rpc_complete_task", { p_task_id: a.id }));
  }, keys);
  const reopen = useAction(async (id: string) => unwrap(await supabase.rpc("rpc_reopen_task", { p_task_id: id })), keys);

  const rows: TodoRow[] = (tasks.data ?? []).map((t) => {
    const me = t.task_assignee.find((a) => a.user_id === uid);
    const done = !!t.completed_at;
    const canTick = t.created_by === uid || (me && me.state !== "declined");
    return {
      id: t.id, title: t.title, done, mine: !!me && me.state !== "declined",
      people: t.task_assignee.filter((a) => a.state !== "declined").map((a) => names.get(a.user_id) ?? "Former member"),
      fromLine: done ? `Done by ${first(t.completed_by)}`
        : me?.state === "pending" ? `From ${cap(first(t.created_by))} · needs your answer`
        : `From ${first(t.created_by)}`,
      tick: () => {
        if (done) {
          if (t.completed_by !== uid && t.created_by !== uid) return ui.toast("Only whoever finished it can untick it");
          reopen.mutate(t.id, { onSuccess: () => ui.toast(`Reopened · ${t.title}`) });
        } else {
          if (!canTick) return ui.toast("Only people on this task can tick it off");
          complete.mutate({ id: t.id, acceptFirst: me?.state === "pending" }, { onSuccess: () => ui.toast(`Done · ${t.title}`) });
        }
      },
    };
  });
  const open = rows.filter((r) => !r.done).sort((a, b) => Number(b.mine) - Number(a.mine));
  const done = rows.filter((r) => r.done);
  return { open, done, loading: tasks.isPending, error: tasks.error ?? complete.error ?? reopen.error, busy: complete.isPending || reopen.isPending };
}

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

function TodoRowView({ r, busy }: { r: TodoRow; busy: boolean }) {
  return (
    <div className={`todo${r.done ? " done" : ""}`}>
      <button className="checkbox" role="checkbox" aria-checked={r.done} aria-label={`${r.title}, done`} disabled={busy} onClick={r.tick}>
        <CheckIcon />
      </button>
      <Link to={`/family/tasks/${r.id}`} className="todo-main">
        <span className="title">{r.title}</span>
        <span className="sub">{r.fromLine}</span>
      </Link>
      <AvatarStack names={r.people} max={3} />
    </div>
  );
}

/* ------------------------------------------------------------------ Plans tab */

export function FamilyCalendar() {
  const { group } = useCurrentGroup();
  return group ? <Plans group={group} /> : null;
}

/** Plans (Stickers board): week strip, Plans / To-Dos, filter chips, a list that scrolls in its card. */
function Plans({ group }: { group: Group }) {
  const tz = group.time_zone;
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const view = params.get("view") === "todos" ? "todos" : params.get("view") === "stays" ? "stays" : "plans";
  const filter = (["event", "meal"].includes(params.get("filter") ?? "") ? params.get("filter") : "all") as Filter;
  const { rows, today, days, loading, error } = usePlans(group);
  const from = days.includes(params.get("from") ?? "") ? params.get("from")! : today;
  const todos = useTodos(group);
  const set = (k: string, v: string | null) => {
    const next = new URLSearchParams(params);
    if (v === null) next.delete(k); else next.set(k, v);
    setParams(next, { replace: true });
  };

  const shown = rows.filter((r) => r.day >= from && (filter === "all" || r.kind === filter));
  const preview = shown.slice(0, PREVIEW);

  return (
    <div className="tab-screen tab-pad">
      <div className="title-row">
        <h1>Plans</h1>
        <Link to="/family/create" className="new-pill press"><PlusIcon />New</Link>
      </div>
      {view !== "stays" && <div className="day-strip" role="group" aria-label="Show plans from">
        {days.slice(0, 7).map((d) => {
          const date = dayBounds(d, tz).start;
          const has = rows.some((r) => r.day === d);
          return (
            <button key={d} aria-pressed={d === from} onClick={() => set("from", d === today ? null : d)}
                    aria-label={new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "long", day: "numeric", month: "long" }).format(date)}>
              <span className="dow">{new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "short" }).format(date)}</span>
              <span className="num">{Number(d.slice(8))}</span>
              <span className={`dot${has ? " has" : ""}`} />
            </button>
          );
        })}
      </div>}
      <div className="seg three" role="group" aria-label="Show">
        <button aria-pressed={view === "plans"} onClick={() => set("view", null)}>Plans · {shown.length}</button>
        <button aria-pressed={view === "todos"} onClick={() => set("view", "todos")}>To-Dos · {todos.open.length}</button>
        <button aria-pressed={view === "stays"} onClick={() => set("view", "stays")}>Stays</button>
      </div>

      {view === "stays" ? (
        <StayCalendar groupId={group.id} timeZone={tz} />
      ) : view === "plans" ? (
        <>
          <div className="filters" role="group" aria-label="Filter">
            {FILTERS.map((f) => (
              <button key={f.id} aria-pressed={filter === f.id} onClick={() => set("filter", f.id === "all" ? null : f.id)}>{f.label}</button>
            ))}
          </div>
          <div className="list-card">
            {loading && <p className="empty">Loading plans…</p>}
            {error && <p className="empty error">{messageOf(error)}</p>}
            {!loading && !error && shown.length === 0 && <p className="empty">Nothing planned from this day.</p>}
            {preview.map((r, i) => (
              <div key={r.key}>
                {(i === 0 || preview[i - 1]!.day !== r.day) && (
                  <div className="day-label"><span className="n">{dayName(r.day, today, tz)}</span><span className="d">{dayDate(r.day, tz)}</span></div>
                )}
                <PlanRowView r={r} />
              </div>
            ))}
          </div>
          <button className="view-all" onClick={() => navigate("/family/all")}>View All Plans ({rows.length})</button>
        </>
      ) : (
        <>
          <div className="list-card todos">
            {todos.loading && <p className="empty">Loading…</p>}
            {!todos.loading && todos.open.length === 0 && <p className="empty">No open to-dos.</p>}
            {todos.open.slice(0, 5).map((r) => <TodoRowView key={r.id} r={r} busy={todos.busy} />)}
            {todos.error && <p className="empty error">{messageOf(todos.error)}</p>}
          </div>
          <button className="view-all" onClick={() => navigate("/family/todos")}>View All Tasks</button>
        </>
      )}
    </div>
  );
}

/* ------------------------------------------------------------------ Full lists */

export function AllPlans() {
  const { group } = useCurrentGroup();
  return group ? <AllPlansBody group={group} /> : null;
}

function AllPlansBody({ group }: { group: Group }) {
  const { rows, today, loading, error } = usePlans(group);
  const groups: Array<{ day: string; rows: PlanRow[] }> = [];
  for (const r of rows) {
    const g = groups[groups.length - 1];
    if (g && g.day === r.day) g.rows.push(r);
    else groups.push({ day: r.day, rows: [r] });
  }
  return (
    <>
      {loading && <p className="muted">Loading plans…</p>}
      {error && <p className="error">{messageOf(error)}</p>}
      {!loading && rows.length === 0 && <p className="card empty">Nothing planned in the next two weeks.</p>}
      {groups.map((g) => (
        <section key={g.day} className="stack tight">
          <div className="group-title"><span className="n">{dayName(g.day, today, group.time_zone)}</span><span className="d">{dayDate(g.day, group.time_zone)}</span></div>
          <div className="group-card">{g.rows.map((r) => <PlanRowView key={r.key} r={r} />)}</div>
        </section>
      ))}
    </>
  );
}

export function AllTasks() {
  const { group } = useCurrentGroup();
  return group ? <AllTasksBody group={group} /> : null;
}

function AllTasksBody({ group }: { group: Group }) {
  const todos = useTodos(group);
  return (
    <>
      <span className="eyebrow">OPEN · {todos.open.length}</span>
      <div className="group-card" style={{ padding: "4px 0" }}>
        {todos.loading && <p className="sched-empty">Loading…</p>}
        {!todos.loading && todos.open.length === 0 && <p className="sched-empty">Nothing open.</p>}
        {todos.open.map((r) => <TodoRowView key={r.id} r={r} busy={todos.busy} />)}
      </div>
      {todos.done.length > 0 && (
        <>
          <span className="eyebrow">DONE THIS WEEK</span>
          <div className="group-card flat" style={{ padding: "4px 0" }}>
            {todos.done.map((r) => <TodoRowView key={r.id} r={r} busy={todos.busy} />)}
          </div>
        </>
      )}
      {todos.error && <p className="error" role="alert">{messageOf(todos.error)}</p>}
    </>
  );
}
