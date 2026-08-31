import type { CoreConnection } from "@devpulse/shared-types";
import {
  QueryClient,
  QueryClientProvider,
  useQueryClient,
} from "@tanstack/react-query";
import { useEffect, useMemo, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { DashboardSkeleton } from "./components/LoadingState";
import { ProjectOnboarding } from "./components/ProjectOnboarding";
import { QaModeBanner } from "./components/QaModeBanner";
import { NotificationCenter } from "./components/NotificationCenter";
import { Sidebar, type Page } from "./components/Sidebar";
import { StartupScreen } from "./components/StartupScreen";
import { useCoreConnection } from "./hooks/useCoreConnection";
import { ActivityPage } from "./pages/ActivityPage";
import { OverviewPage } from "./pages/OverviewPage";
import { ProjectsPage } from "./pages/ProjectsPage";
import { ProjectDetailsPage } from "./pages/ProjectDetailsPage";
import { SettingsPage } from "./pages/SettingsPage";
import { SystemPage } from "./pages/SystemPage";
import { DiagnosticsPage } from "./pages/DiagnosticsPage";
import type { DataProvider } from "./providers/contracts";
import {
  completeInstallQa,
  HttpLocalDataProvider,
  isPathInsideQaRoot,
  qaPathsAreIsolated,
  resolveQaPathStatus,
  writeInstallQaVisualCheckpoint,
  writeQaCheckpoint,
} from "./providers/local";

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, staleTime: 2_000 } },
});

