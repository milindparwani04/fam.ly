// push-dispatch: claims due notification deliveries, sends Web Push, records the outcome (FR-N06).
// Called every 10 s by pg_cron (app.kick_push_dispatch) with a shared secret. The database decides
// what is due and still relevant; this function only talks to push services.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import webpush from "npm:web-push@3.6.7";

const SECRET = Deno.env.get("PUSH_DISPATCH_SECRET") ?? "";
const PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "";

interface Claimed {
  delivery_id: number;
  endpoint: string;
  p256dh: string;
  auth_secret: string;
  title: string;
  body: string;
  url: string;
  tag: string;
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  if (!SECRET || !timingSafeEqual(req.headers.get("x-dispatch-secret") ?? "", SECRET)) {
    return new Response("forbidden", { status: 403 });
  }
  if (!PUBLIC_KEY || !PRIVATE_KEY || !SUBJECT) {
    return new Response("push not configured", { status: 500 });
  }
  webpush.setVapidDetails(SUBJECT, PUBLIC_KEY, PRIVATE_KEY);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const { data, error } = await db.rpc("dispatch_claim_deliveries", { p_limit: 50 });
  if (error) {
    console.error(JSON.stringify({ msg: "claim_failed", error: error.message }));
    return new Response("claim failed", { status: 500 });
  }
  const batch = (data ?? []) as Claimed[];

  const outcomes = await Promise.all(
    batch.map(async (d) => {
      try {
        const res = await webpush.sendNotification(
          { endpoint: d.endpoint, keys: { p256dh: d.p256dh, auth: d.auth_secret } },
          JSON.stringify({ title: d.title, body: d.body, url: d.url, tag: d.tag }),
          { TTL: 6 * 60 * 60, urgency: d.tag.startsWith("prompt.") ? "high" : "normal" },
        );
        return { id: d.delivery_id, status: res.statusCode, error: null as string | null };
      } catch (e) {
        const err = e as { statusCode?: number; body?: string; message?: string };
        return { id: d.delivery_id, status: err.statusCode ?? 0, error: (err.body || err.message || "send failed").slice(0, 500) };
      }
    }),
  );

  for (const o of outcomes) {
    const { error: completeError } = await db.rpc("dispatch_complete_delivery", {
      p_delivery_id: o.id,
      p_status: o.status,
      p_error: o.error,
    });
    if (completeError) console.error(JSON.stringify({ msg: "complete_failed", id: o.id, error: completeError.message }));
  }

  // Structured, PII-free log line (NFR-09): counts by status only.
  const byStatus: Record<string, number> = {};
  for (const o of outcomes) byStatus[o.status] = (byStatus[o.status] ?? 0) + 1;
  console.log(JSON.stringify({ msg: "dispatched", count: outcomes.length, byStatus }));
  return Response.json({ dispatched: outcomes.length, byStatus });
});
