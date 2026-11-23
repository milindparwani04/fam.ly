-- Migration 020 (founder, 2026-11-23): a reminder 12 hours before a plan, and family Documents.
--
-- 1. Plan reminders: 12 hours before a plan starts (dinner at 20:00 -> 08:00), everyone going gets a push:
--    the person who made it plus everyone invited who hasn't declined. Each occurrence of a repeating
--    plan gets its own. Plans made less than 12 hours ahead don't (the "new plan" push just went out).
--    A late cron run catches up for an hour, never later.
-- 2. Documents (Settings -> Documents): folders, and files in them, visible to the whole family. Each file
--    has a title (what the app shows), an optional label (shown as a sticker) and optional comments.
--    Files live in the private Storage bucket "family-docs" at <group id>/<document id>/<file name>.
--    No pushes and no feed rows for documents.

-------------------------------------------------------------------------------
-- 1. Plan reminders
-------------------------------------------------------------------------------
-- Occurrences of a plan that start in [p_from, p_to). Mirrors packages/domain repeat.ts: a repeating
-- plan keeps its wall-clock start in the family's zone, monthly plans on the 31st skip short months.
create function app.event_starts_between(p_event public.family_event, p_tz text, p_from timestamptz, p_to timestamptz)
returns setof timestamptz
language sql
stable
set search_path = ''
as $$
  with first as (
    select (p_event.starts_at at time zone p_tz)::date as day,
           (p_event.starts_at at time zone p_tz)::time as at
  ), days as (
    select generate_series((p_from at time zone p_tz)::date, (p_to at time zone p_tz)::date, interval '1 day')::date as day
  )
  select p_event.starts_at
   where p_event.repeat is null and p_event.starts_at >= p_from and p_event.starts_at < p_to
  union all
  select s.starts
    from first f
    cross join days d
    cross join lateral (select (d.day + f.at) at time zone p_tz as starts) s
   where p_event.repeat is not null
     and d.day >= f.day
     and (p_event.repeat_until is null or d.day <= p_event.repeat_until)
     and case p_event.repeat
           when 'daily' then true
           when 'weekly' then (d.day - f.day) % 7 = 0
           when 'fortnightly' then (d.day - f.day) % 14 = 0
           when 'monthly' then extract(day from d.day) = extract(day from f.day)
         end
     and s.starts >= p_from and s.starts < p_to
$$;

create function app.prompt_event_reminders()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  with due as (
    select e.id as event_id, e.group_id, e.created_by, e.created_at, o.starts
      from public.family_event e
      join public.family_group g on g.id = e.group_id and g.deleted_at is null
      cross join lateral app.event_starts_between(e, g.time_zone, now() + interval '11 hours',
                                                  now() + interval '12 hours') o(starts)
     where e.cancelled_at is null
       and (e.repeat is not null or e.starts_at between now() + interval '11 hours' and now() + interval '12 hours')
  ), going as (
    select d.*, u.user_id
      from due d
      cross join lateral (
        select d.created_by as user_id where d.created_by is not null
        union
        select p.user_id from public.event_participant p where p.event_id = d.event_id and p.state <> 'declined'
      ) u
      join public.group_membership m on m.group_id = d.group_id and m.user_id = u.user_id and m.left_at is null
     where d.created_at <= d.starts - interval '12 hours'
  ), sent as (
    insert into public.notification_outbox (group_id, event_type, actor_id, subject_id, dedupe_key, data, push, recipient_id)
    select group_id, 'notify.event_reminder', null, event_id,
           'event_reminder:' || event_id || ':' || extract(epoch from starts)::bigint || ':' || user_id,
           jsonb_build_object('starts_at', starts), true, user_id
      from going
    on conflict (dedupe_key) do nothing
    returning 1
  )
  select count(*) into v_n from sent;
  return v_n;
end;
$$;
select cron.schedule('famly-event-reminders', '*/5 * * * *', $$ select app.prompt_event_reminders() $$);

