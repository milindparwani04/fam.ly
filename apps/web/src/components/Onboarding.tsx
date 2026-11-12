import type { ReactNode } from "react";

/** Shell for the signed-out and first-run pages (welcome, profile, join): the sign-in look, with the wordmark up top. */
export function Onboarding({ title, children }: { title?: ReactNode; children: ReactNode }) {
  return (
    <div role="main" className="signin onboarding">
      <div className="onboarding-hero">
        <span className="wordmark">fam.ly</span>
      </div>
      <div className="onboarding-body">
        {title && <h1>{title}</h1>}
        {children}
      </div>
    </div>
  );
}

/** Full-screen loading state: the wordmark alone, with the status read out. */
export function Splash() {
  return (
    <div role="main" className="signin">
      <div className="signin-hero">
        <span className="wordmark" aria-hidden="true">fam.ly</span>
      </div>
      <p className="sr-only" role="status">Loading…</p>
    </div>
  );
}
