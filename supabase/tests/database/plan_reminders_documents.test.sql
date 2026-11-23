-- Migration 020: the 12-hours-before plan reminder, and family Documents.
-- (now() is fixed for the whole test; family A is on Asia/Dubai.)
begin;
select plan(40);

\ir _fixtures.psql

-- A third member of family A, so "everyone going" differs from "the whole family".
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a3', 'a3@test.local', '{"display_name":"Ravi"}');
insert into public.group_membership (group_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'member');

create function pg_temp.reminded(p_event uuid) returns text[] language sql as $$
  select coalesce(array_agg(recipient_id::text order by recipient_id), '{}') from public.notification_outbox
   where event_type = 'notify.event_reminder' and subject_id = p_event
$$;

-------------------------------------------------------------------------------
-- Plan reminders
-------------------------------------------------------------------------------
-- f1 in 11h30 (made 2 days ago): Asha made it, Sam invited, Ravi declined.
-- f2 in 11h30 but made 10 minutes ago. f3 in 11h30, cancelled. f4 in 13h. f5 in 10h.
-- f6 weekly, first one a week ago at the same wall time (11h30 from now). f7 weekly but ended yesterday.
-- f8 in 11h30, Family B.
insert into public.family_event (id, group_id, created_by, title, starts_at, ends_at, destination, created_at, cancelled_at, repeat, repeat_until) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'Dinner',
   now() + interval '11 hours 30 minutes', now() + interval '13 hours', 'Nana''s house', now() - interval '2 days', null, null, null),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'Late add',
   now() + interval '11 hours 30 minutes', now() + interval '13 hours', null, now() - interval '10 minutes', null, null, null),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'Cancelled',
   now() + interval '11 hours 30 minutes', now() + interval '13 hours', null, now() - interval '2 days', now(), null, null),
  ('00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'Too far',
   now() + interval '13 hours', now() + interval '14 hours', null, now() - interval '2 days', null, null, null),
  ('00000000-0000-0000-0000-0000000000f5', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'Missed window',
   now() + interval '10 hours', now() + interval '11 hours', null, now() - interval '2 days', null, null, null),
  ('00000000-0000-0000-0000-0000000000f6', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'Padel',
   now() + interval '11 hours 30 minutes' - interval '7 days', now() + interval '12 hours 30 minutes' - interval '7 days', null,
   now() - interval '8 days', null, 'weekly', null),
  ('00000000-0000-0000-0000-0000000000f7', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'Ended',
   now() + interval '11 hours 30 minutes' - interval '7 days', now() + interval '12 hours 30 minutes' - interval '7 days', null,
   now() - interval '8 days', null, 'weekly', (now() at time zone 'Asia/Dubai')::date - 1),
  ('00000000-0000-0000-0000-0000000000f8', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000b1', 'Other family',
   now() + interval '11 hours 30 minutes', now() + interval '13 hours', null, now() - interval '2 days', null, null, null);
insert into public.event_participant (group_id, event_id, user_id, state) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a2', 'invited'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a3', 'declined'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000a2', 'invited');

select ok(app.prompt_event_reminders() >= 1, 'the reminder job runs');
select is(pg_temp.reminded('00000000-0000-0000-0000-0000000000f1'),
  array['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2'],
  'the maker and the invitee are reminded; someone who declined is not');
select is(pg_temp.reminded('00000000-0000-0000-0000-0000000000f2'), '{}'::text[], 'a plan made under 12 hours ahead gets no reminder');
select is(pg_temp.reminded('00000000-0000-0000-0000-0000000000f3'), '{}'::text[], 'a cancelled plan gets no reminder');
select is(pg_temp.reminded('00000000-0000-0000-0000-0000000000f4'), '{}'::text[], 'not before 12 hours ahead');
select is(pg_temp.reminded('00000000-0000-0000-0000-0000000000f5'), '{}'::text[], 'and not more than an hour late');
select is(pg_temp.reminded('00000000-0000-0000-0000-0000000000f6'), array['00000000-0000-0000-0000-0000000000a2'],
  'this week''s occurrence of a weekly plan is reminded');
select is(pg_temp.reminded('00000000-0000-0000-0000-0000000000f7'), '{}'::text[], 'a repeating plan that has ended is not');
select is(pg_temp.reminded('00000000-0000-0000-0000-0000000000f8'), array['00000000-0000-0000-0000-0000000000b1'],
  'other families get their own reminders');
