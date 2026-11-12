import { wallDate } from "@famly/domain";
import { useState } from "react";
import { useAction, useFamilyMenu } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";
import { Sheet, useUI } from "../lib/ui";
import { rateTitle } from "../pages/MenuDetail";
import { StarPicker } from "./Stars";

const WORDS = ["", "Not good", "Could be better", "Good", "Really good", "Loved it"];

/** Rate a day's food (founder, 2026-11-12): 1–5 stars and an optional comment. Final once sent. */
export function RateForm({ groupId, menuId, onDone }: { groupId: string; menuId: string; onDone: (stars: number) => void }) {
  const [stars, setStars] = useState(0);
  const [comment, setComment] = useState("");
  const rate = useAction(
    async () => unwrap(await supabase.rpc("rpc_review_menu", { p_menu_id: menuId, p_stars: stars, p_comment: comment })),
    [["family-menus", groupId], ["menu-reviews", menuId], ["family-menu", menuId]],
  );
  return (
    <>
      <StarPicker value={stars} onChange={setStars} disabled={rate.isPending} />
      <p className="rate-word" aria-live="polite">{WORDS[stars] || "Tap a star"}</p>
      <label>
        <span>Comment <span className="muted">(optional)</span></span>
        <textarea rows={3} maxLength={500} value={comment} onChange={(e) => setComment(e.target.value)}
                  placeholder="e.g. More spice next time" />
      </label>
      <p className="muted" style={{ fontSize: 13 }}>You can&apos;t change your rating after sending. You&apos;ll see everyone&apos;s once you&apos;ve rated.</p>
      {rate.error && <p className="error" role="alert">{messageOf(rate.error)}</p>}
      <button className="confirm-btn press" disabled={stars === 0 || rate.isPending}
              onClick={() => rate.mutate(undefined, { onSuccess: () => onDone(stars) })}>
        {rate.isPending ? "Sending…" : "Send Rating"}
      </button>
    </>
  );
}

export function RateSheet({ groupId, timeZone, menuId }: { groupId: string; timeZone: string; menuId: string }) {
  const ui = useUI();
  const menu = useFamilyMenu(menuId);
  const title = menu.data ? rateTitle(menu.data.menu_date, wallDate(new Date(), timeZone), timeZone) : "Rate The Food";
  return (
    <Sheet label="Rate the food" onClose={ui.close}>
      <h2>{title}</h2>
      {menu.data && <p className="muted rate-items">{menu.data.items.split("\n").map((l) => l.trim()).filter(Boolean).join(", ")}</p>}
      <RateForm groupId={groupId} menuId={menuId}
                onDone={(n) => { ui.close(); ui.toast(`Thanks · you gave it ${n} star${n === 1 ? "" : "s"}`); }} />
    </Sheet>
  );
}
