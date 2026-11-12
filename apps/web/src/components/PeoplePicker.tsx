import { Avatar } from "./Avatar";

/** Family members as avatar chips that toggle (invites, task assignees). Pressed = ink fill. */
export function PeoplePicker(props: {
  members: Array<{ user_id: string; display_name: string }>;
  selected: string[];
  onChange: (ids: string[]) => void;
  label: string;
}) {
  return (
    <div className="pick-people" role="group" aria-label={props.label}>
      {props.members.map((m) => {
        const on = props.selected.includes(m.user_id);
        return (
          <button key={m.user_id} type="button" className="pick-person" aria-pressed={on}
                  onClick={() => props.onChange(on ? props.selected.filter((id) => id !== m.user_id) : [...props.selected, m.user_id])}>
            <Avatar name={m.display_name} />
            {m.display_name.split(/\s+/)[0]}
          </button>
        );
      })}
    </div>
  );
}