select is((select (data ->> 'starts_at')::timestamptz from public.notification_outbox
            where event_type = 'notify.event_reminder' and subject_id = '00000000-0000-0000-0000-0000000000f6'),
  now() + interval '11 hours 30 minutes', 'the reminder carries the occurrence''s start');
select is(app.prompt_event_reminders(), 0, 'each person is reminded once per occurrence');
select is(app.notify_category('notify.event_reminder'), 'plans', 'it follows the Plans notification switch');

select is((select t.title || ' | ' || t.body from public.notification_outbox o cross join lateral app.push_text(o, o.recipient_id) t
            where o.event_type = 'notify.event_reminder' and o.subject_id = '00000000-0000-0000-0000-0000000000f1'
              and o.recipient_id = '00000000-0000-0000-0000-0000000000a2'),
  'Coming up: Dinner | '
  || case when ((now() + interval '11 hours 30 minutes') at time zone 'Asia/Dubai')::date = (now() at time zone 'Asia/Dubai')::date
          then case when ((now() + interval '11 hours 30 minutes') at time zone 'Asia/Dubai')::time >= time '17:00' then 'Tonight' else 'Today' end
          else 'Tomorrow' end
  || ' at ' || to_char((now() + interval '11 hours 30 minutes') at time zone 'Asia/Dubai', 'HH24:MI') || ' · Nana''s house',
  'the push names the plan, when and where');

select ok(app.delivery_relevant((select o from public.notification_outbox o where o.event_type = 'notify.event_reminder'
            and o.subject_id = '00000000-0000-0000-0000-0000000000f1' and o.recipient_id = '00000000-0000-0000-0000-0000000000a2')),
  'relevant while the plan is on');
update public.event_participant set state = 'declined'
 where event_id = '00000000-0000-0000-0000-0000000000f1' and user_id = '00000000-0000-0000-0000-0000000000a2';
select ok(not app.delivery_relevant((select o from public.notification_outbox o where o.event_type = 'notify.event_reminder'
            and o.subject_id = '00000000-0000-0000-0000-0000000000f1' and o.recipient_id = '00000000-0000-0000-0000-0000000000a2')),
  'dropped if you decline before it goes out');
update public.family_event set cancelled_at = now() where id = '00000000-0000-0000-0000-0000000000f1';
select ok(not app.delivery_relevant((select o from public.notification_outbox o where o.event_type = 'notify.event_reminder'
            and o.subject_id = '00000000-0000-0000-0000-0000000000f1' and o.recipient_id = '00000000-0000-0000-0000-0000000000a1')),
  'dropped if the plan is cancelled');
select is((select count(*) from cron.job where jobname = 'famly-event-reminders'), 1::bigint, 'the job is scheduled');

-------------------------------------------------------------------------------
-- Documents
-------------------------------------------------------------------------------
select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select set_config('t.folder', public.rpc_create_doc_folder('00000000-0000-0000-0000-00000000000a', '  Asha Rao ')::text, true);
select is((select name from public.doc_folder where id = current_setting('t.folder')::uuid), 'Asha Rao', 'folder names are trimmed');
select throws_ok($$ select public.rpc_create_doc_folder('00000000-0000-0000-0000-00000000000a', 'asha rao') $$,
  '23505', 'duplicate_folder', 'folder names are unique in a family, ignoring case');
select throws_ok($$ select public.rpc_create_doc_folder('00000000-0000-0000-0000-00000000000a', '   ') $$,
  '22023', 'invalid_folder_name', 'a folder needs a name');
select throws_ok($$ select public.rpc_create_doc_folder('00000000-0000-0000-0000-00000000000b', 'Mine') $$,
  'P0002', 'not_found', 'not in another family');
select set_config('t.folder2', public.rpc_create_doc_folder('00000000-0000-0000-0000-00000000000a', 'House')::text, true);

select throws_ok(format($$ select public.rpc_add_document(%L, '00000000-0000-0000-0000-000000000d01',
  '00000000-0000-0000-0000-00000000000a/00000000-0000-0000-0000-000000000d01/passport.pdf', 'Passport') $$, current_setting('t.folder')),
  '22023', 'file_missing', 'the file must be uploaded first');
select pg_temp.logout();

