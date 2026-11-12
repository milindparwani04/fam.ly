
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "graphql_public": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "graphql":
{ Args: { "extensions"?: Json,"operationName"?: string,"query"?: string,"variables"?: Json }; Returns: Json
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        },"public": {
          Tables: {
            "activity_feed": {
                  Row: {
                    "actor_id": string | null,"created_at": string,"data": NonNullable<Json>,"group_id": string,"id": number,"kind": string,"outbox_id": number,"subject_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "actor_id"?: string | null,"created_at"?: string,"data"?: NonNullable<Json>,"group_id": string,"id"?: never,"kind": string,"outbox_id": number,"subject_id"?: string | null
                  }
                  Update: {
                    "actor_id"?: string | null,"created_at"?: string,"data"?: NonNullable<Json>,"group_id"?: string,"id"?: never,"kind"?: string,"outbox_id"?: number,"subject_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "activity_feed_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "activity_feed_outbox_id_fkey"
      columns: ["outbox_id"]
isOneToOne: true
      referencedRelation: "notification_outbox"
      referencedColumns: ["id"]
    }
                  ]
                },"audit_log": {
                  Row: {
                    "action": string,"actor_id": string | null,"after": Json | null,"at": string,"before": Json | null,"group_id": string,"id": number,"reason": string | null,"target_id": string | null,"target_type": string
                  }
                  ComputedFields: never
                  Insert: {
                    "action": string,"actor_id"?: string | null,"after"?: Json | null,"at"?: string,"before"?: Json | null,"group_id": string,"id"?: never,"reason"?: string | null,"target_id"?: string | null,"target_type": string
                  }
                  Update: {
                    "action"?: string,"actor_id"?: string | null,"after"?: Json | null,"at"?: string,"before"?: Json | null,"group_id"?: string,"id"?: never,"reason"?: string | null,"target_id"?: string | null,"target_type"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "audit_log_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    }
                  ]
                },"device_subscription": {
                  Row: {
                    "auth_secret": string,"created_at": string,"endpoint": string,"id": string,"last_seen_at": string,"p256dh": string,"revoked_at": string | null,"user_agent": string | null,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "auth_secret": string,"created_at"?: string,"endpoint": string,"id"?: string,"last_seen_at"?: string,"p256dh": string,"revoked_at"?: string | null,"user_agent"?: string | null,"user_id": string
                  }
                  Update: {
                    "auth_secret"?: string,"created_at"?: string,"endpoint"?: string,"id"?: string,"last_seen_at"?: string,"p256dh"?: string,"revoked_at"?: string | null,"user_agent"?: string | null,"user_id"?: string
                  }
                  Relationships: [
                    
                  ]
                },"event_participant": {
                  Row: {
                    "event_id": string,"group_id": string,"responded_at": string | null,"state": Database["public"]['Enums']["participant_state"],"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "event_id": string,"group_id": string,"responded_at"?: string | null,"state"?: Database["public"]['Enums']["participant_state"],"user_id": string
                  }
                  Update: {
                    "event_id"?: string,"group_id"?: string,"responded_at"?: string | null,"state"?: Database["public"]['Enums']["participant_state"],"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "event_participant_group_id_event_id_fkey"
      columns: ["group_id","event_id"]
isOneToOne: false
      referencedRelation: "family_event"
      referencedColumns: ["group_id","id"]
    }
                  ]
                },"family_event": {
                  Row: {
                    "cancelled_at": string | null,"created_at": string,"created_by": string | null,"description": string | null,"destination": string | null,"ends_at": string,"group_id": string,"id": string,"outing_id": string | null,"repeat": string | null,"repeat_until": string | null,"reservation_id": string | null,"starts_at": string,"title": string,"updated_at": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "cancelled_at"?: string | null,"created_at"?: string,"created_by"?: string | null,"description"?: string | null,"destination"?: string | null,"ends_at": string,"group_id": string,"id"?: string,"outing_id"?: string | null,"repeat"?: string | null,"repeat_until"?: string | null,"reservation_id"?: string | null,"starts_at": string,"title": string,"updated_at"?: string,"version"?: number
                  }
                  Update: {
                    "cancelled_at"?: string | null,"created_at"?: string,"created_by"?: string | null,"description"?: string | null,"destination"?: string | null,"ends_at"?: string,"group_id"?: string,"id"?: string,"outing_id"?: string | null,"repeat"?: string | null,"repeat_until"?: string | null,"reservation_id"?: string | null,"starts_at"?: string,"title"?: string,"updated_at"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "family_event_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "family_event_group_id_outing_id_fkey"
      columns: ["group_id","outing_id"]
isOneToOne: false
      referencedRelation: "outing"
      referencedColumns: ["group_id","id"]
    },{
      foreignKeyName: "family_event_group_id_reservation_id_fkey"
      columns: ["group_id","reservation_id"]
isOneToOne: false
      referencedRelation: "vehicle_reservation"
      referencedColumns: ["group_id","id"]
    }
                  ]
                },"family_group": {
                  Row: {
                    "audit_retention_days": number,"created_at": string,"deleted_at": string | null,"deletion_requested_at": string | null,"deletion_requested_by": string | null,"deletion_scheduled_for": string | null,"id": string,"name": string,"retention_days": number,"snooze_cap": number,"time_zone": string
                  }
                  ComputedFields: never
                  Insert: {
                    "audit_retention_days"?: number,"created_at"?: string,"deleted_at"?: string | null,"deletion_requested_at"?: string | null,"deletion_requested_by"?: string | null,"deletion_scheduled_for"?: string | null,"id"?: string,"name": string,"retention_days"?: number,"snooze_cap"?: number,"time_zone"?: string
                  }
                  Update: {
                    "audit_retention_days"?: number,"created_at"?: string,"deleted_at"?: string | null,"deletion_requested_at"?: string | null,"deletion_requested_by"?: string | null,"deletion_scheduled_for"?: string | null,"id"?: string,"name"?: string,"retention_days"?: number,"snooze_cap"?: number,"time_zone"?: string
                  }
                  Relationships: [
                    
                  ]
                },"family_menu": {
                  Row: {
                    "created_at": string,"created_by": string | null,"group_id": string,"id": string,"items": string,"menu_date": string,"review_prompted_at": string | null,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"group_id": string,"id"?: string,"items": string,"menu_date": string,"review_prompted_at"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"group_id"?: string,"id"?: string,"items"?: string,"menu_date"?: string,"review_prompted_at"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "family_menu_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    }
                  ]
                },"family_stay": {
                  Row: {
                    "arrives": string,"cancelled_at": string | null,"created_at": string,"created_by": string | null,"from_place": string | null,"group_id": string,"guest_ids": (string)[],"guest_names": (string)[],"id": string,"leaves": string,"note": string | null,"other_guests": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "arrives": string,"cancelled_at"?: string | null,"created_at"?: string,"created_by"?: string | null,"from_place"?: string | null,"group_id": string,"guest_ids"?: (string)[],"guest_names"?: (string)[],"id"?: string,"leaves": string,"note"?: string | null,"other_guests"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "arrives"?: string,"cancelled_at"?: string | null,"created_at"?: string,"created_by"?: string | null,"from_place"?: string | null,"group_id"?: string,"guest_ids"?: (string)[],"guest_names"?: (string)[],"id"?: string,"leaves"?: string,"note"?: string | null,"other_guests"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "family_stay_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    }
                  ]
                },"family_task": {
                  Row: {
                    "cancelled_at": string | null,"completed_at": string | null,"completed_by": string | null,"created_at": string,"created_by": string | null,"description": string | null,"group_id": string,"id": string,"title": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "cancelled_at"?: string | null,"completed_at"?: string | null,"completed_by"?: string | null,"created_at"?: string,"created_by"?: string | null,"description"?: string | null,"group_id": string,"id"?: string,"title": string,"updated_at"?: string
                  }
                  Update: {
                    "cancelled_at"?: string | null,"completed_at"?: string | null,"completed_by"?: string | null,"created_at"?: string,"created_by"?: string | null,"description"?: string | null,"group_id"?: string,"id"?: string,"title"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "family_task_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    }
                  ]
                },"group_membership": {
                  Row: {
                    "group_id": string,"joined_at": string,"left_at": string | null,"role": Database["public"]['Enums']["membership_role"],"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "group_id": string,"joined_at"?: string,"left_at"?: string | null,"role"?: Database["public"]['Enums']["membership_role"],"user_id": string
                  }
                  Update: {
                    "group_id"?: string,"joined_at"?: string,"left_at"?: string | null,"role"?: Database["public"]['Enums']["membership_role"],"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "group_membership_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    }
                  ]
                },"invitation": {
                  Row: {
                    "created_at": string,"expires_at": string,"group_id": string,"id": string,"invited_by": string | null,"note": string | null,"revoked_at": string | null,"token_hash": string,"used_at": string | null,"used_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"expires_at": string,"group_id": string,"id"?: string,"invited_by"?: string | null,"note"?: string | null,"revoked_at"?: string | null,"token_hash": string,"used_at"?: string | null,"used_by"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"expires_at"?: string,"group_id"?: string,"id"?: string,"invited_by"?: string | null,"note"?: string | null,"revoked_at"?: string | null,"token_hash"?: string,"used_at"?: string | null,"used_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "invitation_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    }
                  ]
                },"member_presence": {
                  Row: {
                    "activity": string | null,"changed_at": string,"group_id": string,"has_house_key": boolean | null,"place": string | null,"plan_id": string | null,"plan_title": string | null,"state": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "activity"?: string | null,"changed_at"?: string,"group_id": string,"has_house_key"?: boolean | null,"place"?: string | null,"plan_id"?: string | null,"plan_title"?: string | null,"state": string,"user_id": string
                  }
                  Update: {
                    "activity"?: string | null,"changed_at"?: string,"group_id"?: string,"has_house_key"?: boolean | null,"place"?: string | null,"plan_id"?: string | null,"plan_title"?: string | null,"state"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "member_presence_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    }
                  ]
                },"member_work": {
                  Row: {
                    "days": (number)[],"ends": string | null,"starts": string | null,"updated_at": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "days"?: (number)[],"ends"?: string | null,"starts"?: string | null,"updated_at"?: string,"user_id": string
                  }
                  Update: {
                    "days"?: (number)[],"ends"?: string | null,"starts"?: string | null,"updated_at"?: string,"user_id"?: string
                  }
                  Relationships: [
                    
                  ]
                },"menu_acceptance": {
                  Row: {
                    "accepted_at": string,"group_id": string,"menu_id": string,"user_id": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "accepted_at"?: string,"group_id": string,"menu_id": string,"user_id": string,"version": number
                  }
                  Update: {
                    "accepted_at"?: string,"group_id"?: string,"menu_id"?: string,"user_id"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "menu_acceptance_group_id_menu_id_fkey"
      columns: ["group_id","menu_id"]
isOneToOne: false
      referencedRelation: "family_menu"
      referencedColumns: ["group_id","id"]
    }
                  ]
                },"menu_review": {
                  Row: {
                    "comment": string | null,"created_at": string,"group_id": string,"menu_id": string,"stars": number,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "comment"?: string | null,"created_at"?: string,"group_id": string,"menu_id": string,"stars": number,"user_id": string
                  }
                  Update: {
                    "comment"?: string | null,"created_at"?: string,"group_id"?: string,"menu_id"?: string,"stars"?: number,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "menu_review_group_id_menu_id_fkey"
      columns: ["group_id","menu_id"]
isOneToOne: false
      referencedRelation: "family_menu"
      referencedColumns: ["group_id","id"]
    }
                  ]
                },"notification_delivery": {
                  Row: {
                    "attempts": number,"created_at": string,"device_id": string,"id": number,"last_error": string | null,"lease_until": string | null,"not_before": string,"outbox_id": number,"provider_status": number | null,"state": string,"updated_at": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "attempts"?: number,"created_at"?: string,"device_id": string,"id"?: never,"last_error"?: string | null,"lease_until"?: string | null,"not_before"?: string,"outbox_id": number,"provider_status"?: number | null,"state"?: string,"updated_at"?: string,"user_id": string
                  }
                  Update: {
                    "attempts"?: number,"created_at"?: string,"device_id"?: string,"id"?: never,"last_error"?: string | null,"lease_until"?: string | null,"not_before"?: string,"outbox_id"?: number,"provider_status"?: number | null,"state"?: string,"updated_at"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "notification_delivery_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "device_subscription"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "notification_delivery_outbox_id_fkey"
      columns: ["outbox_id"]
isOneToOne: false
      referencedRelation: "notification_outbox"
      referencedColumns: ["id"]
    }
                  ]
                },"notification_outbox": {
                  Row: {
                    "actor_id": string | null,"attempts": number,"created_at": string,"data": NonNullable<Json>,"dedupe_key": string,"event_type": string,"group_id": string,"id": number,"last_error": string | null,"next_attempt_at": string,"processed_at": string | null,"push": boolean,"recipient_id": string | null,"state": string,"subject_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "actor_id"?: string | null,"attempts"?: number,"created_at"?: string,"data"?: NonNullable<Json>,"dedupe_key": string,"event_type": string,"group_id": string,"id"?: never,"last_error"?: string | null,"next_attempt_at"?: string,"processed_at"?: string | null,"push"?: boolean,"recipient_id"?: string | null,"state"?: string,"subject_id"?: string | null
                  }
                  Update: {
                    "actor_id"?: string | null,"attempts"?: number,"created_at"?: string,"data"?: NonNullable<Json>,"dedupe_key"?: string,"event_type"?: string,"group_id"?: string,"id"?: never,"last_error"?: string | null,"next_attempt_at"?: string,"processed_at"?: string | null,"push"?: boolean,"recipient_id"?: string | null,"state"?: string,"subject_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "notification_outbox_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    }
                  ]
                },"notification_setting": {
                  Row: {
                    "notify_bookings": boolean,"notify_moves": boolean,"notify_plans": boolean,"notify_tasks": boolean,"push_enabled": boolean,"quiet_end": string | null,"quiet_start": string | null,"updated_at": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "notify_bookings"?: boolean,"notify_moves"?: boolean,"notify_plans"?: boolean,"notify_tasks"?: boolean,"push_enabled"?: boolean,"quiet_end"?: string | null,"quiet_start"?: string | null,"updated_at"?: string,"user_id": string
                  }
                  Update: {
                    "notify_bookings"?: boolean,"notify_moves"?: boolean,"notify_plans"?: boolean,"notify_tasks"?: boolean,"push_enabled"?: boolean,"quiet_end"?: string | null,"quiet_start"?: string | null,"updated_at"?: string,"user_id"?: string
                  }
                  Relationships: [
                    
                  ]
                },"outing": {
                  Row: {
                    "created_at": string,"departure_reported_at": string | null,"expected_return_at": string | null,"group_id": string,"home_reported_at": string | null,"id": string,"owner_id": string,"planned_return": string,"planned_start": string,"reservation_id": string | null,"status": Database["public"]['Enums']["outing_status"],"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"departure_reported_at"?: string | null,"expected_return_at"?: string | null,"group_id": string,"home_reported_at"?: string | null,"id"?: string,"owner_id": string,"planned_return": string,"planned_start": string,"reservation_id"?: string | null,"status"?: Database["public"]['Enums']["outing_status"],"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"departure_reported_at"?: string | null,"expected_return_at"?: string | null,"group_id"?: string,"home_reported_at"?: string | null,"id"?: string,"owner_id"?: string,"planned_return"?: string,"planned_start"?: string,"reservation_id"?: string | null,"status"?: Database["public"]['Enums']["outing_status"],"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "outing_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "outing_group_id_reservation_id_fkey"
      columns: ["group_id","reservation_id"]
isOneToOne: false
      referencedRelation: "vehicle_reservation"
      referencedColumns: ["group_id","id"]
    }
                  ]
                },"profile": {
                  Row: {
                    "adult_attested_at": string | null,"created_at": string,"display_name": string,"time_zone": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "adult_attested_at"?: string | null,"created_at"?: string,"display_name"?: string,"time_zone"?: string,"user_id": string
                  }
                  Update: {
                    "adult_attested_at"?: string | null,"created_at"?: string,"display_name"?: string,"time_zone"?: string,"user_id"?: string
                  }
                  Relationships: [
                    
                  ]
                },"scheduled_prompt": {
                  Row: {
                    "due_at": string,"group_id": string,"id": string,"kind": string,"outing_id": string,"sent_at": string | null,"snooze_count": number,"state": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "due_at": string,"group_id": string,"id"?: string,"kind": string,"outing_id": string,"sent_at"?: string | null,"snooze_count"?: number,"state"?: string,"updated_at"?: string
                  }
                  Update: {
                    "due_at"?: string,"group_id"?: string,"id"?: string,"kind"?: string,"outing_id"?: string,"sent_at"?: string | null,"snooze_count"?: number,"state"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "scheduled_prompt_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "scheduled_prompt_outing_id_fkey"
      columns: ["outing_id"]
isOneToOne: false
      referencedRelation: "outing"
      referencedColumns: ["id"]
    }
                  ]
                },"status_report": {
                  Row: {
                    "group_id": string,"id": string,"idempotency_key": string | null,"kind": Database["public"]['Enums']["status_report_kind"],"outing_id": string,"payload": NonNullable<Json>,"reported_at": string,"reported_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "group_id": string,"id"?: string,"idempotency_key"?: string | null,"kind": Database["public"]['Enums']["status_report_kind"],"outing_id": string,"payload"?: NonNullable<Json>,"reported_at"?: string,"reported_by"?: string | null
                  }
                  Update: {
                    "group_id"?: string,"id"?: string,"idempotency_key"?: string | null,"kind"?: Database["public"]['Enums']["status_report_kind"],"outing_id"?: string,"payload"?: NonNullable<Json>,"reported_at"?: string,"reported_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "status_report_group_id_outing_id_fkey"
      columns: ["group_id","outing_id"]
isOneToOne: false
      referencedRelation: "outing"
      referencedColumns: ["group_id","id"]
    }
                  ]
                },"task_assignee": {
                  Row: {
                    "group_id": string,"responded_at": string | null,"state": Database["public"]['Enums']["task_assignee_state"],"task_id": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "group_id": string,"responded_at"?: string | null,"state"?: Database["public"]['Enums']["task_assignee_state"],"task_id": string,"user_id": string
                  }
                  Update: {
                    "group_id"?: string,"responded_at"?: string | null,"state"?: Database["public"]['Enums']["task_assignee_state"],"task_id"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "task_assignee_group_id_task_id_fkey"
      columns: ["group_id","task_id"]
isOneToOne: false
      referencedRelation: "family_task"
      referencedColumns: ["group_id","id"]
    }
                  ]
                },"vehicle": {
                  Row: {
                    "active": boolean,"created_at": string,"group_id": string,"id": string,"name": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"created_at"?: string,"group_id": string,"id"?: string,"name": string,"version"?: number
                  }
                  Update: {
                    "active"?: boolean,"created_at"?: string,"group_id"?: string,"id"?: string,"name"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "vehicle_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "family_group"
      referencedColumns: ["id"]
    }
                  ]
                },"vehicle_reservation": {
                  Row: {
                    "created_at": string,"ends_at": string | null,"group_id": string,"id": string,"idempotency_key": string,"needs_reconciliation": boolean,"owner_id": string,"period": unknown,"possession_uncertain": boolean,"starts_at": string | null,"status": Database["public"]['Enums']["reservation_status"],"updated_at": string,"vehicle_id": string,"vehicle_returned_at": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"ends_at"?: never,"group_id": string,"id"?: string,"idempotency_key": string,"needs_reconciliation"?: boolean,"owner_id": string,"period": unknown,"possession_uncertain"?: boolean,"starts_at"?: never,"status"?: Database["public"]['Enums']["reservation_status"],"updated_at"?: string,"vehicle_id": string,"vehicle_returned_at"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"ends_at"?: never,"group_id"?: string,"id"?: string,"idempotency_key"?: string,"needs_reconciliation"?: boolean,"owner_id"?: string,"period"?: unknown,"possession_uncertain"?: boolean,"starts_at"?: never,"status"?: Database["public"]['Enums']["reservation_status"],"updated_at"?: string,"vehicle_id"?: string,"vehicle_returned_at"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "vehicle_reservation_group_id_vehicle_id_fkey"
      columns: ["group_id","vehicle_id"]
isOneToOne: false
      referencedRelation: "vehicle"
      referencedColumns: ["group_id","id"]
    }
                  ]
                },"vehicle_unavailability": {
                  Row: {
                    "created_at": string,"created_by": string | null,"ends_at": string | null,"group_id": string,"id": string,"period": unknown,"reason": string | null,"starts_at": string | null,"vehicle_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"ends_at"?: never,"group_id": string,"id"?: string,"period": unknown,"reason"?: string | null,"starts_at"?: never,"vehicle_id": string
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"ends_at"?: never,"group_id"?: string,"id"?: string,"period"?: unknown,"reason"?: string | null,"starts_at"?: never,"vehicle_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "vehicle_unavailability_group_id_vehicle_id_fkey"
      columns: ["group_id","vehicle_id"]
isOneToOne: false
      referencedRelation: "vehicle"
      referencedColumns: ["group_id","id"]
    }
                  ]
                }
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "dispatch_claim_deliveries":
{ Args: { "p_limit"?: number }; Returns: {
              "auth_secret": string,"body": string,"delivery_id": number,"endpoint": string,"p256dh": string,"tag": string,"title": string,"url": string
            }[]
                           },
