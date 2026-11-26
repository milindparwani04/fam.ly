import { reviewPhase } from "@famly/domain";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { useUserId } from "./auth";
import { CURRENT_GROUP_KEY, load, save } from "./storage";
import { supabase } from "./supabase";
import { unwrap } from "./rpc";

export function useProfile() {
  const uid = useUserId();
  return useQuery({
    queryKey: ["profile", uid],
    queryFn: async () =>
      unwrap(await supabase.from("profile").select("*").eq("user_id", uid).single()),
  });
}

export function useGroups() {
  return useQuery({
    queryKey: ["groups"],
    queryFn: async () =>
      unwrap(await supabase.from("family_group").select("*").is("deleted_at", null).order("created_at")),
  });
}

/** The group the user is looking at: remembered per device, falling back to their first group. */
export function useCurrentGroup() {
  const groups = useGroups();
  const [chosen, setChosen] = useState(() => load(CURRENT_GROUP_KEY));
  const list = groups.data ?? [];
  const group = list.find((g) => g.id === chosen) ?? list[0] ?? null;
  const select = (id: string) => {
    save(CURRENT_GROUP_KEY, id);
    setChosen(id);
  };
  return { ...groups, groups: list, group, select };
}

export function useMembers(groupId: string) {
  return useQuery({
    queryKey: ["members", groupId],
    queryFn: async () => {
      const members = unwrap(
        await supabase
          .from("group_membership")
          .select("user_id, role, joined_at")
          .eq("group_id", groupId)
          .is("left_at", null)
          .order("joined_at"),
      );
      const profiles = unwrap(
        await supabase
          .from("profile")
          .select("user_id, display_name")
          .in("user_id", members.map((m) => m.user_id)),
      );
      const names = new Map(profiles.map((p) => [p.user_id, p.display_name]));
      return members.map((m) => ({ ...m, display_name: names.get(m.user_id) || "Unnamed" }));
    },
  });
}

export function useOpenInvites(groupId: string) {
  return useQuery({
    queryKey: ["invites", groupId],
    queryFn: async () =>
      unwrap(
        await supabase
          .from("invitation")
          .select("id, note, created_at, expires_at")
          .eq("group_id", groupId)
          .is("used_at", null)
          .is("revoked_at", null)
          .gt("expires_at", new Date().toISOString())
          .order("created_at", { ascending: false }),
      ),
  });
}

/** Wraps a mutation and invalidates the given query keys afterwards. */
export function useAction<TArgs, TResult>(
  fn: (args: TArgs) => Promise<TResult>,
  invalidate: string[][] = [],
) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: () => Promise.all(invalidate.map((queryKey) => qc.invalidateQueries({ queryKey }))),
  });
}

export function useVehicles(groupId: string) {
  return useQuery({
    queryKey: ["vehicles", groupId],
    queryFn: async () =>
      unwrap(
        await supabase
          .from("vehicle")
          .select("id, name, active, version")
          .eq("group_id", groupId)
          .order("active", { ascending: false })
          .order("name"),
      ),
  });
}

/**
 * Live bookings and current/future maintenance for every car in the group: everything the
 * Cars tab needs to derive status. Cars reported out stay included however late they are.
 */
export function useCarActivity(groupId: string) {
  return useQuery({
    queryKey: ["car-activity", groupId],
    refetchInterval: 60_000, // keeps "overdue" and "available" honest while the tab is open
    queryFn: async () => {
      const nowIso = new Date().toISOString();
      const recentIso = new Date(Date.now() - 12 * 3_600_000).toISOString();
      const [bookings, maintenance, outings] = await Promise.all([
        supabase
          .from("vehicle_reservation")
          .select("id, vehicle_id, owner_id, status, starts_at, ends_at, needs_reconciliation, possession_uncertain, vehicle_returned_at")
          .eq("group_id", groupId)
          .or(
            `status.eq.in_use_reported,and(status.eq.reserved,ends_at.gt.${nowIso}),` +
              `and(status.eq.completed,vehicle_returned_at.gt.${recentIso})`,
          )
          .order("starts_at"),
        supabase
          .from("vehicle_unavailability")
          .select("id, vehicle_id, starts_at, ends_at, reason")
          .eq("group_id", groupId)
          .gt("ends_at", nowIso)
          .order("starts_at"),
        // Outings that are upcoming, out now, or just back: drives the big buttons and "Out now".
        supabase
          .from("outing")
          .select("id, owner_id, reservation_id, status, planned_start, planned_return, expected_return_at, departure_reported_at, home_reported_at, family_event(title, destination, cancelled_at)")
          .eq("group_id", groupId)
          .or(`status.eq.departed,and(status.eq.planned,planned_return.gt.${recentIso}),and(status.eq.returned,home_reported_at.gt.${recentIso})`)
          .order("planned_start"),
      ]);
      return { bookings: unwrap(bookings), maintenance: unwrap(maintenance), outings: unwrap(outings) };
    },
  });
}

