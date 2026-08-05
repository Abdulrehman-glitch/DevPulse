import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { open } from "@tauri-apps/plugin-dialog";
import { describe, expect, it, vi } from "vitest";
import { TestApp } from "./App";
import { StartupScreen } from "./components/StartupScreen";
import { successfulProvider } from "./test/fixtures";

vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

const connection = {
  status: "ready" as const,
  version: "0.3.0-alpha.1",
  address: "http://127.0.0.1:1",
  token: "fixture",
};
const qaConnection = { ...connection, qaMode: true, qaAutomation: false };

describe("desktop application states", () => {
  it("shows a dedicated startup state while the local core starts", () => {
    render(
      <StartupScreen
        connection={{ status: "starting" }}
        onRetry={() => undefined}
      />,
    );
    expect(
      screen.getByRole("heading", { name: "Preparing your workspace" }),
    ).toBeInTheDocument();
    expect(screen.getByLabelText("Starting local service")).toBeInTheDocument();
  });

  it("renders live dashboard data after a successful response", async () => {
    render(<TestApp connection={connection} provider={successfulProvider()} />);
    expect(await screen.findByText("Temporary project")).toBeInTheDocument();
    expect(screen.getByText("42%")).toBeInTheDocument();
    expect(screen.getByText("Local core connected")).toBeInTheDocument();
  });

  it("renders an actionable API error state", async () => {
    const failed = successfulProvider();
    failed.getSystemSummary = async () => {
      throw new Error("Local API unavailable");
    };
    render(<TestApp connection={connection} provider={failed} />);
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Local API unavailable",
    );
    expect(
      screen.getByRole("button", { name: "Try again" }),
    ).toBeInTheDocument();
  });

  it("shows the first-run safety experience without scanning", async () => {
    const provider = successfulProvider();
    provider.getSettings = async () => ({
      ...(await successfulProvider().getSettings()),
      onboarding_completed: false,
      projects: [],
    });
    provider.updateSettings = vi.fn(async () => provider.getSettings());
    const user = userEvent.setup();
    render(<TestApp connection={connection} provider={provider} />);
    expect(
      await screen.findByRole("heading", {
        name: /Know what needs attention/i,
      }),
    ).toBeInTheDocument();
    expect(screen.getByText("Read-only boundary active")).toBeInTheDocument();
    await user.click(
      screen.getByRole("button", { name: "Continue Without Projects" }),
    );
    expect(provider.updateSettings).toHaveBeenCalledWith({
      onboarding_completed: true,
    });
  });

  it("supports project search and status filters", async () => {
    const user = userEvent.setup();
    render(<TestApp connection={connection} provider={successfulProvider()} />);
    await screen.findByRole("heading", { level: 1, name: "Overview" });
    await user.click(screen.getByRole("button", { name: "Projects" }));
    const search = await screen.findByPlaceholderText("Search name or path");
    await user.type(search, "missing project");
    expect(
      screen.getByRole("heading", { name: "No repositories detected" }),
    ).toBeInTheDocument();
    await user.clear(search);
    await user.selectOptions(screen.getByLabelText("Status filter"), "clean");
    expect(screen.getByText("Temporary project")).toBeInTheDocument();
  });

  it("renders project details as informational metadata", async () => {
    const user = userEvent.setup();
    render(<TestApp connection={connection} provider={successfulProvider()} />);
    await screen.findByRole("heading", { level: 1, name: "Overview" });
    await user.click(screen.getByRole("button", { name: "Projects" }));
    await user.click(await screen.findByRole("button", { name: "Details" }));
    expect(
      await screen.findByRole("heading", { name: "Temporary project" }),
    ).toBeInTheDocument();
    expect(screen.getByText("Changed files")).toBeInTheDocument();
    expect(
      screen.getAllByText(/File contents are never displayed/),
    ).toHaveLength(2);
  });

  it("shows the fixed safety controls in settings", async () => {
    const user = userEvent.setup();
    render(<TestApp connection={connection} provider={successfulProvider()} />);
    await screen.findByRole("heading", { level: 1, name: "Overview" });
    await user.click(screen.getByRole("button", { name: "Settings" }));
    expect(
      await screen.findByText("Read-only repository mode"),
    ).toBeInTheDocument();
    expect(screen.getByText("Project command execution")).toBeInTheDocument();
    expect(screen.getByText("Telemetry")).toBeInTheDocument();
  });

  it("persists the reduced-motion preference", async () => {
    const provider = successfulProvider();
    provider.updateSettings = vi.fn(async () => provider.getSettings());
    const user = userEvent.setup();
    render(<TestApp connection={connection} provider={provider} />);
    await screen.findByRole("heading", { level: 1, name: "Overview" });
    await user.click(screen.getByRole("button", { name: "Settings" }));
    await user.click(
      await screen.findByRole("checkbox", { name: /Reduced motion/ }),
    );
    await user.click(screen.getByRole("button", { name: "Save changes" }));
    expect(provider.updateSettings).toHaveBeenCalledWith(
      expect.objectContaining({ reduced_motion: true }),
    );
  });

  it("confirms removal from DevPulse without deleting a project", async () => {
    const provider = successfulProvider();
    provider.removeProject = vi.fn(async () => provider.getSettings());
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(true);
    const user = userEvent.setup();
    render(<TestApp connection={connection} provider={provider} />);
    await screen.findByRole("heading", { level: 1, name: "Overview" });
    await user.click(screen.getByRole("button", { name: "Projects" }));
    await user.click(
      await screen.findByRole("button", {
        name: "Remove Temporary project from DevPulse",
      }),
    );
    expect(confirm).toHaveBeenCalledWith(
      expect.stringContaining("remain unchanged"),
    );
    expect(provider.removeProject).toHaveBeenCalledWith("fixture-project");
    confirm.mockRestore();
  });

  it("shows an invalid repository warning before onboarding confirmation", async () => {
    const provider = successfulProvider();
    const base = await provider.getSettings();
    provider.getSettings = async () => ({
      ...base,
      onboarding_completed: false,
      projects: [],
    });
    const detail = await provider.getProject("fixture-project");
    provider.previewProject = vi.fn(async () => ({
      ...detail,
      summary: {
        ...detail.summary,
        is_git_repository: false,
        status: "not_git",
      },
    }));
    vi.mocked(open).mockResolvedValueOnce("C:\\Temporary\\not-a-repository");
    const user = userEvent.setup();
    render(<TestApp connection={connection} provider={provider} />);
    const addProject = (await screen.findByText("Add Project")).closest(
      "button",
    );
    expect(addProject).not.toBeNull();
    await user.click(addProject!);
    expect(
      await screen.findByText(
        "This folder is not a Git repository and cannot be added.",
      ),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Confirm and add/ }),
    ).toBeDisabled();
  });

  it("connects every primary navigation item to its page", async () => {
    const user = userEvent.setup();
    render(<TestApp connection={connection} provider={successfulProvider()} />);
    await screen.findByRole("heading", { level: 1, name: "Overview" });

    for (const page of [
      "Projects",
      "Activity",
      "System",
      "Diagnostics",
      "Settings",
      "Overview",
    ]) {
      await user.click(screen.getByRole("button", { name: page }));
      expect(
        await screen.findByRole("heading", {
          level: 1,
          name: page === "Diagnostics" ? /Diagnostics/ : page,
        }),
      ).toBeInTheDocument();
    }
  });

  it("makes QA isolation and artificial data persistently visible", async () => {
    const user = userEvent.setup();
    render(
      <TestApp connection={qaConnection} provider={successfulProvider()} />,
    );
    expect(await screen.findByText("QA Mode")).toBeInTheDocument();
    expect(screen.getByText(/Artificial repositories/)).toBeInTheDocument();
    expect(
      await screen.findByText("Artificial QA workspace"),
    ).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Projects" }));
    expect(
      screen.getByText("Artificial repository inventory"),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Add Project" })).toBeDisabled();
    expect(
      screen.getByRole("button", { name: /Add Project Root/ }),
    ).toBeDisabled();
  });

  it("confirms QA reset and supports deterministic regeneration", async () => {
    const provider = successfulProvider();
    provider.resetQaData = vi.fn(async () => provider.getSettings());
    provider.regenerateQaData = vi.fn(async () => provider.getSettings());
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(true);
    const user = userEvent.setup();
    render(<TestApp connection={qaConnection} provider={provider} />);
    await screen.findByText("QA Mode");
    await user.click(screen.getByRole("button", { name: "Reset QA Data" }));
    expect(confirm).toHaveBeenCalledWith(
      expect.stringContaining("Only DevPulse QA"),
    );
    expect(provider.resetQaData).toHaveBeenCalledOnce();
    await user.click(
      screen.getByRole("button", { name: "Regenerate QA Data" }),
    );
    expect(provider.regenerateQaData).toHaveBeenCalledOnce();
    confirm.mockRestore();
  });

  it("renders and copies redacted safe diagnostics", async () => {
    const provider = successfulProvider();
    const user = userEvent.setup();
    const writeText = vi.spyOn(navigator.clipboard, "writeText");
    render(<TestApp connection={connection} provider={provider} />);
    await screen.findByRole("heading", { name: "Overview" });
    await user.click(screen.getByRole("button", { name: "Diagnostics" }));
    expect(
      await screen.findByText("Redaction boundary active"),
    ).toBeInTheDocument();
    expect(screen.getByText("Schema 4")).toBeInTheDocument();
    await user.click(
      screen.getByRole("button", { name: "Copy Safe Diagnostics" }),
    );
    expect(
      await screen.findByText("Safe diagnostics copied"),
    ).toBeInTheDocument();
    expect(writeText).toHaveBeenCalledWith(
      expect.stringContaining("connected"),
    );
  });

  it("explains bounded local-core restart failures without exposing credentials", async () => {
    const retry = vi.fn();
    render(
      <StartupScreen
        connection={{
          status: "error",
          qaMode: true,
          message:
            "The local service restart limit was reached. Restart DevPulse to try again.",
          diagnosticsPath: "C:\\DevPulse\\.qa-runtime\\logs\\local-core.log",
        }}
        onRetry={retry}
      />,
    );
    expect(screen.getByText(/restart limit was reached/)).toBeInTheDocument();
    expect(
      screen.getByText(/QA Mode uses isolated artificial data/),
    ).toBeInTheDocument();
    expect(document.body.textContent).not.toContain("fixture-secret");
    await userEvent.click(
      screen.getByRole("button", { name: "Retry startup" }),
    );
    expect(retry).toHaveBeenCalledOnce();
  });

  it("keeps long project names, paths and commit messages readable", async () => {
    const provider = successfulProvider();
    const detail = await provider.getProject("fixture-project");
    provider.getProject = async () => ({
      ...detail,
      summary: {
        ...detail.summary,
        name: "A deliberately long artificial project name used to verify desktop overflow handling",
        path: `C:\\DevPulse\\.qa-runtime\\test-lab\\${"nested\\".repeat(12)}repository`,
      },
      commits: [
        {
          short_sha: "abcdef0",
          author: "DevPulse QA",
          date: "2026-07-18T10:00:00Z",
          message:
            "A long artificial commit message that must wrap cleanly without widening the details panel beyond the desktop window",
        },
      ],
    });
    const user = userEvent.setup();
    render(<TestApp connection={qaConnection} provider={provider} />);
    await user.click(await screen.findByRole("button", { name: "Projects" }));
    await user.click(await screen.findByRole("button", { name: "Details" }));
    expect(
      await screen.findByText(/deliberately long artificial project/),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/long artificial commit message/),
    ).toBeInTheDocument();
  });
});
