import { addDays, dayBounds, wallDate } from "@famly/domain";
import { useState, type FormEvent } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router";
import { VisibleToAll } from "../components/EventForm";
import { PeoplePicker } from "../components/PeoplePicker";
import { useUserId } from "../lib/auth";
import { useAction, useCurrentGroup, useMembers, useStay, type Stay } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

/* ------------------------------------------------------------------ Shared helpers */

/** "Ben, Aunt May" — members' names as saved, then anyone typed in. */
export function stayGuests(s: Pick<Stay, "guest_names" | "other_guests">): string {
  return [...s.guest_names.map((n) => n.split(/\s+/)[0]!), ...(s.other_guests ? [s.other_guests] : [])].join(", ");
}

/** "Fri 20 Nov" for a "YYYY-MM-DD" day in the family's zone. */
export function stayDay(date: string, tz: string, long = false): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: long ? "long" : "short", day: "numeric", month: long ? "long" : "short" })
    .format(dayBounds(date, tz).start).replace(",", "");
}

export function nights(arrives: string, leaves: string): number {
  return Math.round((Date.parse(`${leaves}T00:00:00Z`) - Date.parse(`${arrives}T00:00:00Z`)) / 86_400_000);
}

const stayKeys = (groupId: string, id?: string) => [["family-stays", groupId], ...(id ? [["family-stay", id]] : [])];

/* ------------------------------------------------------------------ Form */

interface StayValues {
  guestIds: string[];
  otherGuests: string;
  arrives: string;
  leaves: string;
  from: string;
  note: string;
}

function StayForm(props: {
  group: Group;
  initial: StayValues;
  submitLabel: string;
  busy: boolean;
  error: string | null;
  onSubmit: (v: StayValues) => void;
  onCancel: () => void;
}) {
  const members = useMembers(props.group.id);
  const [v, setV] = useState(props.initial);
  const set = <K extends keyof StayValues>(k: K, value: StayValues[K]) => setV((old) => ({ ...old, [k]: value }));
  const today = wallDate(new Date(), props.group.time_zone);
  const valid = (v.guestIds.length > 0 || v.otherGuests.trim()) && v.arrives && v.leaves && v.leaves >= v.arrives;
  const n = v.arrives && v.leaves && v.leaves >= v.arrives ? nights(v.arrives, v.leaves) : null;

  function submit(e: FormEvent) {
    e.preventDefault();
    props.onSubmit(v);
  }

  return (
    <form onSubmit={submit} className="stack">
      <VisibleToAll groupName={props.group.name} details="who's staying, where from and the notes" />
      <fieldset className="card stack">
        <legend>Who&apos;s Staying</legend>
        <PeoplePicker label="Who's staying" members={members.data ?? []} selected={v.guestIds} onChange={(ids) => set("guestIds", ids)} />
        <label>
          <span>Anyone else <span className="muted">(optional)</span></span>
          <input maxLength={200} value={v.otherGuests} onChange={(e) => set("otherGuests", e.target.value)}
                 placeholder="e.g. Aunt May and Uncle Joe" />
        </label>
        <p className="muted" style={{ fontSize: 13 }}>Not on fam.ly yet? Type their names, or invite them from Members &amp; Invites while they stay.</p>
      </fieldset>
      <section className="card stack">
        <label>
          Arrives
          <input type="date" required value={v.arrives} onChange={(e) => {
            const a = e.target.value;
            setV((old) => ({ ...old, arrives: a, leaves: old.leaves && old.leaves >= a ? old.leaves : a }));
          }} />
        </label>
        <label>
          Leaves
          <input type="date" required min={v.arrives || today} value={v.leaves} onChange={(e) => set("leaves", e.target.value)} />
        </label>
        {n !== null && <p className="muted">{n === 0 ? "Day visit" : `${n} night${n === 1 ? "" : "s"}`}</p>}
        <label>
          <span>Coming from <span className="muted">(optional)</span></span>
          <input maxLength={120} value={v.from} onChange={(e) => set("from", e.target.value)} placeholder="e.g. London" />
        </label>
        <label>
          <span>Notes <span className="muted">(optional)</span></span>
          <textarea maxLength={1000} rows={3} value={v.note} onChange={(e) => set("note", e.target.value)}
                    placeholder="e.g. Flight EK 2 lands 19:40. Staying in the guest room." />
        </label>
      </section>
      {props.error && <p className="error" role="alert">{props.error}</p>}
      <button type="submit" className="confirm-btn press" disabled={props.busy || !valid}>
        {props.busy ? "Saving…" : props.submitLabel}
      </button>
      <button type="button" className="secondary" onClick={props.onCancel}>Cancel</button>
    </form>
  );
}

const toArgs = (v: StayValues) => ({
  p_guest_ids: v.guestIds, p_other_guests: v.otherGuests, p_arrives: v.arrives, p_leaves: v.leaves, p_from: v.from, p_note: v.note,
});

/* ------------------------------------------------------------------ New */

export function NewStay() {
  const { group } = useCurrentGroup();
  return group ? <NewStayBody group={group} /> : null;
}

