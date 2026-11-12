import { dueBack, formatMoment, type VehicleState } from "@famly/domain";

/**
 * Car status as glyph + words (NFR-04: never colour alone). Self-reported states say so (R3):
 * "confirmed back" is a report, "available" alone only means free on the schedule.
 */
export function StatusChip(props: { state: VehicleState; nameOf: (userId: string) => string; now: Date; timeZone: string }) {
  const { state, nameOf, now, timeZone } = props;
  const at = (d: Date) => formatMoment(d, now, timeZone);

  switch (state.kind) {
    case "available": {
      const r = state.lastReturn;
      return (
        <Chip tone="ok" glyph="✓" label="Available"
              detail={r?.vehicleReturnedAt ? `confirmed back ${at(r.vehicleReturnedAt)} by ${nameOf(r.ownerId)}` : undefined} />
      );
    }
    case "booked":
      return (
        <Chip tone="info" glyph="◷" label={`Booked by ${nameOf(state.booking.ownerId)}`}
              detail={`until ${at(state.booking.endsAt)} · not reported left yet`} />
      );
    case "out": {
      const b = state.booking;
      const late = b.expectedReturnAt && b.expectedReturnAt > b.endsAt;
      return (
        <Chip tone={b.possessionUncertain ? "warn" : "info"} glyph={b.possessionUncertain ? "⚠" : "→"}
              label={`Out with ${nameOf(b.ownerId)}`}
              detail={[
                late ? `expected back ${at(dueBack(b))} (booked until ${at(b.endsAt)})` : `due back ${at(b.endsAt)}`,
                b.possessionUncertain ? "problem reported" : null,
              ].filter(Boolean).join(" · ")} />
      );
    }
    case "overdue":
      return (
        <Chip tone="warn" glyph="⚠" label={`Overdue · ${nameOf(state.booking.ownerId)}`}
              detail={`was due ${at(dueBack(state.booking))} · not confirmed back${state.booking.possessionUncertain ? " · problem reported" : ""}`} />
      );
    case "maintenance":
      return (
        <Chip tone="warn" glyph="🔧" label="Unavailable for maintenance"
              detail={`until ${at(state.window.endsAt)}${state.window.reason ? ` · ${state.window.reason}` : ""}`} />
      );
    case "inactive":
      return <Chip tone="muted" glyph="—" label="Inactive" />;
  }
}

function Chip(props: { tone: "ok" | "info" | "warn" | "muted"; glyph: string; label: string; detail?: string | undefined }) {
  return (
    <div className={`chip ${props.tone}`}>
      <span aria-hidden="true" className="glyph">{props.glyph}</span>
      <span>
        <strong>{props.label}</strong>
        {props.detail && <span className="chip-detail"> {props.detail}</span>}
      </span>
    </div>
  );
}
