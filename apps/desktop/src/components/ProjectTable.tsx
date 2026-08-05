import type { ProjectSummary } from "@devpulse/shared-types";
import {
  Archive,
  ArrowDownRight,
  ArrowUpRight,
  CircleAlert,
  FolderOpen,
  FolderSearch,
  Star,
  StarOff,
  Trash2,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";

const statusLabels: Record<string, string> = {
  clean: "Clean",
  modified: "Modified",
  untracked: "Untracked",
  detached: "Detached",
  missing: "Missing",
  not_git: "Not Git",
  access_error: "Unavailable",
};

const ROW_HEIGHT = 116;
const OVERSCAN = 5;

type ProjectTableProps = {
  projects: ProjectSummary[];
  onOpen?: (id: string) => void;
  onRemove?: (project: ProjectSummary) => void;
  selected?: Set<string>;
  onSelect?: (id: string) => void;
  onFavorite?: (project: ProjectSummary) => void;
  onArchive?: (project: ProjectSummary) => void;
  onOpenFolder?: (project: ProjectSummary) => void;
};

export function ProjectTable({
  projects,
  onOpen,
  onRemove,
  selected = new Set(),
  onSelect,
  onFavorite,
  onArchive,
  onOpenFolder,
}: ProjectTableProps) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const [scrollTop, setScrollTop] = useState(0);
  const hasActions = Boolean(onOpen || onFavorite || onArchive || onRemove);
  const columnCount = 9 + (onSelect ? 1 : 0) + (hasActions ? 1 : 0);
  const viewportHeight = 520;
  const start = Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - OVERSCAN);
  const visibleCount = Math.ceil(viewportHeight / ROW_HEIGHT) + OVERSCAN * 2;
  const end = Math.min(projects.length, start + visibleCount);
  const visibleProjects = projects.slice(start, end);

  useEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport) return;
    const maxScroll = Math.max(
      0,
      projects.length * ROW_HEIGHT - viewport.clientHeight,
    );
    if (viewport.scrollTop > maxScroll) {
      viewport.scrollTop = maxScroll;
      setScrollTop(maxScroll);
    }
  }, [projects.length]);

  if (!projects.length) {
    return (
      <div className="empty-state">
        <FolderSearch size={28} strokeWidth={1.5} />
        <h3>No repositories detected</h3>
        <p>Add a project to begin a bounded, read-only repository scan.</p>
      </div>
    );
  }

  const focusRow = (index: number) => {
    const viewport = viewportRef.current;
    if (!viewport) return;
    const clamped = Math.max(0, Math.min(index, projects.length - 1));
    const nextTop = Math.max(
      0,
      Math.min(
        clamped * ROW_HEIGHT,
        Math.max(0, projects.length * ROW_HEIGHT - viewport.clientHeight),
      ),
    );
    viewport.scrollTop = nextTop;
    setScrollTop(nextTop);
    window.requestAnimationFrame(() => {
      viewport
        .querySelector<HTMLTableRowElement>(
          `[data-project-row-index="${clamped}"]`,
        )
        ?.focus();
    });
  };

  return (
    <>
      <div
        ref={viewportRef}
        className="table-scroll virtual-table-viewport"
        onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}
        data-rendered-row-count={visibleProjects.length}
      >
        <table
          className="project-table virtual-project-table"
          aria-label="Registered DevPulse projects"
          aria-rowcount={projects.length + 1}
        >
          <caption className="visually-hidden">
            Registered DevPulse projects. Use arrow keys to move between rows.
          </caption>
          <thead>
            <tr>
              {onSelect && (
                <th className="select-column">
                  <span className="visually-hidden">Select</span>
                </th>
              )}
              <th>Favorite</th>
              <th>Project</th>
              <th>Status</th>
              <th>Branch</th>
              <th>Technology</th>
              <th>Sync</th>
              <th>Changes</th>
              <th>Last commit</th>
              <th className="align-right">Health</th>
              {hasActions && (
                <th>
                  <span className="visually-hidden">Actions</span>
                </th>
              )}
            </tr>
          </thead>
          <tbody>
            <tr aria-hidden="true" className="virtual-spacer-row">
              <td
                colSpan={columnCount}
                style={{ height: start * ROW_HEIGHT }}
              />
            </tr>
            {visibleProjects.map((project, offset) => (
              <ProjectRow
                key={project.id}
                project={project}
                rowIndex={start + offset}
                total={projects.length}
                hasActions={hasActions}
                onOpen={onOpen}
                onRemove={onRemove}
                selected={selected}
                onSelect={onSelect}
                onFavorite={onFavorite}
                onArchive={onArchive}
                onOpenFolder={onOpenFolder}
                onMoveRow={focusRow}
              />
            ))}
            <tr aria-hidden="true" className="virtual-spacer-row">
              <td
                colSpan={columnCount}
                style={{
                  height: Math.max(0, projects.length - end) * ROW_HEIGHT,
                }}
              />
            </tr>
          </tbody>
        </table>
      </div>
      <div className="visually-hidden" aria-live="polite">
        Showing rows {start + 1} to {end} of {projects.length} projects.
      </div>
    </>
  );
}

