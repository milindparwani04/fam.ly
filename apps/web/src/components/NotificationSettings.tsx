import { useEffect, useState } from "react";
import { disablePush, enablePush, isIOS, pushState, type PushState } from "../lib/push";
import { useAction, useNotificationSettings } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";
import { ToggleRow, useUI } from "../lib/ui";

type Categories = { moves: boolean; bookings: boolean; plans: boolean; tasks: boolean };
const CATEGORY_ROWS: Array<{ k: keyof Categories; t: string; s: string }> = [
  { k: "moves", t: "Departures & returns", s: "When someone leaves, comes home or runs late" },
  { k: "bookings", t: "Car bookings", s: "When someone books or changes a car booking" },
  { k: "plans", t: "New plans & invites", s: "Events, menus, stays and the 10pm food rating" },
  { k: "tasks", t: "Requests", s: "When someone asks you to do something, and a 6pm reminder of open to-dos" },
];

/** Settings → Notifications: this device's push (P08-5b), what to be told about, quiet hours (OP-09: defer). */
export function NotificationSettings() {
  const ui = useUI();
  const settings = useNotificationSettings();
  const s = settings.data;
  const [cats, setCats] = useState<Categories>({ moves: true, bookings: true, plans: true, tasks: true });
  const [quiet, setQuiet] = useState<{ on: boolean; start: string; end: string }>({ on: false, start: "22:00", end: "07:00" });
  useEffect(() => {
    if (!s) return;
    setCats({ moves: s.notify_moves, bookings: s.notify_bookings, plans: s.notify_plans, tasks: s.notify_tasks });
    if (s.quiet_start && s.quiet_end) setQuiet({ on: true, start: s.quiet_start.slice(0, 5), end: s.quiet_end.slice(0, 5) });
  }, [s]);

  const saveCats = useAction(
    async (c: Categories) =>
      unwrap(await supabase.rpc("rpc_update_notification_categories", {
        p_moves: c.moves, p_bookings: c.bookings, p_plans: c.plans, p_tasks: c.tasks,
      })),
    [["notification-settings"]],
  );
  const saveQuiet = useAction(
    async (q: { on: boolean; start: string; end: string }) =>
      unwrap(await supabase.rpc("rpc_update_notification_settings", {
        p_push_enabled: true,
        p_quiet_start: (q.on ? q.start : null) as string,
        p_quiet_end: (q.on ? q.end : null) as string,
      })),
    [["notification-settings"]],
  );
  const setCat = (k: keyof Categories, on: boolean) => {
    const next = { ...cats, [k]: on };
    setCats(next);
    saveCats.mutate(next);
  };
  const setQ = (q: typeof quiet) => {
    setQuiet(q);
    if (q.on && (!q.start || !q.end || q.start === q.end)) return;
    saveQuiet.mutate(q, { onSuccess: () => ui.toast(q.on ? `Quiet hours ${q.start} – ${q.end}` : "Quiet hours off") });
  };
  const error = saveCats.error ?? saveQuiet.error;

  return (
    <div className="set-card">
      <DevicePush />
      {CATEGORY_ROWS.map((r) => (
        <ToggleRow key={r.k} title={r.t} sub={r.s} on={cats[r.k]} onChange={(on) => setCat(r.k, on)} />
      ))}
      <ToggleRow title="Quiet hours" on={quiet.on} onChange={(on) => setQ({ ...quiet, on })}
                 sub={quiet.on ? `${quiet.start} – ${quiet.end} · held until they end` : "Hold notifications overnight"} />
      {quiet.on && (
        <div className="set-block">
          <div className="field-row">
            <label>From<input type="time" value={quiet.start} onChange={(e) => setQuiet({ ...quiet, start: e.target.value })} onBlur={() => setQ(quiet)} /></label>
            <label>Until<input type="time" value={quiet.end} onChange={(e) => setQuiet({ ...quiet, end: e.target.value })} onBlur={() => setQ(quiet)} /></label>
          </div>
          <p className="set-sub">Held notifications are dropped if they&apos;re out of date by then. Activity always shows everything.</p>
        </div>
      )}
      {error && <div className="set-block"><p className="error" role="alert">{messageOf(error)}</p></div>}
    </div>
  );
}

/** Push on this device: install steps on iPhone, turn on, test, turn off. */
function DevicePush() {
  const [state, setState] = useState<PushState | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  useEffect(() => {
    void pushState().then(setState);
  }, []);

  async function run(fn: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (err) {
      setError(messageOf(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="set-block">
      <span className="set-title">This Device</span>
      {state === null && <p className="set-sub">Checking…</p>}
      {state === "needs-install" && (
        <div className="stack tight">
          <p className="set-sub">To get notifications on {isIOS() ? "iPhone" : "this device"}, fam.ly has to be on your Home Screen:</p>
          <ol className="steps set-sub">
            <li>Tap <strong>Share</strong> in Safari (the square with an arrow).</li>
            <li>Choose <strong>Add to Home Screen</strong>, then <strong>Add</strong>.</li>
            <li>Open <strong>fam.ly</strong> from your Home Screen and come back here.</li>
          </ol>
        </div>
      )}
      {state === "unsupported" && <p className="set-sub">This browser can&apos;t receive notifications. Everything still works in the app.</p>}
      {state === "denied" && (
        <p className="warn-text">
          Notifications are blocked for fam.ly. Turn them on in your device settings
          {isIOS() ? " (Settings → Notifications → fam.ly)" : " (site settings for this page)"}, then reopen the app.
        </p>
      )}
      {state === "off" && (
        <>
          <p className="set-sub">Get told when someone leaves, gets home, books a car or makes a plan.</p>
          <button className="press" disabled={busy} onClick={() => run(async () => setState(await enablePush()))}>Turn On Notifications</button>
        </>
      )}
      {state === "on" && (
        <>
          <p className="set-sub">On for this device. Notifications can be late or missing, so check the app too.</p>
          <div className="field-row">
            <button className="secondary" disabled={busy}
                    onClick={() => run(async () => { unwrap(await supabase.rpc("rpc_send_test_push")); setSent(true); })}>
              Send Test
            </button>
            <button className="secondary" disabled={busy} onClick={() => run(async () => { await disablePush(); setState("off"); })}>
              Turn Off
            </button>
          </div>
          {sent && <p className="set-sub" role="status">Sent. It should arrive within a few seconds.</p>}
        </>
      )}
      {error && <p className="error" role="alert">{error}</p>}
    </div>
  );
}
