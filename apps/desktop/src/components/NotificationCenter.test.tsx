import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, expect, it } from "vitest";
import { NotificationCenter } from "./NotificationCenter";
import { successfulProvider } from "../test/fixtures";

describe("NotificationCenter", () => {
  it("traps focus, closes on Escape, and restores the trigger focus", async () => {
    const user = userEvent.setup();
    render(
      <QueryClientProvider client={new QueryClient()}>
        <NotificationCenter provider={successfulProvider()} />
      </QueryClientProvider>,
    );
    const trigger = screen.getByRole("button", { name: /Notifications/ });
    await user.click(trigger);
    const dialog = screen.getByRole("dialog", { name: "Notification centre" });
    const close = screen.getByRole("button", { name: "Close notifications" });
    expect(dialog).toHaveAttribute("aria-modal", "true");
    expect(document.activeElement).toBe(close);

    await user.keyboard("{Shift>}{Tab}{/Shift}");
    expect(document.activeElement).toBe(close);
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(document.activeElement).toBe(trigger);
  });
});
