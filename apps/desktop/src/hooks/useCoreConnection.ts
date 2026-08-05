import type { CoreConnection } from "@devpulse/shared-types";
import { useCallback, useEffect, useRef, useState } from "react";
import { resolveCoreConnection, restartCore } from "../providers/local";

export function useCoreConnection() {
  const [connection, setConnection] = useState<CoreConnection>({
    status: "starting",
  });
  const mounted = useRef(true);

  const check = useCallback(async () => {
    try {
      const next = await resolveCoreConnection();
      if (mounted.current)
        setConnection((current) =>
          current.status === next.status &&
          current.address === next.address &&
          current.message === next.message &&
          current.qaMode === next.qaMode &&
          current.installQa === next.installQa
            ? current
            : next,
        );
      return next;
    } catch (error) {
      const failed: CoreConnection = {
        status: "error",
        message:
          error instanceof Error
            ? error.message
            : "The local service did not start.",
      };
      if (mounted.current) setConnection(failed);
      return failed;
    }
  }, []);

  useEffect(() => {
    mounted.current = true;
    let timeout: number | undefined;
    const poll = async () => {
      const result = await check();
      if (result.status === "starting") timeout = window.setTimeout(poll, 250);
      else if (result.status === "ready")
        timeout = window.setTimeout(poll, 1_500);
    };
    void poll();
    return () => {
      mounted.current = false;
      if (timeout) window.clearTimeout(timeout);
    };
  }, [check]);

  const retry = useCallback(async () => {
    setConnection({ status: "starting" });
    try {
      setConnection(await restartCore());
    } catch (error) {
      setConnection({
        status: "error",
        message:
          error instanceof Error
            ? error.message
            : "The local service could not restart.",
      });
    }
  }, []);

  return { connection, retry };
}
