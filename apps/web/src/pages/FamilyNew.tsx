import { Link } from "react-router";
import { CalendarIcon, CheckCircleIcon, MenuIcon, PersonIcon } from "../components/Icons";

const KINDS = [
  { to: "/family/new", cls: "drive", Icon: CalendarIcon, title: "Event", sub: "A dinner, trip or appointment; can repeat weekly or monthly" },
  { to: "/family/tasks/new", cls: "errand", Icon: CheckCircleIcon, title: "Task", sub: "Ask someone in the family to do something" },
  { to: "/family/menus/new", cls: "padel", Icon: MenuIcon, title: "Menu", sub: "Propose what the cook makes; everyone can accept or modify it" },
  { to: "/family/stays/new", cls: "gym", Icon: PersonIcon, title: "Stay", sub: "Someone staying with the family, from when until when" },
];

/** Plans → New: choose what to add. Everyone in the family is notified about it. */
export function FamilyNew() {
  return (
    <div className="stack">
      {KINDS.map(({ to, cls, Icon, title, sub }) => (
        <Link key={to} to={to} className={`new-kind press ${cls}`}>
          <Icon />
          <span className="text"><span className="t">New {title}</span><span className="s">{sub}</span></span>
        </Link>
      ))}
      <p className="muted" style={{ fontSize: 13 }}>Everyone in the family is notified when you add something, so nobody&apos;s surprised.</p>
    </div>
  );
}