export function DesktopApp({
  connection,
  provider,
}: {
  connection: CoreConnection;
  provider: DataProvider;
}) {
  const [page, setPage] = useState<Page>("overview");
  const [collapsed, setCollapsed] = useState(false);
  const [selectedProject, setSelectedProject] = useState<string | null>(null);
  const [onboarding, setOnboarding] = useState<"project" | "root" | null>(null);
  const contentShellRef = useRef<HTMLElement>(null);
  const client = useQueryClient();
  const automationStarted = useRef(false);
  const settings = useQuery({
    queryKey: ["settings"],
    queryFn: () => provider.getSettings(),
  });
  useEffect(() => {
    document.documentElement.dataset.appearance =
      settings.data?.appearance ?? "system";
    document.documentElement.dataset.reducedMotion = String(
      settings.data?.reduced_motion ?? false,
    );
  }, [settings.data]);
  useEffect(() => {
    if (contentShellRef.current) contentShellRef.current.scrollTop = 0;
  }, [page, selectedProject]);
  useEffect(() => {
    if (
      !connection.qaMode ||
      !connection.qaAutomation ||
      automationStarted.current
    )
      return;
    automationStarted.current = true;
    void (async () => {
      const checks: Record<string, unknown> = {};
      const visualCheckpoint = async (stage: string) => {
        await new Promise<void>((resolve) =>
          window.requestAnimationFrame(() =>
            window.requestAnimationFrame(() => resolve()),
          ),
        );
        if (await writeInstallQaVisualCheckpoint(stage)) {
          await new Promise((resolve) => window.setTimeout(resolve, 1_500));
        }
      };
      try {
        await new Promise((resolve) => window.setTimeout(resolve, 250));
        // The packaged core intentionally starts its first scan in the background.
        // Await an explicit refresh so release automation never snapshots the empty
        // pre-scan state as a frontend failure.
        await provider.refreshProjects();
        const [
          summary,
          projects,
          currentSettings,
          activity,
          qa,
          diagnostics,
          qaPaths,
        ] = await Promise.all([
          provider.getSystemSummary(),
          provider.getProjects(),
          provider.getSettings(),
          provider.getActivity(),
          provider.getQaStatus(),
          provider.getSafeDiagnostics(),
          resolveQaPathStatus(),
        ]);
        const detail = projects.items[0]
          ? await provider.getProject(projects.items[0].id)
          : null;
        checks.configurationBeforeQaReset = currentSettings.projects.map(
          ({ path, favorite, tags, notes, archived }) => ({
            path,
            favorite,
            tags,
            notes,
            archived,
          }),
        );
        const refreshed = await provider.refreshProjects();
        await provider.resetQaData();
        const resetState = await provider.getProjects();
        await provider.regenerateQaData();
        const regenerated = await provider.getProjects();
        checks.overviewRendered =
          document.body.textContent?.includes("Overview") === true;
        checks.qaIndicatorRendered =
          document.body.textContent?.includes("QA Mode") === true;
        checks.frontendConnected = summary.repositories_total > 0;
        checks.projectListLoaded = projects.total >= 10;
        checks.projectDetailsLoaded = Boolean(detail?.summary.name);
        checks.settingsLoaded = currentSettings.schema_version === 5;
        checks.activityLoaded = activity.items.length > 0;
        checks.refreshCompleted = refreshed.total > 0;
        checks.resetCompleted = resetState.total === 0;
        checks.regenerationCompleted = regenerated.total >= 10;
        checks.qaIsolationConfirmed = qa.enabled && qa.artificial_data;
        checks.frontendQaPathsReceived = qaPathsAreIsolated(qaPaths);
        checks.webViewQaIsolationConfirmed = isPathInsideQaRoot(
          qaPaths.webView2UserDataDirectory,
          qaPaths.qaRoot,
        );
        checks.diagnosticsLoaded =
          diagnostics.local_core_status === "connected";
        if (connection.installQa) {
          setSelectedProject(null);
          setPage("overview");
          await visualCheckpoint("qa-mode-banner");
          await visualCheckpoint("overview-page");
          setPage("projects");
          await visualCheckpoint("projects-page");
          if (regenerated.items[0]) {
            setSelectedProject(regenerated.items[0].id);
            await visualCheckpoint("project-details-page");
            setSelectedProject(null);
          }
          setPage("activity");
          await visualCheckpoint("activity-page");
          setPage("settings");
          await visualCheckpoint("settings-page");
          setPage("diagnostics");
          await visualCheckpoint("diagnostics-page");
          setPage("overview");
        }
      } catch (error) {
        checks.automationError =
          error instanceof Error ? error.message : "unknown";
      }
      await client.invalidateQueries();
      await writeQaCheckpoint(checks);
      if (connection.installQa) await completeInstallQa(checks);
    })();
  }, [
    client,
    connection.installQa,
    connection.qaAutomation,
    connection.qaMode,
    provider,
  ]);
  if (settings.isLoading) return <DashboardSkeleton />;
  if (
    settings.data &&
    !settings.data.onboarding_completed &&
    !connection.qaMode
  ) {
    return (
      <ProjectOnboarding
        provider={provider}
        version={connection.version ?? "unknown"}
        firstRun
        onDone={() => void settings.refetch()}
      />
    );
  }
  const content = {
    overview: (
      <OverviewPage
        provider={provider}
        onAddProject={() => setOnboarding("project")}
        onAddRoot={() => setOnboarding("root")}
        onOpen={setSelectedProject}
        qaMode={Boolean(connection.qaMode)}
      />
    ),
    projects: (
      <ProjectsPage
        provider={provider}
        onOpen={setSelectedProject}
        onAddProject={() => setOnboarding("project")}
        onAddRoot={() => setOnboarding("root")}
        qaMode={Boolean(connection.qaMode)}
      />
    ),
    activity: <ActivityPage provider={provider} />,
    system: <SystemPage provider={provider} />,
    diagnostics: <DiagnosticsPage provider={provider} />,
    settings: (
      <SettingsPage
        provider={provider}
        version={connection.version ?? "unknown"}
      />
    ),
  }[page];
  return (
    <div className="app-shell">
      <Sidebar
        page={page}
        collapsed={collapsed}
        version={connection.version ?? "unknown"}
        onNavigate={(next) => {
          setSelectedProject(null);
          setPage(next);
        }}
        onToggle={() => setCollapsed((value) => !value)}
      />
      <main className="content-shell" ref={contentShellRef}>
        {connection.qaMode && <QaModeBanner provider={provider} />}
        <div className="app-toolbar" aria-label="Application status">
          <div className="core-status" title="Private local service connection">
            <span /> Local core connected
          </div>
          <NotificationCenter provider={provider} />
        </div>
        <div
          className="view-frame"
          key={selectedProject ? `project-${selectedProject}` : page}
        >
          {selectedProject ? (
            <ProjectDetailsPage
              provider={provider}
              projectId={selectedProject}
              onBack={() => setSelectedProject(null)}
              qaMode={Boolean(connection.qaMode)}
            />
          ) : (
            content
          )}
        </div>
      </main>
      {onboarding && !connection.qaMode && (
        <ProjectOnboarding
          provider={provider}
          version={connection.version ?? "unknown"}
          initialMode={onboarding}
          onDone={() => setOnboarding(null)}
        />
      )}
    </div>
  );
}

export function App() {
  const { connection, retry } = useCoreConnection();
  const provider = useMemo(
    () =>
      connection.status === "ready"
        ? new HttpLocalDataProvider(connection)
        : null,
    [connection],
  );
  if (!provider)
    return (
      <StartupScreen connection={connection} onRetry={() => void retry()} />
    );
  return (
    <QueryClientProvider client={queryClient}>
      <DesktopApp connection={connection} provider={provider} />
    </QueryClientProvider>
  );
}

export function TestApp({
  connection,
  provider,
}: {
  connection: CoreConnection;
  provider: DataProvider;
}) {
  const client = useMemo(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } }),
    [],
  );
  return (
    <QueryClientProvider client={client}>
      <DesktopApp connection={connection} provider={provider} />
    </QueryClientProvider>
  );
}
