import { formatMoment, nextAction, utcToWallTime, wallTimeToUtc } from "@famly/domain";
import { useState, type FormEvent } from "react";
import { newIdempotencyKey } from "../lib/cars";
import { statusKeys, useAction, useCurrentGroup, useMyPrompts, useOutingReports } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { useUI } from "../lib/ui";
import { ExitIcon } from "./Icons";
import { supabase } from "../lib/supabase";

export interface OutingLike {
  id: string;
  status: string;
  planned_start: string;
  planned_return: string;
  expected_return_at: string | null;
  departure_reported_at: string | null;
  home_reported_at: string | null;
}

/**
 * The owner's status buttons (P07-6, D05). Big, explicit, and safe to tap twice: each intended
 * action carries one idempotency key until it succeeds (T07).
 */
export function StatusActions(props: {
  outing: OutingLike;
  groupId: string;
  timeZone: string;
  carName: string | null;
  bookingEndsAt: Date | null;
}) {
  const { outing, groupId, timeZone: tz, carName } = props;
  const now = new Date();
  const action = nextAction(
    { status: outing.status as "planned", plannedStart: new Date(outing.planned_start) },
    now,
    props.bookingEndsAt,
  );
  const [key, setKey] = useState(newIdempotencyKey);
  const [mode, setMode] = useState<"main" | "issue" | "undo">("main");
  const ui = useUI();
  const keys = statusKeys(groupId, outing.id);
  const done = () => {
    setKey(newIdempotencyKey());
    setMode("main");
  };

  const home = useAction(
    async () => unwrap(await supabase.rpc("rpc_confirm_home", { p_outing_id: outing.id, p_idempotency_key: key })),
    keys,
  );
  const snooze = useAction(
    async (promptId: string) => unwrap(await supabase.rpc("rpc_snooze_prompt", { p_prompt_id: promptId })),
    keys,
  );
  const prompts = useMyPrompts();
  const { group } = useCurrentGroup();
  const prompt = prompts.data?.find((p) => p.outing_id === outing.id);
  const snoozesLeft = prompt && group ? Math.max(0, group.snooze_cap - prompt.snooze_count) : 0;
  const error = home.error ?? snooze.error;

  if (mode === "issue") {
    return <IssueForm {...props} idemKey={key} onDone={done} onCancel={() => setMode("main")} />;
  }
  if (mode === "undo") {
    return <UndoForm {...props} idemKey={key} onDone={done} onCancel={() => setMode("main")} />;
  }

  if (outing.status === "returned") {
    return (
      <section className="card stack">
        <p className="chip ok">
          <span aria-hidden="true" className="glyph">✓</span>
          <strong>
            You&apos;re home{carName ? ` and ${carName} is back` : ""}
            {outing.home_reported_at ? ` · ${formatMoment(new Date(outing.home_reported_at), now, tz)}` : ""}
          </strong>
        </p>
        <button className="link" onClick={() => setMode("undo")}>Tapped By Mistake? Undo</button>
      </section>
    );
  }

  if (!action) return null;

  return (
    <section className="card stack status-actions">
      {action === "left" ? (
        <>
          <button className="big-action press" onClick={() => ui.open({ kind: "leave", outingId: outing.id })}>
            <ExitIcon />I&apos;m Leaving
          </button>
          <p className="muted">
            Tap when you set off{carName ? ` in ${carName}` : ""}. Say what for and whether you have the house key;
            everyone in the family is told.
          </p>
        </>
      ) : (
        <>
          <button className="big-action press" disabled={home.isPending} onClick={() => home.mutate(undefined, { onSuccess: done })}>
            {home.isPending ? "Saving…" : carName ? "I'm Home — Car Returned" : "I'm Home"}
          </button>
          <p className="muted">
            {carName
              ? `One tap says both: you're home AND ${carName} is back and free for others.`
              : "Tells everyone you're back."}
          </p>
          {outing.status === "departed" && (
            <>
              <button className="secondary" onClick={() => setMode("issue")}>
                {carName ? "Not Home / Car Not Back" : "Running Late"}
              </button>
              <button className="link" onClick={() => setMode("undo")}>Tapped Left By Mistake? Undo</button>
            </>
          )}
        </>
      )}
      {prompt && (
        snoozesLeft > 0 ? (
          <button className="link" disabled={snooze.isPending} onClick={() => snooze.mutate(prompt.id)}>
            Remind Me In 15 Min ({snoozesLeft} Left)
          </button>
        ) : (
          <p className="muted">No snoozes left for this one. Tap a button above when you can.</p>
        )
      )}
      {error && <p className="error" role="alert">{messageOf(error)}</p>}
    </section>
  );
}

