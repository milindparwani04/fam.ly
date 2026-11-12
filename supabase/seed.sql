-- Local development seed. Synthetic data only; never runs against the hosted project.
-- Sign in at http://127.0.0.1:5173 as founder@test.local; read the code in Mailpit (http://127.0.0.1:54324).
insert into app.signup_allowlist (email) values ('founder@test.local') on conflict do nothing;
