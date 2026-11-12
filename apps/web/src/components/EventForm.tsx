import { formatWindow, repeatLabel, wallTimeToUtc } from "@famly/domain";
import { useState, type FormEvent, type ReactNode } from "react";
import { Link } from "react-router";
import { PeoplePicker } from "./PeoplePicker";

export interface EventValues {
  title: string;
  start: string; // wall time "YYYY-MM-DDTHH:mm" in the family's zone
  end: string;
  destination: string;
  description: string;
  participantIds: string[];
  /** "" = one-off; else daily | weekly | fortnightly | monthly. */
  repeat: string;
  /** "YYYY-MM-DD" or "" for no end. */
  repeatUntil: string;
}

const REPEAT_OPTIONS = [
  { id: "", label: "Doesn't repeat" },
  { id: "daily", label: "Every day" },
  { id: "weekly", label: "Every week" },
  { id: "fortnightly", label: "Every 2 weeks" },
  { id: "monthly", label: "Every month" },
];

/** R1 notice: always on screen while composing, so nobody posts something they meant to keep private. */
export function VisibleToAll({ groupName, details = "the place and notes" }: { groupName: string; details?: string }) {
  return (
    <p className="notice" role="note">
      <span aria-hidden="true">👁 </span>
      <strong>Visible to everyone in {groupName}</strong>, including {details}.{" "}
      <Link to="/shared">What&apos;s shared?</Link>
    </p>
  );
}

export function EventForm(props: {
  heading: string;
  groupName: string;
  timeZone: string;
  initial: EventValues;
  members: Array<{ user_id: string; display_name: string }>;
  me: string;
  /** Booking-linked events take their times from the booking. */
  lockTimes?: boolean;
  submitLabel: string;
  busy: boolean;
  error: string | null;
  onSubmit: (v: EventValues) => void;
  onCancel?: () => void;
  extra?: ReactNode;
}) {
  const [v, setV] = useState(props.initial);
  const set = <K extends keyof EventValues>(k: K, value: EventValues[K]) => setV((old) => ({ ...old, [k]: value }));

  let preview: string | null = null;
  try {
    const s = wallTimeToUtc(v.start, props.timeZone);
    const e = wallTimeToUtc(v.end, props.timeZone);
    if (e > s) preview = formatWindow(s, e, new Date(), props.timeZone);
  } catch {
    preview = null;
  }

  const repeatText = v.repeat ? repeatLabel(v.repeat, v.start.slice(0, 10), v.repeatUntil || null) : null;

  function submit(e: FormEvent) {
    e.preventDefault();
    props.onSubmit(v);
  }

  const others = props.members.filter((m) => m.user_id !== props.me);

  return (
    <form onSubmit={submit} className="stack">
      <VisibleToAll groupName={props.groupName} />
      {props.extra}
      <section className="card stack">
        <label>
          What
          <input required maxLength={120} value={v.title} onChange={(e) => set("title", e.target.value)}
                 placeholder="e.g. Dinner at Grandma's" />
        </label>
        {props.lockTimes ? (
          <p className="muted">When: {preview} <span>(follows the car booking)</span></p>
        ) : (
          <>
            <label>
              <span>From <span className="muted">({props.timeZone})</span></span>
              <input type="datetime-local" required step={900} value={v.start}
                     onChange={(e) => set("start", e.target.value)} />
            </label>
            <label>
              Until
              <input type="datetime-local" required step={900} value={v.end} min={v.start}
                     onChange={(e) => set("end", e.target.value)} />
            </label>
            {preview ? <p className="muted">{preview}</p> : v.start && v.end && <p className="error">The end must be after the start.</p>}
            <label>
              Repeats
              <select value={v.repeat} onChange={(e) => set("repeat", e.target.value)}>
                {REPEAT_OPTIONS.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
              </select>
            </label>
            {v.repeat && (
              <>
                <label>
                  <span>Until <span className="muted">(optional)</span></span>
                  <input type="date" value={v.repeatUntil} min={v.start.slice(0, 10)} onChange={(e) => set("repeatUntil", e.target.value)} />
                </label>
                {repeatText && <p className="muted">{repeatText}</p>}
              </>
            )}
          </>
        )}
        <label>
          <span>Where <span className="muted">(optional)</span></span>
          <input maxLength={200} value={v.destination} onChange={(e) => set("destination", e.target.value)} />
        </label>
        <label>
          <span>Notes <span className="muted">(optional)</span></span>
          <textarea maxLength={2000} rows={3} value={v.description} onChange={(e) => set("description", e.target.value)} />
        </label>
      </section>

      {others.length > 0 && (
        <fieldset className="card stack">
          <legend>Invite</legend>
          <p className="muted">Invited people can say whether they&apos;re coming. Everyone in the family can still see it.</p>
          <PeoplePicker label="Invite" members={others} selected={v.participantIds} onChange={(ids) => set("participantIds", ids)} />
        </fieldset>
      )}

      {props.error && <p className="error" role="alert">{props.error}</p>}
      <button type="submit" className="confirm-btn press" disabled={props.busy || !v.title.trim() || (!props.lockTimes && !preview)}>
        {props.busy ? "Saving…" : props.submitLabel}
      </button>
      {props.onCancel && <button type="button" className="secondary" onClick={props.onCancel}>Cancel</button>}
    </form>
  );
}
