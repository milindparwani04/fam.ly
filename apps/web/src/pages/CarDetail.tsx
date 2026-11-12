import { formatWindow, wallTimeToUtc } from "@famly/domain";
import { useState, type FormEvent } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { DeleteCar } from "../components/DeleteCar";
import { StatusChip } from "../components/StatusChip";
import { carView } from "../lib/cars";
import { useAction, useCarActivity, useCurrentGroup, useMembers, useVehicles } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

export function CarDetail() {
  const { group } = useCurrentGroup();
  return group ? <CarDetailBody group={group} /> : null;
}

function CarDetailBody({ group }: { group: Group }) {
  const { vehicleId = "" } = useParams();
  const navigate = useNavigate();
  const vehicles = useVehicles(group.id);
  const activity = useCarActivity(group.id);
  const members = useMembers(group.id);

  if (vehicles.isPending || activity.isPending) return <p>Loading…</p>;
  if (vehicles.isError) return <p className="error">{messageOf(vehicles.error)}</p>;
  if (activity.isError) return <p className="error">{messageOf(activity.error)}</p>;

  const vehicle = vehicles.data.find((v) => v.id === vehicleId);
  if (!vehicle) {
    return (
      <div className="stack">
        <p>That car isn&apos;t in {group.name}.</p>
        <Link to="/cars">Back To Cars</Link>
      </div>
    );
  }

  const now = new Date();
  const tz = group.time_zone;
  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const nameOf = (id: string) => names.get(id) ?? "a former member";
  const view = carView(vehicle, activity.data, now);
  const upcoming = view.bookings.filter((b) => b.status !== "completed");
  const flagged = new Set(activity.data.bookings.filter((b) => b.needs_reconciliation).map((b) => b.id));
  const groupKeys = [["vehicles", group.id], ["car-activity", group.id]];

  return (
    <div className="stack">
      <section className="card stack">
        <h2>{vehicle.name}</h2>
        <StatusChip state={view.state} nameOf={nameOf} now={now} timeZone={tz} />
      </section>

      <section className="card stack">
        <h2>Upcoming Bookings</h2>
        {upcoming.length === 0 ? (
          <p className="muted">None.</p>
        ) : (
          <ul className="list">
            {upcoming.map((b) => (
              <li key={b.id} className="stack">
                <span>
                  {formatWindow(b.startsAt, b.endsAt, now, tz)} · {nameOf(b.ownerId)}
                  {b.status === "in_use_reported" && <span className="muted"> · reported out</span>}
                </span>
                {flagged.has(b.id) && (
                  <span className="warn-text">
                    <span aria-hidden="true">⚠ </span>
                    {vehicle.active ? "Clashes with maintenance" : "Car is inactive"}. {nameOf(b.ownerId)} should
                    move or cancel this booking.
                  </span>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      {vehicle.active && (
        <Maintenance vehicleId={vehicle.id} windows={view.maintenance} now={now} timeZone={tz} invalidate={groupKeys} />
      )}
      <Rename groupId={group.id} vehicleId={vehicle.id} current={vehicle.name} invalidate={groupKeys} />
      <ActiveToggle vehicleId={vehicle.id} active={vehicle.active} invalidate={groupKeys} />
      {!vehicle.active && (
        <section className="card stack">
          <DeleteCar vehicleId={vehicle.id} name={vehicle.name} groupId={group.id} onDeleted={() => navigate("/cars", { replace: true })} />
        </section>
      )}
    </div>
  );
}

function Maintenance(props: {
  vehicleId: string;
  windows: ReturnType<typeof carView>["maintenance"];
  now: Date;
  timeZone: string;
  invalidate: string[][];
}) {
  const [start, setStart] = useState("");
  const [end, setEnd] = useState("");
  const [reason, setReason] = useState("");
  const add = useAction(
    async () =>
      unwrap(
        await supabase.rpc("rpc_add_unavailability", {
          p_vehicle_id: props.vehicleId,
          p_starts_at: wallTimeToUtc(start, props.timeZone).toISOString(),
          p_ends_at: wallTimeToUtc(end, props.timeZone).toISOString(),
          p_reason: reason,
        }),
      ),
    props.invalidate,
  );
  const remove = useAction(
    async (id: string) => unwrap(await supabase.rpc("rpc_remove_unavailability", { p_unavailability_id: id })),
    props.invalidate,
  );

  function submit(e: FormEvent) {
    e.preventDefault();
    add.mutate(undefined, {
      onSuccess: () => {
        setStart("");
        setEnd("");
        setReason("");
      },
    });
  }

  return (
    <section className="card stack">
      <h2>Maintenance</h2>
      <p className="muted">
        While a car is in maintenance it can&apos;t be booked. Existing bookings that clash are flagged for their
        owner, not cancelled.
      </p>
      {props.windows.length > 0 && (
        <ul className="list">
          {props.windows.map((m) => (
            <li key={m.id} className="row">
              <span>
                {formatWindow(m.startsAt, m.endsAt, props.now, props.timeZone)}
                {m.reason && <span className="muted"> · {m.reason}</span>}
              </span>
              <button className="link danger" disabled={remove.isPending} onClick={() => remove.mutate(m.id)}>
                Remove
              </button>
            </li>
          ))}
        </ul>
      )}
      {remove.error && <p className="error">{messageOf(remove.error)}</p>}
      <form onSubmit={submit} className="stack inset">
        <h3>Add Maintenance <span className="muted">({props.timeZone})</span></h3>
        <label>
          From
          <input type="datetime-local" required value={start} onChange={(e) => setStart(e.target.value)} />
        </label>
        <label>
          Until
          <input type="datetime-local" required value={end} min={start} onChange={(e) => setEnd(e.target.value)} />
        </label>
        <label>
          <span>Reason <span className="muted">(optional)</span></span>
          <input maxLength={200} placeholder="e.g. Service at the dealer" value={reason}
                 onChange={(e) => setReason(e.target.value)} />
        </label>
        {add.error && <p className="error" role="alert">{messageOf(add.error)}</p>}
        <button type="submit" disabled={add.isPending || !start || !end}>Add Maintenance</button>
      </form>
    </section>
  );
}

function Rename(props: { groupId: string; vehicleId: string; current: string; invalidate: string[][] }) {
  const [name, setName] = useState(props.current);
  const rename = useAction(
    async () =>
      unwrap(
        await supabase.rpc("rpc_upsert_vehicle", {
          p_group_id: props.groupId,
          p_name: name,
          p_vehicle_id: props.vehicleId,
        }),
      ),
    props.invalidate,
  );
  function submit(e: FormEvent) {
    e.preventDefault();
    rename.mutate(undefined);
  }
  return (
    <form onSubmit={submit} className="card stack">
      <h2>Name</h2>
      <label>
        Car name
        <input required maxLength={60} value={name} onChange={(e) => setName(e.target.value)} />
      </label>
      {rename.error && <p className="error" role="alert">{messageOf(rename.error)}</p>}
      {rename.isSuccess && <p className="muted" role="status">Saved.</p>}
      <button type="submit" disabled={rename.isPending || !name.trim() || name.trim() === props.current}>
        Save Name
      </button>
    </form>
  );
}

function ActiveToggle(props: { vehicleId: string; active: boolean; invalidate: string[][] }) {
  const [confirming, setConfirming] = useState(false);
  const toggle = useAction(
    async () =>
      unwrap(await supabase.rpc("rpc_set_vehicle_active", { p_vehicle_id: props.vehicleId, p_active: !props.active })),
    props.invalidate,
  );

  if (!props.active) {
    return (
      <section className="card stack">
        <h2>Inactive</h2>
        <p className="muted">This car can&apos;t be booked.</p>
        {toggle.error && <p className="error">{messageOf(toggle.error)}</p>}
        <button disabled={toggle.isPending} onClick={() => toggle.mutate(undefined)}>Reactivate Car</button>
      </section>
    );
  }
  return (
    <section className="card stack">
      <h2>Deactivate</h2>
      {!confirming ? (
        <button className="secondary" onClick={() => setConfirming(true)}>Deactivate Car…</button>
      ) : (
        <div className="stack inset">
          <p>
            For a car that&apos;s sold or off the road. It can&apos;t be booked, and its upcoming bookings are flagged
            for their owners. You can reactivate it later.
          </p>
          {toggle.error && <p className="error" role="alert">{messageOf(toggle.error)}</p>}
          <div className="row">
            <button className="danger" disabled={toggle.isPending}
                    onClick={() => toggle.mutate(undefined, { onSuccess: () => setConfirming(false) })}>
              Deactivate
            </button>
            <button className="link" onClick={() => setConfirming(false)}>Cancel</button>
          </div>
        </div>
      )}
    </section>
  );
}
