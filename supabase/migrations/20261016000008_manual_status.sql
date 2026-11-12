-- P07 Manual status: Left, I'm home (car returned), ETA/issue, corrections.
-- FR-S01, FR-S06–S09, T07, T11–T14. D05: "I'm home — car returned" is one atomic assertion.
-- Nonresponse never changes state (FR-S04): overdue/unconfirmed is derived by clients.
-- Notifications for each report are added with the outbox (P08).

-- Earliest a departure may be reported, relative to the planned start.
create function app.left_window_opens(p_planned_start timestamptz)
returns timestamptz
language sql
immutable
set search_path = ''
as $$
  select p_planned_start - interval '60 minutes'
$$;

-------------------------------------------------------------------------------
-- Shared: lock an outing for a status write by its owner, with idempotent replay.
-------------------------------------------------------------------------------
create function app.lock_own_outing(p_outing_id uuid)
returns public.outing
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing public.outing;
begin
  select * into v_outing from public.outing where id = p_outing_id;
  if v_outing.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_outing.group_id);
  -- Same lock order as booking writes: car first (if any), then the outing and reservation rows.
  if v_outing.reservation_id is not null then
    perform 1 from public.vehicle v
      join public.vehicle_reservation r on r.vehicle_id = v.id
     where r.id = v_outing.reservation_id
       for update of v;
    perform 1 from public.vehicle_reservation where id = v_outing.reservation_id for update;
  end if;
  select * into v_outing from public.outing where id = p_outing_id for update;
  if v_outing.owner_id <> app.current_user_id() then
    raise exception 'not_owner' using errcode = '42501';
  end if;
  return v_outing;
end;
$$;

create function app.report_result(p_report public.status_report)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('report_id', p_report.id, 'kind', p_report.kind, 'reported_at', p_report.reported_at)
$$;

-- Returns a previous report made with this key by this user, if any (T07: repeat taps are no-ops).
create function app.replayed_report(p_key text)
returns public.status_report
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.status_report where reported_by = app.current_user_id() and idempotency_key = p_key
$$;

