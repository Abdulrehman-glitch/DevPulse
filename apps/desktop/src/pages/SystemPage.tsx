import { useQuery } from "@tanstack/react-query";
import { Database, FolderLock, ServerCog } from "lucide-react";
import { MetricStrip } from "../components/MetricStrip";
import { DashboardSkeleton } from "../components/LoadingState";
import { ErrorState } from "../components/ErrorState";
import type { DataProvider } from "../providers/contracts";
import { resolveDesktopStatus } from "../providers/local";

export function SystemPage({ provider }: { provider: DataProvider }) {
  const query = useQuery({
    queryKey: ["system-summary"],
    queryFn: () => provider.getSystemSummary(),
    refetchInterval: 3_000,
  });
  const desktop = useQuery({
    queryKey: ["desktop-status"],
    queryFn: resolveDesktopStatus,
    refetchInterval: 3_000,
  });
  const history = useQuery({
    queryKey: ["system-history"],
    queryFn: () => provider.getSystemHistory(),
    refetchInterval: 10_000,
  });
  if (query.isLoading || desktop.isLoading || history.isLoading)
    return <DashboardSkeleton />;
  if (query.error)
    return (
      <ErrorState
        message={
          query.error instanceof Error
            ? query.error.message
            : "System data is unavailable."
        }
        onRetry={() => void query.refetch()}
      />
    );
  if (!query.data) return null;
  const data = query.data;
  return (
    <div className="page">
      <header className="page-header">
        <div>
          <p className="eyebrow">Local machine</p>
          <h1>System</h1>
          <p className="page-description">
            Read-only operational information for DevPulse and relevant storage
            volumes.
          </p>
        </div>
      </header>
      <section className="metrics-grid system-metrics">
        <MetricStrip
          label="CPU utilisation"
          value={data.cpu_percent}
          kind="cpu"
        />
        <MetricStrip
          label="Memory utilisation"
          value={data.memory_percent}
          kind="memory"
        />
        <MetricStrip
          label="Disk utilisation"
          value={data.disk_percent}
          kind="disk"
        />
      </section>
      <section className="detail-stat-grid system-facts">
        <Fact
          label="Logical processors"
          value={String(data.logical_processors ?? "Unavailable")}
        />
        <Fact
          label="Available memory"
          value={formatBytes(data.memory_available_bytes)}
        />
        <Fact
          label="DevPulse uptime"
          value={formatDuration(
            desktop.data?.processUptimeSeconds ?? data.process_uptime_seconds,
          )}
        />
        <Fact label="Scan worker" value={data.scan_worker_status} />
        <Fact
          label="Sidecar PID"
          value={String(desktop.data?.sidecarPid ?? "Unavailable")}
        />
      </section>
      <section className="panel history-panel">
        <div className="panel-heading">
          <div>
            <h2>Recent history</h2>
            <p>
              Bounded DevPulse-owned samples; not invasive device monitoring.
            </p>
          </div>
          <span>{history.data?.items.length ?? 0} samples</span>
        </div>
        <div className="history-grid">
          <HistoryChart
            label="CPU"
            values={(history.data?.items ?? []).map((item) => item.cpu_percent)}
          />
          <HistoryChart
            label="Memory"
            values={(history.data?.items ?? []).map(
              (item) => item.memory_percent,
            )}
          />
          <HistoryChart
            label="Warnings"
            values={(history.data?.items ?? []).map(
              (item) => item.warning_count,
            )}
          />
        </div>
        <div className="history-footnote">
          Refresh success and scan duration are recorded locally with the same
          bounded history.
        </div>
      </section>
      <div className="detail-columns">
        <section className="panel status-panel">
          <div className="panel-heading">
            <div>
              <h2>Local services</h2>
              <p>Processes owned by this DevPulse session.</p>
            </div>
            <ServerCog size={19} />
          </div>
          <Status label="Local core" value="connected" />
          <Status
            label="Sidecar process"
            value={desktop.data?.sidecarProcessStatus ?? "unknown"}
          />
          <Status label="Cache" value={data.cache_status} />
        </section>
        <section className="panel">
          <div className="panel-heading">
            <div>
              <h2>Relevant volumes</h2>
              <p>Capacity only; file contents are not scanned.</p>
            </div>
            <Database size={19} />
          </div>
          {data.volumes.length ? (
            <ul className="volume-list">
              {data.volumes.map((volume) => (
                <li key={volume.mount}>
                  <strong>{volume.mount}</strong>
                  <span>
                    {Math.round(volume.usage_percent)}% used ·{" "}
                    {formatBytes(volume.free_bytes)} free
                  </span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="compact-empty">Volume information is unavailable.</p>
          )}
        </section>
      </div>
      <section className="panel path-panel">
        <div className="panel-heading">
          <div>
            <h2>DevPulse storage boundary</h2>
            <p>
              Writable runtime state remains in this application-owned location.
            </p>
          </div>
          <FolderLock size={19} />
        </div>
        <dl>
          <div>
            <dt>Application data</dt>
            <dd>
              {desktop.data?.applicationDataLocation ??
                data.application_data_location}
            </dd>
          </div>
          <div>
            <dt>Logs</dt>
            <dd>
              {desktop.data?.logDirectoryLocation ??
                data.log_directory_location}
            </dd>
          </div>
        </dl>
      </section>
    </div>
  );
}
function Fact({ label, value }: { label: string; value: string }) {
  return (
    <article>
      <span>{label}</span>
      <strong>{value}</strong>
    </article>
  );
}
function Status({ label, value }: { label: string; value: string }) {
  return (
    <div className="service-row">
      <span>{label}</span>
      <strong>
        <i
          className={
            value === "connected" ||
            value === "running" ||
            value === "ready" ||
            value === "idle"
              ? "status-dot-ok"
              : "status-dot-warn"
          }
        />
        {value}
      </strong>
    </div>
  );
}
function HistoryChart({
  label,
  values,
}: {
  label: string;
  values: Array<number | null>;
}) {
  const usable = values.filter((value): value is number => value !== null);
  const max = Math.max(...usable, 1);
  return (
    <div className="history-chart">
      <div>
        <strong>{label}</strong>
        <span>
          {usable.length
            ? `${Math.round(usable[usable.length - 1])}`
            : "No samples"}
        </span>
      </div>
      <div className="history-bars" aria-label={`${label} history`}>
        {usable.slice(-24).map((value, index) => (
          <i
            key={`${index}-${value}`}
            style={{ height: `${Math.max(6, (value / max) * 100)}%` }}
          />
        ))}
      </div>
    </div>
  );
}
function formatBytes(value: number | null) {
  if (value === null) return "Unavailable";
  return `${(value / 1024 ** 3).toFixed(1)} GB`;
}
function formatDuration(seconds: number) {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return hours ? `${hours}h ${minutes}m` : `${minutes}m`;
}