"dispatch_complete_delivery":
{ Args: { "p_delivery_id": number,"p_error"?: string,"p_status": number }; Returns: undefined
                           },
"ops_health_snapshot":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"ops_pilot_metrics":
{ Args: { "p_days"?: number }; Returns: Json
                           },
"ops_swap_health_state":
{ Args: { "p_state": string }; Returns: string
                           },
"rpc_accept_invite":
{ Args: { "p_token": string }; Returns: string
                           },
"rpc_accept_menu":
{ Args: { "p_menu_id": string,"p_version": number }; Returns: undefined
                           },
"rpc_add_booking_to_calendar":
{ Args: { "p_description"?: string,"p_destination"?: string,"p_participant_ids"?: (string)[],"p_reservation_id": string,"p_title": string }; Returns: string
                           },
"rpc_add_unavailability":
{ Args: { "p_ends_at": string,"p_reason"?: string,"p_starts_at": string,"p_vehicle_id": string }; Returns: string
                           },
"rpc_attest_adult":
{ Args: { "p_confirm": boolean }; Returns: undefined
                           },
"rpc_cancel_event":
{ Args: { "p_event_id": string }; Returns: undefined
                           },
"rpc_cancel_group_deletion":
{ Args: { "p_group_id": string }; Returns: undefined
                           },
