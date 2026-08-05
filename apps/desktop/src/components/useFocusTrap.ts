import { useEffect, useRef, type RefObject } from "react";

const FOCUSABLE =
  'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function useFocusTrap<T extends HTMLElement>(
  enabled: boolean,
  onEscape?: () => void,
  initialFocusRef?: RefObject<HTMLElement | null>,
): RefObject<T | null> {
  const containerRef = useRef<T | null>(null);
  const escapeRef = useRef(onEscape);
  useEffect(() => {
    escapeRef.current = onEscape;
  }, [onEscape]);

  useEffect(() => {
    if (!enabled || !containerRef.current) return;
    const container = containerRef.current;
    const previous = document.activeElement;
    const focusInitial = () => {
      const explicit = initialFocusRef?.current;
      const first = container.querySelector<HTMLElement>(FOCUSABLE);
      (explicit ?? first ?? container).focus();
    };
    focusInitial();
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        escapeRef.current?.();
        return;
      }
      if (event.key !== "Tab") return;
      const focusable = Array.from(
        container.querySelectorAll<HTMLElement>(FOCUSABLE),
      );
      if (focusable.length === 0) {
        event.preventDefault();
        container.focus();
        return;
      }
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }
    container.addEventListener("keydown", onKeyDown);
    return () => {
      container.removeEventListener("keydown", onKeyDown);
      if (previous instanceof HTMLElement && previous.isConnected) {
        previous.focus();
      }
    };
  }, [enabled, initialFocusRef]);

  return containerRef;
}
