-- Demo family for local development and screenshots. Stock data only: a made-up family (the Carters),
-- made-up emails on a reserved domain (demo.local), no real people. Never run this against a hosted project.
--
-- Usage (local Supabase running):
--   1. Allow the demo login:   insert into app.signup_allowlist (email) values ('alex@demo.local');
--   2. Sign in once at http://127.0.0.1:5173 as alex@demo.local (code in Mailpit, http://127.0.0.1:54324).
--      Stop at the "About You" screen; this script fills it in.
--   3. psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/demo/demo_family.sql
--
-- Dates are relative to now, so the demo always looks current. Re-running does nothing once the family exists.

begin;

create function pg_temp.act_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end;
$$;

create function pg_temp.act_as_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end;
$$;

-- Wall time in the demo family's zone → instant.
create function pg_temp.at(p_day date, p_time time) returns timestamptz language sql as $$
  select (p_day + p_time) at time zone 'Europe/London'
$$;

do $demo$
declare
  v_tz constant text := 'Europe/London';
  v_today date := (now() at time zone 'Europe/London')::date;
  v_alex uuid := (select id from auth.users where email = 'alex@demo.local');
  v_maya uuid := '0000dead-0000-4000-8000-000000000002';
  v_leo uuid := '0000dead-0000-4000-8000-000000000003';
  v_rose uuid := '0000dead-0000-4000-8000-000000000004';
  v_ben uuid := '0000dead-0000-4000-8000-000000000005';
  v_group uuid := '0000dead-0000-4000-8000-0000000000aa';
  v_hatch uuid := '0000dead-0000-4000-8000-0000000000c1';
  v_van uuid := '0000dead-0000-4000-8000-0000000000c2';
  v_id uuid;
  v_menu uuid;
  v_sunday date;
  v_tuesday date;
  d int;
  v_menus text[] := array[
    E'Lunch: tomato soup, sourdough\nDinner: fish pie, peas',
    E'Lunch: falafel wraps\nDinner: mushroom risotto',
    E'Lunch: jacket potatoes\nDinner: chicken fajitas',
    E'Lunch: leftover risotto\nDinner: shepherd''s pie',
    E'Lunch: pea and ham soup\nDinner: salmon, new potatoes, greens',
    E'Lunch: cheese toasties\nDinner: veggie lasagne'];
  v_comments text[] := array['Lovely, more of this please', 'A bit salty', null, 'Best one this week', null, 'Too spicy for me'];
