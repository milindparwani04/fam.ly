import { addDays, wallDate } from "@famly/domain";
import { useState, type FormEvent } from "react";
import { useNavigate } from "react-router";
import { VisibleToAll } from "../components/EventForm";
import { useAction, useCurrentGroup } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

export function NewMenu() {
  const { group } = useCurrentGroup();
  return group ? <MenuForm group={group} /> : null;
}

/** New Menu: which day and what's on it. Everyone in the family is notified; there's no invite list. */
function MenuForm({ group }: { group: Group }) {
  const navigate = useNavigate();
  const today = wallDate(new Date(), group.time_zone);
  const [date, setDate] = useState(today);
  const [items, setItems] = useState("");
  const [error, setError] = useState<string | null>(null);

  const create = useAction(
    async () =>
      unwrap(
        await supabase.rpc("rpc_create_menu", { p_group_id: group.id, p_menu_date: date, p_items: items }),
      ),
    [["family-menus", group.id]],
  );

  function submit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    create.mutate(undefined, {
      onSuccess: (id) => navigate(`/family/menus/${id}`, { replace: true }),
      onError: (err) => setError(messageOf(err)),
    });
  }

  return (
    <form onSubmit={submit} className="stack">
      <VisibleToAll groupName={group.name} details="what's on the menu" />
      <section className="card stack">
        <label>
          For
          <input type="date" required min={today} max={addDays(today, 30)} value={date}
                 onChange={(e) => setDate(e.target.value)} />
        </label>
        <label>
          Menu
          <textarea required maxLength={2000} rows={6} value={items} onChange={(e) => setItems(e.target.value)}
                    placeholder={"e.g. Lunch: dal, rice, bhindi\nDinner: paneer tikka, roti"} />
        </label>
      </section>
      <p className="muted">
        Everyone in {group.name} is notified and can accept it or modify it. You&apos;ll see who has accepted.
      </p>
      {error && <p className="error" role="alert">{error}</p>}
      <button type="submit" className="confirm-btn press" disabled={create.isPending || !items.trim() || !date}>
        {create.isPending ? "Saving…" : "Share Menu"}
      </button>
      <button type="button" className="secondary" onClick={() => navigate(-1)}>Cancel</button>
    </form>
  );
}