-------------------------------------------------------------------------------
-- 2. Documents
-------------------------------------------------------------------------------
create table public.doc_folder (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_group (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (group_id, id)
);
create unique index doc_folder_name_idx on public.doc_folder (group_id, lower(name));

create table public.family_document (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  folder_id uuid not null,
  title text not null check (char_length(title) between 1 and 80),
  label text check (char_length(label) between 1 and 24),
  comment text check (char_length(comment) <= 1000),
  file_name text not null check (char_length(file_name) between 1 and 200),
  mime_type text not null,
  size_bytes bigint not null check (size_bytes >= 0),
  storage_path text not null unique,
  uploaded_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (group_id, folder_id) references public.doc_folder (group_id, id) on delete cascade
);
create index family_document_folder_idx on public.family_document (folder_id, created_at desc);

alter table public.doc_folder enable row level security;
alter table public.family_document enable row level security;
revoke all on public.doc_folder, public.family_document from anon, authenticated;
grant select on public.doc_folder, public.family_document to authenticated;
create policy doc_folder_select on public.doc_folder for select to authenticated using (app.is_member(group_id));
create policy family_document_select on public.family_document for select to authenticated using (app.is_member(group_id));

-- The bucket: private, 25 MB a file, documents and photos only.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('family-docs', 'family-docs', false, 26214400, array[
  'application/pdf',
  'image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp', 'image/gif',
  'text/plain', 'text/csv', 'application/rtf', 'text/rtf',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
])
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- The family a stored file belongs to: the first path segment, when it's a uuid.
create function app.doc_path_group(p_name text)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select case when split_part(p_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then split_part(p_name, '/', 1)::uuid end
$$;

-- Members read, upload and remove their family's files. Nobody overwrites one (no update policy).
create policy family_docs_select on storage.objects for select to authenticated
  using (bucket_id = 'family-docs' and app.is_member(app.doc_path_group(name)));
create policy family_docs_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'family-docs' and app.is_member(app.doc_path_group(name)));
create policy family_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'family-docs' and app.is_member(app.doc_path_group(name)));

-- Trimmed optional text: blank -> null, too long -> text_too_long.
create function app.clean_doc_text(p text, p_max int)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if char_length(btrim(coalesce(p, ''))) = 0 then
    return null;
  end if;
  if char_length(btrim(p)) > p_max then
    raise exception 'text_too_long' using errcode = '22023';
  end if;
  return btrim(p);
end;
$$;

