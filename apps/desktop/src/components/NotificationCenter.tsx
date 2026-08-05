import type { DataProvider } from "../providers/contracts";
import { useQuery } from "@tanstack/react-query";
import { AlertTriangle, Bell, Check, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";

export function NotificationCenter({ provider }: { provider: DataProvider }) {
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const wasOpenRef = useRef(false);
  const projects = useQuery({
    queryKey: ["projects"],
    queryFn: () => provider.getProjects(),
    refetchInterval: 15_000,
  });
  const activity = useQuery({
    queryKey: ["activity"],
    queryFn: () => provider.getActivity(50),
    refetchInterval: 15_000,
  });
  const notifications = [
    ...(projects.data?.items ?? []).flatMap((item) => [
      ...(item.warning_count > 0
        ? [
            {
              id: `${item.id}-warning`,
              title: item.name,
              detail: `${item.warning_count} repository signal${item.warning_count === 1 ? "" : "s"} needs review`,
              severity: "warning",
            },
          ]
        : []),
      ...(!item.exists
        ? [
            {
              id: `${item.id}-missing`,
              title: item.name,
              detail: "The registered project path is unavailable",
              severity: "error",
            },
          ]
        : []),
    ]),
    ...(activity.data?.items ?? [])
      .filter(
        (item) => item.kind === "error" || item.event_type === "core_restarted",
      )
      .slice(0, 5)
      .map((item) => ({
        id: item.id,
        title: item.event_type.replaceAll("_", " "),
        detail: item.message,
        severity: item.kind,
      })),
  ];
  useEffect(() => {
    if (!open) {
      if (wasOpenRef.current) triggerRef.current?.focus();
      wasOpenRef.current = false;
      return;
    }
    wasOpenRef.current = true;
    const dialog = dialogRef.current;
    if (!dialog) return;
    const focusable = () =>
      [
        ...dialog.querySelectorAll<HTMLElement>(
          'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
        ),
      ].filter((item) => !item.hasAttribute("disabled"));
    focusable()[0]?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        setOpen(false);
        return;
      }
      if (event.key !== "Tab") return;
      const elements = focusable();
      if (!elements.length) return;
      const first = elements[0];
      const last = elements[elements.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    dialog.addEventListener("keydown", onKeyDown);
    return () => dialog.removeEventListener("keydown", onKeyDown);
  }, [open]);
  return (
    <div className="notification-wrap">
      <button
        ref={triggerRef}
        className="notification-trigger"
        aria-label={`Notifications${notifications.length ? `, ${notifications.length} unread` : ""}`}
        aria-expanded={open}
        aria-controls="notification-centre-dialog"
        title="Notification centre"
        onClick={() => setOpen((value) => !value)}
      >
        <Bell size={17} />
        {notifications.length > 0 && (
          <span>{Math.min(notifications.length, 9)}</span>
        )}
      </button>
      {open && (
        <section
          ref={dialogRef}
          className="notification-popover"
          role="dialog"
          aria-modal="true"
          id="notification-centre-dialog"
          aria-label="Notification centre"
        >
          <header>
            <div>
              <strong>Notifications</strong>
              <small>Read-only attention signals</small>
            </div>
            <button
              className="icon-button"
              aria-label="Close notifications"
              onClick={() => setOpen(false)}
            >
              <X size={15} />
            </button>
          </header>
          {notifications.length ? (
            <ul>
              {notifications.map((item) => (
                <li key={item.id}>
                  <AlertTriangle size={15} />
                  <div>
                    <strong>{item.title}</strong>
                    <span>{item.detail}</span>
                  </div>
                </li>
              ))}
            </ul>
          ) : (
            <div className="notification-empty">
              <Check size={18} />
              <p>Nothing needs attention.</p>
            </div>
          )}
          <footer>
            <small>Manage event preferences in Settings.</small>
          </footer>
        </section>
      )}
    </div>
  );
}
