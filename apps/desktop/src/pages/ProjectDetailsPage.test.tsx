import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { successfulProvider } from "../test/fixtures";
import { ProjectDetailsPage } from "./ProjectDetailsPage";

vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

function renderDetails(provider = successfulProvider()) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  render(
    <QueryClientProvider client={client}>
      <ProjectDetailsPage
        provider={provider}
        projectId="fixture-project"
        onBack={() => undefined}
      />
    </QueryClientProvider>,
  );
}

describe("repository detail hierarchy", () => {
  it("leads with repository state and an intentional no-warning result", async () => {
    renderDetails();

    const state = await screen.findByRole("region", {
      name: "Repository state",
    });
    const git = screen.getByRole("region", { name: "Git state" });

    expect(state).toHaveTextContent("Clean working tree");
    expect(state).toHaveTextContent("Up to date with origin/main");
    expect(screen.getByText("No repository warnings")).toBeInTheDocument();
    expect(
      state.compareDocumentPosition(git) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
  });

  it("confirms that the repository path was copied", async () => {
    const user = userEvent.setup();
    const writeText = vi.spyOn(navigator.clipboard, "writeText");
    renderDetails();

    await user.click(
      await screen.findByRole("button", { name: "Copy repository path" }),
    );

    expect(await screen.findByText("Path copied")).toBeInTheDocument();
    expect(writeText).toHaveBeenCalledWith("C:\\Temp\\pytest\\repository");
  });

  it("reports when the repository path cannot be copied", async () => {
    const user = userEvent.setup();
    const writeText = vi
      .spyOn(navigator.clipboard, "writeText")
      .mockRejectedValueOnce(new Error("Clipboard unavailable"));
    renderDetails();

    await user.click(
      await screen.findByRole("button", { name: "Copy repository path" }),
    );

    expect(
      await screen.findByText("Couldn\u2019t copy path"),
    ).toBeInTheDocument();
    writeText.mockRestore();
  });

  it("keeps a long warning list concise until the user asks for details", async () => {
    const provider = successfulProvider();
    const originalGetProject = provider.getProject;
    provider.getProject = async (id) => ({
      ...(await originalGetProject(id)),
      warning_details: Array.from({ length: 7 }, (_, index) => ({
        code: `warning-${index + 1}`,
        title: `Warning ${index + 1}`,
        what: "A repository signal needs review.",
        why: "The latest scan found a condition worth checking.",
        changed: "DevPulse changed nothing.",
        suggested_action: "Review this condition manually.",
      })),
    });
    const user = userEvent.setup();
    renderDetails(provider);

    expect(
      await screen.findByText("7 repository warnings"),
    ).toBeInTheDocument();
    expect(screen.getByText("Warning 3")).toBeInTheDocument();
    expect(screen.getByText("Warning 4")).not.toBeVisible();

    await user.click(screen.getByText("Show 4 more warnings"));
    expect(screen.getByText("Warning 4")).toBeVisible();
  });
});
