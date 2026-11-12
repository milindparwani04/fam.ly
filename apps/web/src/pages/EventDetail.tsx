import { formatWindow, repeatLabel, utcToWallTime, wallDate, wallTimeToUtc } from "@famly/domain";
import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { EventForm, type EventValues } from "../components/EventForm";
import { StatusActions, StatusHistory } from "../components/StatusActions";
import { useUserId } from "../lib/auth";
import { useAction, useCurrentGroup, useFamilyEvent, useMembers, useOuting } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

const STATE_WORDS = { attending: "Going", invited: "Invited (hasn't answered)", declined: "Not going" } as const;

export function EventDetail() {
  const { group } = useCurrentGroup();
  return group ? <EventBody group={group} /> : null;
}

function EventBody({ group }: { group: Group }) {
  const { eventId = "" } = useParams();
  const tz = group.time_zone;
  const uid = useUserId();
  const navigate = useNavigate();
  const event = useFamilyEvent(eventId);
  const members = useMembers(group.id);
  const [editing, setEditing] = useState(false);
  const [confirmCancel, setConfirmCancel] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const keys = [["family-event", eventId], ["family-events", group.id]];

  const respond = useAction(
    async (state: "attending" | "declined") =>
      unwrap(await supabase.rpc("rpc_respond_event", { p_event_id: eventId, p_state: state })),
    keys,
  );
  const update = useAction(
    async (v: EventValues & { version: number; repeatChanged: boolean }) => {
      unwrap(
        await supabase.rpc("rpc_update_event", {
          p_event_id: eventId,
          p_title: v.title,
          p_starts_at: wallTimeToUtc(v.start, tz).toISOString(),
          p_ends_at: wallTimeToUtc(v.end, tz).toISOString(),
          p_destination: v.destination,
          p_description: v.description,
          p_participant_ids: v.participantIds,
          p_expected_version: v.version,
        }),
      );
      if (v.repeatChanged) {
        unwrap(await supabase.rpc("rpc_set_event_repeat", {
          // null clears the rule (the generated type does not know p_repeat accepts null).
          p_event_id: eventId, p_repeat: (v.repeat || null) as string, ...(v.repeat && v.repeatUntil ? { p_until: v.repeatUntil } : {}),
        }));
      }
    },
    keys,
  );
  const cancel = useAction(
    async () => unwrap(await supabase.rpc("rpc_cancel_event", { p_event_id: eventId })),
    [...keys, ["family-event-for-booking", event.data?.reservation_id ?? ""]],
  );

  if (event.isPending) return <p>Loading…</p>;
  if (event.isError) return <p className="error">{messageOf(event.error)}</p>;
  if (!event.data) {
    return (
      <div className="stack">
        <p>That event isn&apos;t in {group.name}.</p>
        <Link to="/family">Back To Plans</Link>
      </div>
    );
  }

  const e = event.data;
  const now = new Date();
  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const nameOf = (id: string | null) => (id ? (names.get(id) ?? "a former member") : "someone");
  const owner = e.tripOwnerId;
  const canChange = !e.cancelled_at && (owner === null || owner === uid);
  const mine = e.event_participant.find((p) => p.user_id === uid);
  const kind = e.reservation_id ? "booking" : e.outing_id ? "outing" : "event";

  if (editing) {
    return (
      <EventForm
        heading="Edit"
        groupName={group.name}
        timeZone={tz}
        me={owner ?? e.created_by ?? uid}
        members={members.data ?? []}
        lockTimes={kind === "booking"}
        initial={{
          title: e.title,
          start: utcToWallTime(new Date(e.starts_at), tz),
          end: utcToWallTime(new Date(e.ends_at), tz),
          destination: e.destination ?? "",
          description: e.description ?? "",
          participantIds: e.event_participant.map((p) => p.user_id),
          repeat: e.repeat ?? "",
          repeatUntil: e.repeat_until ?? "",
        }}
        submitLabel="Save"
        busy={update.isPending}
        error={error}
        onSubmit={(v) => {
          setError(null);
          const repeatChanged = v.repeat !== (e.repeat ?? "") || (v.repeat !== "" && v.repeatUntil !== (e.repeat_until ?? ""));
          update.mutate({ ...v, version: e.version, repeatChanged }, {
            onSuccess: () => setEditing(false),
            onError: (err) => setError(messageOf(err)),
          });
        }}
        onCancel={() => setEditing(false)}
      />
    );
  }

  return (
    <div className="stack">
      <section className="card stack">
        <h2>{e.title}</h2>
        {e.cancelled_at && <p className="warn-text">{kind === "booking" ? "Removed from the Family calendar." : "Cancelled."}</p>}
        <p className="big">{formatWindow(new Date(e.starts_at), new Date(e.ends_at), now, tz)}</p>
        {e.repeat && <p className="chip info"><span className="glyph" aria-hidden="true">↻</span><span>{repeatLabel(e.repeat, wallDate(new Date(e.starts_at), tz), e.repeat_until)}</span></p>}
        {e.destination && <p>📍 {e.destination}</p>}
        {e.description && <p className="pre">{e.description}</p>}
        <p className="muted">
          {kind === "booking" && <>Car trip by {owner === uid ? "you" : nameOf(owner)} · <Link to={`/bookings/${e.reservation_id}`}>see booking</Link></>}
          {kind === "outing" && <>Outing by {owner === uid ? "you" : nameOf(owner)}, no car{e.outingStatus === "cancelled" ? " (cancelled)" : ""}</>}
          {kind === "event" && <>Added by {e.created_by === uid ? "you" : nameOf(e.created_by)}</>}
        </p>
      </section>

      {e.outing_id && !e.cancelled_at && (
        <OutingStatus outingId={e.outing_id} isOwner={owner === uid} carFree={kind === "outing"}
                      groupId={group.id} timeZone={tz} nameOf={nameOf} />
      )}

      <section className="card stack">
        <h2>Who&apos;s Going</h2>
        {e.event_participant.length === 0 ? (
          <p className="muted">Nobody invited.</p>
        ) : (
          <ul className="list">
            {e.event_participant.map((p) => (
              <li key={p.user_id} className="row">
                <span>{p.user_id === uid ? "You" : nameOf(p.user_id)}</span>
                <span className={p.state === "attending" ? "badge" : "muted"}>{STATE_WORDS[p.state]}</span>
              </li>
            ))}
          </ul>
        )}
        {mine && !e.cancelled_at && mine.user_id !== owner && (
          <div className="row actions">
            <button className={mine.state === "attending" ? "" : "secondary"} disabled={respond.isPending}
                    aria-pressed={mine.state === "attending"} onClick={() => respond.mutate("attending")}>
              I&apos;m Going
            </button>
            <button className={mine.state === "declined" ? "" : "secondary"} disabled={respond.isPending}
                    aria-pressed={mine.state === "declined"} onClick={() => respond.mutate("declined")}>
              Not Going
            </button>
          </div>
        )}
        {respond.error && <p className="error">{messageOf(respond.error)}</p>}
      </section>

      {canChange && (
        <>
          <button className="secondary" onClick={() => setEditing(true)}>Edit</button>
          {!confirmCancel ? (
            <button className="link danger" onClick={() => setConfirmCancel(true)}>
              {kind === "booking" ? "Remove From Family Calendar…" : kind === "outing" ? "Cancel Outing…" : "Cancel Event…"}
            </button>
          ) : (
            <section className="card stack">
              <p>
                {kind === "booking"
                  ? "Remove this from the Family calendar? Your car booking stays as it is."
                  : "Cancel this for everyone?"}
              </p>
              {cancel.error && <p className="error">{messageOf(cancel.error)}</p>}
              <div className="row">
                <button className="danger" disabled={cancel.isPending}
                        onClick={() => cancel.mutate(undefined, { onSuccess: () => navigate("/family") })}>
                  {kind === "booking" ? "Remove" : "Cancel It"}
                </button>
                <button className="link" onClick={() => setConfirmCancel(false)}>Keep It</button>
              </div>
            </section>
          )}
        </>
      )}
      {!canChange && !e.cancelled_at && (
        <p className="muted">Only {nameOf(owner)} can change this, because it&apos;s their trip.</p>
      )}
    </div>
  );
}

/** Left / I'm home for a car-free outing (booking-linked trips use the booking page's buttons). */
function OutingStatus(props: {
  outingId: string;
  isOwner: boolean;
  carFree: boolean;
  groupId: string;
  timeZone: string;
  nameOf: (id: string | null) => string;
}) {
  const outing = useOuting(props.outingId);
  return (
    <>
      {props.isOwner && props.carFree && outing.data && (
        <StatusActions outing={outing.data} groupId={props.groupId} timeZone={props.timeZone} carName={null} bookingEndsAt={null} />
      )}
      <StatusHistory outingId={props.outingId} nameOf={props.nameOf} timeZone={props.timeZone} />
    </>
  );
}