function IssueForm(props: {
  outing: OutingLike;
  groupId: string;
  timeZone: string;
  carName: string | null;
  idemKey: string;
  onDone: () => void;
  onCancel: () => void;
}) {
  const tz = props.timeZone;
  const planned = new Date(props.outing.expected_return_at ?? props.outing.planned_return);
  const suggested = new Date(Math.max(planned.getTime(), Date.now()) + 30 * 60_000);
  const [kind, setKind] = useState<"eta_update" | "issue">("eta_update");
  const [eta, setEta] = useState(utcToWallTime(suggested, tz));
  const [note, setNote] = useState("");
  const report = useAction(
    async () =>
      unwrap(
        await supabase.rpc("rpc_report_issue", {
          p_outing_id: props.outing.id,
          p_kind: kind,
          p_expected_return_at: eta ? wallTimeToUtc(eta, tz).toISOString() : (null as unknown as string),
          p_note: note,
          p_idempotency_key: props.idemKey,
        }),
      ),
    statusKeys(props.groupId, props.outing.id),
  );
  function submit(e: FormEvent) {
    e.preventDefault();
    report.mutate(undefined, { onSuccess: props.onDone });
  }
  return (
    <form onSubmit={submit} className="card stack">
      <h2>{props.carName ? "Not Home / Car Not Back" : "Running Late"}</h2>
      {props.carName && (
        <fieldset className="stack">
          <legend className="sr-only">What&apos;s happening</legend>
          <label className="check">
            <input type="radio" name="kind" checked={kind === "eta_update"}
                   onChange={() => { setKind("eta_update"); setEta(utcToWallTime(suggested, tz)); }} />
            Running late, car is fine
          </label>
          <label className="check">
            <input type="radio" name="kind" checked={kind === "issue"}
                   onChange={() => { setKind("issue"); setEta(""); }} />
            Problem with the car
          </label>
        </fieldset>
      )}
      <label>
        <span>Expected back {kind === "issue" && <span className="muted">(optional)</span>}</span>
        <input type="datetime-local" step={900} required={kind === "eta_update"} value={eta}
               onChange={(e) => setEta(e.target.value)} />
      </label>
      <label>
        <span>Note <span className="muted">(optional, everyone sees it)</span></span>
        <input maxLength={500} value={note} onChange={(e) => setNote(e.target.value)}
               placeholder={kind === "issue" ? "e.g. Flat tyre at the mall" : "e.g. Traffic on SZR"} />
      </label>
      <p className="muted">
        This updates when you expect to be back. It doesn&apos;t change your booking or anyone else&apos;s;
        {props.carName ? " whoever has the car next will see the warning." : ""}
      </p>
      {report.error && <p className="error" role="alert">{messageOf(report.error)}</p>}
      <button type="submit" disabled={report.isPending}>Share Update</button>
      <button type="button" className="secondary" onClick={props.onCancel}>Back</button>
    </form>
  );
}

function UndoForm(props: { outing: OutingLike; groupId: string; idemKey: string; onDone: () => void; onCancel: () => void }) {
  const undo = props.outing.status === "returned" ? "home" : "left";
  const [reason, setReason] = useState("");
  const correct = useAction(
    async () =>
      unwrap(
        await supabase.rpc("rpc_correct_status", {
          p_outing_id: props.outing.id,
          p_undo: undo,
          p_reason: reason,
          p_idempotency_key: props.idemKey,
        }),
      ),
    statusKeys(props.groupId, props.outing.id),
  );
  function submit(e: FormEvent) {
    e.preventDefault();
    correct.mutate(undefined, { onSuccess: props.onDone });
  }
  return (
    <form onSubmit={submit} className="card stack">
      <h2>Undo &ldquo;{undo === "home" ? "I'm Home" : "Left"}&rdquo;</h2>
      <p className="muted">The original tap stays in the history with your correction after it.</p>
      <label>
        Why?
        <input required maxLength={200} value={reason} onChange={(e) => setReason(e.target.value)}
               placeholder="e.g. Tapped by mistake" />
      </label>
      {correct.error && <p className="error" role="alert">{messageOf(correct.error)}</p>}
      <button type="submit" disabled={correct.isPending || !reason.trim()}>Undo</button>
      <button type="button" className="secondary" onClick={props.onCancel}>Back</button>
    </form>
  );
}

const REPORT_WORDS: Record<string, string> = {
  left: "Left",
  home: "Home",
  home_and_car_returned: "Home, car returned",
  eta_update: "Running late",
  issue: "Problem reported",
  correction: "Correction",
};

/** Self-reported history (FR-V10, FR-S09), shown apart from the planned schedule. */
export function StatusHistory(props: { outingId: string | null; nameOf: (id: string | null) => string; timeZone: string }) {
  const reports = useOutingReports(props.outingId);
  if (!reports.data || reports.data.length === 0) return null;
  const now = new Date();
  return (
    <section className="card stack">
      <h2>Status Updates</h2>
      <p className="muted">Self-reported by the person going out. Not verified.</p>
      <ul className="list">
        {reports.data.map((r) => {
          const p = (r.payload ?? {}) as {
            expected_return_at?: string; note?: string; undo?: string; reason?: string; has_house_key?: boolean;
          };
          return (
            <li key={r.id}>
              <strong>{REPORT_WORDS[r.kind] ?? r.kind}</strong>
              {p.has_house_key !== undefined && (p.has_house_key ? " · has the house key" : " · doesn't have the house key")}
              {p.expected_return_at && ` · expected back ${formatMoment(new Date(p.expected_return_at), now, props.timeZone)}`}
              {p.note && ` · “${p.note}”`}
              {r.kind === "correction" && ` · undid “${p.undo === "home" ? "I'm home" : "Left"}”${p.reason ? `: ${p.reason}` : ""}`}
              <span className="muted"> · {props.nameOf(r.reported_by)}, {formatMoment(new Date(r.reported_at), now, props.timeZone)}</span>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
