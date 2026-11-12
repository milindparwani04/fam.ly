import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { errorMessage, type RpcErrorCode } from "@famly/domain";
import { EmailCodeForm } from "../components/EmailCodeForm";
import { Onboarding, Splash } from "../components/Onboarding";
import { ProfileSetup } from "../components/ProfileSetup";
import { useAuth } from "../lib/auth";
import { useProfile } from "../lib/queries";
import { AppError, messageOf, unwrap } from "../lib/rpc";
import { CURRENT_GROUP_KEY, PENDING_INVITE_KEY, save } from "../lib/storage";
import { supabase } from "../lib/supabase";

type Preview =
  | { valid: true; group_name: string; invited_by: string | null; expires_at: string }
  | { valid: false; reason: RpcErrorCode };

export function Join() {
  const { token = "" } = useParams();
  const { session, loading } = useAuth();

  // Remember the invite through the sign-in round trip.
  useEffect(() => save(PENDING_INVITE_KEY, token), [token]);

  const preview = useQuery({
    queryKey: ["invite-preview", token],
    queryFn: async () =>
      unwrap(await supabase.rpc("rpc_preview_invite", { p_token: token })) as unknown as Preview,
  });

  if (loading || preview.isPending) return <Splash />;
  if (preview.isError) return <Onboarding title="Invite Link"><p className="error">{messageOf(preview.error)}</p></Onboarding>;

  const p = preview.data;
  if (!p.valid) {
    save(PENDING_INVITE_KEY, null);
    return (
      <Onboarding title="Invite Link">
        <p className="error">{errorMessage(p.reason)}</p>
        <Link className="button block" to="/">Go To fam.ly</Link>
      </Onboarding>
    );
  }

  return (
    <Onboarding title={`Join ${p.group_name}`}>
      <p>
        {p.invited_by ? `${p.invited_by} invited you` : "You've been invited"} to coordinate cars and
        outings with <strong>{p.group_name}</strong> on fam.ly.
      </p>
      {session ? <AcceptInvite token={token} groupName={p.group_name} /> : <EmailCodeForm inviteToken={token} />}
    </Onboarding>
  );
}

function AcceptInvite({ token, groupName }: { token: string; groupName: string }) {
  const profile = useProfile();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (profile.isPending) return <p>Loading…</p>;
  if (profile.isError) return <p className="error">{messageOf(profile.error)}</p>;
  if (!profile.data.adult_attested_at || !profile.data.display_name) {
    return <ProfileSetup initialName={profile.data.display_name} />;
  }

  async function accept() {
    setBusy(true);
    setError(null);
    try {
      const groupId = unwrap(await supabase.rpc("rpc_accept_invite", { p_token: token }));
      finish(groupId);
    } catch (err) {
      if (err instanceof AppError && err.rpc.code === "already_member") return finish(null);
      setError(messageOf(err));
      setBusy(false);
    }
  }

  async function finish(groupId: string | null) {
    save(PENDING_INVITE_KEY, null);
    if (groupId) save(CURRENT_GROUP_KEY, groupId);
    await qc.invalidateQueries({ queryKey: ["groups"] });
    navigate("/", { replace: true });
  }

  return (
    <div className="stack">
      <p className="notice">
        Everyone in {groupName} will see your car bookings, outings and "left / home" updates.{" "}
        <Link to="/about-sharing">What's shared?</Link>
      </p>
      {error && <p className="error" role="alert">{error}</p>}
      <button onClick={accept} disabled={busy}>{busy ? "Joining…" : `Join ${groupName}`}</button>
      <button className="link" onClick={() => { save(PENDING_INVITE_KEY, null); navigate("/"); }}>
        Not Now
      </button>
    </div>
  );
}
