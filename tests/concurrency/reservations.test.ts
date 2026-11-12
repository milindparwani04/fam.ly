// T01, T02, NFR-03: parallel booking harness against the local Supabase Postgres.
// Run `pnpm db:start` first. Override the target with DATABASE_URL.
import { randomUUID } from "node:crypto";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const DATABASE_URL =
  process.env.DATABASE_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
const PARALLEL = 40; // stays under local max_connections alongside the Supabase services

const admin = new pg.Pool({ connectionString: DATABASE_URL, max: 2 });
const pool = new pg.Pool({ connectionString: DATABASE_URL, max: PARALLEL });

const groupId = randomUUID();
const vehicleId = randomUUID();
const users = [randomUUID(), randomUUID(), randomUUID()];

type Outcome = { ok: true; id: string } | { ok: false; code: string; message: string };

/** Opens PARALLEL authenticated sessions, waits until all are ready, then fires together. */
async function burst(calls: Array<{ user: string; sql: string; params: unknown[] }>): Promise<Outcome[]> {
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  let ready = 0;

  const run = async (call: (typeof calls)[number]): Promise<Outcome> => {
    const client = await pool.connect();
    try {
      await client.query("begin");
      await client.query("select set_config('request.jwt.claims', $1, true)", [
        JSON.stringify({ sub: call.user, role: "authenticated" }),
      ]);
      await client.query("set local role authenticated");
      if (++ready === calls.length) release();
      await gate;
      const res = await client.query<{ id: string }>(call.sql, call.params);
      await client.query("commit");
      return { ok: true, id: res.rows[0]!.id };
    } catch (err) {
      await client.query("rollback").catch(() => {});
      const e = err as { code?: string; message: string };
      return { ok: false, code: e.code ?? "?", message: e.message };
    } finally {
      client.release();
    }
  };
  return Promise.all(calls.map(run));
}

const createSql =
  "select public.rpc_create_reservation($1, $2::timestamptz, $3::timestamptz, $4) as id";

beforeAll(async () => {
  for (const [i, id] of users.entries()) {
    await admin.query("insert into auth.users (id, email) values ($1, $2)", [
      id,
      `conc-${i}-${id}@test.local`,
    ]);
  }
  await admin.query("insert into public.family_group (id, name) values ($1, 'Concurrency')", [groupId]);
  for (const id of users) {
    await admin.query("insert into public.group_membership (group_id, user_id) values ($1, $2)", [
      groupId,
      id,
    ]);
  }
  await admin.query("insert into public.vehicle (id, group_id, name) values ($1, $2, 'Harness car')", [
    vehicleId,
    groupId,
  ]);
});

afterAll(async () => {
  await admin.query("delete from public.family_group where id = $1", [groupId]);
  await admin.query("delete from auth.users where id = any($1)", [users]);
  await Promise.all([admin.end(), pool.end()]);
});

async function liveOverlaps(): Promise<number> {
  const { rows } = await admin.query<{ n: string }>(
    `select count(*) as n
       from public.vehicle_reservation a
       join public.vehicle_reservation b
         on a.vehicle_id = b.vehicle_id and a.id < b.id and a.period && b.period
      where a.vehicle_id = $1
        and a.status in ('reserved', 'in_use_reported')
        and b.status in ('reserved', 'in_use_reported')`,
    [vehicleId],
  );
  return Number(rows[0]!.n);
}