"rpc_cancel_reservation":
{ Args: { "p_expected_version"?: number,"p_reservation_id": string }; Returns: undefined
                           },
"rpc_cancel_stay":
{ Args: { "p_stay_id": string }; Returns: undefined
                           },
"rpc_cancel_task":
{ Args: { "p_task_id": string }; Returns: undefined
                           },
"rpc_complete_task":
{ Args: { "p_task_id": string }; Returns: undefined
                           },
"rpc_confirm_home":
{ Args: { "p_idempotency_key": string,"p_outing_id": string }; Returns: Json
                           },
"rpc_correct_status":
{ Args: { "p_idempotency_key": string,"p_outing_id": string,"p_reason": string,"p_undo": string }; Returns: Json
                           },
"rpc_create_event":
{ Args: { "p_description"?: string,"p_destination"?: string,"p_ends_at": string,"p_group_id": string,"p_participant_ids"?: (string)[],"p_starts_at": string,"p_title": string,"p_track_outing"?: boolean }; Returns: string
                           },
"rpc_create_group":
{ Args: { "p_name": string,"p_time_zone"?: string }; Returns: string
                           },
"rpc_create_invite":
{ Args: { "p_group_id": string,"p_note"?: string,"p_ttl_hours"?: number }; Returns: Json
                           },
