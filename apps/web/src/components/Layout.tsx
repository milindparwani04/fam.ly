import { oldestReviewableDay, wallDate } from "@famly/domain";
import { useEffect } from "react";
import { Link, Outlet, useLocation, useNavigate } from "react-router";
import { useUserId } from "../lib/auth";
import { refreshPushSubscription, setBadge } from "../lib/push";
import {
  hasAccepted, menusToRate, stillOpenToAccept, useCurrentGroup, useFamilyMenus, useFamilyRealtime, useMenusToReview, useMyPendingTasks,
  useMyPrompts,
} from "../lib/queries";
import { Toast, UIProvider, useUI } from "../lib/ui";
import { HouseholdMenu } from "./HouseholdMenu";
import { BellIcon, CalendarIcon, CarIcon, ChevronLeft, ClockIcon } from "./Icons";
import { AddCarSheet, BookSheet, ScheduleSheet } from "./CarSheets";
import { LeaveSheet } from "./LeaveSheet";
import { PersonSheet } from "./PersonSheet";
import { RateSheet } from "./RateSheet";

type Tab = "today" | "plans" | "cars" | "activity";

/** The four tabs own exactly these routes; everything else is a sub-page with a back button. */
function tabOf(pathname: string): Tab | null {
  if (pathname === "/") return "today";
  if (pathname === "/family") return "plans";
  if (pathname === "/cars") return "cars";
  if (pathname === "/activity") return "activity";
  return null;
}

/** Title and where Back goes when there's no history (opened from a notification). */
function subpageOf(pathname: string, search: string): { title: string; parent: string } {
  const rules: Array<[RegExp, string, string]> = [
    [/^\/family\/all$/, "All Plans", "/family"],
    [/^\/family\/todos$/, "All Tasks", "/family?view=todos"],
    [/^\/family\/members$/, "Members & Invites", "/"],
    [/^\/family\/create$/, "New Plan", "/family"],
    [/^\/family\/new$/, new URLSearchParams(search).has("reservation") ? "Add To Plans" : "New Event", "/family"],
    [/^\/family\/tasks\/new$/, "New Task", "/family"],
    [/^\/family\/menus\/new$/, "New Menu", "/family"],
    [/^\/family\/stays\/new$/, "New Stay", "/family?view=stays"],
    [/^\/family\/stays\//, "Stay", "/family?view=stays"],
    [/^\/family\/events\//, "Plan", "/family"],
    [/^\/family\/tasks\//, "Task", "/family?view=todos"],
    [/^\/family\/menus\//, "Menu", "/family"],
    [/^\/bookings\//, "Booking", "/cars"],
    [/^\/cars\//, "Manage Car", "/cars"],
    [/^\/calendar$/, "Car Schedule", "/cars"],
    [/^\/book$/, "Book A Car", "/cars"],
    [/^\/settings$/, "Settings", "/"],
    [/^\/shared$/, "What's Shared", "/settings"],
    [/^\/documents$/, "Documents", "/settings"],
    [/^\/documents\//, "Documents", "/documents"],
  ];
  const hit = rules.find(([re]) => re.test(pathname));
  return hit ? { title: hit[1], parent: hit[2] } : { title: "", parent: "/" };
}

export function Layout() {
  return (
    <UIProvider>
      <Shell />
    </UIProvider>
  );
}

function Shell() {
  const { groups, group, select } = useCurrentGroup();
  const { pathname, search } = useLocation();
  const navigate = useNavigate();
  const ui = useUI();
  const tab = tabOf(pathname);
  const prompts = useMyPrompts();
  const tasks = useMyPendingTasks();
  const uid = useUserId();
  const tz = group?.time_zone ?? "Asia/Dubai";
  const now = new Date();
  const today = wallDate(now, tz);
  const menus = useFamilyMenus(group?.id ?? "", today);
  const toReview = useMenusToReview(group?.id ?? "", oldestReviewableDay(today), today);
  const menuCount = group
    ? (menus.data ?? []).filter((m) => !hasAccepted(m, uid) && stillOpenToAccept(m.menu_date, now, tz)).length
      + menusToRate(toReview.data, uid, now, tz).length
    : 0;
  // Everything waiting for my answer: car prompts, task requests and menus (also the app icon badge).
  const waiting = (prompts.data?.length ?? 0) + (tasks.data?.length ?? 0) + menuCount;
  useEffect(() => setBadge(waiting), [waiting]);
  useEffect(() => {
    void refreshPushSubscription();
  }, []);
  useFamilyRealtime(group?.id ?? "");
  // Moving anywhere closes any sheet.
  const { close } = ui;
  useEffect(() => close(), [pathname, close]);

  const tabLink = (to: string, id: Tab, label: string, Icon: typeof ClockIcon, badge?: number) => (
    <Link to={to} className={tab === id ? "active" : undefined} aria-current={tab === id ? "page" : undefined}>
      <Icon />
      {label}
      {badge ? <span className="count" aria-label={`, ${badge} waiting for you`}>{badge}</span> : null}
    </Link>
  );

  const sub = tab ? null : subpageOf(pathname, search);
  const back = () => {
    // react-router keeps the history index in history.state; at 0 there's nothing in the app to go back to.
    const idx = (window.history.state as { idx?: number } | null)?.idx ?? 0;
    if (idx > 0) navigate(-1);
    else navigate(sub?.parent ?? "/");
  };

  return (
    <div className="app">
      <header className="topbar">
        <Link to="/" className="wordmark" aria-label="fam.ly, Today">fam.ly</Link>
        <HouseholdMenu groups={groups} group={group} select={select} />
      </header>
      <main>
        {sub ? (
          <div className="subpage">
            <div className="subpage-head">
              <button className="back" onClick={back} aria-label="Back"><ChevronLeft /></button>
              <h1>{sub.title}</h1>
            </div>
            <div className="subpage-body">
              <Outlet />
            </div>
          </div>
        ) : (
          <Outlet />
        )}
      </main>
      <nav className="tabbar" aria-label="Main">
        {tabLink("/", "today", "Today", ClockIcon, waiting)}
        {tabLink("/family", "plans", "Plans", CalendarIcon)}
        {tabLink("/cars", "cars", "Cars", CarIcon)}
        {tabLink("/activity", "activity", "Activity", BellIcon)}
      </nav>
      <Toast />
      {group && <Sheets groupId={group.id} timeZone={group.time_zone} />}
    </div>
  );
}

function Sheets({ groupId, timeZone }: { groupId: string; timeZone: string }) {
  const { sheet } = useUI();
  if (!sheet) return null;
  switch (sheet.kind) {
    case "book":
      return <BookSheet groupId={groupId} timeZone={timeZone} vehicleId={sheet.vehicleId} />;
    case "schedule":
      return <ScheduleSheet groupId={groupId} timeZone={timeZone} vehicleId={sheet.vehicleId} />;
    case "leave":
      return <LeaveSheet groupId={groupId} timeZone={timeZone} outingId={sheet.outingId} />;
    case "addCar":
      return <AddCarSheet groupId={groupId} />;
    case "rate":
      return <RateSheet groupId={groupId} timeZone={timeZone} menuId={sheet.menuId} />;
    case "person":
      return <PersonSheet groupId={groupId} timeZone={timeZone} userId={sheet.userId} />;
  }
}
