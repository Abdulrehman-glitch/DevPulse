mod lifecycle;

use lifecycle::{
    prepare_runtime_environment, qa_path_report, start_core, write_qa_marker, write_qa_path_report,
    CoreConnection, CoreRuntime, DesktopStatus,
};
use serde::Deserialize;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;
use tauri::{Manager, RunEvent};

#[derive(Debug, Deserialize)]
struct RegisteredProjectPath {
    id: String,
    path: String,
}

#[tauri::command]
fn open_project_folder(
    state: tauri::State<'_, CoreRuntime>,
    project_id: String,
) -> Result<(), String> {
    let candidate = resolve_registered_project_path(&state, &project_id)?;
    #[cfg(windows)]
    {
        std::process::Command::new("explorer.exe")
            .arg(candidate)
            .spawn()
            .map(|_| ())
            .map_err(|_| "Windows Explorer could not open the selected folder.".into())
    }
    #[cfg(not(windows))]
    {
        Err("Opening folders is supported only on Windows desktop builds.".into())
    }
}

fn resolve_registered_project_path(
    state: &CoreRuntime,
    project_id: &str,
) -> Result<PathBuf, String> {
    if project_id.len() != 16 || !project_id.bytes().all(|value| value.is_ascii_hexdigit()) {
        return Err("The selected project is not currently registered.".into());
    }
    let connection = state.snapshot();
    let address = connection
        .address
        .ok_or("The local service connection is not ready.")?;
    let token = connection
        .token
        .ok_or("The local service connection is not ready.")?;
    let mut url = reqwest::Url::parse(&address)
        .map_err(|_| "The local service connection is invalid.".to_string())?;
    url.set_path("");
    url.path_segments_mut()
        .map_err(|_| "The local service connection is invalid.".to_string())?
        .extend(["api", "v1", "projects", project_id, "open-path"]);
    let response = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(3))
        .build()
        .map_err(|_| "The registered project could not be verified.".to_string())?
        .get(url)
        .header("X-DevPulse-Token", token)
        .send()
        .map_err(|_| "The registered project could not be verified.".to_string())?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Err("The selected project is not currently registered.".into());
    }
    if !response.status().is_success() {
        return Err("The registered project path is unavailable or unsafe.".into());
    }
    let registration = response
        .json::<RegisteredProjectPath>()
        .map_err(|_| "The registered project path response is invalid.".to_string())?;
    if registration.id != project_id {
        return Err("The registered project path response is invalid.".into());
    }
    canonical_registered_project_path(Path::new(&registration.path))
}

fn canonical_registered_project_path(path: &Path) -> Result<PathBuf, String> {
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir))
    {
        return Err("The registered project path is unavailable or unsafe.".into());
    }
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        let metadata = std::fs::symlink_metadata(&current)
            .map_err(|_| "The registered project path is unavailable or unsafe.".to_string())?;
        #[cfg(windows)]
        let is_reparse_point = {
            use std::os::windows::fs::MetadataExt;
            metadata.file_attributes() & 0x400 != 0
        };
        #[cfg(not(windows))]
        let is_reparse_point = false;
        if metadata.file_type().is_symlink() || is_reparse_point {
            return Err("The registered project path crosses a symbolic link or junction.".into());
        }
    }
    let canonical = std::fs::canonicalize(path)
        .map_err(|_| "The registered project path is unavailable or unsafe.".to_string())?;
    if !canonical.is_dir() {
        return Err("The registered project path is unavailable or unsafe.".into());
    }
    Ok(canonical)
}

#[tauri::command]
fn core_connection(state: tauri::State<'_, CoreRuntime>) -> CoreConnection {
    state.snapshot()
}

#[tauri::command]
fn restart_core(app: tauri::AppHandle) -> Result<CoreConnection, String> {
    start_core(&app, true)
}

#[tauri::command]
fn desktop_status(state: tauri::State<'_, CoreRuntime>) -> DesktopStatus {
    state.desktop_status()
}

#[tauri::command]
fn qa_path_status(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    qa_path_report(&app)
}

