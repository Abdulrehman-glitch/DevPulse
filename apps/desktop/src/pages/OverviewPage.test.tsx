import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";
import { successfulProvider } from "../test/fixtures";
import { OverviewPage } from "./OverviewPage";

function renderOverview(provider = successfulProvider(), children?: ReactNode) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return render(
    <QueryClientProvider client={client}>
      {children ?? (
        <OverviewPage
          provider={provider}
          onAddProject={() => undefined}
          onAddRoot={() => undefined}
          onOpen={() => undefined}
        />
      )}
    </QueryClientProvider>,
  );
}

describe("Overview repository landscape", () => {
  it("puts repository health and attention before secondary machine status", async () => {
    renderOverview();

    const landscape = await screen.findByRole("region", {
      name: "Project landscape",
    });
    const attention = screen.getByRole("region", { name: "Needs attention" });
    const machine = screen.getByRole("region", { name: "Machine status" });

    expect(landscape).toHaveTextContent("1 tracked");
    expect(landscape).toHaveTextContent("1 clean");
    expect(attention).toHaveTextContent("Nothing needs attention");
    expect(attention).toHaveTextContent("All tracked repositories are clean");
    expect(
      attention.compareDocumentPosition(machine) &
        Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
  });

  it("explains actionable repository signals in human language", async () => {
    const provider = successfulProvider();
    const base = await provider.getProjects();
    provider.getProjects = async () => ({
      ...base,
      total: 2,
      items: [
        {
          ...base.items[0],
          id: "changed-project",
          name: "Changed project",
          status: "modified",
          changed_files: 3,
          modified_count: 2,
          staged_count: 1,
          health_score: 72,
        },
        {
          ...base.items[0],
          id: "diverged-project",
          name: "Diverged project",
          ahead_count: 1,
          behind_count: 2,
          warning_count: 1,
          health_score: 61,
        },
      ],
    });

    renderOverview(provider);

    const attention = await screen.findByRole("region", {
      name: "Needs attention",
    });
    expect(attention).toHaveTextContent("Changed project");
    expect(attention).toHaveTextContent("3 local changes");
    expect(attention).toHaveTextContent("Diverged project");
    expect(attention).toHaveTextContent("1 commit ahead and 2 behind");
    expect(attention).toHaveTextContent("1 warning");
  });

  it("keeps repository data visible while acknowledging a manual scan", async () => {
    const provider = successfulProvider();
    let finishRefresh: (() => void) | undefined;
    provider.refreshProjects = vi.fn(async () => {
      await new Promise<void>((resolve) => {
        finishRefresh = resolve;
      });
      return provider.getProjects();
    });
    const user = userEvent.setup();
    renderOverview(provider);

    expect(await screen.findByText("Temporary project")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Scan projects" }));

    expect(
      screen.getByRole("button", { name: "Scanning projects" }),
    ).toBeDisabled();
    expect(screen.getByText("Temporary project")).toBeInTheDocument();
    finishRefresh?.();
    expect(
      await screen.findByRole("button", { name: "Scan projects" }),
    ).toBeEnabled();
  });

  it("derives landscape counts from active repositories only", async () => {
    const provider = successfulProvider();
    const base = await provider.getProjects();
    provider.getProjects = async () => ({
      ...base,
      total: 2,
      items: [
        base.items[0],
        {
          ...base.items[0],
          id: "archived-project",
          name: "Archived project",
          archived: true,
          status: "modified",
          changed_files: 4,
          warning_count: 2,
        },
      ],
    });
    provider.getSystemSummary = async () => ({
      ...(await successfulProvider().getSystemSummary()),
      repositories_total: 2,
      clean_repositories: 1,
      modified_repositories: 1,
      repositories_with_warnings: 1,
    });

    renderOverview(provider);

    const landscape = await screen.findByRole("region", {
      name: "Project landscape",
    });
    expect(landscape).toHaveTextContent("1 tracked");
    expect(landscape).toHaveTextContent("1 clean");
    expect(landscape).toHaveTextContent("0 with local changes");
    expect(landscape).toHaveTextContent("0 with warnings");
  });

  it("reflects a backend scan that is already in progress", async () => {
    const provider = successfulProvider();
    const base = await provider.getProjects();
    provider.getProjects = async () => ({
      ...base,
      last_successful_refresh: null,
    });
    provider.getSystemSummary = async () => ({
      ...(await successfulProvider().getSystemSummary()),
      last_successful_refresh: null,
      refreshing: true,
    });

    renderOverview(provider);

    expect(await screen.findByText("Scan in progress")).toBeInTheDocument();
    expect(screen.getByText("No completed scan yet")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Scanning projects" }),
    ).toBeDisabled();
  });

  it("identifies repository data that needs a fresh scan", async () => {
    const provider = successfulProvider();
    const base = await provider.getProjects();
    provider.getProjects = async () => ({
      ...base,
      last_successful_refresh: "2020-01-01T00:00:00Z",
    });

    renderOverview(provider);

    expect(await screen.findByText("Scan needs refresh")).toBeInTheDocument();
  });

  it("reconciles repository rows when the backend completes a newer scan", async () => {
    const provider = successfulProvider();
    const baseProjects = await provider.getProjects();
    const latestRefresh = "2026-08-31T09:59:00Z";
    let projectReads = 0;
    provider.getProjects = vi.fn(async () => {
      projectReads += 1;
      if (projectReads === 1) return baseProjects;
      return {
        ...baseProjects,
        last_successful_refresh: latestRefresh,
        items: [
          {
            ...baseProjects.items[0],
            name: "Automatically refreshed project",
            last_scan_timestamp: latestRefresh,
          },
        ],
      };
    });
    provider.getSystemSummary = async () => ({
      ...(await successfulProvider().getSystemSummary()),
      last_successful_refresh: latestRefresh,
    });

    renderOverview(provider);

    expect(
      await screen.findByText("Automatically refreshed project"),
    ).toBeInTheDocument();
    expect(provider.getProjects).toHaveBeenCalledTimes(2);
  });

  it("uses the configured refresh interval for freshness language", async () => {
    const provider = successfulProvider();
    const baseProjects = await provider.getProjects();
    const oneHourAgo = new Date(Date.now() - 60 * 60_000).toISOString();
    provider.getProjects = async () => ({
      ...baseProjects,
      last_successful_refresh: oneHourAgo,
    });
    provider.getSystemSummary = async () => ({
      ...(await successfulProvider().getSystemSummary()),
      last_successful_refresh: oneHourAgo,
    });
    const baseSettings = await provider.getSettings();
    provider.getSettings = async () => ({
      ...baseSettings,
      refresh_interval_seconds: 86_400,
    });

    renderOverview(provider);

    expect(await screen.findByText("Scan current")).toBeInTheDocument();
  });

  it("uses neutral freshness language when automatic refresh is disabled", async () => {
    const provider = successfulProvider();
    const baseSettings = await provider.getSettings();
    provider.getSettings = async () => ({
      ...baseSettings,
      refresh_interval_seconds: 0,
    });

    renderOverview(provider);

    expect(await screen.findByText("Last scan recorded")).toBeInTheDocument();
  });
});
