import { useEffect } from "react";
import { useRouteError } from "react-router";
import { reportError } from "../lib/errors";
import { supabase } from "../lib/supabase";

/** Shown instead of a blank page when a screen crashes; the error is reported (NFR-09). */
export function RouteError() {
  const error = useRouteError();
  useEffect(() => reportError(error), [error]);
  return (
    <div role="main" className="narrow stack">
      <h1>Something Went Wrong</h1>
      <p>This screen hit a problem. It&apos;s been reported. Your data is safe.</p>
      <button onClick={() => window.location.assign("/")}>Go To fam.ly</button>
      <button className="secondary" onClick={() => supabase.auth.signOut({ scope: "local" }).then(() => window.location.assign("/"))}>
        Sign out
      </button>
    </div>
  );
}
