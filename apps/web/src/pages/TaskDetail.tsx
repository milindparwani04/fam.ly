import { formatMoment } from "@famly/domain";
import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { useUserId } from "../lib/auth";
import { useAction, useCurrentGroup, useFamilyTask, useMembers } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

const capitalise = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const STATE_WORDS = { accepted: "Accepted", pending: "Hasn't answered", declined: "Declined" } as const;

export function TaskDetail() {
  const { group } = useCurrentGroup();
  return group ? <TaskBody group={group} /> : null;
}

function TaskBody({ group }: { group: Group }) {
  const { taskId = "" } = useParams();
  const tz = group.time_zone;
  const uid = useUserId();
  const navigate = useNavigate();
  const task = useFamilyTask(taskId);
  const members = useMembers(group.id);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const keys = [["family-task", taskId], ["family-tasks"], ["activity", group.id]];

  const respond = useAction(
    async (state: "accepted" | "declined") =>
      unwrap(await supabase.rpc("rpc_respond_task", { p_task_id: taskId, p_state: state })),
    keys,
  );
  const complete = useAction(
    async () => unwrap(await supabase.rpc("rpc_complete_task", { p_task_id: taskId })),
    keys,
  );
  const remove = useAction(
    async () => unwrap(await supabase.rpc("rpc_cancel_task", { p_task_id: taskId })),
    keys,
  );

  if (task.isPending) return <p>Loading…</p>;
  if (task.isError) return <p className="error">{messageOf(task.error)}</p>;
  if (!task.data) {
    return (
      <div className="stack">
        <p>That task isn&apos;t in {group.name}.</p>
        <Link to="/family">Back To Plans</Link>
      </div>
    );
  }

  const t = task.data;
  const now = new Date();
  const names = new Map(members.data?.map((m) => [m.user_id, m.display_name]));
  const nameOf = (id: string | null) => (id === uid ? "you" : (id && names.get(id)) || "a former member");
  const mine = t.task_assignee.find((a) => a.user_id === uid);
  const isCreator = t.created_by === uid;
  const open = !t.completed_at && !t.cancelled_at;
  const canComplete = open && (isCreator || mine?.state === "accepted");

  return (
    <div className="stack">
      <section className="card stack">
        <h2>{t.title}</h2>
        {t.completed_at && (
          <p className="chip ok"><span className="glyph" aria-hidden="true">✓</span>
            <span>Done by {nameOf(t.completed_by)} · {formatMoment(new Date(t.completed_at), now, tz)}</span></p>
        )}
        {t.cancelled_at && <p className="warn-text">Deleted.</p>}
        {t.description && <p className="pre">{t.description}</p>}
        <p className="muted">Added by {nameOf(t.created_by)} · {formatMoment(new Date(t.created_at), now, tz)}</p>
      </section>

      {mine && open && mine.state === "pending" && (
        <section className="banner warn stack" role="status">
          <p><strong>{capitalise(nameOf(t.created_by))}</strong> asked you to do this. Can you?</p>
        </section>
      )}

      <section className="card stack">
        <h2>Assigned To</h2>
        <ul className="list">
          {t.task_assignee.map((a) => (
            <li key={a.user_id} className="row">
              <span>{a.user_id === uid ? "You" : nameOf(a.user_id)}</span>
              <span className={a.state === "accepted" ? "badge" : "muted"}>{STATE_WORDS[a.state]}</span>
            </li>
          ))}
        </ul>
        {mine && open && (
          <div className="row actions">
            <button className={mine.state === "accepted" ? "" : "secondary"} disabled={respond.isPending}
                    aria-pressed={mine.state === "accepted"} onClick={() => respond.mutate("accepted")}>
              Accept
            </button>
            <button className={mine.state === "declined" ? "" : "secondary"} disabled={respond.isPending}
                    aria-pressed={mine.state === "declined"} onClick={() => respond.mutate("declined")}>
              Decline
            </button>
          </div>
        )}
        {respond.error && <p className="error">{messageOf(respond.error)}</p>}
      </section>

      {canComplete && (
        <>
          <button className="big-action" disabled={complete.isPending} onClick={() => complete.mutate(undefined)}>
            {complete.isPending ? "Saving…" : "Mark As Done"}
          </button>
          <p className="muted">Everyone in {group.name} will see it&apos;s done in Activity.</p>
          {complete.error && <p className="error">{messageOf(complete.error)}</p>}
        </>
      )}
      {open && mine?.state === "pending" && (
        <p className="muted">Accept the task to be able to mark it as done.</p>
      )}

      {isCreator && open && (
        !confirmDelete ? (
          <button className="link danger" onClick={() => setConfirmDelete(true)}>Delete Task…</button>
        ) : (
          <section className="card stack">
            <p>Delete this task? Anyone still assigned will be told.</p>
            {remove.error && <p className="error">{messageOf(remove.error)}</p>}
            <div className="row">
              <button className="danger" disabled={remove.isPending}
                      onClick={() => remove.mutate(undefined, { onSuccess: () => navigate("/family") })}>
                Delete It
              </button>
              <button className="link" onClick={() => setConfirmDelete(false)}>Keep It</button>
            </div>
          </section>
        )
      )}
    </div>
  );
}
