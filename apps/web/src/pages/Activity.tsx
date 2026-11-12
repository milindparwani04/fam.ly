import { addDays, averageStars, dayBounds, formatMoment, formatTime, formatWindow, reviewPhase, wallDate } from "@famly/domain";
import { Link, useSearchParams } from "react-router";
import { Avatar } from "../components/Avatar";
import { Stars } from "../components/Stars";
import { useUserId } from "../lib/auth";
import { hasAccepted, useActivityFeed, useCurrentGroup, useMealHistory, useMembers } from "../lib/queries";
import { messageOf } from "../lib/rpc";
import { activityLabel } from "../lib/status";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;
export type FeedRow = NonNullable<ReturnType<typeof useActivityFeed>["data"]>[number];
type Data = {
  vehicle_name?: string;
  title?: string;
  reservation_id?: string;
  starts_at?: string;
  ends_at?: string;
  owner_id?: string;
  expected_return_at?: string;
  note?: string;
  undo?: string;
  reason?: string;
  has_house_key?: boolean;
  activity?: string;
  after?: { starts_at?: string; ends_at?: string };
  guests?: string;
  arrives?: string;
  leaves?: string;
  from_place?: string;
  plan_title?: string;
  place?: string;
};

export function Activity() {
  const { group } = useCurrentGroup();
  return group ? <ActivityFeed group={group} /> : null;
}

/** Activity tab (FR-N01, D11): every departure and return, and the changes around them. The page scrolls. */
function ActivityFeed({ group }: { group: Group }) {
  const [params, setParams] = useSearchParams();
  const show = params.get("show") === "meals" ? "meals" : "all";
  return (
    <div className="tab-screen activity-tab">
      <h1>Activity</h1>
      <div className="filters" role="group" aria-label="Show">
        <button aria-pressed={show === "all"} onClick={() => setParams({}, { replace: true })}>Everything</button>
        <button aria-pressed={show === "meals"} onClick={() => setParams({ show: "meals" }, { replace: true })}>Meals</button>
      </div>
      {show === "meals" ? <PastMeals group={group} /> : <Feed group={group} />}
    </div>
  );
}

/**
 * Past meals and how they were rated (founder, 2026-11-12). Until you rate a meal you were asked about,
 * the server hides others' ratings, so the row asks you to rate instead of showing a partial average.
 */
function PastMeals({ group }: { group: Group }) {
  const uid = useUserId();
  const tz = group.time_zone;
  const now = new Date();
  const meals = useMealHistory(group.id, wallDate(now, tz));
  const rows = (meals.data ?? []).filter((m) => reviewPhase(m.menu_date, now, tz) !== "before");
  const fmt = (d: string) => new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "short", day: "numeric", month: "short" })
    .format(dayBounds(d, tz).start).replace(",", "");
  return (
    <>
      {meals.isPending && <p>Loading…</p>}
      {meals.isError && <p className="error">{messageOf(meals.error)}</p>}
      {meals.data && rows.length === 0 && <p className="card empty">No past meals yet. Menus show here from 10pm on their day.</p>}
      {rows.length > 0 && (
        <div className="feed-card">
          {rows.map((m) => {
            const mine = m.menu_review.some((r) => r.user_id === uid);
            const waiting = reviewPhase(m.menu_date, now, tz) === "open" && hasAccepted(m, uid) && !mine;
            const avg = averageStars(m.menu_review.map((r) => r.stars));
            return (
              <Link key={m.id} to={`/family/menus/${m.id}`} className="meal-row">
                <span className="day">{fmt(m.menu_date)}</span>
                <span className="items">{m.items.split("\n").map((l) => l.trim()).filter(Boolean).join(", ")}</span>
                <span className="score">
                  {waiting ? <span className="pill mine">Rate It</span>
                    : avg === null ? <span className="n">No ratings</span>
                    : <><Stars value={avg} /><span className="n">{avg.toFixed(1)} · {m.menu_review.length} rating{m.menu_review.length === 1 ? "" : "s"}</span></>}
                </span>
              </Link>
            );
          })}
        </div>
      )}
      <p className="foot">Only people who accepted a menu rate it. Ratings are final once sent.</p>
    </>
  );
}