"rpc_create_menu":
{ Args: { "p_group_id": string,"p_items": string,"p_menu_date": string }; Returns: string
                           },
"rpc_create_reservation":
{ Args: { "p_ends_at": string,"p_idempotency_key": string,"p_starts_at": string,"p_vehicle_id": string }; Returns: string
                           },
"rpc_create_stay":
{ Args: { "p_arrives": string,"p_from"?: string,"p_group_id": string,"p_guest_ids": (string)[],"p_leaves": string,"p_note"?: string,"p_other_guests": string }; Returns: string
                           },
"rpc_create_task":
{ Args: { "p_assignee_ids"?: (string)[],"p_description"?: string,"p_group_id": string,"p_title": string }; Returns: string
                           },
"rpc_delete_my_account":
{ Args: { "p_confirm": string }; Returns: undefined
                           },
"rpc_delete_vehicle":
{ Args: { "p_vehicle_id": string }; Returns: undefined
                           },
"rpc_export_my_data":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"rpc_extend_reservation":
{ Args: { "p_ends_at": string,"p_expected_version": number,"p_reservation_id": string }; Returns: number
                           },
"rpc_leave_for_plan":
{ Args: { "p_event_id": string,"p_has_house_key"?: boolean }; Returns: Json
                           },
"rpc_leave_group":
{ Args: { "p_group_id": string }; Returns: undefined
                           },