create function app.require_key(p_key text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_key is null or char_length(p_key) not between 8 and 100 then
    raise exception 'invalid_idempotency_key' using errcode = '22023';
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- rpc_report_left (FR-S01)
-------------------------------------------------------------------------------
create function public.rpc_report_left(p_outing_id uuid, p_idempotency_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing public.outing;
  v_report public.status_report;
  v_res_ends timestamptz;
begin
  perform app.require_key(p_idempotency_key);
  v_report := app.replayed_report(p_idempotency_key);
  if v_report.id is not null then
    return app.report_result(v_report);
  end if;

  v_outing := app.lock_own_outing(p_outing_id);

  if v_outing.status = 'departed' then
    -- Already reported (e.g. tapped on two devices): return that report rather than adding another.
    select * into v_report from public.status_report
     where outing_id = v_outing.id and kind = 'left' order by reported_at desc limit 1;
    return app.report_result(v_report);
  end if;
  if v_outing.status <> 'planned' then
    raise exception 'invalid_state' using errcode = '55000', detail = v_outing.status::text;
  end if;
  if now() < app.left_window_opens(v_outing.planned_start) then
    raise exception 'too_early' using errcode = '55000',
      detail = jsonb_build_object('opens_at', app.left_window_opens(v_outing.planned_start))::text;
  end if;
  if v_outing.reservation_id is not null then
    select ends_at into v_res_ends from public.vehicle_reservation where id = v_outing.reservation_id;
    if now() >= v_res_ends then
      raise exception 'booking_ended' using errcode = '55000';
    end if;
  end if;

  update public.outing
     set status = 'departed', departure_reported_at = now(), version = version + 1
   where id = v_outing.id;
  if v_outing.reservation_id is not null then
    update public.vehicle_reservation
       set status = 'in_use_reported', version = version + 1, updated_at = now()
     where id = v_outing.reservation_id;
  end if;

  insert into public.status_report (group_id, outing_id, kind, reported_by, idempotency_key, payload)
  values (v_outing.group_id, v_outing.id, 'left', app.current_user_id(), p_idempotency_key,
          jsonb_build_object('planned_start', v_outing.planned_start))
  returning * into v_report;
  return app.report_result(v_report);
end;
$$;

-------------------------------------------------------------------------------
-- rpc_confirm_home (FR-S06, FR-S07, D05, T11, T12): home AND car returned, all or nothing.
-- Works from 'planned' too: forgetting to tap "Left" must not stop you saying you're back.
-------------------------------------------------------------------------------
create function public.rpc_confirm_home(p_outing_id uuid, p_idempotency_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing public.outing;
  v_report public.status_report;
  v_kind public.status_report_kind;
begin
  perform app.require_key(p_idempotency_key);
  v_report := app.replayed_report(p_idempotency_key);
  if v_report.id is not null then
    return app.report_result(v_report);
  end if;

  v_outing := app.lock_own_outing(p_outing_id);

  if v_outing.status = 'returned' then
    select * into v_report from public.status_report
     where outing_id = v_outing.id and kind in ('home', 'home_and_car_returned')
     order by reported_at desc limit 1;
    return app.report_result(v_report);
  end if;
  if v_outing.status not in ('planned', 'departed') then
    raise exception 'invalid_state' using errcode = '55000', detail = v_outing.status::text;
  end if;
  if v_outing.status = 'planned' and now() < app.left_window_opens(v_outing.planned_start) then
    raise exception 'too_early' using errcode = '55000';
  end if;

  update public.outing
     set status = 'returned', home_reported_at = now(), version = version + 1
   where id = v_outing.id;

  -- Test-only fault point (T12). Session settings can't be set through the API.
  if current_setting('app.fault_inject', true) = 'confirm_home_mid' then
    raise exception 'fault_injected' using errcode = 'XX000';
  end if;

  if v_outing.reservation_id is not null then
    update public.vehicle_reservation
       set status = 'completed', vehicle_returned_at = now(), possession_uncertain = false,
           version = version + 1, updated_at = now()
     where id = v_outing.reservation_id;
    v_kind := 'home_and_car_returned';
  else
    v_kind := 'home';
  end if;

  insert into public.status_report (group_id, outing_id, kind, reported_by, idempotency_key, payload)
  values (v_outing.group_id, v_outing.id, v_kind, app.current_user_id(), p_idempotency_key,
          jsonb_build_object('planned_return', v_outing.planned_return,
                             'skipped_left', v_outing.status = 'planned'))
  returning * into v_report;
  return app.report_result(v_report);
end;
$$;

-------------------------------------------------------------------------------
-- rpc_report_issue (FR-S08, T14): "Not home / car not back". Updates the forecast only.
-- 'eta_update' = running late; 'issue' = something's wrong (marks car possession uncertain).
-- The booking period never changes, so the next booking is never silently moved.
-------------------------------------------------------------------------------
create function public.rpc_report_issue(
  p_outing_id uuid, p_kind public.status_report_kind, p_expected_return_at timestamptz,
  p_note text, p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing public.outing;
  v_report public.status_report;
begin
  perform app.require_key(p_idempotency_key);
  v_report := app.replayed_report(p_idempotency_key);
  if v_report.id is not null then
    return app.report_result(v_report);
  end if;
  if p_kind not in ('eta_update', 'issue') then
    raise exception 'invalid_state' using errcode = '22023';
  end if;
  if p_expected_return_at is not null and p_expected_return_at <= now() then
    raise exception 'ends_in_past' using errcode = '22023';
  end if;
  if p_kind = 'eta_update' and p_expected_return_at is null then
    raise exception 'eta_required' using errcode = '22023';
  end if;
  if char_length(coalesce(p_note, '')) > 500 then
    raise exception 'text_too_long' using errcode = '22023';
  end if;

  v_outing := app.lock_own_outing(p_outing_id);
  if v_outing.status <> 'departed' then
    raise exception 'invalid_state' using errcode = '55000', detail = v_outing.status::text;
  end if;

  update public.outing
     set expected_return_at = coalesce(p_expected_return_at, expected_return_at), version = version + 1
   where id = v_outing.id;
  if p_kind = 'issue' and v_outing.reservation_id is not null then
    update public.vehicle_reservation
       set possession_uncertain = true, version = version + 1, updated_at = now()
     where id = v_outing.reservation_id;
  end if;

  insert into public.status_report (group_id, outing_id, kind, reported_by, idempotency_key, payload)
  values (v_outing.group_id, v_outing.id, p_kind, app.current_user_id(), p_idempotency_key,
          jsonb_strip_nulls(jsonb_build_object('expected_return_at', p_expected_return_at,
                                               'note', nullif(btrim(p_note), ''))))
  returning * into v_report;
  return app.report_result(v_report);
end;
$$;

-------------------------------------------------------------------------------
-- rpc_correct_status (FR-S09): undo a mistaken "Left" or "I'm home". Appends a correction;
-- the original report stays in history. Undoing "home" puts the car back in use, which is
-- refused if someone has since booked the freed time.
-------------------------------------------------------------------------------
create function public.rpc_correct_status(
  p_outing_id uuid, p_undo text, p_reason text, p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing public.outing;
  v_report public.status_report;
  v_new_outing public.outing_status;
begin
  perform app.require_key(p_idempotency_key);
  v_report := app.replayed_report(p_idempotency_key);
  if v_report.id is not null then
    return app.report_result(v_report);
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'reason_required' using errcode = '22023';
  end if;

  v_outing := app.lock_own_outing(p_outing_id);

  if p_undo = 'left' then
    if v_outing.status <> 'departed' then
      raise exception 'invalid_state' using errcode = '55000', detail = v_outing.status::text;
    end if;
    update public.outing
       set status = 'planned', departure_reported_at = null, expected_return_at = null, version = version + 1
     where id = v_outing.id;
    update public.vehicle_reservation
       set status = 'reserved', possession_uncertain = false, version = version + 1, updated_at = now()
     where id = v_outing.reservation_id;
  elsif p_undo = 'home' then
    if v_outing.status <> 'returned' then
      raise exception 'invalid_state' using errcode = '55000', detail = v_outing.status::text;
    end if;
    v_new_outing := case when v_outing.departure_reported_at is null then 'planned' else 'departed' end;
    update public.outing
       set status = v_new_outing, home_reported_at = null, version = version + 1
     where id = v_outing.id;
    begin
      update public.vehicle_reservation
         set status = case when v_new_outing = 'departed' then 'in_use_reported'::public.reservation_status
                           else 'reserved' end,
             vehicle_returned_at = null, version = version + 1, updated_at = now()
       where id = v_outing.reservation_id;
    exception when exclusion_violation then
      raise exception 'cannot_undo_slot_taken' using errcode = '23P01';
    end;
  else
    raise exception 'invalid_state' using errcode = '22023';
  end if;

  insert into public.status_report (group_id, outing_id, kind, reported_by, idempotency_key, payload)
  values (v_outing.group_id, v_outing.id, 'correction', app.current_user_id(), p_idempotency_key,
          jsonb_build_object('undo', p_undo, 'reason', btrim(p_reason)))
  returning * into v_report;
  perform app.audit(v_outing.group_id, 'status.correct', 'outing', v_outing.id,
                    jsonb_build_object('status', v_outing.status), jsonb_build_object('undo', p_undo),
                    btrim(p_reason));
  return app.report_result(v_report);
end;
$$;

-- History is append-only: status reports can't be edited or deleted except with their family.
create function app.status_report_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.outing where id = old.outing_id) then
    return old;
  end if;
  if tg_op = 'UPDATE' and old.reported_by is not null and new.reported_by is null
     and (to_jsonb(new) - 'reported_by') = (to_jsonb(old) - 'reported_by') then
    return new;
  end if;
  raise exception 'status history is append-only' using errcode = '42501';
end;
$$;
create trigger status_report_append_only
  before update or delete on public.status_report
  for each row execute function app.status_report_immutable();

revoke execute on function
  app.left_window_opens(timestamptz), app.lock_own_outing(uuid), app.report_result(public.status_report),
  app.replayed_report(text), app.require_key(text), app.status_report_immutable()
  from public, anon, authenticated;

revoke execute on function
  public.rpc_report_left(uuid, text),
  public.rpc_confirm_home(uuid, text),
  public.rpc_report_issue(uuid, public.status_report_kind, timestamptz, text, text),
  public.rpc_correct_status(uuid, text, text, text)
  from public, anon;
grant execute on function
  public.rpc_report_left(uuid, text),
  public.rpc_confirm_home(uuid, text),
  public.rpc_report_issue(uuid, public.status_report_kind, timestamptz, text, text),
  public.rpc_correct_status(uuid, text, text, text)
  to authenticated;
