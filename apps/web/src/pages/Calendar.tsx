import {
  addDays,
  dayBounds,
  formatTime,
  segmentsForDay,
  wallDate,
  type DaySegment,
  type Interval,
} from "@famly/domain";
import { useEffect, useRef, useState } from "react";
import { Link } from "react-router";
import { ChevronLeft, ChevronRight, PlusIcon } from "../components/Icons";
import { useCalendar, useCurrentGroup, useMembers, useVehicles } from "../lib/queries";
import { messageOf } from "../lib/rpc";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

interface Item extends Interval {
  id: string;
  kind: "booking" | "maintenance";
  vehicleId: string;
  label: string;
  out: boolean;
}

export function Calendar() {
  const { group } = useCurrentGroup();
  return group ? <CalendarBody group={group} /> : null;
}

function CalendarBody({ group }: { group: Group }) {
  const tz = group.time_zone;
  const today = wallDate(new Date(), tz);
  const [mode, setMode] = useState<"day" | "week">("day");
  const [date, setDate] = useState(today);

  const days = mode === "day" ? [date] : Array.from({ length: 7 }, (_, i) => addDays(date, i));
  const range = { start: dayBounds(days[0]!, tz).start, end: dayBounds(days[days.length - 1]!, tz).end };

  const vehicles = useVehicles(group.id);
  const members = useMembers(group.id);
  const cal = useCalendar(group.id, range.start, range.end);

  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const carNames = new Map(vehicles.data?.map((v) => [v.id, v.name]));
  const items: Item[] = [
    ...(cal.data?.bookings ?? []).map((b) => ({
      id: b.id,
      kind: "booking" as const,
      vehicleId: b.vehicle_id,
      startsAt: new Date(b.starts_at!),
      endsAt: new Date(b.ends_at!),
      label: names.get(b.owner_id) ?? "Former member",
      out: b.status === "in_use_reported",
    })),
    ...(cal.data?.maintenance ?? []).map((m) => ({
      id: m.id,
      kind: "maintenance" as const,
      vehicleId: m.vehicle_id,
      startsAt: new Date(m.starts_at!),
      endsAt: new Date(m.ends_at!),
      label: m.reason ? `Maintenance · ${m.reason}` : "Maintenance",
      out: false,
    })),
  ];
  const cars = vehicles.data?.filter((v) => v.active || items.some((i) => i.vehicleId === v.id)) ?? [];
  const step = mode === "day" ? 1 : 7;

  return (
    <div className="stack screen">
      <div className="segmented full" role="group" aria-label="View">
        <button className={mode === "day" ? "on" : ""} aria-pressed={mode === "day"} onClick={() => setMode("day")}>Day</button>
        <button className={mode === "week" ? "on" : ""} aria-pressed={mode === "week"} onClick={() => setMode("week")}>Week</button>
      </div>
      <div className="datebar">
        <button className="iconbtn" aria-label={mode === "day" ? "Previous day" : "Previous week"} onClick={() => setDate(addDays(date, -step))}>
          <ChevronLeft className="icon" />
        </button>
        <strong aria-live="polite">
          {mode === "day" ? longDate(date, tz) : `${dayTitle(days[0]!, today, tz)} – ${dayTitle(days[6]!, today, tz)}`}
        </strong>
        <button className="iconbtn" aria-label={mode === "day" ? "Next day" : "Next week"} onClick={() => setDate(addDays(date, step))}>
          <ChevronRight className="icon" />
        </button>
      </div>
      {mode === "day" && <WeekStrip date={date} today={today} tz={tz} onPick={setDate} />}
      {date !== today && <button className="link" onClick={() => setDate(today)}>Back To Today</button>}

      {cal.isPending && <p>Loading…</p>}
      {cal.isError && <p className="error">{messageOf(cal.error)}</p>}
      {cal.data && mode === "day" && (
        <DayView date={date} tz={tz} cars={cars} items={items} carNames={carNames} isToday={date === today} />
      )}
      {cal.data && mode === "week" && (
        <div className="subscroll stack">
          {days.map((d) => (
            <section key={d} className="card stack">
              <h2>{dayTitle(d, today, tz)}</h2>
              <SegmentList segments={segmentsForDay(items, dayBounds(d, tz))} tz={tz} carNames={carNames} />
            </section>
          ))}
        </div>
      )}
      <Link className="button block" to="/book"><PlusIcon className="icon" />New Booking</Link>
    </div>
  );
}

function longDate(date: string, tz: string): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "short", day: "numeric", month: "long", year: "numeric" })
    .format(dayBounds(date, tz).start);
}

/** Monday–Sunday of the week containing `date`; tapping a day jumps to it. Today is marked in words for screen readers. */
function WeekStrip(props: { date: string; today: string; tz: string; onPick: (d: string) => void }) {
  const fmt = (d: string, o: Intl.DateTimeFormatOptions) =>
    new Intl.DateTimeFormat("en-GB", { timeZone: props.tz, ...o }).format(dayBounds(d, props.tz).start);
  const weekday = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(fmt(props.date, { weekday: "short" }));
  const monday = addDays(props.date, -Math.max(weekday, 0));
  const week = Array.from({ length: 7 }, (_, i) => addDays(monday, i));
  return (
    <div className="week-strip" role="group" aria-label="Choose a day">
      {week.map((d) => (
        <button key={d} className={`${d === props.date ? "on" : ""} ${d === props.today ? "today" : ""}`}
                aria-pressed={d === props.date} onClick={() => props.onPick(d)}
                aria-label={`${fmt(d, { weekday: "long", day: "numeric", month: "long" })}${d === props.today ? ", today" : ""}`}>
          <span className="num">{fmt(d, { day: "numeric" })}</span>
          <span className="dow">{fmt(d, { weekday: "short" })}</span>
        </button>
      ))}
    </div>
  );
}

