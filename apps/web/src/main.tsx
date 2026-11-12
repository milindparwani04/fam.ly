import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createBrowserRouter, Link, Navigate } from "react-router";
import { RouterProvider } from "react-router/dom";
import { Layout } from "./components/Layout";
import { RouteError } from "./components/RouteError";
import { Onboarding, Splash } from "./components/Onboarding";
import { ProfileSetup } from "./components/ProfileSetup";
import { AuthProvider, useAuth } from "./lib/auth";
import { useGroups, useProfile } from "./lib/queries";
import { messageOf } from "./lib/rpc";
import { installGlobalErrorReporting } from "./lib/errors";
import { registerServiceWorker } from "./lib/push";
import { load, PENDING_INVITE_KEY } from "./lib/storage";
import { supabase } from "./lib/supabase";
import { Activity } from "./pages/Activity";
import { Book } from "./pages/Book";
import { BookingDetail } from "./pages/BookingDetail";
import { Calendar } from "./pages/Calendar";
import { CarDetail } from "./pages/CarDetail";
import { Cars } from "./pages/Cars";
import { EventDetail } from "./pages/EventDetail";
import { AllPlans, AllTasks, FamilyCalendar } from "./pages/FamilyCalendar";
import { FamilyHome } from "./pages/FamilyHome";
import { FamilyNew } from "./pages/FamilyNew";
import { MenuDetail } from "./pages/MenuDetail";
import { NewStay, StayDetail } from "./pages/Stays";
import { NewEvent } from "./pages/NewEvent";
import { NewMenu } from "./pages/NewMenu";
import { NewTask } from "./pages/NewTask";
import { Privacy } from "./pages/Privacy";
import { Join } from "./pages/Join";
import { Settings } from "./pages/Settings";
import { Shared } from "./pages/Shared";
import { TaskDetail } from "./pages/TaskDetail";
import { Today } from "./pages/Today";
import { SignIn } from "./pages/SignIn";
import { Welcome } from "./pages/Welcome";
import "@fontsource-variable/bricolage-grotesque/opsz.css";
import "@fontsource/jetbrains-mono/500.css";
import "@fontsource/jetbrains-mono/700.css";
import "./styles.css";

/** Routes a signed-in user to the right first-run step, or into the app. */
function Gate() {
  const { session, loading } = useAuth();
  if (loading) return <Splash />;
  if (!session) return <Navigate to="/sign-in" replace />;
  return <SignedIn />;
}

function SignedIn() {
  const profile = useProfile();
  const groups = useGroups();
  if (profile.isPending || groups.isPending) return <Splash />;
  if (profile.isError) return <FatalError error={profile.error} />;
  if (groups.isError) return <FatalError error={groups.error} />;

  const pendingInvite = load(PENDING_INVITE_KEY);
  if (pendingInvite) return <Navigate to={`/join/${pendingInvite}`} replace />;

  if (!profile.data.adult_attested_at || !profile.data.display_name) {
    return (
      <Onboarding title="Welcome To fam.ly">
        <ProfileSetup initialName={profile.data.display_name} />
      </Onboarding>
    );
  }
  if (groups.data.length === 0) return <Welcome />;
  return <Layout />;
}

/** Full-page error with a way out, so a broken session is never a dead end. */
function FatalError({ error }: { error: unknown }) {
  return (
    <div role="main" className="narrow stack">
      <p className="error" role="alert">{messageOf(error)}</p>
      <button onClick={() => window.location.reload()}>Try Again</button>
      <button className="secondary" onClick={() => supabase.auth.signOut({ scope: "local" })}>
        Sign out
      </button>
    </div>
  );
}

const router = createBrowserRouter([
  { path: "/sign-in", element: <SignIn />, errorElement: <RouteError /> },
  { path: "/privacy", element: <Privacy /> },
  { path: "/join/:token", element: <Join /> },
  {
    path: "/about-sharing",
    element: (
      <div role="main" className="narrow stack">
        <Shared />
        <Link to="/">Back</Link>
      </div>
    ),
  },
  {
    path: "/",
    element: <Gate />,
    errorElement: <RouteError />,
    children: [
      { index: true, element: <Today /> },
      { path: "cars", element: <Cars /> },
      { path: "cars/:vehicleId", element: <CarDetail /> },
      { path: "book", element: <Book /> },
      { path: "bookings/:bookingId", element: <BookingDetail /> },
      { path: "calendar", element: <Calendar /> },
      { path: "activity", element: <Activity /> },
      { path: "family", element: <FamilyCalendar /> },
      { path: "family/all", element: <AllPlans /> },
      { path: "family/todos", element: <AllTasks /> },
      { path: "family/members", element: <FamilyHome /> },
      { path: "family/new", element: <NewEvent /> },
      { path: "family/events/:eventId", element: <EventDetail /> },
      { path: "family/tasks/new", element: <NewTask /> },
      { path: "family/tasks/:taskId", element: <TaskDetail /> },
      { path: "family/create", element: <FamilyNew /> },
      { path: "family/menus/new", element: <NewMenu /> },
      { path: "family/menus/:menuId", element: <MenuDetail /> },
      { path: "family/stays/new", element: <NewStay /> },
      { path: "family/stays/:stayId", element: <StayDetail /> },
      { path: "settings", element: <Settings /> },
      { path: "shared", element: <Shared /> },
    ],
  },
  { path: "*", element: <Navigate to="/" replace /> },
]);

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 30_000, retry: 1 } },
});

void registerServiceWorker();
installGlobalErrorReporting();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <RouterProvider router={router} />
      </AuthProvider>
    </QueryClientProvider>
  </StrictMode>,
);
