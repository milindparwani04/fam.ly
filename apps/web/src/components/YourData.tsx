import { useState, type FormEvent } from "react";
import { messageOf, unwrap } from "../lib/rpc";
import { DownloadIcon } from "./Icons";
import { supabase } from "../lib/supabase";

/** FR-D03: export and account deletion. */
export function YourData() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [typed, setTyped] = useState("");

  async function download() {
    setBusy(true);
    setError(null);
    try {
      const data = unwrap(await supabase.rpc("rpc_export_my_data"));
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `famly-my-data-${new Date().toISOString().slice(0, 10)}.json`;
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError(messageOf(err));
    } finally {
      setBusy(false);
    }
  }

  async function deleteAccount(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      unwrap(await supabase.rpc("rpc_delete_my_account", { p_confirm: typed }));
      await supabase.auth.signOut({ scope: "local" });
    } catch (err) {
      setError(messageOf(err));
      setBusy(false);
    }
  }

  return (
    <section className="stack">
      <button className="secondary" disabled={busy} onClick={download}><DownloadIcon />Download My Data</button>
      <p className="muted">A file with your account, bookings, outings, status updates, events and settings.</p>

      {!deleting ? (
        <button className="link danger" onClick={() => setDeleting(true)}>Delete My Account…</button>
      ) : (
        <form onSubmit={deleteAccount} className="stack inset">
          <p>
            This permanently deletes your account, your profile and your bookings, and removes you from every
            family. Upcoming bookings are cancelled. Family history keeps what happened but no longer shows it was you.
            If you&apos;re the only member of a family, that family is deleted too.
          </p>
          <label>
            <span>Type <strong>DELETE</strong> to confirm</span>
            <input value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" />
          </label>
          <div className="row">
            <button type="submit" className="danger" disabled={busy || typed !== "DELETE"}>Delete My Account</button>
            <button type="button" className="link" onClick={() => setDeleting(false)}>Cancel</button>
          </div>
        </form>
      )}
      {error && <p className="error" role="alert">{error}</p>}
      <a href="/privacy">Privacy &amp; Terms</a>
    </section>
  );
}
