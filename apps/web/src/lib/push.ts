import { unwrap } from "./rpc";
import { supabase } from "./supabase";

// Web Push on this device (ADR-001: installable PWA). iOS only allows push for apps added to the
// Home Screen, and only asks for permission in response to a tap.

export function isIOS(): boolean {
  const ua = navigator.userAgent;
  return /iPhone|iPad|iPod/.test(ua) || (ua.includes("Macintosh") && navigator.maxTouchPoints > 1);
}

export function isStandalone(): boolean {
  return window.matchMedia("(display-mode: standalone)").matches || (navigator as { standalone?: boolean }).standalone === true;
}

export function pushSupported(): boolean {
  return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
}

export type PushState =
  | "unsupported"        // browser can't do push at all
  | "needs-install"      // iPhone/iPad in Safari: add to Home Screen first
  | "denied"             // permission refused; must be changed in system settings
  | "off"                // can be turned on
  | "on";                // subscribed and registered

export async function registerServiceWorker(): Promise<void> {
  if (!("serviceWorker" in navigator)) return;
  try {
    await navigator.serviceWorker.register("/sw.js");
  } catch (err) {
    console.warn("service worker registration failed", err);
  }
}

export async function pushState(): Promise<PushState> {
  if (isIOS() && !isStandalone()) return "needs-install";
  if (!pushSupported()) return "unsupported";
  if (Notification.permission === "denied") return "denied";
  const reg = await navigator.serviceWorker.getRegistration();
  const sub = await reg?.pushManager.getSubscription();
  return sub && Notification.permission === "granted" ? "on" : "off";
}

function vapidKey(): Uint8Array {
  const b64 = import.meta.env.VITE_VAPID_PUBLIC_KEY;
  const padded = (b64 + "=".repeat((4 - (b64.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

async function register(sub: PushSubscription): Promise<void> {
  const json = sub.toJSON();
  unwrap(
    await supabase.rpc("rpc_register_device", {
      p_endpoint: sub.endpoint,
      p_p256dh: json.keys?.p256dh ?? "",
      p_auth: json.keys?.auth ?? "",
      p_user_agent: navigator.userAgent,
    }),
  );
}

/** Must be called from a tap (iOS requirement). */
export async function enablePush(): Promise<PushState> {
  const permission = await Notification.requestPermission();
  if (permission !== "granted") return permission === "denied" ? "denied" : "off";
  const reg = await navigator.serviceWorker.ready;
  const sub =
    (await reg.pushManager.getSubscription()) ??
    (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: vapidKey() as BufferSource }));
  await register(sub);
  return "on";
}

export async function disablePush(): Promise<void> {
  const reg = await navigator.serviceWorker.getRegistration();
  const sub = await reg?.pushManager.getSubscription();
  if (!sub) return;
  unwrap(await supabase.rpc("rpc_unregister_device", { p_endpoint: sub.endpoint }));
  await sub.unsubscribe();
}

/**
 * On every app open: if permission is granted, make sure this device still has a subscription and
 * that the server knows it belongs to the signed-in person (P08-5b re-subscribe).
 */
export async function refreshPushSubscription(): Promise<void> {
  if (!pushSupported() || Notification.permission !== "granted") return;
  try {
    const reg = await navigator.serviceWorker.ready;
    const sub =
      (await reg.pushManager.getSubscription()) ??
      (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: vapidKey() as BufferSource }));
    await register(sub);
  } catch (err) {
    console.warn("push refresh failed", err);
  }
}

/** Home-screen badge = pending actions (Badging API, where available). */
export function setBadge(count: number): void {
  const nav = navigator as Navigator & { setAppBadge?: (n?: number) => Promise<void>; clearAppBadge?: () => Promise<void> };
  try {
    if (count > 0) void nav.setAppBadge?.(count);
    else void nav.clearAppBadge?.();
  } catch {
    // unsupported
  }
}
