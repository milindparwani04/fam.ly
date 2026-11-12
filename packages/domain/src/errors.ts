import { z } from "zod";

/** Error codes raised by the rpc_* functions (message text is the code). */
export const RPC_ERROR_CODES = [
  "not_authenticated",
  "not_found",
  "not_owner",
  "invalid_period",
  "starts_in_past",
  "too_long",
  "invalid_idempotency_key",
  "invalid_time_zone",
  "vehicle_inactive",
  "vehicle_unavailable",
  "reservation_conflict",
  "stale_version",
  "invalid_state",
  "adult_attestation_required",
  "invalid_display_name",
  "invalid_name",
  "invalid_ttl",
  "invite_invalid",
  "invite_expired",
  "invite_used",
  "invite_revoked",
  "already_member",
  "group_pending_deletion",
  "last_member",
  "has_car_in_use",
  "use_leave_group",
  "reason_required",
  "custodian_required",
  "last_custodian",
  "confirm_name_mismatch",
  "duplicate_name",
  "vehicle_in_use",
  "vehicle_active",
  "vehicle_has_bookings",
  "ends_in_past",
  "reason_too_long",
  "feature_disabled",
  "invalid_title",
  "text_too_long",
  "participant_not_member",
  "not_invited",
  "times_follow_booking",
  "too_early",
  "booking_ended",
  "eta_required",
  "cannot_undo_slot_taken",
  "snooze_limit",
  "invalid_subscription",
  "invalid_quiet_hours",
  "confirm_required",
  "assignee_required",
  "not_assigned",
  "task_closed",
  "not_task_creator",
  "menu_required",
  "menu_past",
  "menu_too_far",
  "invalid_stars",
  "comment_too_long",
  "review_not_open",
  "review_closed",
  "not_reviewer",
  "already_reviewed",
  "guest_required",
  "stay_too_long",
  "invalid_repeat",
  "repeat_not_allowed",
  "repeat_too_long",
  "use_trip",
] as const;
export type RpcErrorCode = (typeof RPC_ERROR_CODES)[number] | "unknown";

const conflictDetail = z.object({
  reservation_id: z.string().uuid().optional(),
  owner_id: z.string().uuid().optional(),
  starts_at: z.string(),
  ends_at: z.string(),
});
export type ConflictDetail = z.infer<typeof conflictDetail>;

export interface RpcError {
  code: RpcErrorCode;
  conflict?: ConflictDetail;
}

/** Normalises a PostgREST / supabase-js error ({ code, message, details }) into a domain error. */
export function parseRpcError(err: { message?: string; details?: string | null }): RpcError {
  const code = (RPC_ERROR_CODES as readonly string[]).includes(err.message ?? "")
    ? (err.message as RpcErrorCode)
    : "unknown";
  if ((code === "reservation_conflict" || code === "vehicle_unavailable") && err.details) {
    try {
      const parsed = conflictDetail.safeParse(JSON.parse(err.details));
      if (parsed.success) return { code, conflict: parsed.data };
    } catch {
      // details not JSON; fall through
    }
  }
  return { code };
}