export function useBooking(id: string) {
  return useQuery({
    queryKey: ["booking", id],
    queryFn: async () =>
      unwrap(
        await supabase
          .from("vehicle_reservation")
          .select("id, group_id, vehicle_id, owner_id, status, starts_at, ends_at, version, needs_reconciliation, vehicle(name)")
          .eq("id", id)
          .maybeSingle(),
      ),
  });
}

/** Change history for one booking, newest first, kept separate from its planned schedule (FR-V10). */
export function useBookingHistory(id: string) {
  return useQuery({
    queryKey: ["booking-history", id],
    queryFn: async () =>
      unwrap(
        await supabase
          .from("audit_log")
          .select("id, action, actor_id, reason, before, after, at")
          .eq("target_id", id)
          .order("at", { ascending: false }),
      ),
  });
}

/** Bookings (live and completed) and maintenance overlapping [start, end). */
export function useCalendar(groupId: string, start: Date, end: Date) {
  return useQuery({
    queryKey: ["calendar", groupId, start.toISOString(), end.toISOString()],
    queryFn: async () => {
      const [bookings, maintenance] = await Promise.all([
        supabase
          .from("vehicle_reservation")
          .select("id, vehicle_id, owner_id, status, starts_at, ends_at")
          .eq("group_id", groupId)
          .in("status", ["reserved", "in_use_reported", "completed"])
          .lt("starts_at", end.toISOString())
          .gt("ends_at", start.toISOString())
          .order("starts_at"),
        supabase
          .from("vehicle_unavailability")
          .select("id, vehicle_id, starts_at, ends_at, reason")
          .eq("group_id", groupId)
          .lt("starts_at", end.toISOString())
          .gt("ends_at", start.toISOString()),
      ]);
      return { bookings: unwrap(bookings), maintenance: unwrap(maintenance) };
    },
  });
}

/** Query keys to refresh after any booking change. */
export function bookingKeys(groupId: string, bookingId?: string): string[][] {
  // Every booking is also a plan, so the plan lists change with it.
  const keys = [["car-activity", groupId], ["calendar", groupId], ["family-events", groupId]];
  if (bookingId) keys.push(["booking", bookingId], ["booking-history", bookingId], ["family-event-for-booking", bookingId]);
  return keys;
}

/** Live family events overlapping [start, end), with who's invited/attending. Visible to all members (D04). */
export function useFamilyEvents(groupId: string, start: Date, end: Date) {
  return useQuery({
    queryKey: ["family-events", groupId, start.toISOString(), end.toISOString()],
    queryFn: async () =>
      unwrap(
        await supabase
          .from("family_event")
          .select("id, title, description, starts_at, ends_at, destination, outing_id, reservation_id, created_by, repeat, repeat_until, event_participant(user_id, state)")
          .eq("group_id", groupId)
          .is("cancelled_at", null)
          .lt("starts_at", end.toISOString())
          // One-offs that overlap the window, and repeating plans that started before it and haven't ended
          // (their occurrences are worked out by the caller with occurrences()).
          .or(`ends_at.gt.${start.toISOString()},and(repeat.not.is.null,or(repeat_until.is.null,repeat_until.gte.${start.toISOString().slice(0, 10)}))`)
          .order("starts_at"),
      ),
  });
}

export function useFamilyEvent(id: string) {
  return useQuery({
    queryKey: ["family-event", id],
    queryFn: async () => {
      const event = unwrap(
        await supabase
          .from("family_event")
          .select("*, event_participant(user_id, state)")
          .eq("id", id)
          .maybeSingle(),
      );
      // Whose trip this is (tracked outing or car booking), which decides who may change it.
      const outing = event?.outing_id
        ? unwrap(await supabase.from("outing").select("owner_id, status").eq("id", event.outing_id).maybeSingle())
        : null;
      return event ? { ...event, tripOwnerId: outing?.owner_id ?? null, outingStatus: outing?.status ?? null } : null;
    },
  });
}

/** The live Family-calendar event for a booking, if it has one. */
export function useEventForBooking(reservationId: string) {
  return useQuery({
    queryKey: ["family-event-for-booking", reservationId],
    queryFn: async () =>
      unwrap(
        await supabase
          .from("family_event")
          .select("id, title")
          .eq("reservation_id", reservationId)
          .is("cancelled_at", null)
          .maybeSingle(),
      ),
  });
}

/** Self-reported status history for an outing (FR-V10): kept apart from the planned schedule. */
export function useOutingReports(outingId: string | null) {
  return useQuery({
    queryKey: ["outing-reports", outingId],
    enabled: !!outingId,
    queryFn: async () =>
      unwrap(
        await supabase
          .from("status_report")
          .select("id, kind, reported_by, reported_at, payload")
          .eq("outing_id", outingId!)
          .order("reported_at", { ascending: false }),
      ),
  });
}

