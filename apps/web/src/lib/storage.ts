// Per-device conveniences only. Every access is guarded: storage can be unavailable.
export function load(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function save(key: string, value: string | null): void {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    // ignore
  }
}

export const PENDING_INVITE_KEY = "famly.pendingInvite";
export const CURRENT_GROUP_KEY = "famly.groupId";
