-- Vehicle inventory and maintenance windows. FR-V01, FR-V02.

create table public.vehicle (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_group (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  active boolean not null default true,
  version int not null default 1,
  created_at timestamptz not null default now(),
  unique (group_id, id)   -- target for composite FKs: children can't point at another group's car
);

create table public.vehicle_unavailability (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  vehicle_id uuid not null,
  period tstzrange not null check (not isempty(period) and not lower_inf(period) and not upper_inf(period)),
  reason text check (char_length(reason) <= 200),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (group_id, vehicle_id) references public.vehicle (group_id, id) on delete cascade
);
create index vehicle_unavailability_period_idx
  on public.vehicle_unavailability using gist (vehicle_id, period);

alter table public.vehicle enable row level security;
alter table public.vehicle_unavailability enable row level security;
revoke all on public.vehicle, public.vehicle_unavailability from anon, authenticated;
grant select on public.vehicle, public.vehicle_unavailability to authenticated;

create policy vehicle_select on public.vehicle for select to authenticated
  using (app.is_member(group_id));
create policy vehicle_unavailability_select on public.vehicle_unavailability for select to authenticated
  using (app.is_member(group_id));

-- Any adult member may add or rename a car (D09: all adults have routine admin rights).
create function public.rpc_upsert_vehicle(p_group_id uuid, p_name text, p_vehicle_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.assert_member(p_group_id);

  if p_vehicle_id is null then
    insert into public.vehicle (group_id, name)
    values (p_group_id, btrim(p_name))
    returning id into v_id;
    perform app.audit(p_group_id, 'vehicle.create', 'vehicle', v_id, null,
                      jsonb_build_object('name', btrim(p_name)));
  else
    update public.vehicle
       set name = btrim(p_name), version = version + 1
     where id = p_vehicle_id and group_id = p_group_id
    returning id into v_id;
    if v_id is null then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
    perform app.audit(p_group_id, 'vehicle.rename', 'vehicle', v_id, null,
                      jsonb_build_object('name', btrim(p_name)));
  end if;
  return v_id;
end;
$$;

revoke execute on function public.rpc_upsert_vehicle(uuid, text, uuid) from public, anon;
grant execute on function public.rpc_upsert_vehicle(uuid, text, uuid) to authenticated;