/** Everything a status report can change. */
export function statusKeys(groupId: string, outingId?: string): string[][] {
  const keys = [["car-activity", groupId], ["calendar", groupId], ["family-events", groupId], ["booking"], ["family-event"], ["prompts"]];
  if (outingId) keys.push(["outing-reports", outingId]);
  return keys;
}

export function useOutingForBooking(reservationId: string) {
  return useQuery({
    queryKey: ["booking", reservationId, "outing"],
    queryFn: async () =>
      unwrap(
        await supabase
          .from("outing")
          .select("id, owner_id, reservation_id, status, planned_start, planned_return, expected_return_at, departure_reported_at, home_reported_at")
          .eq("reservation_id", reservationId)
          .maybeSingle(),
      ),
  });
}

export function useOuting(outingId: string | null) {
  return useQuery({
    queryKey: ["family-event", "outing", outingId],
    enabled: !!outingId,
    queryFn: async () =>
      unwrap(
        await supabase
          .from("outing")
          .select("id, owner_id, reservation_id, status, planned_start, planned_return, expected_return_at, departure_reported_at, home_reported_at")
          .eq("id", outingId!)
          .maybeSingle(),
      ),
  });
}

/**
 * Keeps every tab live (mounted once, in Layout): each new family feed row (someone left, came home,
 * booked, planned, finished a task) refreshes what it could have changed.
 */
