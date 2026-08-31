import type { ProjectSummary } from "@devpulse/shared-types";
import {
  Archive,
  FolderOpen,
  FolderSearch,
  Star,
  StarOff,
  Trash2,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";

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
  const columnCount = 7 + (onSelect ? 1 : 0) + (hasActions ? 1 : 0);
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
          className={`project-table virtual-project-table ${onSelect ? "table-has-selection" : ""} ${hasActions ? "table-has-actions" : ""}`}
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
              <th className="favorite-column">Favorite</th>
              <th className="project-column">Project</th>
              <th className="state-column">State</th>
              <th className="branch-column">Branch &amp; upstream</th>
              <th className="sync-column">Sync</th>
              <th className="changes-column">Local changes</th>
              <th className="activity-column">Activity</th>
              {hasActions && (
                <th className="row-actions">
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
  const state = repositoryState(project);
  const sync = syncSummary(project);
  const changes = changeSummary(project);
  const language = project.primary_technology.trim() || "Unknown language";
  const branch = project.branch.trim() || "Unknown branch";
  const upstream = project.tracking_branch?.trim() || "No upstream configured";
  const activity = activitySummary(project);

  return (
    <tr
      key={project.id}
      className={project.archived ? "project-row-archived" : undefined}
      data-project-row-index={rowIndex}
      data-project-id={project.id}
      tabIndex={0}
      aria-rowindex={rowIndex + 2}
      aria-label={`${project.name}, ${state}, row ${rowIndex + 1} of ${total}`}
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
      <td className="favorite-column">
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
      <td className="project-column">
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
        <div className="project-language" title={language}>
          {language}
        </div>
        {project.tags.length > 0 && (
          <div className="project-tags">
            {project.tags.slice(0, 3).map((tag) => (
              <span key={tag}>{tag}</span>
            ))}
          </div>
        )}
      </td>
      <td className="state-column">
        <span className={`status-pill status-${project.status}`}>
          <i aria-hidden="true" />
          {state}
        </span>
      </td>
      <td className="branch-column">
        <span className="branch-cell" title={branch}>
          {branch}
        </span>
        <small className="subtle-cell" title={upstream}>
          {upstream}
        </small>
      </td>
      <td className="data-cell sync-column" title={sync.detail}>
        {sync.label}
      </td>
      <td className="data-cell changes-column" title={changes.detail}>
        {changes.label}
      </td>
      <td className="activity-column">
        <div className="activity-state">{activity}</div>
        <div className="commit-message" title={project.last_commit_message}>
          {project.last_commit_message || "No commit message"}
        </div>
        <div className="commit-meta">
          {project.last_commit_date
            ? new Intl.DateTimeFormat(undefined, {
                dateStyle: "medium",
              }).format(new Date(project.last_commit_date))
            : "No commits"}
        </div>
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

function repositoryState(project: ProjectSummary) {
  if (!project.exists || project.status === "missing")
    return "Repository missing";
  if (project.error || project.status === "access_error") {
    return "Repository unavailable";
  }
  if (!project.is_git_repository || project.status === "not_git") {
    return "Not a Git repository";
  }
  if (project.status === "clean") return "Clean — no local changes";
  if (project.status === "modified" || project.status === "untracked") {
    return "Changes detected";
  }
  if (project.status === "detached") return "Detached HEAD";
  return "Repository state unknown";
}

function syncSummary(project: ProjectSummary) {
  if (!project.exists || project.error || !project.is_git_repository) {
    return {
      label: "Sync unavailable",
      detail: "Sync information is unavailable",
    };
  }
  if (!project.tracking_branch) {
    return {
      label: "Sync unknown",
      detail: "No upstream branch is configured",
    };
  }
  if (project.ahead_count > 0 && project.behind_count > 0) {
    return {
      label: `Diverged: ${project.ahead_count} ahead, ${project.behind_count} behind`,
      detail: `${project.ahead_count} commits ahead and ${project.behind_count} commits behind`,
    };
  }
  if (project.ahead_count > 0) {
    return {
      label: `Ahead by ${commitCount(project.ahead_count)}`,
      detail: `${project.ahead_count} commit${plural(project.ahead_count)} ahead of upstream`,
    };
  }
  if (project.behind_count > 0) {
    return {
      label: `Behind by ${commitCount(project.behind_count)}`,
      detail: `${project.behind_count} commit${plural(project.behind_count)} behind upstream`,
    };
  }
  return { label: "Up to date", detail: "Matches the upstream branch" };
}

function changeSummary(project: ProjectSummary) {
  if (!project.exists || project.error || !project.is_git_repository) {
    return {
      label: "Changes unavailable",
      detail: "Local change information is unavailable",
    };
  }
  const count = Math.max(
    project.changed_files,
    project.modified_count + project.staged_count + project.untracked_count,
  );
  if (count === 0)
    return { label: "No local changes", detail: "Working tree is clean" };
  return {
    label: `${count} local change${plural(count)}`,
    detail: `${project.modified_count} modified, ${project.staged_count} staged, ${project.untracked_count} untracked`,
  };
}

function activitySummary(project: ProjectSummary) {
  if (project.recent_activity === true) return "Recent activity";
  if (project.recent_activity === false) return "No recent activity";
  return "Activity unknown";
}

function commitCount(count: number) {
  return `${count} commit${plural(count)}`;
}

function plural(count: number) {
  return count === 1 ? "" : "s";
}