begin
  if v_alex is null then
    raise exception 'Sign in once as alex@demo.local first (see the top of this file).';
  end if;
  if exists (select 1 from public.family_group where id = v_group) then
    raise notice 'Demo family already exists; nothing to do.';
    return;
  end if;

  -- People. Alex is you; Ben is visiting from Toronto and was added to the family for his stay.
  update public.profile set display_name = 'Alex Carter', time_zone = v_tz, adult_attested_at = now() where user_id = v_alex;
  insert into auth.users (id, email, raw_user_meta_data) values
    (v_maya, 'maya@demo.local', '{"display_name":"Maya Carter"}'),
    (v_leo, 'leo@demo.local', '{"display_name":"Leo Carter"}'),
    (v_rose, 'rose@demo.local', '{"display_name":"Rose Carter"}'),
    (v_ben, 'ben@demo.local', '{"display_name":"Ben Carter"}');
  update public.profile set time_zone = v_tz, adult_attested_at = now() where user_id in (v_maya, v_leo, v_rose, v_ben);

  insert into public.family_group (id, name, time_zone) values (v_group, 'Carter', v_tz);
  insert into public.group_membership (group_id, user_id, role) values
    (v_group, v_alex, 'custodian'), (v_group, v_maya, 'custodian'), (v_group, v_leo, 'member'),
    (v_group, v_rose, 'member'), (v_group, v_ben, 'member');
  insert into public.vehicle (id, group_id, name) values (v_hatch, v_group, 'Blue Hatchback'), (v_van, v_group, 'Family Van');

  -- Maya works weekdays; Leo is at the gym right now.
  perform pg_temp.act_as(v_maya);
  perform public.rpc_set_work_hours(array[1, 2, 3, 4, 5]::smallint[], '09:00', '17:30');
  perform pg_temp.act_as(v_leo);
  perform public.rpc_set_presence(v_group, true, 'gym', true);

  -- Car bookings
  perform pg_temp.act_as(v_maya);
  perform public.rpc_create_reservation(v_van, pg_temp.at(v_today + 1, '10:00'), pg_temp.at(v_today + 1, '13:00'), gen_random_uuid()::text);
  perform pg_temp.act_as(v_alex);
  perform public.rpc_create_reservation(v_hatch, pg_temp.at(v_today + 2, '08:00'), pg_temp.at(v_today + 2, '09:30'), gen_random_uuid()::text);

  -- Plans: Sunday lunch, a weekly padel game, parents' evening.
  v_sunday := v_today + ((7 - extract(isodow from v_today)::int) % 7);
  if v_sunday = v_today then v_sunday := v_today + 7; end if;
  v_tuesday := v_today + ((9 - extract(isodow from v_today)::int) % 7);
  if v_tuesday = v_today then v_tuesday := v_today + 7; end if;
  perform pg_temp.act_as(v_rose);
  perform public.rpc_create_event(v_group, 'Sunday roast', pg_temp.at(v_sunday, '13:00'), pg_temp.at(v_sunday, '15:30'),
                                  'Nana''s house', 'Bring dessert!', array[v_alex, v_maya, v_leo, v_ben]);
  perform pg_temp.act_as(v_leo);
  v_id := public.rpc_create_event(v_group, 'Padel with Sam', pg_temp.at(v_tuesday, '19:00'), pg_temp.at(v_tuesday, '20:30'),
                                  'Riverside Club', null, array[v_alex]);
  perform public.rpc_set_event_repeat(v_id, 'weekly', null);
  perform pg_temp.act_as(v_maya);
  perform public.rpc_create_event(v_group, 'Parents'' evening', pg_temp.at(v_today + 1, '18:00'), pg_temp.at(v_today + 1, '19:00'),
                                  'Oakfield School', null, array[v_alex]);

  -- Maya has left for book club (Today shows where); Alex has dinner plans later today.
  perform pg_temp.act_as(v_maya);
  v_id := public.rpc_create_event(v_group, 'Book club', now() - interval '40 minutes', now() + interval '80 minutes',
                                  'Riverside Library', null, '{}');
  perform public.rpc_leave_for_plan(v_id, true);
  perform pg_temp.act_as(v_alex);
  perform public.rpc_create_event(v_group, 'Dinner with Jordan', date_trunc('hour', now()) + interval '2 hours',
                                  date_trunc('hour', now()) + interval '4 hours', 'The Olive Tree, Market Street', null, '{}');

  -- To-dos
  perform pg_temp.act_as(v_rose);
  perform public.rpc_create_task(v_group, 'Pick up my prescription', 'Ready at the pharmacy on the high street', array[v_alex]);
  perform pg_temp.act_as(v_maya);
  v_id := public.rpc_create_task(v_group, 'Book the boiler service', null, array[v_alex]);
  perform pg_temp.act_as(v_alex);
  perform public.rpc_respond_task(v_id, 'accepted');
  perform pg_temp.act_as(v_maya);
  v_id := public.rpc_create_task(v_group, 'Take the recycling out', null, array[v_leo]);
  perform pg_temp.act_as(v_leo);
  perform public.rpc_respond_task(v_id, 'accepted');
  perform public.rpc_complete_task(v_id);

  -- Menus: today's waits for Alex's OK; tomorrow's is agreed.
  perform pg_temp.act_as(v_rose);
  v_menu := public.rpc_create_menu(v_group, v_today, E'Lunch: lentil soup, crusty bread\nDinner: chicken curry, rice, naan');
  perform pg_temp.act_as(v_maya);
  perform public.rpc_accept_menu(v_menu, 1);
  perform pg_temp.act_as(v_maya);
  v_menu := public.rpc_create_menu(v_group, v_today + 1, E'Lunch: Greek salad\nDinner: spaghetti bolognese');
  perform pg_temp.act_as_admin();

  -- Past menus with everyone's ratings (written directly: their rating windows have closed).
  for d in 1 .. 6 loop
    v_menu := gen_random_uuid();
    insert into public.family_menu (id, group_id, created_by, menu_date, items, updated_by, review_prompted_at, created_at)
    values (v_menu, v_group, case when d % 2 = 0 then v_rose else v_maya end, v_today - d, v_menus[d],
            case when d % 2 = 0 then v_rose else v_maya end, now() - make_interval(days => d), now() - make_interval(days => d + 1));
    insert into public.menu_acceptance (group_id, menu_id, user_id, version)
    select v_group, v_menu, u, 1 from unnest(array[v_alex, v_maya, v_leo, v_rose]) u;
    if d >= 3 then
      insert into public.menu_review (group_id, menu_id, user_id, stars, comment, created_at) values
        (v_group, v_menu, v_alex, 3 + (d % 3), v_comments[d], now() - make_interval(days => d - 1)),
        (v_group, v_menu, v_maya, 5 - (d % 2), null, now() - make_interval(days => d - 1)),
        (v_group, v_menu, v_leo, 2 + (d % 4), case when d = 4 then 'Could do with more cheese' end, now() - make_interval(days => d - 1)),
        (v_group, v_menu, v_rose, 4, case when d = 3 then 'Delicious, thank you!' end, now() - make_interval(days => d - 1));
    end if;
  end loop;
  -- Yesterday's food: rating is open; everyone but Alex has rated, so Today asks Alex.
  select id into v_menu from public.family_menu where group_id = v_group and menu_date = v_today - 1;
  insert into public.menu_review (group_id, menu_id, user_id, stars, comment) values
    (v_group, v_menu, v_maya, 5, 'Perfect after a long day'),
    (v_group, v_menu, v_rose, 4, null),
    (v_group, v_menu, v_leo, 4, 'More garlic bread next time');
  -- Two days ago: Alex rated, the window is still open.
  select id into v_menu from public.family_menu where group_id = v_group and menu_date = v_today - 2;
  insert into public.menu_review (group_id, menu_id, user_id, stars, comment) values
    (v_group, v_menu, v_alex, 4, null), (v_group, v_menu, v_maya, 3, 'Risotto was a little dry'), (v_group, v_menu, v_rose, 5, null);

  -- Stays: Ben flies in from Toronto; Aunt May and Uncle Joe come down from Edinburgh.
  perform pg_temp.act_as(v_alex);
  perform public.rpc_create_stay(v_group, array[v_ben], null, v_today + 5, v_today + 17, 'Toronto',
                                 'Flight lands Heathrow T2 at 07:40. Guest room.');
  perform pg_temp.act_as(v_maya);
  perform public.rpc_create_stay(v_group, '{}', 'Aunt May and Uncle Joe', v_today + 9, v_today + 13, 'Edinburgh',
                                 'Arriving by train, King''s Cross 16:20');
  perform pg_temp.act_as_admin();

  perform app.process_outbox(500);
  raise notice 'Demo family ready. Signed in as Alex Carter.';
end
$demo$;

commit;
