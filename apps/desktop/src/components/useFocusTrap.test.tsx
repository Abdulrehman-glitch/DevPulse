import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useRef, useState } from "react";
import { describe, expect, it } from "vitest";
import { useFocusTrap } from "./useFocusTrap";

function FocusTrapFixture() {
  const [open, setOpen] = useState(false);
  const cancelRef = useRef<HTMLButtonElement>(null);
  const trapRef = useFocusTrap<HTMLElement>(
    open,
    () => setOpen(false),
    cancelRef,
  );
  return (
    <>
      <button onClick={() => setOpen(true)}>Open dialog</button>
      {open && (
        <section ref={trapRef} role="dialog" aria-label="Fixture dialog">
          <button ref={cancelRef}>Cancel</button>
          <button>Confirm</button>
        </section>
      )}
    </>
  );
}

describe("useFocusTrap", () => {
  it("wraps keyboard focus and restores the invoking control", async () => {
    const user = userEvent.setup();
    render(<FocusTrapFixture />);
    const trigger = screen.getByRole("button", { name: "Open dialog" });
    await user.click(trigger);
    const cancel = screen.getByRole("button", { name: "Cancel" });
    const confirm = screen.getByRole("button", { name: "Confirm" });
    expect(document.activeElement).toBe(cancel);
    await user.keyboard("{Shift>}{Tab}{/Shift}");
    expect(document.activeElement).toBe(confirm);
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(document.activeElement).toBe(trigger);
  });
});