const MESSAGES: Record<RpcErrorCode, string> = {
  not_authenticated: "Please sign in again.",
  not_found: "That doesn't exist, or you don't have access to it.",
  not_owner: "Only the person who made this booking can change it.",
  invalid_period: "The end time must be after the start time.",
  starts_in_past: "Bookings can't start in the past.",
  too_long: "Bookings can be at most 14 days long.",
  invalid_idempotency_key: "Something went wrong. Please try again.",
  invalid_time_zone: "That time zone isn't recognised.",
  vehicle_inactive: "This car is no longer in use.",
  vehicle_unavailable: "This car is unavailable (maintenance) at that time.",
  reservation_conflict: "This car is already booked at that time.",
  stale_version: "This changed while you were looking at it. Refresh and try again.",
  invalid_state: "That can't be done in the booking's current state.",
  adult_attestation_required: "fam.ly is for adults only. Please confirm you are 18 or over.",
  invalid_display_name: "Please enter a name (up to 80 characters).",
  invalid_name: "Please enter a family name (up to 80 characters).",
  invalid_ttl: "Invites can last between 1 hour and 7 days.",
  invite_invalid: "This invite link isn't valid.",
  invite_expired: "This invite link has expired. Ask for a new one.",
  invite_used: "This invite link has already been used. Ask for a new one.",
  invite_revoked: "This invite link was cancelled. Ask for a new one.",
  already_member: "You're already in this family.",
  group_pending_deletion: "This family is scheduled for deletion.",
  last_member: "You're the last member. Delete the family instead of leaving.",
  has_car_in_use: "You have a car out right now. Mark it returned before leaving.",
  use_leave_group: "To remove yourself, use Leave family.",
  reason_required: "Please give a reason.",
  custodian_required: "Only a custodian can do this.",
  last_custodian: "A family needs at least one custodian.",
  confirm_name_mismatch: "The name you typed doesn't match the family name.",
  duplicate_name: "There's already a car with that name in your family.",
  vehicle_in_use: "This car is out right now. It can be deactivated once it's reported back.",
  vehicle_active: "Make the car inactive before deleting it.",
  vehicle_has_bookings: "This car still has upcoming bookings or is out right now. Cancel them or wait until it's back, then delete it.",
  ends_in_past: "That time has already passed.",
  reason_too_long: "Please keep the reason under 200 characters.",
  feature_disabled: "That isn't available yet.",
  invalid_title: "Please give it a title (up to 120 characters).",
  text_too_long: "That's too long. Keep the place under 200 and notes under 2000 characters.",
  participant_not_member: "You can only invite people in this family.",
  not_invited: "You weren't invited to this one.",
  times_follow_booking: "This event follows its car booking. Change the booking's time instead.",
  too_early: "It's too early to report that. You can tap Left from an hour before your start.",
  booking_ended: "This booking has already ended. You can still confirm you're home and the car is back.",
  eta_required: "Please say when you expect to be back.",
  cannot_undo_slot_taken: "Can't undo: someone has already booked the car for the time you freed.",
  snooze_limit: "You've used all your snoozes. Please confirm in the app when you can.",
  invalid_subscription: "This device couldn't be set up for notifications. Please try again.",
  invalid_quiet_hours: "Quiet hours need a different start and end time.",
  confirm_required: "Please type the confirmation exactly as shown.",
  assignee_required: "Choose at least one person to do this task.",
  not_assigned: "Only someone who has accepted this task can do that.",
  task_closed: "This task is already done or was deleted.",
  not_task_creator: "Only the person who made this task can delete it.",
  menu_required: "Please write what's on the menu.",
  menu_past: "This menu's day has passed, so it can't be changed.",
  menu_too_far: "Menus can be planned up to 30 days ahead.",
  invalid_stars: "Choose 1 to 5 stars.",
  comment_too_long: "Please keep the comment under 500 characters.",
  review_not_open: "You can rate this menu from 10pm on the day.",
  review_closed: "Rating for this menu has closed.",
  not_reviewer: "Only people who accepted this menu rate it.",
  already_reviewed: "You've already rated this menu.",
  guest_required: "Choose who's staying, or type their names.",
  stay_too_long: "Stays can be up to a year long.",
  invalid_repeat: "Choose how often it repeats.",
  repeat_not_allowed: "Car trips can't repeat. Book each trip on its own.",
  repeat_too_long: "This plan is too long to repeat that often.",
  use_trip: "This plan has your booked trip. Leave from the booking so the car shows as in use.",
  unknown: "Something went wrong. Please try again.",
};

/** User-facing copy for an RPC error. */
export function errorMessage(err: RpcError | RpcErrorCode): string {
  return MESSAGES[typeof err === "string" ? err : err.code];
}
