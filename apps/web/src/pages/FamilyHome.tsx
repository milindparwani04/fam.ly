import { useState, type FormEvent } from "react";
import { useUserId } from "../lib/auth";
import { useAction, useCurrentGroup, useMembers, useOpenInvites } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

export function FamilyHome() {
  const { group } = useCurrentGroup();
  if (!group) return null;
  return (
    <div className="stack">
      <DeletionBanner group={group} />
      <Members groupId={group.id} />
      <Invites groupId={group.id} pendingDeletion={!!group.deletion_requested_at} />
    </div>
  );
}

function DeletionBanner({ group }: { group: Group }) {
  const cancel = useAction(
    async () => unwrap(await supabase.rpc("rpc_cancel_group_deletion", { p_group_id: group.id })),
    [["groups"]],
  );
  if (!group.deletion_requested_at || !group.deletion_scheduled_for) return null;
  return (
    <div className="banner warn stack" role="status">
      <p>
        <strong>{group.name}</strong> is scheduled to be deleted on{" "}
        {new Date(group.deletion_scheduled_for).toLocaleString()}. Any adult can stop this.
      </p>
      {cancel.error && <p className="error">{messageOf(cancel.error)}</p>}
      <button onClick={() => cancel.mutate(undefined)} disabled={cancel.isPending}>
        Keep This Family
      </button>
    </div>
  );
}

function Members({ groupId }: { groupId: string }) {
  const uid = useUserId();
  const members = useMembers(groupId);
  const [removing, setRemoving] = useState<string | null>(null);
  const iAmCustodian = members.data?.some((m) => m.user_id === uid && m.role === "custodian");

  const setRole = useAction(
    async (a: { userId: string; role: "member" | "custodian" }) =>
      unwrap(
        await supabase.rpc("rpc_set_member_role", {
          p_group_id: groupId,
          p_user_id: a.userId,
          p_role: a.role,
        }),
      ),
    [["members", groupId]],
  );

  if (members.isPending) return <p>Loading members…</p>;
  if (members.isError) return <p className="error">{messageOf(members.error)}</p>;

  return (
    <section className="card stack">
      <h2>Members</h2>
      <ul className="list">
        {members.data.map((m) => (
          <li key={m.user_id} className="stack">
            <div className="row">
              <span>
                {m.display_name}
                {m.user_id === uid && <span className="muted"> (you)</span>}
              </span>
              {m.role === "custodian" && <span className="badge">Custodian</span>}
            </div>
            {m.user_id !== uid && removing !== m.user_id && (
              <div className="row actions">
                {iAmCustodian && (
                  <button
                    className="link"
                    disabled={setRole.isPending}
                    onClick={() =>
                      setRole.mutate({
                        userId: m.user_id,
                        role: m.role === "custodian" ? "member" : "custodian",
                      })
                    }
                  >
                    {m.role === "custodian" ? "Remove Custodian Role" : "Make Custodian"}
                  </button>
                )}
                <button className="link danger" onClick={() => setRemoving(m.user_id)}>
                  Remove…
                </button>
              </div>
            )}
            {removing === m.user_id && (
              <RemoveMember
                groupId={groupId}
                userId={m.user_id}
                name={m.display_name}
                onDone={() => setRemoving(null)}
              />
            )}
          </li>
        ))}
      </ul>
      {setRole.error && <p className="error">{messageOf(setRole.error)}</p>}
    </section>
  );
}

function RemoveMember(props: { groupId: string; userId: string; name: string; onDone: () => void }) {
  const [reason, setReason] = useState("");
  const remove = useAction(
    async () =>
      unwrap(
        await supabase.rpc("rpc_remove_member", {
          p_group_id: props.groupId,
          p_user_id: props.userId,
          p_reason: reason,
        }),
      ),
    [["members", props.groupId]],
  );
  function submit(e: FormEvent) {
    e.preventDefault();
    remove.mutate(undefined, { onSuccess: props.onDone });
  }
  return (
    <form onSubmit={submit} className="stack inset">
      <p>Remove {props.name}? Their upcoming bookings will be cancelled. Everyone can see the reason.</p>
      <label>
        Reason
        <input required value={reason} onChange={(e) => setReason(e.target.value)} />
      </label>
      {remove.error && <p className="error">{messageOf(remove.error)}</p>}
      <div className="row">
        <button type="submit" className="danger" disabled={remove.isPending || !reason.trim()}>
          Remove
        </button>
        <button type="button" className="link" onClick={props.onDone}>
          Cancel
        </button>
      </div>
    </form>
  );
}

function Invites({ groupId, pendingDeletion }: { groupId: string; pendingDeletion: boolean }) {
  const invites = useOpenInvites(groupId);
  const [note, setNote] = useState("");
  const [link, setLink] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  const create = useAction(
    async () => {
      const res = unwrap(
        await supabase.rpc("rpc_create_invite", { p_group_id: groupId, p_note: note }),
      ) as { token: string };
      return `${window.location.origin}/join/${res.token}`;
    },
    [["invites", groupId]],
  );
  const revoke = useAction(
    async (id: string) => unwrap(await supabase.rpc("rpc_revoke_invite", { p_invitation_id: id })),
    [["invites", groupId]],
  );

  function submit(e: FormEvent) {
    e.preventDefault();
    setCopied(false);
    create.mutate(undefined, {
      onSuccess: (url) => {
        setLink(url);
        setNote("");
      },
    });
  }

  async function share(url: string) {
    if (navigator.share) {
      await navigator.share({ title: "Join our family on fam.ly", url }).catch(() => {});
    } else {
      await navigator.clipboard.writeText(url);
      setCopied(true);
    }
  }

  if (pendingDeletion) return null;

  return (
    <section className="card stack">
      <h2>Invite An Adult</h2>
      <form onSubmit={submit} className="stack">
        <label>
          <span>Who is it for? <span className="muted">(only your family sees this)</span></span>
          <input maxLength={80} placeholder="e.g. Mum" value={note} onChange={(e) => setNote(e.target.value)} />
        </label>
        <button type="submit" disabled={create.isPending}>
          Create Invite Link
        </button>
      </form>
      {create.error && <p className="error">{messageOf(create.error)}</p>}
      {link && (
        <div className="inset stack">
          <p>
            Send this link to them. It works once and expires in 3 days.{" "}
            <strong>You won&apos;t be able to see it again.</strong>
          </p>
          <input readOnly value={link} onFocus={(e) => e.currentTarget.select()} aria-label="Invite link" />
          <button onClick={() => share(link)}>{copied ? "Copied" : "Share Link"}</button>
        </div>
      )}
      {invites.data && invites.data.length > 0 && (
        <>
          <h3>Open Invites</h3>
          <ul className="list">
            {invites.data.map((inv) => (
              <li key={inv.id} className="row">
                <span>
                  {inv.note || "Invite"}{" "}
                  <span className="muted">· expires {new Date(inv.expires_at).toLocaleDateString()}</span>
                </span>
                <button
                  className="link danger"
                  disabled={revoke.isPending}
                  onClick={() => revoke.mutate(inv.id)}
                >
                  Cancel
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  );
}
