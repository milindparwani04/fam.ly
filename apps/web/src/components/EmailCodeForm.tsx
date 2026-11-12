import { useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase";

/**
 * Email + 6-digit code sign-in. Codes (not magic links) keep the user inside the
 * installed home-screen app on iOS; a link would open Safari instead.
 * With an inviteToken, the token rides along in user metadata for the sign-up hook to check.
 */
export function EmailCodeForm({ inviteToken }: { inviteToken?: string }) {
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [step, setStep] = useState<"email" | "code">("email");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function sendCode(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      // New accounts are gated server-side by the before_user_created hook (invite token or
      // allowlist), so the client may always ask to create one.
      options: inviteToken
        ? { shouldCreateUser: true, data: { invite_token: inviteToken } }
        : { shouldCreateUser: true },
    });
    setBusy(false);
    if (error) {
      setError(
        inviteToken
          ? "We couldn't send a code. The invite may have expired. Ask for a new link."
          : "We couldn't find a fam.ly account for that email. fam.ly is invite-only: ask a family member for an invite link.",
      );
      return;
    }
    setStep("code");
  }

  async function verify(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { error } = await supabase.auth.verifyOtp({ email: email.trim(), token: code.trim(), type: "email" });
    setBusy(false);
    if (error) setError("That code didn't work. Check it, or request a new one.");
    // On success the auth listener updates the session and the route re-renders.
  }

  if (step === "email") {
    return (
      <form onSubmit={sendCode} className="stack">
        <label>
          Email
          <input
            type="email"
            autoComplete="email"
            required
            value={email}
            placeholder="you@domain.com"
            aria-describedby={inviteToken ? undefined : "email-hint"}
            onChange={(e) => setEmail(e.target.value)}
          />
        </label>
        {!inviteToken && <p id="email-hint" className="muted">Use the email your family invited.</p>}
        {error && <p className="error" role="alert">{error}</p>}
        <button type="submit" disabled={busy}>
          {busy ? "Sending…" : "Continue"}
        </button>
      </form>
    );
  }

  return (
    <form onSubmit={verify} className="stack">
      <p>We sent a code to <strong>{email}</strong>.</p>
      <label>
        Code
        <input
          inputMode="numeric"
          autoComplete="one-time-code"
          pattern="[0-9]*"
          required
          value={code}
          onChange={(e) => setCode(e.target.value)}
        />
      </label>
      {error && <p className="error" role="alert">{error}</p>}
      <button type="submit" disabled={busy}>{busy ? "Checking…" : "Sign In"}</button>
      <button type="button" className="link" onClick={() => setStep("email")}>Use A Different Email</button>
    </form>
  );
}