create function public.rpc_create_doc_folder(p_group_id uuid, p_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_id uuid;
begin
  perform app.assert_member(p_group_id);
  if char_length(v_name) not between 1 and 60 then
    raise exception 'invalid_folder_name' using errcode = '22023';
  end if;
  if exists (select 1 from public.doc_folder where group_id = p_group_id and lower(name) = lower(v_name)) then
    raise exception 'duplicate_folder' using errcode = '23505';
  end if;
  insert into public.doc_folder (group_id, name, created_by) values (p_group_id, v_name, app.current_user_id())
  returning id into v_id;
  return v_id;
end;
$$;

create function public.rpc_rename_doc_folder(p_folder_id uuid, p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_folder public.doc_folder;
  v_name text := btrim(coalesce(p_name, ''));
begin
  select * into v_folder from public.doc_folder where id = p_folder_id;
  if v_folder.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_folder.group_id);
  if char_length(v_name) not between 1 and 60 then
    raise exception 'invalid_folder_name' using errcode = '22023';
  end if;
  if exists (select 1 from public.doc_folder
              where group_id = v_folder.group_id and lower(name) = lower(v_name) and id <> p_folder_id) then
    raise exception 'duplicate_folder' using errcode = '23505';
  end if;
  update public.doc_folder set name = v_name, updated_at = now() where id = p_folder_id;
end;
$$;

-- Deletes the folder and everything in it. Returns the stored files' paths for the app to remove.
create function public.rpc_delete_doc_folder(p_folder_id uuid)
returns text[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_folder public.doc_folder;
  v_paths text[];
begin
  select * into v_folder from public.doc_folder where id = p_folder_id;
  if v_folder.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_folder.group_id);
  select coalesce(array_agg(storage_path), '{}') into v_paths from public.family_document where folder_id = p_folder_id;
  delete from public.doc_folder where id = p_folder_id;
  return v_paths;
end;
$$;

-- Called after the app has uploaded the file to family-docs/<group>/<p_document_id>/<name>. Size and
-- type come from Storage, not the app.
create function public.rpc_add_document(
  p_folder_id uuid, p_document_id uuid, p_storage_path text, p_title text, p_label text default null, p_comment text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_folder public.doc_folder;
  v_obj record;
  v_title text := btrim(coalesce(p_title, ''));
begin
  select * into v_folder from public.doc_folder where id = p_folder_id;
  if v_folder.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_folder.group_id);
  if char_length(v_title) not between 1 and 80 then
    raise exception 'invalid_doc_title' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_label, ''))) > 24 then
    raise exception 'label_too_long' using errcode = '22023';
  end if;
  if p_document_id is null or p_storage_path is null
     or p_storage_path not like v_folder.group_id || '/' || p_document_id || '/%'
     or split_part(p_storage_path, '/', 3) = '' or split_part(p_storage_path, '/', 4) <> '' then
    raise exception 'file_missing' using errcode = '22023';
  end if;
  select o.metadata into v_obj from storage.objects o where o.bucket_id = 'family-docs' and o.name = p_storage_path;
  if not found then
    raise exception 'file_missing' using errcode = '22023';
  end if;

  insert into public.family_document (id, group_id, folder_id, title, label, comment, file_name, mime_type,
                                      size_bytes, storage_path, uploaded_by)
  values (p_document_id, v_folder.group_id, p_folder_id, v_title, app.clean_doc_text(p_label, 24),
          app.clean_doc_text(p_comment, 1000), split_part(p_storage_path, '/', 3),
          coalesce(v_obj.metadata ->> 'mimetype', 'application/octet-stream'),
          coalesce((v_obj.metadata ->> 'size')::bigint, 0), p_storage_path, app.current_user_id());
  update public.doc_folder set updated_at = now() where id = p_folder_id;
  return p_document_id;
end;
$$;

