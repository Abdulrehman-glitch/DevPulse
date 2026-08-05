import { useQuery } from "@tanstack/react-query";
import { Check, Clipboard, ShieldCheck } from "lucide-react";
import { useState } from "react";
import { DashboardSkeleton } from "../components/LoadingState";
import { ErrorState } from "../components/ErrorState";
import type { DataProvider } from "../providers/contracts";

export function DiagnosticsPage({ provider }: { provider: DataProvider }) {
  const [copied, setCopied] = useState(false);
  const query = useQuery({
    queryKey: ["safe-diagnostics"],
    queryFn: () => provider.getSafeDiagnostics(),
  });
  if (query.isLoading) return <DashboardSkeleton />;
  if (query.error || !query.data)
    return (
      <ErrorState
        title="Safe diagnostics are unavailable"
        message={
          query.error instanceof Error
            ? query.error.message
            : "DevPulse could not assemble its local diagnostic summary."
        }
        onRetry={() => void query.refetch()}
      />
    );
  const data = query.data;
  async function copy() {
    const text = await provider.exportSafeDiagnostics();
    await navigator.clipboard.writeText(text);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 2_000);
  }
  return (
    <div className="page diagnostics-page">
      <header className="page-header">
        <div>
          <p className="eyebrow">Support-ready summary</p>
          <h1>Safe Diagnostics</h1>
          <p className="page-description">
            DevPulse-owned operational facts with credentials, private URLs,
            environment values and file contents excluded.
          </p>
        </div>
        <button className="button button-primary" onClick={() => void copy()}>
          {copied ? <Check size={16} /> : <Clipboard size={16} />}
          {copied ? "Safe diagnostics copied" : "Copy Safe Diagnostics"}
        </button>
      </header>
      <section className="diagnostics-assurance">
        <ShieldCheck size={19} />
        <div>
          <strong>Redaction boundary active</strong>
          <p>
            No tokens, credentials, environment values or file contents are
            included.
          </p>
        </div>
      </section>
      <section className="panel diagnostics-grid">
        <Fact label="DevPulse" value={data.devpulse_version} />
        <Fact label="Operating system" value={data.operating_system} />
        <Fact label="Local core" value={data.local_core_status} />
        <Fact label="Sidecar" value={data.sidecar_status} />
        <Fact label="Startup" value={`${data.startup_duration_ms} ms`} />
        <Fact label="Last scan" value={data.last_scan_status} />
        <Fact label="Projects" value={String(data.registered_projects)} />
        <Fact label="Cache" value={data.cache_status} />
        <Fact
          label="Configuration"
          value={`Schema ${data.configuration_schema_version}`}
        />
        <Fact label="Data boundary" value={data.data_boundary} />
      </section>
      <section className="panel diagnostic-log-panel">
        <div className="panel-heading">
          <div>
            <h2>Redacted DevPulse log excerpt</h2>
            <p>
              Only recent DevPulse-owned messages; paths and secret-like values
              are removed.
            </p>
          </div>
        </div>
        {data.log_excerpt.length ? (
          <ol>
            {data.log_excerpt.map((line, index) => (
              <li key={`${index}-${line}`}>{line}</li>
            ))}
          </ol>
        ) : (
          <p className="compact-empty">
            No diagnostic log entries are available.
          </p>
        )}
      </section>
    </div>
  );
}

function Fact({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <span>{label}</span>
      <strong title={value}>{value}</strong>
    </div>
  );
}
