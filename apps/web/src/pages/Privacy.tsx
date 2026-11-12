import { Link } from "react-router";

/**
 * Privacy notice, terms and disclaimers (P09-8, BRD §11, G-08). Plain language, written from what the
 * app actually does. Needs review by a qualified adviser before anyone outside the founder's family uses it.
 */
export function Privacy() {
  return (
    <div role="main" className="narrow stack prose">
      <h1>Privacy &amp; Terms</h1>
      <p className="muted">Last updated 16 October 2026 · Family pilot version</p>

      <h2>What fam.ly Is (And Isn&apos;t)</h2>
      <p>
        fam.ly helps adults in one household share cars and plans. Everything about where people are is
        <strong> self-reported</strong>: someone taps &ldquo;Left&rdquo; or &ldquo;I&apos;m home&rdquo;. fam.ly does not track
        location and does not verify anything anyone reports.
      </p>
      <p className="warn-text">
        fam.ly is not a safety or emergency service. Notifications can be late or never arrive. Never rely on it
        to know whether someone is safe; call them, or call emergency services.
      </p>

      <h2>Who Can See What</h2>
      <ul>
        <li>Everyone in your family sees everything shared in it: members, cars, every booking, family events and
          outings (including place and notes), &ldquo;Left&rdquo; / &ldquo;I&apos;m home&rdquo; updates and the change history.</li>
        <li>Nobody outside your family can see any of it, including people in another family you belong to.</li>
        <li>Lock-screen notifications only say &ldquo;Family update in fam.ly&rdquo;; details stay in the app.</li>
      </ul>

      <h2>What We Store</h2>
      <ul>
        <li>Your email address and the name you choose; your confirmation that you are 18 or over.</li>
        <li>Your bookings, outings, events, responses and status updates, with the times they were reported.</li>
        <li>For notifications: a push address for each device you turn them on for (no phone number, no contacts).</li>
        <li>An audit trail of changes (who did what, when, and any reason given).</li>
        <li>Technical error reports from the app, without the ids of anything you were viewing.</li>
      </ul>

      <h2>Where It Lives</h2>
      <ul>
        <li>The database runs on Supabase, in the region chosen when fam.ly was set up.</li>
        <li>The website is served by Cloudflare. Sign-in emails are sent by Resend.</li>
        <li>Notifications pass through Apple&apos;s or Google&apos;s push service, which see only the generic text.</li>
      </ul>

      <h2>How Long It&apos;s Kept</h2>
      <ul>
        <li>Shared history (bookings, outings, events, status updates, activity) is deleted after <strong>90 days</strong>.</li>
        <li>The audit trail is kept for <strong>365 days</strong> to protect against disputes and mistakes.</li>
        <li>A family scheduled for deletion is permanently deleted 7 days later, with everything in it.</li>
      </ul>

      <h2>Your Choices</h2>
      <ul>
        <li><strong>Download your data</strong> at any time from Settings → Your data.</li>
        <li><strong>Delete your account</strong> from the same place. Your profile and bookings are deleted; family
          history keeps events but no longer shows who did them.</li>
        <li>Leave a family, turn notifications off, or set quiet hours whenever you like.</li>
      </ul>

      <h2>Terms</h2>
      <ul>
        <li>fam.ly is for adults (18+) coordinating within their own household, in a private family pilot.</li>
        <li>Only add information you&apos;re happy for everyone in your family to see.</li>
        <li>It is provided as is, without guarantees of availability or accuracy. Bookings are an agreement
          between family members, not a legal reservation.</li>
      </ul>

      <h2>Contact</h2>
      <p>Questions or requests: ask the person who set up fam.ly for your family.</p>
      <Link to="/">Back to fam.ly</Link>
    </div>
  );
}