"rpc_modify_menu":
{ Args: { "p_items": string,"p_menu_id": string,"p_version": number }; Returns: number
                           },
"rpc_override_reservation":
{ Args: { "p_reason": string,"p_reservation_id": string }; Returns: undefined
                           },
"rpc_preview_invite":
{ Args: { "p_token": string }; Returns: Json
                           },
"rpc_register_device":
{ Args: { "p_auth": string,"p_endpoint": string,"p_p256dh": string,"p_user_agent"?: string }; Returns: string
                           },
"rpc_remove_member":
{ Args: { "p_group_id": string,"p_reason": string,"p_user_id": string }; Returns: undefined
                           },
"rpc_remove_unavailability":
{ Args: { "p_unavailability_id": string }; Returns: undefined
                           },
"rpc_reopen_task":
{ Args: { "p_task_id": string }; Returns: undefined
                           },
"rpc_report_client_error":
{ Args: { "p_message": string,"p_path"?: string,"p_stack"?: string,"p_user_agent"?: string }; Returns: undefined
                           },
"rpc_report_issue":
{ Args: { "p_expected_return_at": string,"p_idempotency_key": string,"p_kind": Database["public"]['Enums']["status_report_kind"],"p_note": string,"p_outing_id": string }; Returns: Json
                           },