export function useFamilyRealtime(groupId: string) {
  const qc = useQueryClient();
  useEffect(() => {
    if (!groupId) return;
    const channel = supabase
      .channel(`activity:${groupId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "activity_feed", filter: `group_id=eq.${groupId}` },
        () => {
          for (const key of ["activity", "car-activity", "presence", "family-events", "family-tasks", "family-menus", "family-stays", "calendar"]) {
            void qc.invalidateQueries({ queryKey: [key, groupId] });
          }
        },
      )
      .subscribe();
    return () => {
      void supabase.removeChannel(channel);
    };
  }, [groupId, qc]);
}

/** Family activity (FR-N01), newest first. Kept live by useFamilyRealtime and refreshed on focus. */
export function useActivityFeed(groupId: string) {
  return useQuery({
    queryKey: ["activity", groupId],
    queryFn: async () =>
      unwrap(
        await supabase
          .from("activity_feed")
          .select("id, kind, actor_id, subject_id, data, created_at")
          .eq("group_id", groupId)
          .order("created_at", { ascending: false })
          .limit(100),
      ),
  });
}

/** My prompts waiting for an answer: these drive the badge and the snooze buttons. */
export function useMyPrompts() {
  const uid = useUserId();
  return useQuery({
    queryKey: ["prompts", uid],
    refetchInterval: 30_000,
    queryFn: async () =>
      unwrap(
        await supabase
          .from("scheduled_prompt")
          .select("id, outing_id, kind, snooze_count, due_at, sent_at")
          // The 30-minute heads-ups ask for nothing, so they never count as waiting for an answer.
          .in("kind", ["departure", "return"])
          .eq("state", "sent"),
      ),
  });
}

export function useNotificationSettings() {
  const uid = useUserId();
  return useQuery({
    queryKey: ["notification-settings", uid],
    queryFn: async () =>
      unwrap(await supabase.from("notification_setting").select("*").eq("user_id", uid).maybeSingle()),
  });
}

/** Open tasks and ones finished in the last week, with each assignee's answer. Visible to all members (D04). */
export function useFamilyTasks(groupId: string) {
  return useQuery({
    queryKey: ["family-tasks", groupId],
    queryFn: async () => {
      const since = new Date(Date.now() - 7 * 86_400_000).toISOString();
      return unwrap(
        await supabase
          .from("family_task")
          .select("id, title, created_by, completed_at, completed_by, created_at, task_assignee(user_id, state)")
          .eq("group_id", groupId)
          .is("cancelled_at", null)
          .or(`completed_at.is.null,completed_at.gt.${since}`)
          .order("created_at", { ascending: false }),
      );
    },
  });
}

export function useFamilyTask(id: string) {
  return useQuery({
    queryKey: ["family-task", id],
    queryFn: async () =>
      unwrap(
        await supabase
          .from("family_task")
          .select("*, task_assignee(user_id, state, responded_at)")
          .eq("id", id)
          .maybeSingle(),
      ),
  });
}

/** Tasks given to me that I haven't accepted or declined yet: these drive the Family tab badge. */
export function useMyPendingTasks() {
  const uid = useUserId();
  return useQuery({
    queryKey: ["family-tasks", "mine", uid],
    refetchInterval: 60_000,
    queryFn: async () =>
      unwrap(
        await supabase
          .from("task_assignee")
          .select("task_id, family_task!inner(id)")
          .eq("user_id", uid)
          .eq("state", "pending")
          .is("family_task.cancelled_at", null)
          .is("family_task.completed_at", null),
      ),
  });
}

/** Menus from today on (in the family's time zone), with who has accepted which version. Visible to all members. */
export function useFamilyMenus(groupId: string, today: string) {
  return useQuery({
    queryKey: ["family-menus", groupId, today],
    enabled: !!groupId,
    refetchInterval: 60_000,
    queryFn: async () =>
      unwrap(
        await supabase
          .from("family_menu")
          .select("id, menu_date, items, version, created_by, updated_by, menu_acceptance(user_id, version)")
          .eq("group_id", groupId)
          .gte("menu_date", today)
          .order("menu_date")
          .order("created_at"),
      ),
  });
}

export function useFamilyMenu(id: string) {
  return useQuery({
    queryKey: ["family-menu", id],
    queryFn: async () =>
      unwrap(
        await supabase
          .from("family_menu")
          .select("*, menu_acceptance(user_id, version, accepted_at)")
          .eq("id", id)
          .maybeSingle(),
      ),
  });
}

/** Has this person accepted the menu as it stands now? (Accepting an older version doesn't count.) */
export function hasAccepted(menu: { version: number; menu_acceptance: { user_id: string; version: number }[] }, userId: string) {
  return menu.menu_acceptance.some((a) => a.user_id === userId && a.version === menu.version);
}

/**
 * Menus whose review window may be open (menu day from two days ago to today), with your review if any.
 * Today shows "Rate" for the ones you accepted and haven't rated (migration 019).
 */
export function useMenusToReview(groupId: string, oldest: string, today: string) {
  const uid = useUserId();
  return useQuery({
    queryKey: ["family-menus", groupId, "review", oldest, today, uid],
    enabled: !!groupId,
    refetchInterval: 60_000,
    queryFn: async () =>
      unwrap(
        await supabase
          .from("family_menu")
          .select("id, menu_date, items, version, menu_acceptance(user_id, version), menu_review(user_id)")
          .eq("group_id", groupId)
          .gte("menu_date", oldest)
          .lte("menu_date", today)
          .order("menu_date"),
      ),
  });
}

/** Past menus with the ratings you may see (others' are hidden until you rate; see migration 019). */
export function useMealHistory(groupId: string, today: string) {
  return useQuery({
    queryKey: ["family-menus", groupId, "history", today],
    enabled: !!groupId,
    queryFn: async () =>
      unwrap(
        await supabase
          .from("family_menu")
          .select("id, menu_date, items, version, created_by, menu_acceptance(user_id, version), menu_review(user_id, stars)")
          .eq("group_id", groupId)
          .lte("menu_date", today)
          .order("menu_date", { ascending: false })
          .limit(60),
      ),
  });
}

export function useMenuReviews(menuId: string) {
  return useQuery({
    queryKey: ["menu-reviews", menuId],
    enabled: !!menuId,
    queryFn: async () =>
      unwrap(
        await supabase
          .from("menu_review")
          .select("user_id, stars, comment, created_at")
          .eq("menu_id", menuId)
          .order("created_at"),
      ),
  });
}

/** Stays that haven't ended before `from` (live ones only). */
export function useStays(groupId: string, from: string) {
  return useQuery({
    queryKey: ["family-stays", groupId, from],
    enabled: !!groupId,
    queryFn: async () =>
      unwrap(
        await supabase
          .from("family_stay")
          .select("*")
          .eq("group_id", groupId)
          .is("cancelled_at", null)
          .gte("leaves", from)
          .order("arrives"),
      ),
  });
}

export function useStay(id: string) {
  return useQuery({
    queryKey: ["family-stay", id],
    enabled: !!id,
    queryFn: async () => unwrap(await supabase.from("family_stay").select("*").eq("id", id).maybeSingle()),
  });
}

export type Stay = NonNullable<ReturnType<typeof useStay>["data"]>;

type ReviewableMenu = NonNullable<ReturnType<typeof useMenusToReview>["data"]>[number];

/** Menus you accepted, whose rating window is open, that you haven't rated yet. */
export function menusToRate(menus: readonly ReviewableMenu[] | undefined, userId: string, now: Date, timeZone: string) {
  return (menus ?? []).filter((m) =>
    reviewPhase(m.menu_date, now, timeZone) === "open" && hasAccepted(m, userId) && !m.menu_review.some((r) => r.user_id === userId));
}

/** A menu can be accepted until its rating window opens at 22:00 on the day. */
export function stillOpenToAccept(menuDate: string, now: Date, timeZone: string) {
  return reviewPhase(menuDate, now, timeZone) === "before";
}
