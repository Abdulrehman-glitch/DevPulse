import { Cpu, Database, HardDrive, MemoryStick } from "lucide-react";

const icons = {
  cpu: Cpu,
  memory: MemoryStick,
  disk: HardDrive,
  health: Database,
};

export function MetricStrip({
  label,
  value,
  kind,
}: {
  label: string;
  value: number | null;
  kind: keyof typeof icons;
}) {
  const Icon = icons[kind];
  const safe = value ?? 0;
  return (
    <article className="metric-strip">
      <div className="metric-heading">
        <span className="metric-icon">
          <Icon size={17} />
        </span>
        <span>{label}</span>
        <strong>{value === null ? "—" : `${Math.round(value)}%`}</strong>
      </div>
      <div
        className="meter"
        role="progressbar"
        aria-label={label}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={value === null ? undefined : Math.round(value)}
      >
        <span style={{ width: `${safe}%` }} />
      </div>
    </article>
  );
}