"rpc_report_left":
{ Args: { "p_activity"?: string,"p_has_house_key"?: boolean,"p_idempotency_key": string,"p_outing_id": string }; Returns: Json
                           },
"rpc_request_group_deletion":
{ Args: { "p_confirm_name": string,"p_group_id": string }; Returns: string
                           },
"rpc_respond_event":
{ Args: { "p_event_id": string,"p_state": Database["public"]['Enums']["participant_state"] }; Returns: undefined
                           },
"rpc_respond_task":
{ Args: { "p_state": Database["public"]['Enums']["task_assignee_state"],"p_task_id": string }; Returns: undefined
                           },
"rpc_review_menu":
{ Args: { "p_comment"?: string,"p_menu_id": string,"p_stars": number }; Returns: undefined
                           },
"rpc_revoke_invite":
{ Args: { "p_invitation_id": string }; Returns: undefined
                           },
"rpc_send_test_push":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"rpc_set_event_repeat":
{ Args: { "p_event_id": string,"p_repeat": string,"p_until"?: string }; Returns: undefined
                           },
"rpc_set_member_role":
{ Args: { "p_group_id": string,"p_role": Database["public"]['Enums']["membership_role"],"p_user_id": string }; Returns: undefined
                           },
"rpc_set_presence":
{ Args: { "p_activity"?: string,"p_group_id": string,"p_has_house_key"?: boolean,"p_out": boolean }; Returns: Json
                           },