#[tauri::command]
fn qa_frontend_checkpoint(
    state: tauri::State<'_, CoreRuntime>,
    checks: serde_json::Value,
) -> Result<(), String> {
    if !state.qa_mode() {
        return Err("QA checkpoints are unavailable outside QA mode.".into());
    }
    let root = state.qa_root().ok_or("QA data root is unavailable.")?;
    let status = state.desktop_status();
    write_qa_marker(
        &root,
        "qa-frontend-checkpoint.json",
        &serde_json::json!({
            "status": "complete",
            "desktopPid": std::process::id(),
            "sidecarPid": status.sidecar_pid,
            "qaMode": true,
            "checks": checks,
        }),
    );
    Ok(())
}

#[tauri::command]
fn qa_visual_checkpoint(state: tauri::State<'_, CoreRuntime>, stage: String) -> Result<(), String> {
    if !state.qa_mode() || !state.install_qa() || !state.qa_automation() {
        return Err("Visual checkpoints require installed QA automation.".into());
    }
    let allowed = [
        "qa-mode-banner",
        "overview-page",
        "projects-page",
        "project-details-page",
        "activity-page",
        "settings-page",
        "diagnostics-page",
    ];
    if !allowed.contains(&stage.as_str()) {
        return Err("The requested visual checkpoint is not allowlisted.".into());
    }
    let root = state.qa_root().ok_or("QA data root is unavailable.")?;
    write_qa_marker(
        &root,
        "qa-visual-checkpoint.json",
        &serde_json::json!({
            "schemaVersion": 1,
            "stage": stage,
            "desktopPid": std::process::id()
        }),
    );
    Ok(())
}

#[tauri::command]
fn complete_install_qa(
    app: tauri::AppHandle,
    state: tauri::State<'_, CoreRuntime>,
    checks: serde_json::Value,
) -> Result<(), String> {
    if !state.qa_mode() || !state.install_qa() || !state.qa_automation() {
        return Err("Installed smoke completion requires both QA gates and QA automation.".into());
    }
    let root = state.qa_root().ok_or("QA data root is unavailable.")?;
    let required = [
        "overviewRendered",
        "frontendConnected",
        "projectListLoaded",
        "settingsLoaded",
        "activityLoaded",
        "qaIsolationConfirmed",
        "frontendQaPathsReceived",
        "webViewQaIsolationConfirmed",
    ];
    let passed = checks.get("automationError").is_none()
        && required
            .iter()
            .all(|name| checks.get(name).and_then(serde_json::Value::as_bool) == Some(true));
    let status = state.desktop_status();
    let exit_code = if passed { 0 } else { 20 };
    write_qa_marker(
        &root,
        "installed-smoke-result.json",
        &serde_json::json!({
            "schemaVersion": 1,
            "status": if passed { "passed" } else { "failed" },
            "exitCode": exit_code,
            "qaMode": true,
            "installQa": true,
            "artificialRepositoriesOnly": true,
            "desktopPid": std::process::id(),
            "sidecarPid": status.sidecar_pid,
            "checks": checks,
        }),
    );
    std::thread::spawn(move || {
        let observed = root.join("installed-smoke-observed.json");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while !observed.is_file() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        app.exit(exit_code);
    });
    Ok(())
}