function Feed({ group }: { group: Group }) {
  const uid = useUserId();
  const feed = useActivityFeed(group.id);
  const members = useMembers(group.id);
  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const nameOf = (id: string | null | undefined) => (id === uid ? "You" : (id && names.get(id)) || "A former member");
  const now = new Date();
  const tz = group.time_zone;
  const days = groupByDay(feed.data ?? [], tz, now);

  return (
    <>
      {feed.isPending && <p>Loading…</p>}
      {feed.isError && <p className="error">{messageOf(feed.error)}</p>}
      {feed.data && feed.data.length === 0 && <p className="card empty">Nothing yet.</p>}
      {days.map(({ label, rows }) => (
        <section key={label} className="feed-group">
          <h2 className="eyebrow">{label}</h2>
          <div className="feed-card">
            {rows.map((row) => {
              const { text, link, warn } = describeActivity(row, nameOf, now, tz);
              const created = new Date(row.created_at);
              const body = (
                <>
                  <time className="when" dateTime={row.created_at} title={formatMoment(created, now, tz)}>{formatTime(created, tz)}</time>
                  <Avatar name={(row.actor_id && names.get(row.actor_id)) || "?"} size="md" />
                  <span className={`what${warn ? " warn" : ""}`}>{warn && <span aria-hidden="true">⚠ </span>}{text}</span>
                </>
              );
              return link
                ? <Link key={row.id} to={link} className="feed-row">{body}</Link>
                : <div key={row.id} className="feed-row">{body}</div>;
            })}
          </div>
        </section>
      ))}
      <p className="foot">Everyone in {group.name} sees this. Updates are self-reported, not tracked. No location tracking.</p>
    </>
  );
}

/** Feed rows (newest first) bucketed into Today / Yesterday / dated sections in the family's time zone. */
function groupByDay(rows: FeedRow[], tz: string, now: Date): Array<{ label: string; rows: FeedRow[] }> {
  const today = wallDate(now, tz);
  const out: Array<{ key: string; label: string; rows: FeedRow[] }> = [];
  for (const row of rows) {
    const created = new Date(row.created_at);
    const key = wallDate(created, tz);
    let bucket = out[out.length - 1];
    if (!bucket || bucket.key !== key) {
      const label = key === today ? "Today" : key === addDays(today, -1) ? "Yesterday"
        : new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "long", day: "numeric", month: "long" }).format(created);
      bucket = { key, label, rows: [] };
      out.push(bucket);
    }
    bucket.rows.push(row);
  }
  return out;
}

