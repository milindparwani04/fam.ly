import { useCurrentGroup, useMembers } from "../lib/queries";

/**
 * Initials for a member ("Maya Carter" → "MC", "Aman" → "AM"). When two people in the family would
 * share initials (Mark and Maya Carter), each falls back to the first two letters of their first
 * name (MI, MO). The name is always shown or read beside it.
 */
export function initials(name: string, family: readonly string[] = []): string {
  const short = (n: string) => {
    const parts = n.trim().split(/\s+/).filter(Boolean);
    if (parts.length === 0) return "?";
    if (parts.length === 1) return parts[0]!.slice(0, 2).toUpperCase();
    return (parts[0]![0]! + parts[parts.length - 1]![0]!).toUpperCase();
  };
  const mine = short(name);
  const clash = family.some((other) => other.trim() !== name.trim() && short(other) === mine);
  if (!clash) return mine;
  return (name.trim().split(/\s+/)[0] ?? "?").slice(0, 2).toUpperCase();
}

/** Sun, tomato, mint or lilac, fixed per name (stable hash) so a member keeps one colour everywhere. */
export function colourOf(name: string): number {
  let h = 0;
  for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return h % 4;
}

export function Avatar({ name, size, children }: { name: string; size?: "sm" | "md" | "lg"; children?: React.ReactNode }) {
  const { group } = useCurrentGroup();
  const members = useMembers(group?.id ?? "");
  const family = members.data?.map((m) => m.display_name) ?? [];
  return (
    <span className={`avatar c${colourOf(name)}${size ? ` ${size}` : ""}`} aria-hidden="true">
      {initials(name, family)}
      {children}
    </span>
  );
}

/** Overlapping 26px avatars (plan and task rows), then "+N". */
export function AvatarStack({ names, max = 4 }: { names: string[]; max?: number }) {
  if (names.length === 0) return null;
  const shown = names.slice(0, max);
  const extra = names.length - shown.length;
  return (
    <span className="stack-avatars" role="img" aria-label={`With ${names.join(", ")}`}>
      {shown.map((n, i) => <Avatar key={`${n}-${i}`} name={n} size="sm" />)}
      {extra > 0 && <span className="avatar sm more" aria-hidden="true">+{extra}</span>}
    </span>
  );
}
