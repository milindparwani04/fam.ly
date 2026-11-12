import { addDays, averageStars, dayBounds, formatMoment, reviewPhase, reviewWindow, wallDate } from "@famly/domain";
import { useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Link, useParams } from "react-router";
import { useUserId } from "../lib/auth";
import { RateForm } from "../components/RateSheet";
import { Stars } from "../components/Stars";
import { hasAccepted, useAction, useCurrentGroup, useFamilyMenu, useMembers, useMenuReviews } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

/** "Today", "Tomorrow", or e.g. "Wed 29 October", for a menu's YYYY-MM-DD day. */
export function menuDay(date: string, today: string, tz: string): string {
  if (date === today) return "Today";
  if (date === addDays(today, 1)) return "Tomorrow";
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "short", day: "numeric", month: "long" })
    .format(dayBounds(date, tz).start);
}

/** "How Was Tonight's Food?" / "Yesterday's" / "Tuesday's" for a rating prompt. */
export function rateTitle(date: string, today: string, tz: string): string {
  const when = date === today ? "Tonight" : date === addDays(today, -1) ? "Yesterday"
    : new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "long" }).format(dayBounds(date, tz).start);
  return `How Was ${when}'s Food?`;
}

export function MenuDetail() {
  const { group } = useCurrentGroup();
  return group ? <MenuBody group={group} /> : null;
}

/**
 * One menu. Everyone but its latest author is asked to Accept or Modify; a modification is a new
 * version that everyone is asked about again. Everyone sees who has accepted the current version.
 */
function MenuBody({ group }: { group: Group }) {
  const { menuId = "" } = useParams();
  const tz = group.time_zone;
  const uid = useUserId();
  const qc = useQueryClient();
  const menu = useFamilyMenu(menuId);
  const members = useMembers(group.id);
  const reviews = useMenuReviews(menuId);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const keys = [["family-menu", menuId], ["family-menus", group.id]];
  // Someone else changed it first: show them the latest so they never accept or overwrite blind.
  const refreshOnStale = () => void qc.invalidateQueries({ queryKey: ["family-menu", menuId] });

  const accept = useAction(
    async (version: number) => unwrap(await supabase.rpc("rpc_accept_menu", { p_menu_id: menuId, p_version: version })),
    keys,
  );
  const modify = useAction(
    async (version: number) =>
      unwrap(await supabase.rpc("rpc_modify_menu", { p_menu_id: menuId, p_items: draft, p_version: version })),
    keys,
  );

  if (menu.isPending) return <p>Loading…</p>;
  if (menu.isError) return <p className="error">{messageOf(menu.error)}</p>;
  if (!menu.data) {
    return (
      <div className="stack">
        <p>That menu isn&apos;t in {group.name}.</p>
        <Link to="/family">Back To Plans</Link>
      </div>
    );
  }

  const m = menu.data;
  const now = new Date();
  const today = wallDate(now, tz);
  const phase = reviewPhase(m.menu_date, now, tz);
  const past = m.menu_date < today || phase !== "before";
  const names = new Map(members.data?.map((x) => [x.user_id, x.display_name]));
  const nameOf = (id: string | null) => (id === uid ? "you" : (id && names.get(id)) || "a former member");
  const iAccepted = hasAccepted(m, uid);
  const changed = m.version > 1 && m.updated_by !== m.created_by;

  function save(e: FormEvent) {
    e.preventDefault();
    modify.mutate(m.version, { onSuccess: () => setEditing(false), onError: refreshOnStale });
  }

  return (
    <div className="stack">
      <section className="card stack">
        <span className="eyebrow">Menu · {menuDay(m.menu_date, today, tz)}</span>
        {!editing && <p className="pre">{m.items}</p>}
        <p className="muted">
          Proposed by {nameOf(m.created_by)}
          {changed && ` · changed by ${nameOf(m.updated_by)} ${formatMoment(new Date(m.updated_at), now, tz)}`}
        </p>
      </section>

      {editing ? (
        <form onSubmit={save} className="card stack">
          <h2>Modify Menu</h2>
          <label>
            <span className="sr-only">Menu</span>
            <textarea required maxLength={2000} rows={6} value={draft} onChange={(e) => setDraft(e.target.value)} />
          </label>
          <p className="muted">Everyone else is notified with the new menu and asked to accept it.</p>
          {modify.error && <p className="error" role="alert">{messageOf(modify.error)}</p>}
          <button type="submit" disabled={modify.isPending || !draft.trim() || draft.trim() === m.items}>
            {modify.isPending ? "Saving…" : "Send Modified Menu"}
          </button>
          <button type="button" className="secondary" onClick={() => setEditing(false)}>Cancel</button>
        </form>
      ) : (
        !past && (
          <div className="stack">
            {iAccepted ? (
              <p className="chip ok"><span className="glyph" aria-hidden="true">✓</span><span>You&apos;ve accepted this menu</span></p>
            ) : (
              <button className="big-action" disabled={accept.isPending}
                      onClick={() => accept.mutate(m.version, { onError: refreshOnStale })}>
                {accept.isPending ? "Saving…" : "Accept"}
              </button>
            )}
            <button className="secondary" onClick={() => { setDraft(m.items); modify.reset(); setEditing(true); }}>
              Modify
            </button>
            {accept.error && <p className="error" role="alert">{messageOf(accept.error)}</p>}
          </div>
        )
      )}

      {phase !== "before" && (
        <Ratings menuDate={m.menu_date} tz={tz} now={now} canRate={phase === "open" && iAccepted && !reviews.data?.some((r) => r.user_id === uid)}
                 iAccepted={iAccepted} groupId={group.id} menuId={m.id} reviews={reviews.data ?? []} loading={reviews.isPending}
                 nameOf={(id) => (id === uid ? "You" : names.get(id) ?? "A former member")} />
      )}

      <section className="card stack">
        <h2>Accepted</h2>
        <ul className="list">
          {(members.data ?? []).map((x) => {
            const yes = hasAccepted(m, x.user_id);
            return (
              <li key={x.user_id} className="row">
                <span>{x.user_id === uid ? "You" : x.display_name}</span>
                {yes ? <span className="badge">✓ Accepted</span> : <span className="muted">{past ? "Didn't accept" : "Not yet"}</span>}
              </li>
            );
          })}
        </ul>
        {m.version > 1 && <p className="muted">Only acceptances of the latest version count.</p>}
      </section>
    </div>
  );
}

