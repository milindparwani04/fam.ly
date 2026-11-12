import { useState, type FormEvent } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

/** Display name + adults-only confirmation (FR-A02). Required before creating or joining a family. */
export function ProfileSetup({ initialName }: { initialName: string }) {
  const qc = useQueryClient();
  const [name, setName] = useState(initialName);
  const [adult, setAdult] = useState(false);
  const [under18, setUnder18] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (under18) {
    return (
      <div className="stack">
        <h2>fam.ly Is For Adults Only</h2>
        <p>Sorry, you need to be 18 or over to use fam.ly. Nothing has been shared with your family.</p>
        <button className="link" onClick={() => supabase.auth.signOut()}>Sign Out</button>
      </div>
    );
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
      unwrap(await supabase.rpc("rpc_update_profile", { p_display_name: name, p_time_zone: timeZone }));
      unwrap(await supabase.rpc("rpc_attest_adult", { p_confirm: true }));
      await qc.invalidateQueries({ queryKey: ["profile"] });
    } catch (err) {
      setError(messageOf(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={submit} className="stack">
      <h2>About You</h2>
      <label>
        Your name, as your family will see it
        <input required maxLength={80} value={name} onChange={(e) => setName(e.target.value)} />
      </label>
      <label className="check">
        <input type="checkbox" checked={adult} onChange={(e) => setAdult(e.target.checked)} />
        I confirm I am 18 or older
      </label>
      {error && <p className="error" role="alert">{error}</p>}
      <button type="submit" disabled={busy || !adult || !name.trim()}>{busy ? "Saving…" : "Continue"}</button>
      <button type="button" className="link" onClick={() => setUnder18(true)}>I'm Under 18</button>
    </form>
  );
}
