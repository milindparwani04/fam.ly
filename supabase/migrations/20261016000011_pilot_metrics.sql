-- P10-1 Pilot instrumentation (privacy-minimal) and P10-2 operator view. BG-02–BG-06.
-- Aggregates only, computed on demand from data the app already keeps; nothing new is collected.
-- Operator-only (service role). Covers at most the 90-day retention window.

create function public.ops_pilot_metrics(p_days int default 28)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from timestamptz := now() - make_interval(days => least(greatest(p_days, 1), 90));
begin
  return jsonb_build_object(
    'window_days', least(greatest(p_days, 1), 90),
    'generated_at', now(),
    'families', coalesce((
      select jsonb_agg(f order by f ->> 'family')
      from (
        select jsonb_build_object(
          'family', g.name,
          'members', (select count(*) from public.group_membership m where m.group_id = g.id and m.left_at is null),
          'members_with_push', (select count(distinct d.user_id) from public.device_subscription d
                                  join public.group_membership m on m.user_id = d.user_id and m.group_id = g.id and m.left_at is null
                                 where d.revoked_at is null),
          'members_push_paused', (select count(*) from public.notification_setting s
                                    join public.group_membership m on m.user_id = s.user_id and m.group_id = g.id and m.left_at is null
                                   where not s.push_enabled),
          'cars', (select count(*) from public.vehicle v where v.group_id = g.id and v.active),
          -- BG: adoption — bookings per member per week
          'bookings', (select count(*) from public.vehicle_reservation r where r.group_id = g.id and r.created_at >= v_from),
          'bookings_per_member_per_week', round(
             (select count(*) from public.vehicle_reservation r where r.group_id = g.id and r.created_at >= v_from)::numeric
             / nullif((select count(*) from public.group_membership m where m.group_id = g.id and m.left_at is null), 0)
             / greatest(extract(epoch from now() - v_from) / 604800, 1), 2),
          'bookings_by_person', coalesce((
             select jsonb_object_agg(coalesce(nullif(p.display_name, ''), 'unnamed'), n)
               from (select r.owner_id, count(*) n from public.vehicle_reservation r
                      where r.group_id = g.id and r.created_at >= v_from group by r.owner_id) c
               left join public.profile p on p.user_id = c.owner_id), '{}'),
          'bookings_cancelled', (select count(*) from public.vehicle_reservation r
                                  where r.group_id = g.id and r.created_at >= v_from and r.status = 'cancelled'),
          'family_events', (select count(*) from public.family_event e where e.group_id = g.id and e.created_at >= v_from),
          'car_free_outings', (select count(*) from public.outing o where o.group_id = g.id and o.reservation_id is null and o.created_at >= v_from),
          -- BG: status confirmation — share of finished trips where people actually reported
          'trips_finished', (select count(*) from public.outing o where o.group_id = g.id and o.planned_return >= v_from
                              and o.planned_return < now() and o.status <> 'cancelled'),
          'trips_confirmed_left', (select count(*) from public.outing o where o.group_id = g.id and o.planned_return >= v_from
                                    and o.planned_return < now() and o.departure_reported_at is not null),
          'trips_confirmed_home', (select count(*) from public.outing o where o.group_id = g.id and o.planned_return >= v_from
                                    and o.planned_return < now() and o.home_reported_at is not null),
          -- BG: car clashes / handover problems
          'late_returns', (select count(*) from public.vehicle_reservation r where r.group_id = g.id and r.created_at >= v_from
                            and r.vehicle_returned_at > upper(r.period)),
          'still_overdue_now', (select count(*) from public.vehicle_reservation r where r.group_id = g.id
                                 and r.status = 'in_use_reported' and upper(r.period) < now()),
          'problems_reported', (select count(*) from public.status_report s where s.group_id = g.id and s.kind = 'issue' and s.reported_at >= v_from),
          'corrections', (select count(*) from public.status_report s where s.group_id = g.id and s.kind = 'correction' and s.reported_at >= v_from),
          -- BG: prompts — sent, answered, snoozed, and how fast people answered
          'prompts_sent', (select count(*) from public.scheduled_prompt p where p.group_id = g.id and p.sent_at >= v_from),
          'prompts_answered', (select count(*) from public.scheduled_prompt p where p.group_id = g.id and p.sent_at >= v_from and p.state = 'acted'),
          'prompt_snoozes', (select coalesce(sum(p.snooze_count), 0) from public.scheduled_prompt p where p.group_id = g.id and p.updated_at >= v_from),
          'median_minutes_prompt_to_answer', (
             select round(percentile_cont(0.5) within group (order by extract(epoch from s.reported_at - p.sent_at) / 60)::numeric, 1)
               from public.scheduled_prompt p
               join public.status_report s on s.outing_id = p.outing_id
                and s.kind = case p.kind when 'departure' then 'left'::public.status_report_kind else 'home_and_car_returned'::public.status_report_kind end
              where p.group_id = g.id and p.sent_at >= v_from and p.state = 'acted' and s.reported_at >= p.sent_at),
          -- Push delivery truth (FR-N06): accepted by Apple/Google, not "read"
          'pushes_accepted', (select count(*) from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
                               where o.group_id = g.id and d.created_at >= v_from and d.state in ('provider_accepted', 'acted')),
          'pushes_failed', (select count(*) from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
                             where o.group_id = g.id and d.created_at >= v_from and d.state = 'failed'),
          'pushes_dropped_as_stale', (select count(*) from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
                                       where o.group_id = g.id and d.created_at >= v_from and d.state = 'obsolete'),
          'median_seconds_to_push_accepted', (
             select round(percentile_cont(0.5) within group (order by extract(epoch from d.updated_at - greatest(d.created_at, d.not_before)))::numeric, 1)
               from public.notification_delivery d join public.notification_outbox o on o.id = d.outbox_id
              where o.group_id = g.id and d.created_at >= v_from and d.state in ('provider_accepted', 'acted'))
        ) as f
        from public.family_group g
        where g.deleted_at is null
      ) s), '[]'),
    'app_errors_last_7_days', (select count(*) from app.client_error where at >= now() - interval '7 days')
  );
end;
$$;

revoke execute on function public.ops_pilot_metrics(int) from public, anon, authenticated;
grant execute on function public.ops_pilot_metrics(int) to service_role;
