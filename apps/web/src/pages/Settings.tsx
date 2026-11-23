import { useEffect, useState, type FormEvent } from "react";
import { Link, useNavigate } from "react-router";
import { ChevronRight } from "../components/Icons";
import { NotificationSettings } from "../components/NotificationSettings";
import { YourData } from "../components/YourData";
import { useUserId } from "../lib/auth";
import { useAction, useCurrentGroup, useMembers } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { useWorkHours } from "../lib/status";
import { CURRENT_GROUP_KEY, save } from "../lib/storage";
import { supabase } from "../lib/supabase";
import { useUI } from "../lib/ui";

/** Settings (Stickers board), opened from the household menu. The page scrolls. */
export function Settings() {
  const { group } = useCurrentGroup();
  const [dataOpen, setDataOpen] = useState(false);
  if (!group) return null;
  return (
    <div className="stack settings">
      <h2 className="eyebrow">NOTIFICATIONS</h2>
      <NotificationSettings />

      <h2 className="eyebrow">WORK</h2>
      <WorkHours familyName={group.name} />

      <h2 className="eyebrow">DOCUMENTS</h2>
      <div className="set-card flat">
        <ul className="rows">
          <li>
            <Link to="/documents" className="rowlink">
              <span className="text"><span className="title">Documents</span><span className="sub">Family papers in folders. Everyone in {group.name} can see them.</span></span>
              <ChevronRight className="chev" />
            </Link>
          </li>
        </ul>
      </div>

      <h2 className="eyebrow">PRIVACY</h2>
      <div className="set-card flat">
        <ul className="rows">
          <li>
            <Link to="/shared" className="rowlink">
              <span className="text"><span className="title">What&apos;s Shared</span><span className="sub">What everyone in {group.name} can see.</span></span>
              <ChevronRight className="chev" />
            </Link>
          </li>
          <li>
            <button className="rowlink" aria-expanded={dataOpen} onClick={() => setDataOpen(!dataOpen)}>
              <span className="text"><span className="title">Your Data</span><span className="sub">Download or delete what fam.ly keeps.</span></span>
              <ChevronRight className="chev" />
            </button>
            {dataOpen && <div className="set-block"><YourData /></div>}
          </li>
        </ul>
      </div>

      <h2 className="eyebrow">ACCOUNT</h2>
      <button className="outline-btn" onClick={() => supabase.auth.signOut()}>Sign Out</button>

      <h2 className="eyebrow">FAMILY</h2>
      <LeaveFamily groupId={group.id} groupName={group.name} />
      <DeleteFamily groupId={group.id} groupName={group.name} pending={!!group.deletion_requested_at} />
    </div>
  );
}

const WEEK = [
  { iso: 1, short: "M", long: "Monday" },
  { iso: 2, short: "T", long: "Tuesday" },
  { iso: 3, short: "W", long: "Wednesday" },
  { iso: 4, short: "T", long: "Thursday" },
  { iso: 5, short: "F", long: "Friday" },
  { iso: 6, short: "S", long: "Saturday" },
  { iso: 7, short: "S", long: "Sunday" },
];

/**
 * Work (founder, 2026-11-07): tap the days you work and set your hours. During them Today shows you as
 * "Work". Saved as you change it.
 */
