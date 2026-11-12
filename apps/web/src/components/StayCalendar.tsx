import { addDays, dayBounds, stayOverlaps, wallDate } from "@famly/domain";
import { useState } from "react";
import { Link } from "react-router";
import { useStays } from "../lib/queries";
import { messageOf } from "../lib/rpc";
import { nights, stayDay, stayGuests } from "../pages/Stays";
import { ChevronLeft, ChevronRight, PlusIcon } from "./Icons";

const COLORS = ["sky", "mint", "lilac", "sun", "tomato"] as const;
const DOW = ["M", "T", "W", "T", "F", "S", "S"];

function monthStart(date: string) {
  return `${date.slice(0, 7)}-01`;
}
function shiftMonth(first: string, n: number) {
  const [y, m] = first.split("-").map(Number) as [number, number];
  return new Date(Date.UTC(y, m - 1 + n, 1)).toISOString().slice(0, 10);
}
/** Monday-first grid of whole weeks covering the month. */
function gridDays(first: string): string[] {
  const dow = (new Date(`${first}T12:00:00Z`).getUTCDay() + 6) % 7;
  const start = addDays(first, -dow);
  const last = addDays(shiftMonth(first, 1), -1);
  const days: string[] = [];
  for (let d = start; d <= last || days.length % 7 !== 0; d = addDays(d, 1)) days.push(d);
  return days;
}

/**
 * Stays (founder, 2026-11-12): who's staying with the family and when. Each stay is a coloured bar across
 * its days. Tap a day to see who's here that day; tap a second day to pick a range ("who's here 20–27 Nov?").
 * Tapping again starts a new pick. The list under the month scrolls inside its card.
 */
export function StayCalendar({ groupId, timeZone }: { groupId: string; timeZone: string }) {
  const today = wallDate(new Date(), timeZone);
  const [month, setMonth] = useState(monthStart(today));
  const [range, setRange] = useState<{ from: string; to: string; picking: boolean } | null>(null);
  const days = gridDays(month);
  const stays = useStays(groupId, days[0]! < today ? days[0]! : today);
  const all = stays.data ?? [];
  const colorOf = new Map(all.map((s, i) => [s.id, COLORS[i % COLORS.length]!]));
  const monthName = new Intl.DateTimeFormat("en-GB", { timeZone, month: "long", year: "numeric" }).format(dayBounds(month, timeZone).start);

  function tap(day: string) {
    if (range?.picking && day >= range.from) setRange({ from: range.from, to: day, picking: false });
    else setRange({ from: day, to: day, picking: true });
  }

  const shown = range ? all.filter((s) => stayOverlaps(s, range.from, range.to)) : all.filter((s) => s.leaves >= today);
  const heading = !range ? "Upcoming stays"
    : range.from === range.to ? `Here on ${stayDay(range.from, timeZone)}`
    : `Here ${stayDay(range.from, timeZone)} – ${stayDay(range.to, timeZone)}`;

  return (
    <>
      <div className="month">
        <div className="month-head">
          <button className="sq-btn" aria-label="Previous month" onClick={() => setMonth(shiftMonth(month, -1))}><ChevronLeft /></button>
          <span className="name">{monthName}</span>
          <button className="sq-btn" aria-label="Next month" onClick={() => setMonth(shiftMonth(month, 1))}><ChevronRight /></button>
        </div>
        <div className="month-grid" role="grid" aria-label={`${monthName}. Tap a day, then another, to pick a range.`}>
          {DOW.map((d, i) => <span key={i} className="dow" aria-hidden="true">{d}</span>)}
          {days.map((d) => {
            const here = all.filter((s) => s.arrives <= d && s.leaves >= d);
            const inRange = range && d >= range.from && d <= range.to;
            const label = new Intl.DateTimeFormat("en-GB", { timeZone, weekday: "long", day: "numeric", month: "long" }).format(dayBounds(d, timeZone).start);
            return (
              <button key={d} role="gridcell" aria-selected={!!inRange}
                      aria-label={`${label}${here.length ? `, ${here.map(stayGuests).join("; ")} staying` : ""}`}
                      className={`mday${d.slice(0, 7) !== month.slice(0, 7) ? " other" : ""}${d === today ? " today" : ""}${inRange ? " sel" : ""}${range && (d === range.from || d === range.to) ? " end" : ""}`}
                      onClick={() => tap(d)}>
                <span className="num">{Number(d.slice(8))}</span>
                <span className="bars" aria-hidden="true">
                  {here.slice(0, 3).map((s) => (
                    <span key={s.id} className={`bar ${colorOf.get(s.id)}${s.arrives === d ? " start" : ""}${s.leaves === d ? " finish" : ""}`} />
                  ))}
                </span>
              </button>
            );
          })}
        </div>
      </div>
      <div className="stays-head">
        <span className="t">{heading}</span>
        {range ? <button className="link" onClick={() => setRange(null)}>Clear</button>
          : <span className="hint">Tap two days for a range</span>}
      </div>
      <div className="list-card">
        {stays.isPending && <p className="empty">Loading stays…</p>}
        {stays.error && <p className="empty error">{messageOf(stays.error)}</p>}
        {!stays.isPending && shown.length === 0 && <p className="empty">{range ? "Nobody staying then." : "No stays coming up."}</p>}
        {shown.map((s) => {
          const n = nights(s.arrives, s.leaves);
          return (
            <Link key={s.id} to={`/family/stays/${s.id}`} className="stay-row">
              <span className={`swatch ${colorOf.get(s.id)}`} aria-hidden="true" />
              <span className="mid">
                <span className="title">{stayGuests(s)}</span>
                <span className="sub">
                  {stayDay(s.arrives, timeZone)} → {stayDay(s.leaves, timeZone)} · {n === 0 ? "day visit" : `${n} night${n === 1 ? "" : "s"}`}
                  {s.from_place ? ` · from ${s.from_place}` : ""}
                </span>
              </span>
              <ChevronRight />
            </Link>
          );
        })}
      </div>
      <Link className="button block view-all add-stay press"
            to={range ? `/family/stays/new?from=${range.from}&to=${range.to === range.from ? addDays(range.from, 3) : range.to}` : "/family/stays/new"}>
        <PlusIcon />{range && range.from !== range.to ? "Add Stay For These Days" : "Add Stay"}
      </Link>
    </>
  );
}
