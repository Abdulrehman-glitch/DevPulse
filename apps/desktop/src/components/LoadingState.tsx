export function DashboardSkeleton() {
  return (
    <div aria-label="Loading dashboard" className="skeleton-layout">
      <div className="skeleton skeleton-title" />
      <div className="skeleton-metrics">
        {[0, 1, 2, 3].map((item) => (
          <div className="skeleton skeleton-metric" key={item} />
        ))}
      </div>
      <div className="skeleton skeleton-panel" />
      <div className="skeleton skeleton-panel skeleton-panel-short" />
    </div>
  );
}
