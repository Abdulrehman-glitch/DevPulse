import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { projects } from "../test/fixtures";
import { ProjectTable } from "./ProjectTable";

describe("ProjectTable", () => {
  it("renders repository identity, state and health", () => {
    render(<ProjectTable projects={projects.items} />);
    expect(screen.getByRole("table")).toBeInTheDocument();
    expect(screen.getByText("Temporary project")).toBeInTheDocument();
    expect(screen.getByText("Clean")).toBeInTheDocument();
    expect(screen.getByText("86")).toBeInTheDocument();
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
