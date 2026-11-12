export function Shared() {
  return (
    <div className="stack prose">
      <h2>What's Shared With Everyone In Your Family</h2>
      <p>fam.ly is built for adults in one household to coordinate. Inside a family, everyone sees:</p>
      <ul>
        <li>Who is in the family, and who the custodians are</li>
        <li>The family's cars, maintenance windows and every booking</li>
        <li>Family calendar events and outings, including destination and notes</li>
        <li>"Left" and "I'm home" updates, and when they were reported</li>
        <li>A history of changes (who did what, and when)</li>
      </ul>
      <h3>What fam.ly Does Not Do</h3>
      <ul>
        <li>No location tracking. Everything is self-reported by tapping a button.</li>
        <li>No one outside your family can see anything. People in another family you belong to can't see this one.</li>
        <li>Lock-screen notifications never show where someone is going.</li>
      </ul>
      <p className="muted">Status is self-reported and not verified. Notifications are best-effort and may be delayed.</p>
    </div>
  );
}
