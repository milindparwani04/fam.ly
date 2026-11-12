import { useState, type FormEvent } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { messageOf, unwrap } from "../lib/rpc";
import { CURRENT_GROUP_KEY, save } from "../lib/storage";
import { Onboarding } from "../components/Onboarding";
import { supabase } from "../lib/supabase";

/** Signed in, attested, but in no family yet. */
export function Welcome() {
  const qc = useQueryClient();
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function create(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
      const id = unwrap(await supabase.rpc("rpc_create_group", { p_name: name, p_time_zone: timeZone }));
      save(CURRENT_GROUP_KEY, id);
      await qc.invalidateQueries({ queryKey: ["groups"] });
    } catch (err) {
      setError(messageOf(err));
      setBusy(false);
    }
  }

  return (
    <Onboarding title="Start Your Family">
      <form onSubmit={create} className="stack">
        <label>
          Family name
          <input required maxLength={80} placeholder="e.g. The Carters" value={name}
                 onChange={(e) => setName(e.target.value)} />
        </label>
        {error && <p className="error" role="alert">{error}</p>}
        <button type="submit" disabled={busy || !name.trim()}>{busy ? "Creating…" : "Create Family"}</button>
      </form>
      <p className="muted">Joining someone else's family? Open the invite link they sent you.</p>
      <button className="link" onClick={() => supabase.auth.signOut()}>Sign Out</button>
    </Onboarding>
  );
}