function ProjectRow({
  project,
  rowIndex,
  total,
  hasActions,
  onOpen,
  onRemove,
  selected,
  onSelect,
  onFavorite,
  onArchive,
  onOpenFolder,
  onMoveRow,
}: {
  project: ProjectSummary;
  rowIndex: number;
  total: number;
  hasActions: boolean;
  onOpen?: (id: string) => void;
  onRemove?: (project: ProjectSummary) => void;
  selected: Set<string>;
  onSelect?: (id: string) => void;
  onFavorite?: (project: ProjectSummary) => void;
  onArchive?: (project: ProjectSummary) => void;
  onOpenFolder?: (project: ProjectSummary) => void;
  onMoveRow: (index: number) => void;
}) {
  return (
    <tr
      key={project.id}
      className={project.archived ? "project-row-archived" : undefined}
      data-project-row-index={rowIndex}
      data-project-id={project.id}
      tabIndex={0}
      aria-rowindex={rowIndex + 2}
      aria-label={`${project.name}, ${statusLabels[project.status] ?? project.status}, row ${rowIndex + 1} of ${total}`}
      onKeyDown={(event) => {
        if (event.key === "ArrowDown") {
          event.preventDefault();
          onMoveRow(rowIndex + 1);
        } else if (event.key === "ArrowUp") {
          event.preventDefault();
          onMoveRow(rowIndex - 1);
        }
      }}
    >
      {onSelect && (
        <td className="select-column">
          <input
            type="checkbox"
            aria-label={`Select ${project.name}`}
            checked={selected.has(project.id)}
            onChange={() => onSelect(project.id)}
          />
        </td>
      )}
      <td>
        {onFavorite ? (
          <button
            className={`favorite-button ${project.favorite ? "favorite-active" : ""}`}
            aria-label={`${project.favorite ? "Unfavorite" : "Favorite"} ${project.name}`}
            title={project.favorite ? "Remove favorite" : "Mark favorite"}
            onClick={() => onFavorite(project)}
          >
            {project.favorite ? (
              <Star size={16} fill="currentColor" />
            ) : (
              <StarOff size={16} />
            )}
          </button>
        ) : project.favorite ? (
          <Star size={16} fill="currentColor" aria-label="Favorite" />
        ) : null}
      </td>
      <td>
        <button
          className="project-name-button"
          onClick={() => onOpen?.(project.id)}
          disabled={!onOpen}
        >
          <div className="project-name" title={project.name}>
            {project.name}
          </div>
        </button>
        <div className="project-path" title={project.path}>
          {project.path}
        </div>
        {project.tags.length > 0 && (
          <div className="project-tags">
            {project.tags.slice(0, 3).map((tag) => (
              <span key={tag}>{tag}</span>
            ))}
          </div>
        )}
      </td>
      <td>
        <span className={`status-pill status-${project.status}`}>
          <i aria-hidden="true" />
          {statusLabels[project.status] ?? project.status}
        </span>
      </td>
      <td className="data-cell" title={project.tracking_branch ?? undefined}>
        <span className="branch-cell">{project.branch}</span>
        {project.tracking_branch && (
          <small className="subtle-cell">{project.tracking_branch}</small>
        )}
      </td>
      <td>{project.primary_technology}</td>
      <td>
        <span className="sync-count" title="Commits ahead">
          <ArrowUpRight size={14} /> {project.ahead_count}
        </span>
        <span className="sync-count" title="Commits behind">
          <ArrowDownRight size={14} /> {project.behind_count}
        </span>
      </td>
      <td
        className="data-cell"
        title={`${project.modified_count} modified, ${project.staged_count} staged, ${project.untracked_count} untracked`}
      >
        {project.changed_files}
        <span className="change-breakdown">
          M {project.modified_count} / S {project.staged_count} / U{" "}
          {project.untracked_count}
        </span>
      </td>
      <td>
        <div className="commit-message" title={project.last_commit_message}>
          {project.last_commit_message}
        </div>
        <div className="commit-meta">
          {project.last_commit_date
            ? new Intl.DateTimeFormat(undefined, {
                dateStyle: "medium",
              }).format(new Date(project.last_commit_date))
            : "No commits"}
        </div>
      </td>
      <td className="align-right">
        <span className="health-score">{project.health_score}</span>
        {project.warning_count > 0 && (
          <CircleAlert
            className="warning-icon"
            size={15}
            aria-label={`${project.warning_count} warnings`}
          />
        )}
      </td>
      {hasActions && (
        <td className="row-actions">
          {onOpen && (
            <button className="text-button" onClick={() => onOpen(project.id)}>
              Details
            </button>
          )}
          {onOpenFolder && project.exists && (
            <button
              className="icon-button"
              title="Open folder in Windows Explorer"
              aria-label={`Open ${project.name} in Windows Explorer`}
              onClick={() => onOpenFolder(project)}
            >
              <FolderOpen size={15} />
            </button>
          )}
          {onArchive && (
            <button
              className="icon-button"
              title={project.archived ? "Restore project" : "Archive project"}
              aria-label={`${project.archived ? "Restore" : "Archive"} ${project.name}`}
              onClick={() => onArchive(project)}
            >
              <Archive size={15} />
            </button>
          )}
          {onRemove && (
            <button
              className="icon-button"
              title="Remove from DevPulse"
              aria-label={`Remove ${project.name} from DevPulse`}
              onClick={() => onRemove(project)}
            >
              <Trash2 size={15} />
            </button>
          )}
        </td>
      )}
    </tr>
  );
}