#[tauri::command]
fn exit_qa_mode(app: tauri::AppHandle, state: tauri::State<'_, CoreRuntime>) -> Result<(), String> {
    if !state.qa_mode() {
        return Err("Exit QA Mode is unavailable outside QA mode.".into());
    }
    app.exit(0);
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let prepared = prepare_runtime_environment().unwrap_or_else(|error| {
        // Refuse before constructing Tauri: configured windows resolve and create their
        // WebView data directory before setup(), so an error UI here would itself violate
        // the QA storage boundary we are protecting.
        eprintln!("DevPulse QA startup refused: {error}");
        std::process::exit(78);
    });
    let qa_mode = prepared.qa_mode;
    let qa_webview_data_directory = prepared.webview_data_directory;
    let mut context = tauri::generate_context!();
    if qa_mode {
        if context.config().app.windows.is_empty() {
            eprintln!("DevPulse QA startup refused: no configured window is available.");
            std::process::exit(78);
        }
        for window in &mut context.config_mut().app.windows {
            // Tauri's config-level dataDirectory accepts only paths relative to the real
            // Windows LocalAppData Known Folder. Suppress auto-creation and construct each
            // QA WebView manually below with the validated absolute directory instead.
            window.create = false;
            window.data_directory = None;
        }
    }
    let mut builder = tauri::Builder::default()
        // Must be registered first so a second process cannot start another sidecar.
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.unminimize();
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init());
    // The window-state plugin reads and writes the normal application-data directory.
    // QA launches deliberately omit it so production state is neither restored nor changed.
    if !qa_mode {
        builder = builder.plugin(tauri_plugin_window_state::Builder::default().build());
    }
    let application = builder
        .manage(CoreRuntime::default())
        .invoke_handler(tauri::generate_handler![
            core_connection,
            restart_core,
            desktop_status,
            qa_path_status,
            qa_frontend_checkpoint,
            qa_visual_checkpoint,
            complete_install_qa,
            exit_qa_mode,
            open_project_folder
        ])
        .setup(move |app| {
            if let Some(data_directory) = &qa_webview_data_directory {
                let window_configs = app.config().app.windows.clone();
                for config in window_configs {
                    tauri::WebviewWindowBuilder::from_config(app.handle(), &config)?
                        .data_directory(data_directory.clone())
                        .build()?;
                }
            }
            write_qa_path_report(app)?;
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                let _ = start_core(&handle, false);
            });
            Ok(())
        })
        .build(context)
        .expect("error while building DevPulse");

    application.run(|app, event| match event {
        RunEvent::ExitRequested { api, .. } => {
            let runtime = app.state::<CoreRuntime>();
            runtime.trace("native-exit-requested", "Tauri exit request received");
            if runtime.begin_shutdown() {
                // Keep the event loop responsive while startup and the local core finish.
                // The window disappears immediately; the process exits after owned cleanup.
                api.prevent_exit();
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                }
                let handle = app.clone();
                std::thread::spawn(move || {
                    handle.state::<CoreRuntime>().trace(
                        "shutdown-worker-started",
                        "close event delegated off the UI thread",
                    );
                    handle.state::<CoreRuntime>().finish_shutdown();
                    handle
                        .state::<CoreRuntime>()
                        .trace("shutdown-exit-dispatched", "requesting final process exit");
                    handle.exit(0);
                });
            }
        }
        RunEvent::Exit => app.state::<CoreRuntime>().shutdown(),
        _ => {}
    });
}

#[cfg(test)]
mod tests {
    use super::canonical_registered_project_path;
    use std::path::Path;
    use uuid::Uuid;

    fn fixture_root() -> std::path::PathBuf {
        std::env::current_dir()
            .expect("current crate directory")
            .join("target")
            .join("open-project-tests")
            .join(Uuid::new_v4().simple().to_string())
    }

    #[test]
    fn registered_project_path_rejects_relative_and_traversal_inputs() {
        assert!(canonical_registered_project_path(Path::new("relative-project")).is_err());
        assert!(canonical_registered_project_path(Path::new(r"C:\fixture\..\escape")).is_err());
    }

    #[test]
    fn registered_project_path_accepts_an_existing_canonical_directory() {
        let root = fixture_root();
        std::fs::create_dir_all(&root).expect("create canonical path fixture");
        let accepted = canonical_registered_project_path(&root).expect("accept canonical path");
        assert_eq!(
            accepted,
            std::fs::canonicalize(&root).expect("canonical fixture")
        );
        std::fs::remove_dir_all(&root).expect("remove canonical path fixture");
    }

    #[cfg(windows)]
    #[test]
    fn registered_project_path_rejects_directory_links_where_supported() {
        use std::os::windows::fs::symlink_dir;

        let fixture = fixture_root();
        let target = fixture.join("target");
        let linked = fixture.join("linked");
        std::fs::create_dir_all(&target).expect("create link target");
        if symlink_dir(&target, &linked).is_err() {
            std::fs::remove_dir_all(&fixture).expect("remove unsupported link fixture");
            return;
        }
        assert!(canonical_registered_project_path(&linked).is_err());
        std::fs::remove_dir(&linked).expect("remove directory link");
        std::fs::remove_dir_all(&fixture).expect("remove link fixture");
    }
}
