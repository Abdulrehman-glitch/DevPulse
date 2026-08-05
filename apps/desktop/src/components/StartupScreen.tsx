import type { CoreConnection } from "@devpulse/shared-types";
import { AlertCircle, FileText, RefreshCw } from "lucide-react";

export function StartupScreen({
  connection,
  onRetry,
}: {
  connection: CoreConnection;
  onRetry: () => void;
}) {
  const failed = connection.status === "error";
  return (
    <main className="startup-shell" aria-live="polite">
      <section className="startup-card">
        <div className="brand-mark brand-mark-large" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
        <p className="eyebrow">DevPulse desktop</p>
        <h1>
          {failed
            ? "Local service needs attention"
            : "Preparing your workspace"}
        </h1>
        <p className="startup-copy">
          {failed
            ? (connection.message ??
              "DevPulse could not start its internal service.")
            : "Starting the private local service and collecting current system information."}
        </p>
        {connection.qaMode && (
          <p className="qa-startup-note">
            QA Mode uses isolated artificial data. Production projects and
            settings are not loaded.
          </p>
        )}
        {failed ? (
          <div className="startup-actions">
            <button className="button button-primary" onClick={onRetry}>
              <RefreshCw size={16} /> Retry startup
            </button>
            {connection.diagnosticsPath && (
              <p className="diagnostic-path">
                <FileText size={15} /> Diagnostics: {connection.diagnosticsPath}
              </p>
            )}
          </div>
        ) : (
          <div className="startup-progress" aria-label="Starting local service">
            <span />
          </div>
        )}
        {failed && (
          <AlertCircle className="startup-status-icon" aria-hidden="true" />
        )}
      </section>
    </main>
  );
}