-- The upload itself (what Storage writes).
insert into storage.objects (bucket_id, name, owner, metadata) values
  ('family-docs', '00000000-0000-0000-0000-00000000000a/00000000-0000-0000-0000-000000000d01/passport.pdf',
   '00000000-0000-0000-0000-0000000000a1', '{"size": 204800, "mimetype": "application/pdf"}'),
  ('family-docs', '00000000-0000-0000-0000-00000000000b/00000000-0000-0000-0000-000000000d02/b.pdf',
   '00000000-0000-0000-0000-0000000000b1', '{"size": 10, "mimetype": "application/pdf"}');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(format($$ select public.rpc_add_document(%L, '00000000-0000-0000-0000-000000000d02',
  '00000000-0000-0000-0000-00000000000b/00000000-0000-0000-0000-000000000d02/b.pdf', 'Theirs') $$, current_setting('t.folder')),
  '22023', 'file_missing', 'can''t claim another family''s file');
select throws_ok(format($$ select public.rpc_add_document(%L, '00000000-0000-0000-0000-000000000d01',
  '00000000-0000-0000-0000-00000000000a/00000000-0000-0000-0000-000000000d01/passport.pdf', '  ') $$, current_setting('t.folder')),
  '22023', 'invalid_doc_title', 'a document needs a title');
select throws_ok(format($$ select public.rpc_add_document(%L, '00000000-0000-0000-0000-000000000d01',
  '00000000-0000-0000-0000-00000000000a/00000000-0000-0000-0000-000000000d01/passport.pdf', 'Passport', repeat('x', 25)) $$, current_setting('t.folder')),
  '22023', 'label_too_long', 'labels are short (sticker size)');
select lives_ok(format($$ select public.rpc_add_document(%L, '00000000-0000-0000-0000-000000000d01',
  '00000000-0000-0000-0000-00000000000a/00000000-0000-0000-0000-000000000d01/passport.pdf', ' UK Passport ', ' Passport ', 'Expires 2031') $$, current_setting('t.folder')),
  'a member adds the uploaded file');
select is((select row(title, label, comment, file_name, mime_type, size_bytes)::text from public.family_document
            where id = '00000000-0000-0000-0000-000000000d01'),
  row('UK Passport', 'Passport', 'Expires 2031', 'passport.pdf', 'application/pdf', 204800::bigint)::text,
  'title, sticker and comments saved; size and type taken from Storage');
select pg_temp.logout();

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select is((select count(*) from public.family_document), 1::bigint, 'the whole family sees the document');
select is((select count(*) from storage.objects where bucket_id = 'family-docs'), 1::bigint, 'and can open its file, not other families''');
select lives_ok(format($$ select public.rpc_update_document('00000000-0000-0000-0000-000000000d01', 'Passport', '', '', %L) $$, current_setting('t.folder2')),
  'any member can edit and move it');
select is((select row(title, label, comment, folder_id)::text from public.family_document where id = '00000000-0000-0000-0000-000000000d01'),
  row('Passport', null::text, null::text, current_setting('t.folder2')::uuid)::text, 'blank label and comments are cleared');
select pg_temp.logout();

select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
select is((select count(*) from public.doc_folder), 0::bigint, 'other families see no folders');
select is((select count(*) from public.family_document), 0::bigint, 'or documents');
select is((select count(*) from storage.objects where bucket_id = 'family-docs' and name like '00000000-0000-0000-0000-00000000000a/%'), 0::bigint,
  'or files');
select throws_ok($$ select public.rpc_delete_document('00000000-0000-0000-0000-000000000d01') $$, 'P0002', 'not_found',
  'and can''t delete them');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('family-docs', %L) $$,
  '00000000-0000-0000-0000-00000000000a/x/evil.pdf'), '42501', null, 'or upload into them');
select pg_temp.logout();

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('family-docs', '00000000-0000-0000-0000-00000000000a/00000000-0000-0000-0000-000000000d03/a.png') $$,
  'members upload into their family''s space');
select is(public.rpc_delete_document('00000000-0000-0000-0000-000000000d01'),
  '00000000-0000-0000-0000-00000000000a/00000000-0000-0000-0000-000000000d01/passport.pdf', 'deleting returns the file to remove');
select is(public.rpc_delete_doc_folder(current_setting('t.folder2')::uuid), '{}'::text[], 'an empty folder deletes cleanly');
select pg_temp.logout();

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
select ok(public.rpc_export_my_data() ? 'documents', 'the data export lists your documents');
select pg_temp.logout();

select * from finish();
rollback;
