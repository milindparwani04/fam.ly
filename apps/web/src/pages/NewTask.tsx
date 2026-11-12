import { useState, type FormEvent } from "react";
import { useNavigate } from "react-router";
import { VisibleToAll } from "../components/EventForm";
import { PeoplePicker } from "../components/PeoplePicker";
import { useUserId } from "../lib/auth";
import { useAction, useCurrentGroup, useMembers } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

export function NewTask() {
  const { group } = useCurrentGroup();
  return group ? <TaskForm group={group} /> : null;
}

/** New Task: what, optional details, and who should do it. Each assignee accepts or declines in the app. */
function TaskForm({ group }: { group: Group }) {
  const me = useUserId();
  const navigate = useNavigate();
  const members = useMembers(group.id);
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [assigneeIds, setAssigneeIds] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);

  const create = useAction(
    async () =>
      unwrap(
        await supabase.rpc("rpc_create_task", {
          p_group_id: group.id,
          p_title: title,
          p_description: description,
          p_assignee_ids: assigneeIds,
        }),
      ),
    [["family-tasks", group.id]],
  );

  function submit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    create.mutate(undefined, {
      onSuccess: (id) => navigate(`/family/tasks/${id}`, { replace: true }),
      onError: (err) => setError(messageOf(err)),
    });
  }

  if (members.isPending) return <p>Loading…</p>;
  const others = (members.data ?? []).filter((m) => m.user_id !== me);

  return (
    <form onSubmit={submit} className="stack">
      <VisibleToAll groupName={group.name} details="the description and who it's for" />
      <section className="card stack">
        <label>
          Task
          <input required maxLength={120} value={title} onChange={(e) => setTitle(e.target.value)}
                 placeholder="e.g. Pick up the dry cleaning" />
        </label>
        <label>
          <span>Description <span className="muted">(optional)</span></span>
          <textarea maxLength={2000} rows={3} value={description} onChange={(e) => setDescription(e.target.value)} />
        </label>
      </section>

      <fieldset className="card stack">
        <legend>Assign To</legend>
        {others.length === 0 ? (
          <p className="muted">There&apos;s nobody else in {group.name} yet. Invite someone from Members &amp; Invites.</p>
        ) : (
          <>
            <p className="muted">Each person is notified and asked to accept or decline. You&apos;ll hear when they accept and when it&apos;s done.</p>
            <PeoplePicker label="Assign to" members={others} selected={assigneeIds} onChange={setAssigneeIds} />
          </>
        )}
      </fieldset>

      {error && <p className="error" role="alert">{error}</p>}
      <button type="submit" className="confirm-btn press" disabled={create.isPending || !title.trim() || assigneeIds.length === 0}>
        {create.isPending ? "Saving…" : "Assign Task"}
      </button>
      <button type="button" className="secondary" onClick={() => navigate(-1)}>Cancel</button>
    </form>
  );
}
