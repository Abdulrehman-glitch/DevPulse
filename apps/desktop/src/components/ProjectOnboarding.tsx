import type {
  ProjectDetail,
  ProjectSummary,
  Settings,
} from "@devpulse/shared-types";
import { open } from "@tauri-apps/plugin-dialog";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Check,
  FolderOpen,
  FolderTree,
  LockKeyhole,
  ShieldCheck,
  X,
} from "lucide-react";
import { useRef, useState } from "react";
import type { DataProvider } from "../providers/contracts";
import { useFocusTrap } from "./useFocusTrap";

type Mode = "intro" | "project" | "root";

export function ProjectOnboarding({
  provider,
  version,
  firstRun = false,
  initialMode = "intro",
  onDone,
}: {
  provider: DataProvider;
  version: string;
  firstRun?: boolean;
  initialMode?: Mode;
  onDone: () => void;
}) {
  const client = useQueryClient();
  const [mode, setMode] = useState<Mode>(initialMode);
  const [privacy, setPrivacy] = useState(false);
  const [preview, setPreview] = useState<ProjectDetail | null>(null);
  const [rootItems, setRootItems] = useState<ProjectSummary[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const onboardingRef = useFocusTrap<HTMLElement>(
    !firstRun && !privacy,
    onDone,
  );
  const settings = useQuery({
    queryKey: ["settings"],
    queryFn: () => provider.getSettings(),
  });
  const previewOne = useMutation({
    mutationFn: (path: string) => provider.previewProject(path),
    onSuccess: setPreview,
  });
  const previewMany = useMutation({
    mutationFn: (path: string) => provider.previewRoot(path),
    onSuccess: (result) => {
      setRootItems(result.items);
      setSelected(new Set(result.items.map((item) => item.path)));
    },
  });
  const save = useMutation({
    mutationFn: (paths: string[]) => provider.addProjects(paths),
    onSuccess: async () => {
      await Promise.all([
        client.invalidateQueries({ queryKey: ["settings"] }),
        client.invalidateQueries({ queryKey: ["projects"] }),
        client.invalidateQueries({ queryKey: ["system-summary"] }),
        client.invalidateQueries({ queryKey: ["activity"] }),
      ]);
      onDone();
    },
  });
  const continueWithout = useMutation({
    mutationFn: () => provider.updateSettings({ onboarding_completed: true }),
    onSuccess: onDone,
  });

  async function choose(next: "project" | "root") {
    setMode(next);
    setPreview(null);
    setRootItems([]);
    const path = await open({
      directory: true,
      multiple: false,
      title:
        next === "project"
          ? "Choose a Git repository"
          : "Choose a project root",
    });
    if (typeof path !== "string") return;
    if (next === "project") previewOne.mutate(path);
    else previewMany.mutate(path);
  }

  const error =
    previewOne.error ??
    previewMany.error ??
    save.error ??
    continueWithout.error;
  return (
    <div
      className={firstRun ? "onboarding-shell" : "modal-backdrop"}
      role={firstRun ? undefined : "presentation"}
    >
      <section
        ref={onboardingRef}
        className="onboarding-card"
        role={firstRun ? undefined : "dialog"}
        aria-modal={!firstRun}
      >
        {!firstRun && (
          <button
            className="icon-button modal-close"
            onClick={onDone}
            aria-label="Close onboarding"
          >
            <X size={18} />
          </button>
        )}
        <div className="safety-rail" aria-label="Repository protection enabled">
          <ShieldCheck size={18} /> Read-only boundary active
        </div>
        <div className="onboarding-content">
          <div className="brand-mark brand-mark-large" aria-hidden="true">
            <span />
            <span />
            <span />
          </div>
          <p className="eyebrow">DevPulse {version}</p>
          <div className="onboarding-steps" aria-label="Onboarding progress">
            <span className={mode === "intro" ? "step-active" : ""}>
              Welcome
            </span>
            <span
              className={
                mode === "project" || mode === "root" ? "step-active" : ""
              }
            >
              Choose projects
            </span>
            <span>Finish</span>
          </div>
          <h1>
            {mode === "intro"
              ? "Know what needs attention—without touching your code."
              : mode === "project"
                ? "Preview repository"
                : "Preview project root"}
          </h1>
          {mode === "intro" && (
            <>
              <p className="onboarding-lead">
                DevPulse reads bounded Git and system metadata locally. It never
                edits project files, runs project commands, or starts a
                laptop-wide scan.
              </p>
              <ul className="onboarding-assurances">
                <li>
                  Project paths and local notes stay in DevPulse application
                  data.
                </li>
                <li>No cloud account is required. Telemetry is disabled.</li>
                <li>
                  Remove a project from DevPulse without deleting the
                  repository.
                </li>
              </ul>
              <div className="onboarding-actions">
                <button
                  className="choice-card"
                  onClick={() => void choose("project")}
                >
                  <FolderOpen />
                  <strong>Add Project</strong>
                  <span>Choose one explicit Git repository.</span>
                </button>
                <button
                  className="choice-card"
                  onClick={() => void choose("root")}
                >
                  <FolderTree />
                  <strong>Add Project Root</strong>
                  <span>
                    Preview repositories within a narrow parent folder.
                  </span>
                </button>
              </div>
              <div className="onboarding-footer">
                <button
                  className="text-button"
                  onClick={() => setPrivacy(true)}
                >
                  View local safety and privacy
                </button>
                {firstRun && (
                  <button
                    className="button"
                    onClick={() => continueWithout.mutate()}
                    disabled={continueWithout.isPending}
                  >
                    Continue Without Projects
                  </button>
                )}
                {firstRun && (
                  <button
                    className="text-button"
                    onClick={() => continueWithout.mutate()}
                  >
                    Skip optional settings
                  </button>
                )}
              </div>
            </>
          )}
          {mode === "project" && (
            <ProjectPreview
              preview={preview}
              pending={previewOne.isPending}
              onChoose={() => void choose("project")}
              onConfirm={() => preview && save.mutate([preview.summary.path])}
              saving={save.isPending}
            />
          )}
          {mode === "root" && (
            <RootPreview
              items={rootItems}
              selected={selected}
              settings={settings.data}
              pending={previewMany.isPending}
              onToggle={(path) =>
                setSelected((current) => {
                  const next = new Set(current);
                  if (next.has(path)) next.delete(path);
                  else next.add(path);
                  return next;
                })
              }
              onChoose={() => void choose("root")}
              onConfirm={() => save.mutate([...selected])}
              saving={save.isPending}
            />
          )}
          {mode !== "intro" && (
            <button
              className="text-button back-link"
              onClick={() => setMode("intro")}
            >
              Back to options
            </button>
          )}
          {error && (
            <p className="inline-error" role="alert">
              {error instanceof Error
                ? error.message
                : "The selection could not be processed."}
            </p>
          )}
        </div>
      </section>
      {privacy && <SafetyDialog onClose={() => setPrivacy(false)} />}
    </div>
  );
}

function ProjectPreview({
  preview,
  pending,
  onChoose,
  onConfirm,
  saving,
}: {
  preview: ProjectDetail | null;
  pending: boolean;
  onChoose: () => void;
  onConfirm: () => void;
  saving: boolean;
}) {
  if (pending)
    return (
      <div className="preview-loading">
        Inspecting bounded repository metadata…
      </div>
    );
  if (!preview)
    return (
      <button className="button button-primary" onClick={onChoose}>
        <FolderOpen size={16} /> Choose folder
      </button>
    );
  const item = preview.summary;
  return (
    <div className="preview-stack">
      <div className="preview-identity">
        <strong>{item.name}</strong>
        <span>{item.path}</span>
      </div>
      <div className="preview-facts">
        <span>
          Git repository <b>{item.is_git_repository ? "Yes" : "No"}</b>
        </span>
        <span>
          Status <b>{item.status}</b>
        </span>
        <span>
          Technology <b>{item.technologies.join(", ") || "Not detected"}</b>
        </span>
      </div>
      {!item.is_git_repository && (
        <p className="inline-warning">
          This folder is not a Git repository and cannot be added.
        </p>
      )}
      <div className="dialog-actions">
        <button className="button" onClick={onChoose}>
          Choose another
        </button>
        <button
          className="button button-primary"
          disabled={!item.is_git_repository || saving}
          onClick={onConfirm}
        >
          <Check size={16} /> Confirm and add
        </button>
      </div>
    </div>
  );
}

function RootPreview({
  items,
  selected,
  settings,
  pending,
  onToggle,
  onChoose,
  onConfirm,
  saving,
}: {
  items: ProjectSummary[];
  selected: Set<string>;
  settings?: Settings;
  pending: boolean;
  onToggle: (path: string) => void;
  onChoose: () => void;
  onConfirm: () => void;
  saving: boolean;
}) {
  if (pending)
    return (
      <div className="preview-loading">
        Discovering up to depth {settings?.maximum_scan_depth ?? 3} within
        configured limits…
      </div>
    );
  if (!items.length)
    return (
      <div className="preview-stack">
        <p>
          No Git repositories were discovered within depth{" "}
          {settings?.maximum_scan_depth ?? 3}.
        </p>
        <button className="button button-primary" onClick={onChoose}>
          Choose another root
        </button>
      </div>
    );
  return (
    <div className="preview-stack">
      <p className="preview-note">
        Depth {settings?.maximum_scan_depth ?? 3} · maximum{" "}
        {settings?.maximum_repositories_per_root ?? 100} repositories. Deselect
        anything you do not want to retain.
      </p>
      <div className="repository-picker">
        {items.map((item) => (
          <label key={item.id}>
            <input
              type="checkbox"
              checked={selected.has(item.path)}
              onChange={() => onToggle(item.path)}
            />
            <span>
              <strong>{item.name}</strong>
              <small>{item.path}</small>
            </span>
          </label>
        ))}
      </div>
      <div className="dialog-actions">
        <button className="button" onClick={onChoose}>
          Choose another
        </button>
        <button
          className="button button-primary"
          disabled={!selected.size || saving}
          onClick={onConfirm}
        >
          Add {selected.size} selected
        </button>
      </div>
    </div>
  );
}

function SafetyDialog({ onClose }: { onClose: () => void }) {
  const closeRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useFocusTrap<HTMLElement>(true, onClose, closeRef);
  return (
    <div className="modal-backdrop modal-nested">
      <section
        ref={dialogRef}
        className="safety-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="safety-title"
      >
        <LockKeyhole size={24} />
        <h2 id="safety-title">Local safety and privacy</h2>
        <p>
          DevPulse stores selected paths and its own metadata in its dedicated
          application-data folder. Repository inspection is read-only and
          bounded. Project commands, source contents, credentials, full-drive
          discovery, telemetry, and external writes are unavailable.
        </p>
        <button
          ref={closeRef}
          className="button button-primary"
          onClick={onClose}
        >
          Close
        </button>
      </section>
    </div>
  );
}
