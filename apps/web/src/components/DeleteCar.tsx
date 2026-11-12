import { useState } from "react";
import { useAction } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";

/**
 * Delete an inactive car, with an inline confirmation that says exactly what goes with it.
 * The server refuses active cars and cars with live bookings (rpc_delete_vehicle).
 */
export function DeleteCar(props: { vehicleId: string; name: string; groupId: string; onDeleted?: () => void }) {
  const [confirming, setConfirming] = useState(false);
  const remove = useAction(
    async () => unwrap(await supabase.rpc("rpc_delete_vehicle", { p_vehicle_id: props.vehicleId })),
    [["vehicles", props.groupId], ["car-activity", props.groupId], ["calendar", props.groupId], ["family-events", props.groupId]],
  );

  if (!confirming) {
    return (
      <button className="link danger" onClick={() => setConfirming(true)}>
        Delete Car<span className="sr-only"> {props.name}</span>
      </button>
    );
  }
  return (
    <div className="stack inset" role="group" aria-label={`Delete ${props.name}`}>
      <p>
        Delete {props.name} for everyone? Its past bookings and maintenance go with it. Family plans stay, without
        the car. This can&apos;t be undone.
      </p>
      {remove.error && <p className="error" role="alert">{messageOf(remove.error)}</p>}
      <div className="row actions">
        <button className="danger" disabled={remove.isPending}
                onClick={() => remove.mutate(undefined, { onSuccess: () => props.onDeleted?.() })}>
          {remove.isPending ? "Deleting…" : "Delete"}
        </button>
        <button className="link" onClick={() => { setConfirming(false); remove.reset(); }}>Cancel</button>
      </div>
    </div>
  );
}
