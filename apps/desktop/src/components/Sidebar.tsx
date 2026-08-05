import {
  Activity,
  ChevronLeft,
  ChevronRight,
  FolderKanban,
  Gauge,
  LifeBuoy,
  MonitorCog,
  Settings,
} from "lucide-react";

export type Page =
  "overview" | "projects" | "activity" | "system" | "diagnostics" | "settings";

const navigation = [
  { id: "overview" as const, label: "Overview", icon: Gauge },
  { id: "projects" as const, label: "Projects", icon: FolderKanban },
  { id: "activity" as const, label: "Activity", icon: Activity },
  { id: "system" as const, label: "System", icon: MonitorCog },
  { id: "diagnostics" as const, label: "Diagnostics", icon: LifeBuoy },
  { id: "settings" as const, label: "Settings", icon: Settings },
];

export function Sidebar({
  page,
  collapsed,
  version,
  onNavigate,
  onToggle,
}: {
  page: Page;
  collapsed: boolean;
  version: string;
  onNavigate: (page: Page) => void;
  onToggle: () => void;
}) {
  return (
    <aside className={`sidebar ${collapsed ? "sidebar-collapsed" : ""}`}>
      <div className="brand">
        <div className="brand-mark" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
        {!collapsed && <span className="brand-name">DevPulse</span>}
      </div>
      <nav aria-label="Primary navigation">
        {navigation.map(({ id, label, icon: Icon }) => (
          <button
            key={id}
            className={page === id ? "nav-item nav-item-active" : "nav-item"}
            onClick={() => onNavigate(id)}
            aria-current={page === id ? "page" : undefined}
            title={collapsed ? label : undefined}
          >
            <Icon size={18} strokeWidth={1.8} />
            {!collapsed && <span>{label}</span>}
          </button>
        ))}
      </nav>
      <div className="sidebar-footer">
        {!collapsed && <span className="version">Version {version}</span>}
        <button
          className="collapse-button"
          onClick={onToggle}
          title="Toggle navigation"
        >
          {collapsed ? <ChevronRight size={17} /> : <ChevronLeft size={17} />}
          <span className="visually-hidden">Toggle navigation</span>
        </button>
      </div>
    </aside>
  );
}