"rpc_set_vehicle_active":
{ Args: { "p_active": boolean,"p_vehicle_id": string }; Returns: undefined
                           },
"rpc_set_work_hours":
{ Args: { "p_days": (number)[],"p_ends": string,"p_starts": string }; Returns: undefined
                           },
"rpc_snooze_prompt":
{ Args: { "p_prompt_id": string }; Returns: string
                           },
"rpc_unregister_device":
{ Args: { "p_endpoint": string }; Returns: undefined
                           },
"rpc_update_event":
{ Args: { "p_description": string,"p_destination": string,"p_ends_at": string,"p_event_id": string,"p_expected_version": number,"p_participant_ids": (string)[],"p_starts_at": string,"p_title": string }; Returns: number
                           },
"rpc_update_notification_categories":
{ Args: { "p_bookings": boolean,"p_moves": boolean,"p_plans": boolean,"p_tasks": boolean }; Returns: undefined
                           },
"rpc_update_notification_settings":
{ Args: { "p_push_enabled": boolean,"p_quiet_end": string,"p_quiet_start": string }; Returns: undefined
                           },
"rpc_update_profile":
{ Args: { "p_display_name": string,"p_time_zone"?: string }; Returns: undefined
                           },
"rpc_update_reservation":
{ Args: { "p_ends_at": string,"p_expected_version": number,"p_reservation_id": string,"p_starts_at": string }; Returns: number
                           },