/** New Stay (founder, 2026-11-12): someone staying with the family for some days. Everyone is notified. */
function NewStayBody({ group }: { group: Group }) {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const [error, setError] = useState<string | null>(null);
  const today = wallDate(new Date(), group.time_zone);
  const valid = (d: string | null) => (d && /^\d{4}-\d{2}-\d{2}$/.test(d) ? d : null);
  const arrives = valid(params.get("from")) ?? today;
  const leaves = valid(params.get("to")) ?? addDays(arrives, 3);
  const create = useAction(
    async (v: StayValues) => unwrap(await supabase.rpc("rpc_create_stay", { p_group_id: group.id, ...toArgs(v) })),
    stayKeys(group.id),
  );
  return (
    <StayForm
      group={group}
      initial={{ guestIds: [], otherGuests: "", arrives, leaves: leaves >= arrives ? leaves : arrives, from: "", note: "" }}
      submitLabel="Add Stay"
      busy={create.isPending}
      error={error}
      onSubmit={(v) => {
        setError(null);
        create.mutate(v, { onSuccess: (id) => navigate(`/family/stays/${id}`, { replace: true }), onError: (e) => setError(messageOf(e)) });
      }}
      onCancel={() => navigate(-1)}
    />
  );
}

/* ------------------------------------------------------------------ Detail */

export function StayDetail() {
  const { group } = useCurrentGroup();
  return group ? <StayBody group={group} /> : null;
}

function StayBody({ group }: { group: Group }) {
  const { stayId = "" } = useParams();
  const tz = group.time_zone;
  const uid = useUserId();
  const navigate = useNavigate();
  const stay = useStay(stayId);
  const members = useMembers(group.id);
  const [editing, setEditing] = useState(false);
  const [confirmCancel, setConfirmCancel] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const update = useAction(
    async (v: StayValues) => unwrap(await supabase.rpc("rpc_update_stay", { p_stay_id: stayId, ...toArgs(v) })),
    stayKeys(group.id, stayId),
  );
  const cancel = useAction(async () => unwrap(await supabase.rpc("rpc_cancel_stay", { p_stay_id: stayId })), stayKeys(group.id, stayId));

  if (stay.isPending) return <p>Loading…</p>;
  if (stay.isError) return <p className="error">{messageOf(stay.error)}</p>;
  if (!stay.data) {
    return (
      <div className="stack">
        <p>That stay isn&apos;t in {group.name}.</p>
        <Link to="/family?view=stays">Back To Stays</Link>
      </div>
    );
  }
  const s = stay.data;
  const today = wallDate(new Date(), tz);
  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const by = s.created_by === uid ? "you" : (s.created_by && names.get(s.created_by)) || "a former member";
  const n = nights(s.arrives, s.leaves);
  const status = s.cancelled_at ? "Cancelled"
    : s.leaves < today ? "Left"
    : s.arrives > today ? `Arrives in ${nights(today, s.arrives)} day${nights(today, s.arrives) === 1 ? "" : "s"}`
    : s.leaves === today ? "Leaves today" : "Staying now";

  if (editing) {
    return (
      <StayForm
        group={group}
        initial={{ guestIds: s.guest_ids, otherGuests: s.other_guests ?? "", arrives: s.arrives, leaves: s.leaves, from: s.from_place ?? "", note: s.note ?? "" }}
        submitLabel="Save"
        busy={update.isPending}
        error={error}
        onSubmit={(v) => {
          setError(null);
          update.mutate(v, { onSuccess: () => setEditing(false), onError: (e) => setError(messageOf(e)) });
        }}
        onCancel={() => setEditing(false)}
      />
    );
  }

  return (
    <div className="stack">
      <section className="card stack stay-card">
        <span className="pill stay-pill">{status}</span>
        <h2>{stayGuests(s)}</h2>
        {s.from_place && <p>From {s.from_place}</p>}
        <div className="stay-dates">
          <span><span className="k">ARRIVES</span>{stayDay(s.arrives, tz, true)}</span>
          <span><span className="k">LEAVES</span>{stayDay(s.leaves, tz, true)}</span>
        </div>
        <p className="muted">{n === 0 ? "Day visit" : `${n} night${n === 1 ? "" : "s"}`} · added by {by}</p>
        {s.note && <p className="pre">{s.note}</p>}
      </section>
      {!s.cancelled_at && s.leaves >= today && (
        <>
          <button className="secondary" onClick={() => setEditing(true)}>Edit</button>
          {!confirmCancel ? (
            <button className="link danger" onClick={() => setConfirmCancel(true)}>Cancel Stay…</button>
          ) : (
            <section className="card stack">
              <p>Cancel this stay for everyone?</p>
              {cancel.error && <p className="error">{messageOf(cancel.error)}</p>}
              <div className="row">
                <button className="danger" disabled={cancel.isPending}
                        onClick={() => cancel.mutate(undefined, { onSuccess: () => navigate("/family?view=stays") })}>Cancel It</button>
                <button className="link" onClick={() => setConfirmCancel(false)}>Keep It</button>
              </div>
            </section>
          )}
        </>
      )}
    </div>
  );
}
