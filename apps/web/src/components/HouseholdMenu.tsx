import { useEffect, useId, useRef, useState } from "react";
import { Link, useLocation } from "react-router";
import { ChevronDown } from "./Icons";

type Group = { id: string; name: string };

/**
 * "CARTER ⌄" pill at the top right: Settings, Members & Invites and the family switcher. A disclosure
 * button + list of links, so it reads correctly with VoiceOver; closes on navigation, Escape or a tap outside.
 */
export function HouseholdMenu({ groups, group, select }: { groups: Group[]; group: Group | null; select: (id: string) => void }) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const listId = useId();
  const { pathname } = useLocation();

  useEffect(() => setOpen(false), [pathname]);
  useEffect(() => {
    if (!open) return;
    const onDown = (e: PointerEvent) => {
      if (!root.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setOpen(false);
        button.current?.focus();
      }
    };
    document.addEventListener("pointerdown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  if (!group) return null;
  return (
    <div className="household-menu" ref={root}>
      <button ref={button} className="household" aria-expanded={open} aria-controls={listId} onClick={() => setOpen(!open)}>
        <span className="household-name">{group.name}</span>
        <ChevronDown />
      </button>
      {open && (
        <div id={listId} className="popover">
          <Link to="/settings" className="popover-item">Settings</Link>
          <Link to="/family/members" className="popover-item">Members &amp; Invites</Link>
          <div className="popover-divider" aria-hidden="true" />
          <p className="popover-label">SWITCH FAMILY</p>
          {groups.map((g) => (
            <button key={g.id} className="popover-item" aria-current={g.id === group.id ? "true" : undefined}
                    onClick={() => { select(g.id); setOpen(false); }}>
              <span>{g.name}</span>
              {g.id === group.id && <span className="current">Current</span>}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