/**
 * Ratings (founder, 2026-11-12). People who accepted rate from 22:00 for 48 hours; until you rate, others'
 * ratings stay hidden (the server only returns them once you have, or if you weren't asked).
 */
function Ratings(props: {
  menuDate: string; tz: string; now: Date; canRate: boolean; iAccepted: boolean; groupId: string; menuId: string;
  reviews: Array<{ user_id: string; stars: number; comment: string | null }>; loading: boolean; nameOf: (id: string) => string;
}) {
  const avg = averageStars(props.reviews.map((r) => r.stars));
  const closes = reviewWindow(props.menuDate, props.tz).closes;
  const open = props.now < closes;
  if (props.canRate) {
    return (
      <section className="card stack">
        <h2>How Was It?</h2>
        <RateForm groupId={props.groupId} menuId={props.menuId} onDone={() => undefined} />
      </section>
    );
  }
  return (
    <section className="card stack">
      <div className="row">
        <h2>Ratings</h2>
        {avg !== null && <span className="meal-avg"><Stars value={avg} />{avg.toFixed(1)}</span>}
      </div>
      {props.loading && <p className="muted">Loading…</p>}
      {!props.loading && props.reviews.length === 0 && (
        <p className="muted">{open ? "Nobody has rated it yet." : "Nobody rated it."}</p>
      )}
      <div>
        {props.reviews.map((r) => (
          <div key={r.user_id} className="review-row">
            <span className="rv-who">{props.nameOf(r.user_id)}<Stars value={r.stars} small /></span>
            {r.comment && <p className="comment">{r.comment}</p>}
          </div>
        ))}
      </div>
      {open && <p className="muted" style={{ fontSize: 13 }}>
        {props.iAccepted ? "Rating" : "Rating by everyone who accepted"} is open until{" "}
        {new Intl.DateTimeFormat("en-GB", { timeZone: props.tz, weekday: "short", hour: "2-digit", minute: "2-digit" }).format(closes)}.
      </p>}
    </section>
  );
}
