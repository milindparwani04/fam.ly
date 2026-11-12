// health-check (P09-5, NFR-09): hourly via pg_cron. Runs the database health snapshot (which includes a
// self-rolling-back synthetic booking journey), checks the website responds, and emails the operator
// only when the overall state changes (problem appears / clears).
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const SECRET = Deno.env.get("PUSH_DISPATCH_SECRET") ?? "";
const APP_URL = Deno.env.get("APP_URL") ?? "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const ALERT_TO = Deno.env.get("OPS_ALERT_EMAIL") ?? "";
const ALERT_FROM = Deno.env.get("OPS_ALERT_FROM") ?? "fam.ly monitor <no-reply@example.com>";

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function sendEmail(subject: string, text: string): Promise<void> {
  if (!RESEND_API_KEY || !ALERT_TO) {
    console.log(JSON.stringify({ msg: "alert_not_sent_unconfigured", subject }));
    return;
  }
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { authorization: `Bearer ${RESEND_API_KEY}`, "content-type": "application/json" },
    body: JSON.stringify({ from: ALERT_FROM, to: [ALERT_TO], subject, text }),
  });
  if (!res.ok) console.error(JSON.stringify({ msg: "alert_send_failed", status: res.status }));
}

Deno.serve(async (req) => {
  if (req.method !== "POST" || !SECRET || !safeEqual(req.headers.get("x-dispatch-secret") ?? "", SECRET)) {
    return new Response("forbidden", { status: 403 });
  }
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const problems: string[] = [];
  const { data: snap, error } = await db.rpc("ops_health_snapshot");
  if (error) problems.push(`health snapshot failed: ${error.message}`);
  else problems.push(...((snap?.problems as string[]) ?? []));

  if (APP_URL) {
    try {
      const res = await fetch(APP_URL, { method: "GET", signal: AbortSignal.timeout(10_000) });
      if (res.status !== 200) problems.push(`website returned HTTP ${res.status}`);
    } catch (e) {
      problems.push(`website unreachable: ${(e as Error).message}`);
    }
  }

  const state = problems.length === 0 ? "ok" : "problem";
  const { data: previous } = await db.rpc("ops_swap_health_state", { p_state: state });

  if (state === "problem" && previous !== "problem") {
    await sendEmail("fam.ly: something needs attention", `Health check found:\n\n- ${problems.join("\n- ")}\n\nChecked ${new Date().toISOString()}.`);
  } else if (state === "ok" && previous === "problem") {
    await sendEmail("fam.ly: all clear again", `The earlier problem has cleared. Checked ${new Date().toISOString()}.`);
  }

  console.log(JSON.stringify({ msg: "health", state, problems: problems.length, client_errors_24h: snap?.client_errors_24h ?? null }));
  return Response.json({ state, problems });
});