function dayTitle(date: string, today: string, tz: string): string {
  if (date === today) return "Today";
  if (date === addDays(today, 1)) return "Tomorrow";
  if (date === addDays(today, -1)) return "Yesterday";
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "short", day: "numeric", month: "short" })
    .format(dayBounds(date, tz).start);
}

function DayView(props: {
  date: string;
  tz: string;
  cars: Array<{ id: string; name: string }>;
  items: Item[];
  carNames: Map<string, string>;
  isToday: boolean;
}) {
  const bounds = dayBounds(props.date, props.tz);
  const span = bounds.end.getTime() - bounds.start.getTime();
  const nowPos = (Date.now() - bounds.start.getTime()) / span;
  const all = segmentsForDay(props.items, bounds);
  const time = (d: Date) => formatTime(d, props.tz);
  const scroller = useRef<HTMLDivElement>(null);

  // Open on the part of the day that matters: an hour before now (today) or before the first booking.
  useEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const first = all.length ? Math.min(...all.map((s) => s.from)) : 8 / 24;
    const focus = props.isToday && nowPos > 0 && nowPos < 1 ? Math.min(nowPos, first) : first;
    el.scrollTop = Math.max(0, focus * 24 - 1) * HOUR_PX;
  }, [props.date]);

  return (
    <section className="dayview" aria-label="Bookings by car">
      <div className="dayview-head" style={{ gridTemplateColumns: `48px repeat(${props.cars.length}, 1fr)` }}>
        <span />
        {props.cars.map((car) => {
          const free = !all.some((s) => s.item.vehicleId === car.id);
          return (
            <span key={car.id} className="dayview-car">
              <strong>{car.name}</strong>
              <span className="muted">{free ? "Available all day" : `${all.filter((s) => s.item.vehicleId === car.id).length} booked`}</span>
            </span>
          );
        })}
      </div>
      <div className="dayview-scroll" ref={scroller}>
        <div className="dayview-grid" style={{ gridTemplateColumns: `48px repeat(${props.cars.length}, 1fr)`, height: 24 * HOUR_PX }}>
          <div className="hours" aria-hidden="true">
            {Array.from({ length: 25 }, (_, h) => (
              <span key={h} style={{ top: h * HOUR_PX }}>{String(h % 24).padStart(2, "0")}:00</span>
            ))}
          </div>
          {props.cars.map((car) => (
            <div key={car.id} className="lane">
              {all.filter((s) => s.item.vehicleId === car.id).map((s) => {
                const overdue = s.item.out && s.item.endsAt < new Date();
                const range = `${s.continuesFromPreviousDay ? "↤ " : ""}${time(s.start)} – ${s.continuesToNextDay ? "00:00 ↦" : time(s.end)}`;
                const body = (
                  <>
                    <strong>{s.item.label}</strong>
                    <span>{range}</span>
                    {overdue && <span className="warn-text">⚠ Overdue · not confirmed back</span>}
                    {s.item.out && !overdue && <span>Out now</span>}
                  </>
                );
                // Height follows the duration but never less than the text needs (short bookings grow).
                const style = { top: s.from * 24 * HOUR_PX, minHeight: Math.max((s.to - s.from) * 24 * HOUR_PX, 30) };
                const cls = `cal-block ${s.item.kind}${s.item.out ? " out" : ""}`;
                const label = `${car.name}, ${s.item.label}, ${range}${overdue ? ", overdue, not confirmed back" : s.item.out ? ", out now" : ""}`;
                return s.item.kind === "booking"
                  ? <Link key={s.item.id} to={`/bookings/${s.item.id}`} className={cls} style={style} aria-label={label}>{body}</Link>
                  : <div key={s.item.id} className={cls} style={style} role="note" aria-label={label}>{body}</div>;
              })}
            </div>
          ))}
          {props.isToday && nowPos > 0 && nowPos < 1 && (
            <div className="nowline" style={{ top: nowPos * 24 * HOUR_PX }} aria-hidden="true" />
          )}
        </div>
      </div>
      {props.cars.length === 0 && <p className="muted">No cars yet.</p>}
    </section>
  );
}

const HOUR_PX = 48;

function SegmentList(props: { segments: DaySegment<Item>[]; tz: string; carNames: Map<string, string> }) {
  if (props.segments.length === 0) return <p className="muted">Nothing booked.</p>;
  const time = (d: Date) => formatTime(d, props.tz);
  return (
    <ul className="list">
      {props.segments.map((s) => {
        const text = (
          <>
            <strong>
              {s.continuesFromPreviousDay ? "↤ " : ""}
              {time(s.start)}–{s.continuesToNextDay ? "24:00" : time(s.end)}
              {s.continuesToNextDay ? " ↦" : ""}
            </strong>{" "}
            {props.carNames.get(s.item.vehicleId) ?? "Car"} · {s.item.label}
            {s.item.out && (s.item.endsAt < new Date()
              ? <span className="warn-text"> ⚠ overdue · not confirmed back</span>
              : <span className="muted"> · out now</span>)}
            {(s.continuesFromPreviousDay || s.continuesToNextDay) && (
              <span className="muted">
                {" "}({s.continuesFromPreviousDay ? "from the day before" : ""}
                {s.continuesFromPreviousDay && s.continuesToNextDay ? ", " : ""}
                {s.continuesToNextDay ? "continues next day" : ""})
              </span>
            )}
          </>
        );
        return (
          <li key={s.item.id}>
            {s.item.kind === "booking" ? <Link to={`/bookings/${s.item.id}`} className="plain">{text}</Link> : text}
          </li>
        );
      })}
    </ul>
  );
}