"rpc_update_stay":
{ Args: { "p_arrives": string,"p_from"?: string,"p_guest_ids": (string)[],"p_leaves": string,"p_note"?: string,"p_other_guests": string,"p_stay_id": string }; Returns: undefined
                           },
"rpc_upsert_vehicle":
{ Args: { "p_group_id": string,"p_name": string,"p_vehicle_id"?: string }; Returns: string
                           }
          }
          Enums: {
            "membership_role": "member"|"custodian","outing_status": "planned"|"departed"|"returned"|"cancelled","participant_state": "invited"|"attending"|"declined","reservation_status": "reserved"|"in_use_reported"|"completed"|"cancelled","status_report_kind": "left"|"home"|"home_and_car_returned"|"eta_update"|"issue"|"correction","task_assignee_state": "pending"|"accepted"|"declined"
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "graphql_public": {
          Enums: {
            
          }
        },"public": {
          Enums: {
            "membership_role": ["member", "custodian"],"outing_status": ["planned", "departed", "returned", "cancelled"],"participant_state": ["invited", "attending", "declined"],"reservation_status": ["reserved", "in_use_reported", "completed", "cancelled"],"status_report_kind": ["left", "home", "home_and_car_returned", "eta_update", "issue", "correction"],"task_assignee_state": ["pending", "accepted", "declined"]
          }
        }
} as const
