import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { projects } from "../test/fixtures";
import { ProjectTable } from "./ProjectTable";

describe("ProjectTable", () => {
  it("renders repository identity, state and health", () => {
    render(<ProjectTable projects={projects.items} />);
    expect(screen.getByRole("table")).toBeInTheDocument();
    expect(screen.getByText("Temporary project")).toBeInTheDocument();
    expect(screen.getByText("Clean — no local changes")).toBeInTheDocument();
    expect(screen.getByText("Up to date")).toBeInTheDocument();
    expect(screen.getByText("No local changes")).toBeInTheDocument();
    expect(screen.getByText("React")).toBeInTheDocument();
    expect(
      screen.getByRole("columnheader", { name: "State" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("columnheader", { name: "Activity" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("columnheader", { name: "Technology" }),
    ).toBeNull();
    expect(screen.queryByRole("columnheader", { name: "Health" })).toBeNull();
  });

  it("uses plain-language repository state, sync, changes, and fallback language", () => {
    const scanStates = [
      {
        ...projects.items[0],
        id: "changed",
        name: "Changed project",
        status: "modified",
        changed_files: 3,
        modified_count: 2,
        staged_count: 1,
      },
      {
        ...projects.items[0],
        id: "missing",
        name: "Missing project",
        exists: false,
        status: "missing",
      },
      {
        ...projects.items[0],
        id: "unavailable",
        name: "Unavailable project",
        status: "access_error",
        error: "Access denied",
      },
      {
        ...projects.items[0],
        id: "ahead",
        name: "Ahead project",
        ahead_count: 2,
      },
      {
        ...projects.items[0],
        id: "behind",
        name: "Behind project",
        behind_count: 1,
      },
      {
        ...projects.items[0],
        id: "diverged",
        name: "Diverged project",
        ahead_count: 2,
        behind_count: 4,
      },
      {
        ...projects.items[0],
        id: "unknown",
        name: "Unknown project",
        tracking_branch: null,
        primary_technology: "",
      },
    ];

    render(<ProjectTable projects={scanStates} />);

    expect(screen.getByText("Changes detected")).toBeInTheDocument();
    expect(screen.getByText("3 local changes")).toBeInTheDocument();
    expect(screen.getByText("Repository missing")).toBeInTheDocument();
    expect(screen.getByText("Repository unavailable")).toBeInTheDocument();
    expect(screen.getByText("Ahead by 2 commits")).toBeInTheDocument();
    expect(screen.getByText("Behind by 1 commit")).toBeInTheDocument();
    expect(screen.getByText("Diverged: 2 ahead, 4 behind")).toBeInTheDocument();
    expect(screen.getByText("Sync unknown")).toBeInTheDocument();
    expect(screen.getByText("Unknown language")).toBeInTheDocument();
  });

  it("provides a useful empty state", () => {
    render(<ProjectTable projects={[]} />);
    expect(
      screen.getByRole("heading", { name: "No repositories detected" }),
    ).toBeInTheDocument();
  });

  it("virtualizes a 250-project collection while retaining row semantics", () => {
    const largeCollection = Array.from({ length: 250 }, (_, index) => ({
      ...projects.items[0],
      id: `artificial-${index}`,
      name: `Artificial project ${index.toString().padStart(3, "0")}`,
      path: `C:\\DevPulse\\.qa-runtime\\test-lab\\project-${index}`,
    }));
    render(<ProjectTable projects={largeCollection} />);
    const table = screen.getByRole("table");
    expect(table).toHaveAttribute("aria-rowcount", "251");
    expect(screen.getByText("Artificial project 000")).toBeInTheDocument();
    expect(
      document.querySelectorAll("[data-project-row-index]").length,
    ).toBeLessThan(250);
    expect(
      document
        .querySelector("[data-rendered-row-count]")
        ?.getAttribute("data-rendered-row-count"),
    ).not.toBe("250");
  });

  it("moves the active row with arrow keys", () => {
    render(<ProjectTable projects={projects.items} />);
    const row = document.querySelector<HTMLTableRowElement>(
      '[data-project-row-index="0"]',
    );
    expect(row).not.toBeNull();
    row?.focus();
    fireEvent.keyDown(row!, { key: "ArrowDown" });
    expect(document.activeElement).toBe(row);
  });
});