-- Title, label, comments, or move to another folder in the same family. Any member can.
create function public.rpc_update_document(
  p_document_id uuid, p_title text, p_label text, p_comment text, p_folder_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_doc public.family_document;
  v_title text := btrim(coalesce(p_title, ''));
begin
  select * into v_doc from public.family_document where id = p_document_id;
  if v_doc.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_doc.group_id);
  if char_length(v_title) not between 1 and 80 then
    raise exception 'invalid_doc_title' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_label, ''))) > 24 then
    raise exception 'label_too_long' using errcode = '22023';
  end if;
  if p_folder_id is not null and not exists (
       select 1 from public.doc_folder where id = p_folder_id and group_id = v_doc.group_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  update public.family_document
     set title = v_title, label = app.clean_doc_text(p_label, 24), comment = app.clean_doc_text(p_comment, 1000),
         folder_id = coalesce(p_folder_id, folder_id), updated_at = now()
   where id = p_document_id;
end;
$$;

-- Returns the stored file's path for the app to remove.
create function public.rpc_delete_document(p_document_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_doc public.family_document;
begin
  select * into v_doc from public.family_document where id = p_document_id;
  if v_doc.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform app.assert_member(v_doc.group_id);
  delete from public.family_document where id = p_document_id;
  return v_doc.storage_path;
end;
$$;

-------------------------------------------------------------------------------
-- Notifications: wording, relevance, deep link for the plan reminder
-------------------------------------------------------------------------------
alter function app.push_text(public.notification_outbox, uuid) rename to push_text_019;

create function app.push_text(p_outbox public.notification_outbox, p_user_id uuid, out title text, out body text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
  v_event public.family_event;
  v_starts timestamptz;
  v_day date;
begin
  if p_outbox.event_type <> 'notify.event_reminder' then
    select t.title, t.body into title, body from app.push_text_019(p_outbox, p_user_id) t;
    return;
  end if;

  select coalesce(p.time_zone, g.time_zone, 'Asia/Dubai') into v_tz
    from public.family_group g left join public.profile p on p.user_id = p_user_id
   where g.id = p_outbox.group_id;
  v_tz := coalesce(v_tz, 'Asia/Dubai');
  select * into v_event from public.family_event where id = p_outbox.subject_id;
  v_starts := coalesce((p_outbox.data ->> 'starts_at')::timestamptz, v_event.starts_at);
  v_day := (v_starts at time zone v_tz)::date;

  -- "Coming up: Dinner" / "Tonight at 20:00 · Nana's house"
  title := 'Coming up: ' || coalesce(v_event.title, 'a family plan');
  body := concat_ws(' · ',
    case when v_day = (now() at time zone v_tz)::date
           then case when (v_starts at time zone v_tz)::time >= time '17:00' then 'Tonight' else 'Today' end
         when v_day = (now() at time zone v_tz)::date + 1 then 'Tomorrow'
         else to_char(v_day, 'FMDay') end || ' at ' || to_char(v_starts at time zone v_tz, 'HH24:MI'),
    v_event.destination);
  title := left(title, 80);
  if char_length(body) > 180 then
    body := left(body, 179) || '…';
  end if;
end;
$$;

alter function app.delivery_relevant(public.notification_outbox) rename to delivery_relevant_019;

-- A plan reminder is worth sending until the plan starts, unless it was cancelled or you declined.
create function app.delivery_relevant(p_outbox public.notification_outbox)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_outbox.event_type = 'notify.event_reminder' then exists (
      select 1 from public.family_event e
       where e.id = p_outbox.subject_id and e.cancelled_at is null
         and now() < (p_outbox.data ->> 'starts_at')::timestamptz
         and (e.created_by = p_outbox.recipient_id or exists (
               select 1 from public.event_participant p
                where p.event_id = e.id and p.user_id = p_outbox.recipient_id and p.state <> 'declined')))
    else app.delivery_relevant_019(p_outbox)
  end
$$;
-- (dispatch_claim_deliveries already links notify.event_% to /family/events/<id>; category is 'plans'.)

-------------------------------------------------------------------------------
-- Data export: adds the documents you uploaded (details only; the files are in the app).
-------------------------------------------------------------------------------
alter function public.rpc_export_my_data() set schema app;
alter function app.rpc_export_my_data() rename to export_my_data_019;

create function public.rpc_export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  return app.export_my_data_019() || jsonb_build_object(
    'documents', coalesce((select jsonb_agg(jsonb_build_object('family', g.name, 'folder', f.name, 'title', d.title,
                                                               'label', d.label, 'comment', d.comment,
                                                               'file_name', d.file_name, 'added_at', d.created_at))
                             from public.family_document d
                             join public.doc_folder f on f.id = d.folder_id
                             join public.family_group g on g.id = d.group_id
                            where d.uploaded_by = v_uid), '[]')
  );
end;
$$;

revoke execute on function
  public.rpc_create_doc_folder(uuid, text),
  public.rpc_rename_doc_folder(uuid, text),
  public.rpc_delete_doc_folder(uuid),
  public.rpc_add_document(uuid, uuid, text, text, text, text),
  public.rpc_update_document(uuid, text, text, text, uuid),
  public.rpc_delete_document(uuid),
  public.rpc_export_my_data()
  from public, anon;
grant execute on function
  public.rpc_create_doc_folder(uuid, text),
  public.rpc_rename_doc_folder(uuid, text),
  public.rpc_delete_doc_folder(uuid),
  public.rpc_add_document(uuid, uuid, text, text, text, text),
  public.rpc_update_document(uuid, text, text, text, uuid),
  public.rpc_delete_document(uuid),
  public.rpc_export_my_data()
  to authenticated;
