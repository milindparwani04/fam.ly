import { formatWindow } from "@famly/domain";
import { useState } from "react";
import { Link } from "react-router";
import { DeleteCar } from "../components/DeleteCar";
import { ChevronRight, PlusIcon } from "../components/Icons";
import { useUserId } from "../lib/auth";
import { carDetails, carState, handoverWarning } from "../lib/cars";
import { useCarActivity, useCurrentGroup, useMembers, useVehicles } from "../lib/queries";
import { messageOf } from "../lib/rpc";
import { useUI } from "../lib/ui";

export function Cars() {
  const { group } = useCurrentGroup();
  if (!group) return null;
  return <CarsList groupId={group.id} timeZone={group.time_zone} />;
}

/** Cars (Stickers board): one card per active car with Now / Next, Book Car and Schedule; Add Car below. */
function CarsList({ groupId, timeZone }: { groupId: string; timeZone: string }) {
  const uid = useUserId();
  const ui = useUI();
  const vehicles = useVehicles(groupId);
  const activity = useCarActivity(groupId);
  const members = useMembers(groupId);
  const [showInactive, setShowInactive] = useState(false);

  if (vehicles.isPending || activity.isPending) return <div className="tab-screen tab-pad"><p>Loading cars…</p></div>;
  if (vehicles.isError) return <div className="tab-screen tab-pad"><p className="error">{messageOf(vehicles.error)}</p></div>;
  if (activity.isError) return <div className="tab-screen tab-pad"><p className="error">{messageOf(activity.error)}</p></div>;

  const now = new Date();
  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const nameOf = (id: string) => names.get(id) ?? "a former member";
  const firstName = (id: string) => (id === uid ? "You" : names.get(id)?.split(/\s+/)[0] ?? "Someone");
  const active = vehicles.data.filter((v) => v.active);
  const inactive = vehicles.data.filter((v) => !v.active);
  const cars = active.map((v) => ({ v, st: carState(v, activity.data, uid, firstName, now, timeZone) }));
  const free = cars.filter((c) => c.st.cls === "free").length;

  return (
    <div className="tab-screen tab-pad cars-tab">
      <div className="title-row" style={{ alignItems: "baseline" }}>
        <h1>Cars</h1>
        {cars.length > 0 && <span className="summary">{free === 0 ? "No cars free" : free === 1 ? "1 car free" : `${free} cars free`}</span>}
      </div>

      {cars.length === 0 && (
        <div className="card stack">
          <h2>No Cars Yet</h2>
          <p className="muted">Add the cars your family shares. A name is enough, no plate needed.</p>
        </div>
      )}

      {cars.map(({ v, st }) => {
        const details = carDetails(v.name);
        const next = st.next && st.next.id !== st.mineBookingId ? st.next : null;
        const warning = st.next ? handoverWarning(st.next.id, activity.data, { carName: v.name, nameOf, timeZone }, now) : null;
        return (
          <section key={v.id} className="card car-card">
            <div className="car-top">
              <Link to={`/cars/${v.id}`} className="car-head">
                <span className="name">{v.name}<span className="sr-only">, manage</span></span>
                <span className="detail">{details ?? "Tap to manage"}</span>
              </Link>
              <span className={`pill ${st.cls}`}>{st.label}</span>
            </div>
            <div className="now-next">
              <span className="k">NOW</span><span>{st.line}</span>
              <span className="k">NEXT</span>
              {next ? (
                <Link to={`/bookings/${next.id}`}>{firstName(next.ownerId)} · {formatWindow(next.startsAt, next.endsAt, now, timeZone)}</Link>
              ) : (
                <span>No upcoming bookings</span>
              )}
            </div>
            {warning && <p className="warn-text" role="status"><span aria-hidden="true">⚠ </span>{warning}</p>}
            <div className="car-btns">
              <button className="press" onClick={() => ui.open({ kind: "book", vehicleId: v.id })}>Book Car<span className="sr-only"> {v.name}</span></button>
              <button className="secondary press" onClick={() => ui.open({ kind: "schedule", vehicleId: v.id })}>Schedule · {st.count}</button>
            </div>
          </section>
        );
      })}

      <button className="add-car" onClick={() => ui.open({ kind: "addCar" })}><PlusIcon />Add Car</button>

      {inactive.length > 0 && (
        <div className="card rows-card flat">
          <button className="rowlink" onClick={() => setShowInactive(!showInactive)} aria-expanded={showInactive}>
            <span className="text"><span className="title">Inactive Cars ({inactive.length})</span></span>
            <ChevronRight className="icon chev" />
          </button>
          {showInactive && (
            <ul className="rows" style={{ borderTop: "1.5px solid var(--line)" }}>
              {inactive.map((v) => (
                <li key={v.id}>
                  <Link to={`/cars/${v.id}`} className="rowlink">
                    <span className="text"><span className="title">{v.name}</span><span className="sub">Inactive · Manage</span></span>
                    <ChevronRight className="icon chev" />
                  </Link>
                  <div style={{ padding: "0 14px 12px" }}><DeleteCar vehicleId={v.id} name={v.name} groupId={groupId} /></div>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