describe("reservation concurrency", () => {
  it("T01: identical window from many users at once → exactly one wins, per round", async () => {
    for (let round = 0; round < 3; round++) {
      const start = `2027-06-0${round + 1}T10:00:00+04:00`;
      const end = `2027-06-0${round + 1}T12:00:00+04:00`;
      const results = await burst(
        Array.from({ length: PARALLEL }, (_, i) => ({
          user: users[i % users.length]!,
          sql: createSql,
          params: [vehicleId, start, end, `t01-r${round}-${i}-${randomUUID()}`],
        })),
      );
      const wins = results.filter((r) => r.ok);
      const losses = results.filter((r): r is Extract<Outcome, { ok: false }> => !r.ok);
      expect(wins).toHaveLength(1);
      expect(losses.every((l) => l.code === "23P01")).toBe(true);
    }
    expect(await liveOverlaps()).toBe(0);
  });

  it("T01: random overlapping windows → no two live bookings overlap", async () => {
    const base = Date.parse("2027-07-01T00:00:00+04:00");
    const quarterHour = 15 * 60_000;
    for (let round = 0; round < 4; round++) {
      const calls = Array.from({ length: PARALLEL }, (_, i) => {
        const startQ = Math.floor(Math.random() * 96); // anywhere in a 24h day
        const lenQ = 1 + Math.floor(Math.random() * 12); // 15 min – 3 h
        return {
          user: users[i % users.length]!,
          sql: createSql,
          params: [
            vehicleId,
            new Date(base + startQ * quarterHour).toISOString(),
            new Date(base + (startQ + lenQ) * quarterHour).toISOString(),
            `t01b-r${round}-${i}-${randomUUID()}`,
          ],
        };
      });
      const results = await burst(calls);
      const unexpected = results.filter((r) => !r.ok && r.code !== "23P01");
      expect(unexpected).toEqual([]);
    }
    expect(await liveOverlaps()).toBe(0);
  });

  it("FR-V06: many owners moving their own bookings into the same slot at once → exactly one wins", async () => {
    // One booking per caller on its own day, then everyone tries to move into 1 Sep 10:00–12:00.
    const owned: Array<{ user: string; id: string }> = [];
    for (let i = 0; i < PARALLEL; i++) {
      const user = users[i % users.length]!;
      const day = new Date(Date.parse("2027-09-10T10:00:00+04:00") + i * 86_400_000);
      const [res] = await burst([
        {
          user,
          sql: createSql,
          params: [vehicleId, day.toISOString(), new Date(day.getTime() + 3_600_000).toISOString(), `mv-${i}-${randomUUID()}`],
        },
      ]);
      if (!res?.ok) throw new Error(`setup booking ${i} failed: ${JSON.stringify(res)}`);
      owned.push({ user, id: res.id });
    }

    const results = await burst(
      owned.map((o) => ({
        user: o.user,
        sql: "select public.rpc_update_reservation($1, $2::timestamptz, $3::timestamptz, 1)::text as id",
        params: [o.id, "2027-09-01T10:00:00+04:00", "2027-09-01T12:00:00+04:00"],
      })),
    );
    expect(results.filter((r) => r.ok)).toHaveLength(1);
    expect(results.filter((r) => !r.ok).every((r) => !r.ok && r.code === "23P01")).toBe(true);
    expect(await liveOverlaps()).toBe(0);
  });

  it("T07/T11: 40 devices tapping \"I'm home\" at once → one report, car returned once", async () => {
    const owner = users[0]!;
    const start = new Date(Date.now() + 20 * 60_000);
    const [created] = await burst([
      {
        user: owner,
        sql: createSql,
        params: [vehicleId, start.toISOString(), new Date(start.getTime() + 2 * 3_600_000).toISOString(), `home-${randomUUID()}`],
      },
    ]);
    if (!created?.ok) throw new Error(`setup failed: ${JSON.stringify(created)}`);
    const { rows } = await admin.query<{ id: string }>("select id from public.outing where reservation_id = $1", [created.id]);
    const outingId = rows[0]!.id;
    const [left] = await burst([
      { user: owner, sql: "select (public.rpc_report_left($1, $2) ->> 'report_id') as id", params: [outingId, `left-${randomUUID()}`] },
    ]);
    expect(left?.ok).toBe(true);

    const results = await burst(
      Array.from({ length: PARALLEL }, () => ({
        user: owner,
        sql: "select (public.rpc_confirm_home($1, $2) ->> 'report_id') as id",
        params: [outingId, `home-tap-${randomUUID()}`], // every device has its own key
      })),
    );
    expect(results.every((r) => r.ok)).toBe(true);
    expect(new Set(results.map((r) => (r.ok ? r.id : ""))).size).toBe(1);
    const { rows: reports } = await admin.query<{ n: string }>(
      "select count(*) as n from public.status_report where outing_id = $1 and kind = 'home_and_car_returned'",
      [outingId],
    );
    expect(Number(reports[0]!.n)).toBe(1);
  });

  it("T02: retry storm with one idempotency key → one booking, same id everywhere", async () => {
    const key = `t02-${randomUUID()}`;
    const results = await burst(
      Array.from({ length: PARALLEL }, () => ({
        user: users[0]!,
        sql: createSql,
        params: [vehicleId, "2027-08-01T10:00:00+04:00", "2027-08-01T11:00:00+04:00", key],
      })),
    );
    expect(results.every((r) => r.ok)).toBe(true);
    const ids = new Set(results.map((r) => (r.ok ? r.id : "")));
    expect(ids.size).toBe(1);
    const { rows } = await admin.query<{ n: string }>(
      "select count(*) as n from public.vehicle_reservation where idempotency_key = $1",
      [key],
    );
    expect(Number(rows[0]!.n)).toBe(1);
  });
});
