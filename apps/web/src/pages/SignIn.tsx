import { Link, Navigate } from "react-router";
import { EmailCodeForm } from "../components/EmailCodeForm";
import { useAuth } from "../lib/auth";

export function SignIn() {
  const { session } = useAuth();
  if (session) return <Navigate to="/" replace />;
  return (
    <div role="main" className="signin">
      <div className="signin-hero">
        <h1 className="wordmark">fam.ly</h1>
      </div>
      <div className="signin-form">
        <EmailCodeForm />
      </div>
      <p className="signin-foot">
        <Link to="/privacy" className="muted">Privacy &amp; Terms</Link>
      </p>
    </div>
  );
}
