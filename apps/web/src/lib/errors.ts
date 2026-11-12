import { supabase } from "./supabase";

// Client error reporting (NFR-09) into our own database, no third party. The server caps volume,
// strips record ids from paths and drops reports from signed-out visitors.
let sent = 0;

export function reportError(err: unknown): void {
  if (sent >= 10) return; // per page load; the server also rate-limits
  sent++;
  const e = err instanceof Error ? err : new Error(String(err));
  void supabase
    .rpc("rpc_report_client_error", {
      p_message: `${e.name}: ${e.message}`.slice(0, 500),
      p_stack: (e.stack ?? "").slice(0, 4000),
      p_path: window.location.pathname,
      p_user_agent: navigator.userAgent,
    })
    .then(() => undefined, () => undefined);
}

export function installGlobalErrorReporting(): void {
  window.addEventListener("error", (ev) => reportError(ev.error ?? ev.message));
  window.addEventListener("unhandledrejection", (ev) => reportError(ev.reason));
}
