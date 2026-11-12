# ADR-005: Sign-up gate, member exit and group deletion (interim policies)

- **Status:** Accepted for the family pilot (interim; revisit OP-06/OP-07/OP-10 before any external pilot)
- **Date:** 2026-10-16
- **Related:** FR-A02, FR-A03, FR-A04, FR-A06, T19, OP-06, OP-07, OP-10

## Sign-up gate
Supabase `enable_signup = true`, gated by the `before_user_created` auth hook
(`app.hook_before_user_created`). A new account is allowed only if the email is in
`app.signup_allowlist` (founder bootstrap, operator-managed via SQL) or the sign-up carries a
currently valid invite token in `user_metadata.invite_token`. Verified end to end against the
local Auth API (no token 403, valid token 200, bogus token 403).

Sign-in uses a 6-digit email code, not a magic link: on iOS a link opens Safari, not the
installed home-screen PWA.

**Hosted project setup:** enable the hook in the dashboard (Auth → Hooks → Before User Created →
Postgres `app.hook_before_user_created`) *before* enabling sign-ups, and use code-based email templates.

## Invites
32 random bytes, base64url; only the SHA-256 is stored. 72h default, 1h–7d allowed. Single-use,
revocable by any member. Distinct rejection reasons (expired / used / revoked / invalid) for UX.
Accepting requires 18+ self-attestation (OP-10 interim).

## Member exit (OP-07 interim)
- Leaving or removal is **blocked** while the member has a booking in `in_use_reported`.
- Their future `reserved` bookings are cancelled, each with an audit entry.
- The last member cannot leave (delete the group instead).
- If the last custodian exits, the longest-standing remaining member becomes custodian.
- Any adult may remove another adult (D09) with a mandatory reason, which is audited.
- Notices to affected members are added when the notification outbox lands (P08).

## Group deletion (OP-06 interim)
Custodian only, exact group name typed, 7-day soft-delete window cancellable by any adult;
outstanding invites are revoked at request time. Final purge is P09-3.
