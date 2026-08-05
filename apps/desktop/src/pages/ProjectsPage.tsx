import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Archive,
  FilterX,
  FolderPlus,
  RefreshCw,
  Search,
  Star,
} from "lucide-react";
import { useMemo, useState } from "react";
import { DashboardSkeleton } from "../components/LoadingState";
import { ErrorState } from "../components/ErrorState";
import { ProjectTable } from "../components/ProjectTable";
import type { Settings } from "@devpulse/shared-types";
import type { DataProvider } from "../providers/contracts";
import { openProjectFolder } from "../providers/local";

export function ProjectsPage({
  provider,
  onOpen,
  onAddProject,
  onAddRoot,
  qaMode = false,
}: {
  provider: DataProvider;
  onOpen: (id: string) => void;
  onAddProject: () => void;
  onAddRoot: () => void;
  qaMode?: boolean;
}) {
  const client = useQueryClient();
  const [filter, setFilter] = useState("");
  const [tagFilter, setTagFilter] = useState("all");
  const [status, setStatus] = useState("all");
  const [technology, setTechnology] = useState("all");
  const [warning, setWarning] = useState("all");
  const [minimumHealth, setMinimumHealth] = useState(0);
  const [sort, setSort] = useState("name");
  const [favoritesOnly, setFavoritesOnly] = useState(false);
  const [showArchived, setShowArchived] = useState(false);
  const [viewName, setViewName] = useState("");
  const [activeViewId, setActiveViewId] = useState("");
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const query = useQuery({
    queryKey: ["projects"],
    queryFn: () => provider.getProjects(),
  });
  const settings = useQuery({
    queryKey: ["settings"],
    queryFn: () => provider.getSettings(),
  });
  const refresh = useMutation({
    mutationFn: () => provider.refreshProjects(),
    onSuccess: async () => {
      await client.invalidateQueries();
    },
  });
  const update = useMutation({
    mutationFn: ({
      id,
      patch,
    }: {
      id: string;
      patch: Parameters<DataProvider["updateProject"]>[1];
    }) => provider.updateProject(id, patch),
    onSuccess: async () => {
      await client.invalidateQueries();
    },
  });
  const remove = useMutation({
    mutationFn: (id: string) => provider.removeProject(id),
    onSuccess: async () => {
      setSelected(new Set());
      await client.invalidateQueries();
    },
  });
  const technologies = useMemo(
    () =>
      [
        ...new Set(
          query.data?.items.flatMap((item) => item.technologies) ?? [],
        ),
      ].sort(),
    [query.data],
  );
  const tags = useMemo(
    () =>
      [...new Set(query.data?.items.flatMap((item) => item.tags) ?? [])].sort(),
    [query.data],
  );
  const items = useMemo(() => {
    const value = filter.trim().toLowerCase();
    return [...(query.data?.items ?? [])]
      .filter((item) => (showArchived ? item.archived : !item.archived))
      .filter((item) =>
        `${item.name} ${item.path} ${item.tags.join(" ")}`
          .toLowerCase()
          .includes(value),
      )
      .filter((item) => tagFilter === "all" || item.tags.includes(tagFilter))
      .filter((item) => status === "all" || item.status === status)
      .filter(
        (item) =>
          technology === "all" || item.technologies.includes(technology),
      )
      .filter((item) =>
        warning === "all"
          ? true
          : warning === "with"
            ? item.warning_count > 0
            : item.warning_count === 0,
      )
      .filter((item) => item.health_score >= minimumHealth)
      .filter((item) => !favoritesOnly || item.favorite)
      .sort((left, right) => {
        if (sort === "recent")
          return (
            new Date(right.last_commit_date ?? 0).getTime() -
            new Date(left.last_commit_date ?? 0).getTime()
          );
        if (sort === "changes") return right.changed_files - left.changed_files;
        if (sort === "health") return right.health_score - left.health_score;
        if (sort === "warnings")
          return right.warning_count - left.warning_count;
        if (sort === "refresh")
          return (
            new Date(right.last_scan_timestamp).getTime() -
            new Date(left.last_scan_timestamp).getTime()
          );
        return left.name.localeCompare(right.name);
      });
  }, [
    favoritesOnly,
    filter,
    minimumHealth,
    query.data,
    showArchived,
    sort,
    status,
    tagFilter,
    technology,
    warning,
  ]);
  const savedViews = (settings.data?.saved_views ??
    []) as Settings["saved_views"];
  if (query.isLoading) return <DashboardSkeleton />;
  if (query.error)
    return (
      <ErrorState
        message={
          query.error instanceof Error
            ? query.error.message
            : "Project data is unavailable."
        }
        onRetry={() => void query.refetch()}
      />
    );

  const visibleIds = new Set(items.map((item) => item.id));
  const allVisibleSelected =
    items.length > 0 && items.every((item) => selected.has(item.id));
  const resetFilters = () => {
    setFilter("");
    setTagFilter("all");
    setStatus("all");
    setTechnology("all");
    setWarning("all");
    setMinimumHealth(0);
    setSort("name");
    setFavoritesOnly(false);
    setShowArchived(false);
    setActiveViewId("");
  };
  const applySavedView = (view: Settings["saved_views"][number]) => {
    setFilter(view.query);
    setStatus(view.status);
    setTechnology(view.technology);
    setTagFilter(view.tag);
    setWarning(view.warning);
    setMinimumHealth(view.minimum_health);
    setSort(view.sort);
    setFavoritesOnly(view.favorites_only);
    setShowArchived(view.show_archived);
    setActiveViewId(view.id);
    void provider.updateSettings({ active_saved_view: view.id });
  };
  const saveCurrentView = async () => {
    const name = viewName.trim();
    if (!name) return;
    const id = `view-${
      name
        .toLocaleLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-|-$/g, "")
        .slice(0, 50) || "custom"
    }`;
    const next = [
      ...savedViews.filter((view) => view.id !== id),
      {
        id,
        name,
        query: filter,
        status,
        technology,
        tag: tagFilter,
        warning,
        minimum_health: minimumHealth,
        sort,
        favorites_only: favoritesOnly,
        show_archived: showArchived,
      },
    ].slice(-50);
    await provider.updateSettings({ saved_views: next, active_saved_view: id });
    setActiveViewId(id);
    await client.invalidateQueries({ queryKey: ["settings"] });
  };
  const deleteCurrentView = async () => {
    if (!activeViewId) return;
    await provider.updateSettings({
      saved_views: savedViews.filter((view) => view.id !== activeViewId),
      active_saved_view: null,
    });
    setActiveViewId("");
    await client.invalidateQueries({ queryKey: ["settings"] });
  };
  const toggleSelect = (id: string) =>
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const toggleAll = () =>
    setSelected((current) => {
      const next = new Set(current);
      if (allVisibleSelected) visibleIds.forEach((id) => next.delete(id));
      else visibleIds.forEach((id) => next.add(id));
      return next;
    });
  async function removeProject(id: string, name: string) {
    if (
      settings.data?.confirm_before_removing_project !== false &&
      !window.confirm(
        `Remove ${name} from DevPulse?\n\nThe repository and every project file will remain unchanged.`,
      )
    )
      return;
    remove.mutate(id);
  }
  async function bulkArchive() {
    if (
      !selected.size ||
      !window.confirm(
        `${showArchived ? "Restore" : "Archive"} ${selected.size} selected project${selected.size === 1 ? "" : "s"} in DevPulse?`,
      )
    )
      return;
    const lookup = new Map(
      (query.data?.items ?? []).map((item) => [item.id, item]),
    );
    await Promise.all(
      [...selected].map((id) => {
        const item = lookup.get(id);
        return item
          ? provider.updateProject(id, { archived: !showArchived })
          : undefined;
      }),
    );
    setSelected(new Set());
    await client.invalidateQueries();
  }
  async function bulkRemove() {
    if (
      !selected.size ||
      !window.confirm(
        `Remove ${selected.size} selected project${selected.size === 1 ? "" : "s"} from DevPulse?\n\nNo external repository files will be changed.`,
      )
    )
      return;
    await Promise.all([...selected].map((id) => provider.removeProject(id)));
    setSelected(new Set());
    await client.invalidateQueries();
  }
  return (
    <div className="page">
      <header className="page-header">
        <div>
          <p className="eyebrow">Repository inventory</p>
          <h1>Projects</h1>
          <p className="page-description">
            A local register of repositories DevPulse can inspect without
            modification.
          </p>
        </div>
        <div className="header-actions">
          <button className="button" onClick={onAddRoot} disabled={qaMode}>
            <FolderPlus size={16} /> Add Project Root
          </button>
          <button
            className="button button-primary"
            onClick={onAddProject}
            disabled={qaMode}
          >
            Add Project
          </button>
        </div>
      </header>
      {qaMode && (
        <section className="qa-artificial-notice">
          <strong>Artificial repository inventory</strong>
          <span>
            Folder onboarding is locked. Reset or regenerate fixtures from the
            QA Mode bar.
          </span>
        </section>
      )}
      <section className="panel projects-inventory">
        <div className="saved-view-bar" aria-label="Saved project views">
          <label>
            <span>Saved view</span>
            <select
              aria-label="Saved views"
              value={activeViewId}
              onChange={(event) => {
                const view = savedViews.find(
                  (item) => item.id === event.target.value,
                );
                if (view) applySavedView(view);
                else resetFilters();
              }}
            >
              <option value="">Current filters</option>
              {savedViews.map((view) => (
                <option key={view.id} value={view.id}>
                  {view.name}
                </option>
              ))}
            </select>
          </label>
          <label className="saved-view-name">
            <span className="visually-hidden">Saved view name</span>
            <input
              aria-label="Saved view name"
              value={viewName}
              onChange={(event) => setViewName(event.target.value)}
              placeholder="Name this view"
              maxLength={80}
            />
          </label>
          <button
            className="button button-small"
            onClick={() => void saveCurrentView()}
            disabled={!viewName.trim()}
          >
            Save view
          </button>
          <button
            className="text-button"
            onClick={() => void deleteCurrentView()}
            disabled={!activeViewId}
          >
            Delete view
          </button>
        </div>
        <div className="table-toolbar project-toolbar">
          <label className="search-field">
            <Search size={16} />
            <span className="visually-hidden">
              Search projects by name, path or tag
            </span>
            <input
              value={filter}
              onChange={(event) => setFilter(event.target.value)}
              placeholder="Search name or path"
            />
          </label>
          <select
            aria-label="Status filter"
            value={status}
            onChange={(event) => setStatus(event.target.value)}
          >
            <option value="all">All statuses</option>
            <option value="clean">Clean</option>
            <option value="modified">Modified</option>
            <option value="untracked">Untracked</option>
            <option value="detached">Detached</option>
            <option value="missing">Missing</option>
            <option value="access_error">Unavailable</option>
          </select>
          <select
            aria-label="Technology filter"
            value={technology}
            onChange={(event) => setTechnology(event.target.value)}
          >
            <option value="all">All technologies</option>
            {technologies.map((item) => (
              <option key={item}>{item}</option>
            ))}
          </select>
          <select
            aria-label="Tag filter"
            value={tagFilter}
            onChange={(event) => setTagFilter(event.target.value)}
          >
            <option value="all">All tags</option>
            {tags.map((item) => (
              <option key={item}>{item}</option>
            ))}
          </select>
          <select
            aria-label="Warning filter"
            value={warning}
            onChange={(event) => setWarning(event.target.value)}
          >
            <option value="all">All warnings</option>
            <option value="with">Needs attention</option>
            <option value="without">No warnings</option>
          </select>
          <select
            aria-label="Health score filter"
            value={minimumHealth}
            onChange={(event) => setMinimumHealth(Number(event.target.value))}
          >
            <option value={0}>Any health</option>
            <option value={50}>Health 50+</option>
            <option value={70}>Health 70+</option>
            <option value={90}>Health 90+</option>
          </select>
          <select
            aria-label="Sort projects"
            value={sort}
            onChange={(event) => setSort(event.target.value)}
          >
            <option value="name">Name</option>
            <option value="recent">Recent commit</option>
            <option value="changes">Change count</option>
            <option value="health">Health score</option>
            <option value="warnings">Warning count</option>
            <option value="refresh">Last refresh</option>
          </select>
          <button
            className="icon-button"
            title="Reset filters"
            aria-label="Reset filters"
            onClick={resetFilters}
          >
            <FilterX size={16} />
          </button>
          <button
            className="icon-button"
            title="Refresh projects"
            aria-label="Refresh projects"
            onClick={() => refresh.mutate()}
          >
            <RefreshCw size={16} className={refresh.isPending ? "spin" : ""} />
          </button>
        </div>
        <div className="inventory-toolbar">
          <label className="check-all">
            <input
              type="checkbox"
              aria-label="Select all visible projects"
              checked={allVisibleSelected}
              onChange={toggleAll}
            />{" "}
            Select visible
          </label>
          <button
            className={`filter-chip ${favoritesOnly ? "filter-chip-active" : ""}`}
            onClick={() => setFavoritesOnly((value) => !value)}
          >
            <Star size={14} /> Favorites
          </button>
          <button
            className={`filter-chip ${showArchived ? "filter-chip-active" : ""}`}
            onClick={() => setShowArchived((value) => !value)}
          >
            <Archive size={14} /> {showArchived ? "Archived" : "Active"}
          </button>
          {selected.size > 0 && (
            <>
              <span className="selection-count">{selected.size} selected</span>
              <button
                className="button button-small"
                onClick={() => void bulkArchive()}
              >
                <Archive size={14} /> {showArchived ? "Restore" : "Archive"}
              </button>
              <button
                className="button button-small button-danger"
                onClick={() => void bulkRemove()}
              >
                Remove
              </button>
            </>
          )}
          <span className="result-count">
            {items.length} of {query.data?.total ?? 0} projects
          </span>
        </div>
        <ProjectTable
          projects={items}
          selected={selected}
          onSelect={toggleSelect}
          onOpen={onOpen}
          onFavorite={(item) =>
            update.mutate({ id: item.id, patch: { favorite: !item.favorite } })
          }
          onArchive={(item) =>
            update.mutate({ id: item.id, patch: { archived: !item.archived } })
          }
          onRemove={(item) => void removeProject(item.id, item.name)}
          onOpenFolder={(item) => void openProjectFolder(item.id)}
        />
      </section>
    </div>
  );
}