export function describeActivity(
  row: FeedRow,
  nameOf: (id: string | null | undefined) => string,
  now: Date,
  tz: string,
): { text: string; link: string | null; warn?: boolean } {
  const d = (row.data ?? {}) as Data;
  const who = nameOf(row.actor_id);
  const at = (iso?: string) => (iso ? formatMoment(new Date(iso), now, tz) : "?");
  const span = (s?: string, e?: string) => (s && e ? formatWindow(new Date(s), new Date(e), now, tz) : "");
  const what = d.vehicle_name ?? d.title ?? "an outing";
  const bookingLink = d.reservation_id ? `/bookings/${d.reservation_id}` : null;
  const resLink = row.subject_id ? `/bookings/${row.subject_id}` : null;
  const you = who === "You";
  const has = you ? "have" : "has";
  const is = you ? "are" : "is";
  const keyText = d.has_house_key === undefined ? ""
    : d.has_house_key ? ` · ${has} the house key`
    : ` · ${you ? "don't" : "doesn't"} have the house key`;
  const act = activityLabel(d.activity) ?? ([d.plan_title, d.place].filter(Boolean).join(" · ") || null);

  switch (row.kind) {
    case "presence.left":
      return { text: `${who} left the house${act ? ` · ${act}` : ""}${keyText}`, link: null };
    case "presence.home":
      return { text: `${who} ${is} home${act ? ` · back from ${act.toLowerCase()}` : ""}`, link: null };
    case "status.left":
      return { text: `${who} left the house${act ? ` · ${act}` : ""} · ${what}${keyText}`, link: bookingLink };
    case "status.home":
      return { text: `${who} ${is} home · ${what}`, link: bookingLink };
    case "status.home_and_car_returned":
      return { text: `${who} ${is} home · ${d.vehicle_name ?? "car"} returned`, link: bookingLink };
    case "status.eta_update":
      return { text: `${who} ${is} running late · expected back ${at(d.expected_return_at)}${d.note ? ` · “${d.note}”` : ""}`, link: bookingLink };
    case "status.issue":
      return { text: `${who} reported a problem${d.vehicle_name ? ` with ${d.vehicle_name}` : ""}${d.note ? ` · “${d.note}”` : ""}`, link: bookingLink, warn: true };
    case "status.correction":
      return { text: `${who} corrected an update (undid “${d.undo === "home" ? "I'm home" : "Left"}”)`, link: bookingLink };
    case "reservation.create":
      return { text: `${who} booked ${d.vehicle_name ?? "a car"} · ${span(d.starts_at, d.ends_at)}`, link: resLink };
    case "reservation.update":
      return { text: `${who} moved a ${d.vehicle_name ?? "car"} booking to ${span(d.after?.starts_at, d.after?.ends_at)}`, link: resLink };
    case "reservation.extend":
      return { text: `${who} extended a ${d.vehicle_name ?? "car"} booking to ${at(d.ends_at)}`, link: resLink };
    case "reservation.cancel":
      return { text: `${who} cancelled a ${d.vehicle_name ?? "car"} booking · ${span(d.starts_at, d.ends_at)}`, link: resLink };
    case "reservation.cancel_on_exit":
      return { text: `${nameOf(d.owner_id)}'s ${d.vehicle_name ?? "car"} booking was cancelled when they left`, link: resLink };
    case "reservation.override":
      return { text: `${who} cancelled ${nameOf(d.owner_id)}'s ${d.vehicle_name ?? "car"} booking${d.reason ? `: “${d.reason}”` : ""}`, link: resLink, warn: true };
    case "event.create":
      return { text: `${who} added ${d.title ?? "an event"} · ${span(d.starts_at, d.ends_at)}`, link: row.subject_id ? `/family/events/${row.subject_id}` : null };
    case "event.cancel":
      return { text: `${who} cancelled ${d.title ?? "an event"}`, link: row.subject_id ? `/family/events/${row.subject_id}` : null };
    case "task.complete":
      return { text: `${who} completed a task · ${d.title ?? "untitled"}`, link: row.subject_id ? `/family/tasks/${row.subject_id}` : null };
    case "task.reopen":
      return { text: `${who} reopened a task · ${d.title ?? "untitled"}`, link: row.subject_id ? `/family/tasks/${row.subject_id}` : null };
    case "stay.create":
    case "stay.update":
    case "stay.cancel": {
      const verb = row.kind === "stay.create" ? "added a stay" : row.kind === "stay.update" ? "changed a stay" : "cancelled a stay";
      const dates = d.arrives && d.leaves ? `${shortDay(d.arrives, tz)} – ${shortDay(d.leaves, tz)}` : "";
      return {
        text: [`${who} ${verb}`, d.guests, d.from_place ? `from ${d.from_place}` : null, dates].filter(Boolean).join(" · "),
        link: row.kind === "stay.cancel" ? null : row.subject_id ? `/family/stays/${row.subject_id}` : null,
      };
    }
    case "member.join":
      return { text: `${who} joined the family`, link: null };
    case "member.leave":
      return { text: `${nameOf(row.subject_id)} left the family`, link: null };
    case "member.remove":
      return { text: `${who} removed ${nameOf(row.subject_id)}${d.reason ? `: “${d.reason}”` : ""}`, link: null };
    case "vehicle.unavailability.add":
      return { text: `${who} put ${d.vehicle_name ?? "a car"} into maintenance`, link: null };
    default:
      return { text: `${who}: ${row.kind}`, link: null };
  }
}

function shortDay(date: string, tz: string) {
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, day: "numeric", month: "short" }).format(dayBounds(date, tz).start);
}
