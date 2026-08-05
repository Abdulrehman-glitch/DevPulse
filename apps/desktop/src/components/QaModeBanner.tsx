import { useMutation, useQueryClient } from "@tanstack/react-query";
import { FlaskConical, LogOut, RefreshCw, RotateCcw } from "lucide-react";
import type { DataProvider } from "../providers/contracts";
import { exitQaMode } from "../providers/local";

export function QaModeBanner({ provider }: { provider: DataProvider }) {
  const client = useQueryClient();
  const reset = useMutation({
    mutationFn: () => provider.resetQaData(),
    onSuccess: async () => client.invalidateQueries(),
  });
  const regenerate = useMutation({
    mutationFn: () => provider.regenerateQaData(),
    onSuccess: async () => client.invalidateQueries(),
  });
  function confirmReset() {
    if (
      window.confirm(
        "Reset the artificial QA repositories?\n\nOnly DevPulse QA test-lab data will be deleted. Production settings and real projects remain untouched.",
      )
    )
      reset.mutate();
  }
  return (
    <section className="qa-mode-banner" aria-label="QA Mode">
      <div className="qa-mode-identity">
        <FlaskConical size={17} />
        <strong>QA Mode</strong>
        <span>Artificial repositories · isolated application data</span>
      </div>
      <div className="qa-mode-actions">
        <button
          className="qa-action"
          onClick={confirmReset}
          disabled={reset.isPending || regenerate.isPending}
        >
          <RotateCcw size={14} /> Reset QA Data
        </button>
        <button
          className="qa-action"
          onClick={() => regenerate.mutate()}
          disabled={reset.isPending || regenerate.isPending}
        >
          <RefreshCw size={14} className={regenerate.isPending ? "spin" : ""} />
          Regenerate QA Data
        </button>
        <button className="qa-action qa-exit" onClick={() => void exitQaMode()}>
          <LogOut size={14} /> Exit QA Mode
        </button>
      </div>
      {(reset.isError || regenerate.isError) && (
        <p role="alert">
          {String((reset.error ?? regenerate.error) || "QA action failed")}
        </p>
      )}
    </section>
  );
}