function WorkHours({ familyName }: { familyName: string }) {
  const uid = useUserId();
  const ui = useUI();
  const work = useWorkHours([uid]);
  const row = work.data?.[0];
  const [days, setDays] = useState<number[]>([]);
  const [starts, setStarts] = useState("09:00");
  const [ends, setEnds] = useState("17:00");
  useEffect(() => {
    if (!row) return;
    setDays([...row.days]);
    if (row.starts) setStarts(row.starts.slice(0, 5));
    if (row.ends) setEnds(row.ends.slice(0, 5));
  }, [row]);

  const saveWork = useAction(
    async (v: { days: number[]; starts: string; ends: string }) =>
      unwrap(await supabase.rpc("rpc_set_work_hours", { p_days: v.days, p_starts: v.starts, p_ends: v.ends })),
    [["work-hours"]],
  );
  function commit(next: { days: number[]; starts: string; ends: string }) {
    setDays(next.days);
    setStarts(next.starts);
    setEnds(next.ends);
    if (!next.starts || !next.ends || next.starts === next.ends) return;
    saveWork.mutate(next, { onSuccess: () => ui.toast("Work hours saved") });
  }
  const toggle = (iso: number) =>
    commit({ days: days.includes(iso) ? days.filter((d) => d !== iso) : [...days, iso].sort(), starts, ends });

  return (
    <div className="set-card">
      <div className="set-block">
        <span className="set-title">Working Days</span>
        <div className="weekdays" role="group" aria-label="Working days">
          {WEEK.map((d) => (
            <button key={d.iso} className="weekday" aria-pressed={days.includes(d.iso)} aria-label={d.long}
                    disabled={work.isPending} onClick={() => toggle(d.iso)}>
              {d.short}
            </button>
          ))}
        </div>
      </div>
      <div className="set-block">
        <div className="field-row">
          <label>Starts<input type="time" value={starts} onChange={(e) => setStarts(e.target.value)} onBlur={() => commit({ days, starts, ends })} /></label>
          <label>Ends<input type="time" value={ends} onChange={(e) => setEnds(e.target.value)} onBlur={() => commit({ days, starts, ends })} /></label>
        </div>
        <p className="set-sub">
          {days.length === 0
            ? "Tap the days you work. Today will show you as Work during these hours."
            : `Today shows you as Work during these hours. Everyone in ${familyName} can see them.`}
        </p>
        {starts && ends && starts === ends && <p className="error">Start and end can&apos;t be the same.</p>}
        {saveWork.error && <p className="error" role="alert">{messageOf(saveWork.error)}</p>}
      </div>
    </div>
  );
}

function LeaveFamily({ groupId, groupName }: { groupId: string; groupName: string }) {
  const navigate = useNavigate();
  const [confirming, setConfirming] = useState(false);
  const leave = useAction(async () => unwrap(await supabase.rpc("rpc_leave_group", { p_group_id: groupId })), [["groups"]]);
  function confirmLeave() {
    leave.mutate(undefined, {
      onSuccess: () => {
        save(CURRENT_GROUP_KEY, null);
        navigate("/");
      },
    });
  }
  if (!confirming) return <button className="outline-btn" onClick={() => setConfirming(true)}>Leave {groupName}…</button>;
  return (
    <div className="set-card flat">
      <div className="set-block">
        <span className="set-title">Leave {groupName}?</span>
        <p className="set-sub">Your upcoming bookings will be cancelled and you&apos;ll lose access to this family&apos;s information.</p>
        {leave.error && <p className="error">{messageOf(leave.error)}</p>}
        <div className="field-row">
          <button className="danger" disabled={leave.isPending} onClick={confirmLeave}>Leave</button>
          <button className="secondary" onClick={() => setConfirming(false)}>Cancel</button>
        </div>
      </div>
    </div>
  );
}

function DeleteFamily(props: { groupId: string; groupName: string; pending: boolean }) {
  const uid = useUserId();
  const members = useMembers(props.groupId);
  const [typed, setTyped] = useState("");
  const request = useAction(
    async () => unwrap(await supabase.rpc("rpc_request_group_deletion", { p_group_id: props.groupId, p_confirm_name: typed })),
    [["groups"]],
  );
  const isCustodian = members.data?.some((m) => m.user_id === uid && m.role === "custodian");
  if (props.pending) return null;

  function submit(e: FormEvent) {
    e.preventDefault();
    request.mutate(undefined);
  }

  return (
    <div className="delete-box">
      <span className="t">Delete Family</span>
      {!isCustodian ? (
        <p>Only a custodian can delete the family. Deletion happens after 7 days.</p>
      ) : (
        <form onSubmit={submit} className="stack">
          <p>
            Deletion happens after <strong>7 days</strong>, and any adult can stop it during that time. After that, all
            bookings, outings and history for this family are permanently removed.
          </p>
          <label>
            <span>Type <strong>{props.groupName}</strong> to confirm</span>
            <input value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" />
          </label>
          {request.error && <p className="error">{messageOf(request.error)}</p>}
          <button type="submit" className="danger" disabled={typed !== props.groupName || request.isPending}>Schedule Deletion</button>
        </form>
      )}
    </div>
  );
}
