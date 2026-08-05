use serde::{Deserialize, Serialize};
#[cfg(debug_assertions)]
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(windows)]
use std::os::windows::fs::MetadataExt;
use std::path::PathBuf;
#[cfg(debug_assertions)]
use std::process::{Child as StdChild, Command as StdCommand, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU8, Ordering};
use std::sync::mpsc;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};
#[cfg(not(debug_assertions))]
use tauri_plugin_shell::process::CommandChild;
#[cfg(not(debug_assertions))]
use tauri_plugin_shell::process::CommandEvent;
#[cfg(not(debug_assertions))]
use tauri_plugin_shell::ShellExt;
use uuid::Uuid;
#[cfg(all(windows, not(debug_assertions)))]
use windows_sys::Win32::{
    Foundation::{CloseHandle, HANDLE},
    System::{
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
        Threading::{
            OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SET_QUOTA, PROCESS_TERMINATE,
        },
    },
};

const MAX_MANUAL_RESTARTS: u8 = 3;
const STARTUP_TIMEOUT: Duration = Duration::from_secs(15);
const STARTUP_PROTOCOL_VERSION: u8 = 1;
const MAX_LAUNCH_FRAME_BYTES: usize = 1024;
const MAX_READY_FRAME_BYTES: usize = 512;
const LAUNCH_FRAME_PREFIX: &str = "DEVPULSE_LAUNCH ";
const READY_FRAME_PREFIX: &str = "DEVPULSE_READY ";
const TAURI_IDENTIFIER: &str = "com.devpulse.desktop";

#[derive(Clone, Debug, PartialEq)]
struct QaPathPlan {
    root: PathBuf,
    roaming_app_data: PathBuf,
    local_app_data: PathBuf,
    tauri_config: PathBuf,
    tauri_data: PathBuf,
    tauri_local_data: PathBuf,
    tauri_cache: PathBuf,
    tauri_log: PathBuf,
    webview2_user_data: PathBuf,
}

impl QaPathPlan {
    fn new(root: PathBuf) -> Result<Self, String> {
        let root = validate_qa_root(&root)?;
        let plan = Self {
            roaming_app_data: root.join("process-env").join("roaming"),
            local_app_data: root.join("process-env").join("local"),
            tauri_config: root.join("tauri").join("config"),
            tauri_data: root.join("tauri").join("data"),
            tauri_local_data: root.join("tauri").join("local-data"),
            tauri_cache: root.join("tauri").join("cache"),
            tauri_log: root.join("tauri").join("logs"),
            webview2_user_data: root.join("webview2"),
            root,
        };
        if [
            &plan.roaming_app_data,
            &plan.local_app_data,
            &plan.tauri_config,
            &plan.tauri_data,
            &plan.tauri_local_data,
            &plan.tauri_cache,
            &plan.tauri_log,
            &plan.webview2_user_data,
        ]
        .iter()
        .any(|path| !path.starts_with(&plan.root))
        {
            return Err("A QA runtime path escaped the validated QA root.".into());
        }
        Ok(plan)
    }

    fn activate(&self) -> Result<(), String> {
        for path in [
            &self.root,
            &self.roaming_app_data,
            &self.local_app_data,
            &self.tauri_config,
            &self.tauri_data,
            &self.tauri_local_data,
            &self.tauri_cache,
            &self.tauri_log,
            &self.webview2_user_data,
        ] {
            std::fs::create_dir_all(path).map_err(|error| {
                format!("Could not create the isolated QA runtime directory: {error}")
            })?;
        }
        // Re-check after creation so a pre-existing junction or link cannot become the
        // process-wide AppData boundary.
        validate_qa_root(&self.root)?;
        for path in [
            &self.roaming_app_data,
            &self.local_app_data,
            &self.tauri_config,
            &self.tauri_data,
            &self.tauri_local_data,
            &self.tauri_cache,
            &self.tauri_log,
            &self.webview2_user_data,
        ] {
            validate_qa_descendant(path, &self.root)?;
        }

        // This is deliberately the first process-level mutation in run(). These variables
        // isolate downstream components that honour process paths. Tauri's Windows resolver
        // uses Known Folder APIs instead, so run() separately suppresses its auto-window and
        // supplies the validated absolute WebView directory through the Rust builder API.
        std::env::set_var("APPDATA", &self.roaming_app_data);
        std::env::set_var("LOCALAPPDATA", &self.local_app_data);
        std::env::set_var("WEBVIEW2_USER_DATA_FOLDER", &self.webview2_user_data);
        std::env::set_var("DEVPULSE_QA_ROOT", &self.root);
        std::env::set_var("DEVPULSE_DATA_DIR", &self.root);
        Ok(())
    }
}

#[derive(Debug)]
struct RuntimeMode {
    enabled: bool,
    automation: bool,
    install_qa: bool,
    root: Option<PathBuf>,
    error: Option<String>,
}

impl RuntimeMode {
    fn from_environment() -> Self {
        Self::from_values(
            std::env::var("DEVPULSE_QA_MODE").ok().as_deref(),
            std::env::var("DEVPULSE_QA_ROOT").ok().as_deref(),
            std::env::var("DEVPULSE_QA_AUTOMATION").ok().as_deref(),
            std::env::var("DEVPULSE_INSTALL_QA").ok().as_deref(),
            std::env::var("DEVPULSE_QA_FAIL_START").ok().as_deref(),
        )
    }

    fn from_values(
        mode: Option<&str>,
        root: Option<&str>,
        automation: Option<&str>,
        install_qa: Option<&str>,
        fail_start: Option<&str>,
    ) -> Self {
        let install_requested = install_qa == Some("1");
        let auxiliary_qa_requested = root.is_some()
            || automation == Some("1")
            || install_requested
            || fail_start == Some("1");
        if mode != Some("1") {
            let explicitly_disabled = matches!(mode, None | Some("0"));
            let error = (!explicitly_disabled || auxiliary_qa_requested).then(|| {
                "QA mode requires DEVPULSE_QA_MODE=1 and an explicit DEVPULSE_QA_ROOT; installed QA also requires DEVPULSE_INSTALL_QA=1.".into()
            });
            return Self {
                // Any attempted partial QA launch must be distinguishable from production
                // so run() can refuse it before Tauri resolves per-user directories.
                enabled: error.is_some(),
                automation: false,
                install_qa: false,
                root: None,
                error,
            };
        }
        if !matches!(automation, None | Some("0") | Some("1"))
            || !matches!(install_qa, None | Some("0") | Some("1"))
            || !matches!(fail_start, None | Some("0") | Some("1"))
        {
            return Self {
                enabled: true,
                automation: false,
                install_qa: false,
                root: None,
                error: Some("QA flags accept only the values 0 or 1.".into()),
            };
        }
        let Some(candidate) = root
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from)
        else {
            return Self {
                enabled: true,
                automation: automation == Some("1"),
                install_qa: install_requested,
                root: None,
                error: Some("QA mode requires an explicit DEVPULSE_QA_ROOT.".into()),
            };
        };
        match validate_qa_root(&candidate) {
            Ok(validated) => Self {
                enabled: true,
                automation: automation == Some("1"),
                install_qa: install_requested,
                root: Some(validated),
                error: None,
            },
            Err(error) => Self {
                enabled: true,
                automation: automation == Some("1"),
                install_qa: install_requested,
                root: None,
                error: Some(error),
            },
        }
    }
}

/// Validate and activate the QA path boundary before Tauri, its plugins, or any
/// configured window can resolve a per-user directory. Production launches do not
/// mutate their environment and retain the normal Tauri/platformdirs behaviour.
pub struct PreparedRuntimeEnvironment {
    pub qa_mode: bool,
    pub webview_data_directory: Option<PathBuf>,
}

pub fn prepare_runtime_environment() -> Result<PreparedRuntimeEnvironment, String> {
    let mode = RuntimeMode::from_environment();
    if let Some(error) = mode.error {
        return Err(error);
    }
    if !mode.enabled {
        return Ok(PreparedRuntimeEnvironment {
            qa_mode: false,
            webview_data_directory: None,
        });
    }
    let root = mode
        .root
        .ok_or("QA mode does not have a validated runtime root.")?;
    let plan = QaPathPlan::new(root)?;
    plan.activate()?;
    Ok(PreparedRuntimeEnvironment {
        qa_mode: true,
        webview_data_directory: Some(plan.webview2_user_data),
    })
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreConnection {
    pub status: CoreStatus,
    pub address: Option<String>,
    pub token: Option<String>,
    pub version: Option<String>,
    pub message: Option<String>,
    pub diagnostics_path: Option<String>,
    pub qa_mode: bool,
    pub qa_automation: bool,
    pub install_qa: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopStatus {
    pub sidecar_process_status: String,
    pub process_uptime_seconds: u64,
    pub application_data_location: Option<String>,
    pub log_directory_location: Option<String>,
    pub sidecar_pid: Option<u32>,
    pub qa_mode: bool,
    pub install_qa: bool,
    pub startup_duration_ms: u64,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum CoreStatus {
    Starting,
    Ready,
    Error,
    Stopped,
}

#[derive(Debug)]
struct ReadyHandshake {
    address: String,
    instance_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadyFrame {
    protocol_version: u8,
    port: u16,
    pid: u32,
    status: String,
    instance_id: String,
}

#[derive(Serialize)]
struct LaunchFrame<'a> {
    protocol_version: u8,
    token: &'a str,
}

pub enum ManagedChild {
    #[cfg(not(debug_assertions))]
    Sidecar(CommandChild),
    #[cfg(debug_assertions)]
    Development(StdChild),
}

#[cfg(all(windows, not(debug_assertions)))]
struct OwnedJob(HANDLE);

#[cfg(all(windows, not(debug_assertions)))]
unsafe impl Send for OwnedJob {}

#[cfg(all(windows, not(debug_assertions)))]
impl OwnedJob {
    fn for_process(pid: u32) -> Result<Self, String> {
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
                return Err("Could not create the local-service ownership boundary.".into());
            }
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as *const std::ffi::c_void,
                std::mem::size_of_val(&limits) as u32,
            ) == 0
            {
                CloseHandle(job);
                return Err("Could not configure the local-service ownership boundary.".into());
            }
            let process = OpenProcess(
                PROCESS_SET_QUOTA | PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION,
                0,
                pid,
            );
            if process.is_null() || AssignProcessToJobObject(job, process) == 0 {
                if !process.is_null() {
                    CloseHandle(process);
                }
                CloseHandle(job);
                return Err("Could not assign the local service to its ownership boundary.".into());
            }
            CloseHandle(process);
            Ok(Self(job))
        }
    }
}

#[cfg(all(windows, not(debug_assertions)))]
impl Drop for OwnedJob {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

impl ManagedChild {
    fn kill(self) {
        match self {
            #[cfg(not(debug_assertions))]
            Self::Sidecar(child) => {
                let _ = child.kill();
            }
            #[cfg(debug_assertions)]
            Self::Development(mut child) => {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
}

pub struct CoreRuntime {
    pub child: Mutex<Option<ManagedChild>>,
    pub connection: Mutex<CoreConnection>,
    start_lock: Mutex<()>,
    data_dir: Mutex<Option<PathBuf>>,
    restart_count: AtomicU8,
    shutting_down: AtomicBool,
    sidecar_pid: AtomicU32,
    #[cfg(all(windows, not(debug_assertions)))]
    sidecar_job: Mutex<Option<OwnedJob>>,
    startup_duration_ms: AtomicU32,
    started: Instant,
    qa_mode: bool,
    qa_automation: bool,
    install_qa: bool,
    qa_root: Option<PathBuf>,
    mode_error: Option<String>,
}

impl Default for CoreRuntime {
    fn default() -> Self {
        let mode = RuntimeMode::from_environment();
        Self {
            child: Mutex::new(None),
            connection: Mutex::new(CoreConnection {
                status: CoreStatus::Starting,
                address: None,
                token: None,
                version: None,
                message: None,
                diagnostics_path: None,
                qa_mode: mode.enabled,
                qa_automation: mode.automation,
                install_qa: mode.install_qa,
            }),
            start_lock: Mutex::new(()),
            data_dir: Mutex::new(None),
            restart_count: AtomicU8::new(0),
            shutting_down: AtomicBool::new(false),
            sidecar_pid: AtomicU32::new(0),
            #[cfg(all(windows, not(debug_assertions)))]
            sidecar_job: Mutex::new(None),
            startup_duration_ms: AtomicU32::new(0),
            started: Instant::now(),
            qa_mode: mode.enabled,
            qa_automation: mode.automation,
            install_qa: mode.install_qa,
            qa_root: mode.root,
            mode_error: mode.error,
        }
    }
}

impl CoreRuntime {
    pub fn trace(&self, state: &str, detail: &str) {
        if !self.qa_mode {
            return;
        }
        let Some(root) = self.qa_root.as_ref() else {
            return;
        };
        let path = root.join("lifecycle-state.jsonl");
        let timestamp_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_millis())
            .unwrap_or_default();
        let payload = serde_json::json!({
            "timestampUnixMs": timestamp_ms,
            "state": state,
            "detail": detail,
            "desktopPid": std::process::id(),
            "sidecarPid": self.sidecar_pid.load(Ordering::SeqCst),
            "shutdownRequested": self.shutting_down.load(Ordering::SeqCst),
        });
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            use std::io::Write;
            let _ = writeln!(file, "{payload}");
        }
    }

    pub fn snapshot(&self) -> CoreConnection {
        self.connection
            .lock()
            .expect("core connection lock")
            .clone()
    }

    pub fn shutdown(&self) {
        if self.begin_shutdown() {
            self.finish_shutdown();
        }
    }

    pub fn begin_shutdown(&self) -> bool {
        !self.shutting_down.swap(true, Ordering::SeqCst)
    }

    pub fn finish_shutdown(&self) {
        // Startup owns this lock from before spawning until the authenticated health check
        // finishes. Waiting here prevents an early window close from killing PyInstaller's
        // launcher while its worker process is still being created.
        self.trace("shutdown-worker-entered", "startup lock pending");
        let _start_guard = self.start_lock.lock().expect("core startup lock");
        self.trace(
            "shutdown-startup-lock-acquired",
            "owned startup operation is quiescent",
        );
        self.stop_child_gracefully();
        self.trace("shutdown-worker-finished", "owned sidecar cleanup complete");
        self.connection.lock().expect("core connection lock").status = CoreStatus::Stopped;
    }

    fn stop_child_gracefully(&self) {
        let connection = self.snapshot();
        if let (Some(address), Some(token)) = (connection.address, connection.token) {
            self.trace("shutdown-request-sending", "authenticated loopback request");
            request_shutdown(&address, &token);
            self.trace("shutdown-request-sent", "loopback request returned");
            #[cfg(not(debug_assertions))]
            {
                // A PyInstaller worker can still be finishing a bounded repository scan
                // after accepting shutdown. Killing its launcher too early detaches that
                // worker, so wait for the owned launcher termination event first.
                let deadline = Instant::now() + Duration::from_secs(15);
                while self.sidecar_pid.load(Ordering::SeqCst) != 0 && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(100));
                }
                self.trace(
                    "shutdown-sidecar-wait-complete",
                    if self.sidecar_pid.load(Ordering::SeqCst) == 0 {
                        "termination event acknowledged"
                    } else {
                        "termination event not acknowledged before bounded wait"
                    },
                );
            }
            #[cfg(debug_assertions)]
            std::thread::sleep(Duration::from_millis(600));
        }
        if let Some(child) = self.child.lock().expect("core child lock").take() {
            if self.sidecar_pid.load(Ordering::SeqCst) != 0 {
                self.trace(
                    "shutdown-owned-kill",
                    "termination acknowledgement unavailable; killing exact owned child",
                );
                child.kill();
            }
        }
        #[cfg(all(windows, not(debug_assertions)))]
        self.sidecar_job.lock().expect("sidecar job lock").take();
        self.sidecar_pid.store(0, Ordering::SeqCst);
        self.trace("shutdown-child-state-cleared", "owned child state cleared");
    }

    pub fn desktop_status(&self) -> DesktopStatus {
        let running = self.child.lock().expect("core child lock").is_some();
        let data_dir = self.data_dir.lock().expect("data directory lock").clone();
        DesktopStatus {
            sidecar_process_status: if running { "running" } else { "stopped" }.into(),
            process_uptime_seconds: self.started.elapsed().as_secs(),
            application_data_location: data_dir
                .as_ref()
                .map(|path| path.to_string_lossy().into_owned()),
            log_directory_location: data_dir
                .as_ref()
                .map(|path| path.join("logs").to_string_lossy().into_owned()),
            sidecar_pid: match self.sidecar_pid.load(Ordering::SeqCst) {
                0 => None,
                value => Some(value),
            },
            qa_mode: self.qa_mode,
            install_qa: self.install_qa,
            startup_duration_ms: self.startup_duration_ms.load(Ordering::SeqCst) as u64,
        }
    }

    pub fn qa_mode(&self) -> bool {
        self.qa_mode
    }

    pub fn qa_root(&self) -> Option<PathBuf> {
        self.qa_root.clone()
    }

    pub fn install_qa(&self) -> bool {
        self.install_qa
    }

    pub fn qa_automation(&self) -> bool {
        self.qa_automation
    }

    fn data_dir_for(
        &self,
        production_data_dir: Option<&std::path::Path>,
    ) -> Result<PathBuf, String> {
        select_runtime_data_directory(self.qa_mode, self.qa_root.as_deref(), production_data_dir)
    }

    fn prepare_restart(&self) -> Result<(), String> {
        let count = self.restart_count.fetch_add(1, Ordering::SeqCst) + 1;
        if count > MAX_MANUAL_RESTARTS {
            return Err(
                "The local service restart limit was reached. Restart DevPulse to try again."
                    .into(),
            );
        }
        self.stop_child_gracefully();
        Ok(())
    }
}

fn select_runtime_data_directory(
    qa_mode: bool,
    qa_root: Option<&std::path::Path>,
    production_data_dir: Option<&std::path::Path>,
) -> Result<PathBuf, String> {
    if qa_mode {
        return qa_root
            .map(std::path::Path::to_path_buf)
            .ok_or("QA mode does not have a valid isolated data root.".into());
    }
    production_data_dir
        .map(std::path::Path::to_path_buf)
        .ok_or("Production application-data resolution was unavailable.".into())
}

pub fn start_core(app: &AppHandle, manual_restart: bool) -> Result<CoreConnection, String> {
    let startup_started = Instant::now();
    let runtime = app.state::<CoreRuntime>();
    runtime.trace(
        "core-start-requested",
        if manual_restart {
            "manual restart"
        } else {
            "initial start"
        },
    );
    let _start_guard = runtime.start_lock.lock().expect("core startup lock");
    if runtime.shutting_down.load(Ordering::SeqCst) {
        return Err("The application is shutting down.".into());
    }
    if let Some(message) = runtime.mode_error.clone() {
        return Err(message);
    }
    if manual_restart {
        runtime.prepare_restart()?;
    } else if runtime.child.lock().expect("core child lock").is_some() {
        return Ok(runtime.snapshot());
    }

    // Never invoke Tauri's Known Folder-backed AppData resolver in QA mode. The explicit
    // DevPulse QA resolver is the only writable root for the desktop and local core.
    let production_data_dir = if runtime.qa_mode {
        None
    } else {
        Some(
            app.path()
                .app_data_dir()
                .map_err(|error| error.to_string())?,
        )
    };
    let data_dir = runtime.data_dir_for(production_data_dir.as_deref())?;
    std::fs::create_dir_all(&data_dir).map_err(|error| error.to_string())?;
    *runtime.data_dir.lock().expect("data directory lock") = Some(data_dir.clone());
    let diagnostics = diagnostics_path(&data_dir);
    let token = new_session_token();
    *runtime.connection.lock().expect("core connection lock") = CoreConnection {
        status: CoreStatus::Starting,
        address: None,
        token: None,
        version: None,
        message: None,
        diagnostics_path: Some(diagnostics.to_string_lossy().into_owned()),
        qa_mode: runtime.qa_mode,
        qa_automation: runtime.qa_automation,
        install_qa: runtime.install_qa,
    };

    let result = spawn_core(app, &data_dir, &token).and_then(|handshake| {
        verify_health(&handshake, &token).map(|version| (handshake, version))
    });

    match result {
        Ok((handshake, version)) => {
            runtime.trace(
                "core-authenticated-ready",
                "sidecar handshake and health check passed",
            );
            runtime.startup_duration_ms.store(
                startup_started.elapsed().as_millis().min(u32::MAX as u128) as u32,
                Ordering::SeqCst,
            );
            record_lifecycle_event(
                &handshake.address,
                &token,
                if manual_restart {
                    "core-restarted"
                } else {
                    "application-started"
                },
            );
            let connection = CoreConnection {
                status: CoreStatus::Ready,
                address: Some(handshake.address),
                token: Some(token),
                version: Some(version),
                message: None,
                diagnostics_path: Some(diagnostics.to_string_lossy().into_owned()),
                qa_mode: runtime.qa_mode,
                qa_automation: runtime.qa_automation,
                install_qa: runtime.install_qa,
            };
            *runtime.connection.lock().expect("core connection lock") = connection.clone();
            Ok(connection)
        }
        Err(message) => {
            runtime.trace("core-start-failed", &message);
            if let Some(child) = runtime.child.lock().expect("core child lock").take() {
                child.kill();
            }
            #[cfg(all(windows, not(debug_assertions)))]
            runtime.sidecar_job.lock().expect("sidecar job lock").take();
            let connection = CoreConnection {
                status: CoreStatus::Error,
                address: None,
                token: None,
                version: None,
                message: Some(message.clone()),
                diagnostics_path: Some(diagnostics.to_string_lossy().into_owned()),
                qa_mode: runtime.qa_mode,
                qa_automation: runtime.qa_automation,
                install_qa: runtime.install_qa,
            };
            *runtime.connection.lock().expect("core connection lock") = connection;
            if runtime.qa_mode {
                write_qa_marker(
                    &data_dir,
                    "qa-startup-failure.json",
                    &serde_json::json!({"status": "error", "code": classify_startup_error(&message)}),
                );
            }
            Err(message)
        }
    }
}

fn sidecar_arguments(data_dir: &std::path::Path, qa_mode: bool) -> Vec<String> {
    let mut arguments = vec![
        "--host".to_string(),
        "127.0.0.1".to_string(),
        "--port".to_string(),
        "0".to_string(),
        "--data-dir".to_string(),
        data_dir.to_string_lossy().into_owned(),
    ];
    if qa_mode {
        arguments.push("--qa-mode".to_string());
    }
    arguments
}

fn launch_message(token: &str) -> Result<Vec<u8>, String> {
    let payload = serde_json::to_vec(&LaunchFrame {
        protocol_version: STARTUP_PROTOCOL_VERSION,
        token,
    })
    .map_err(|_| "Could not encode the local service launch frame.".to_string())?;
    let mut message = Vec::with_capacity(LAUNCH_FRAME_PREFIX.len() + payload.len() + 1);
    message.extend_from_slice(LAUNCH_FRAME_PREFIX.as_bytes());
    message.extend_from_slice(&payload);
    message.push(b'\n');
    if message.len() > MAX_LAUNCH_FRAME_BYTES {
        return Err("The local service launch frame exceeded its bound.".into());
    }
    Ok(message)
}

fn parse_ready_frame(frame: &[u8]) -> Result<ReadyHandshake, String> {
    if frame.len() > MAX_READY_FRAME_BYTES {
        return Err("The local service readiness frame exceeded its bound.".into());
    }
    let frame = frame.strip_suffix(b"\r").unwrap_or(frame);
    let payload = frame
        .strip_prefix(READY_FRAME_PREFIX.as_bytes())
        .ok_or("The local service returned an invalid readiness frame.")?;
    let ready: ReadyFrame = serde_json::from_slice(payload)
        .map_err(|_| "The local service returned malformed readiness data.".to_string())?;
    if ready.protocol_version != STARTUP_PROTOCOL_VERSION
        || ready.status != "ready"
        || ready.port == 0
        || ready.pid == 0
        || ready.instance_id.len() != 32
        || !ready
            .instance_id
            .bytes()
            .all(|value| value.is_ascii_hexdigit())
    {
        return Err("The local service returned invalid readiness data.".into());
    }
    Ok(ReadyHandshake {
        address: format!("http://127.0.0.1:{}", ready.port),
        instance_id: ready.instance_id,
    })
}

#[cfg(not(debug_assertions))]
fn spawn_core(
    app: &AppHandle,
    data_dir: &std::path::Path,
    token: &str,
) -> Result<ReadyHandshake, String> {
    let arguments = sidecar_arguments(data_dir, app.state::<CoreRuntime>().qa_mode);
    let launch = launch_message(token)?;
    let mut sidecar = app
        .shell()
        .sidecar("devpulse-local-core")
        .map_err(|error| format!("The packaged local service is unavailable: {error}"))?
        .args(arguments);
    let runtime = app.state::<CoreRuntime>();
    if runtime.qa_mode {
        let root = runtime
            .qa_root
            .as_ref()
            .ok_or("The packaged local service requires a validated QA root.")?
            .to_string_lossy()
            .into_owned();
        sidecar = sidecar
            .env("DEVPULSE_QA_MODE", "1")
            .env(
                "DEVPULSE_INSTALL_QA",
                if runtime.install_qa { "1" } else { "0" },
            )
            .env("DEVPULSE_QA_ROOT", &root)
            .env("DEVPULSE_DATA_DIR", &root);
        for name in ["APPDATA", "LOCALAPPDATA", "WEBVIEW2_USER_DATA_FOLDER"] {
            let value = std::env::var(name)
                .map_err(|_| format!("The isolated QA environment is missing {name}."))?;
            sidecar = sidecar.env(name, value);
        }
        if std::env::var("DEVPULSE_QA_FAIL_START").as_deref() == Ok("1") {
            sidecar = sidecar.env("DEVPULSE_QA_FAIL_START", "1");
        }
    }
    let (mut events, mut child) = sidecar
        .spawn()
        .map_err(|error| format!("Could not start the local service: {error}"))?;
    if child.write(&launch).is_err() {
        let _ = child.kill();
        return Err("Could not write the local service launch frame.".into());
    }
    let pid = child.pid();
    app.state::<CoreRuntime>()
        .trace("sidecar-process-spawned", "packaged sidecar child created");
    let owned_job = match OwnedJob::for_process(pid) {
        Ok(job) => job,
        Err(error) => {
            let _ = child.kill();
            return Err(error);
        }
    };
    app.state::<CoreRuntime>()
        .sidecar_pid
        .store(pid, Ordering::SeqCst);
    *app.state::<CoreRuntime>()
        .sidecar_job
        .lock()
        .expect("sidecar job lock") = Some(owned_job);
    *app.state::<CoreRuntime>()
        .child
        .lock()
        .expect("core child lock") = Some(ManagedChild::Sidecar(child));
    let (startup_tx, startup_rx) = mpsc::sync_channel(1);
    let monitor_app = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut startup_sender = Some(startup_tx);
        while let Some(event) = events.recv().await {
            match event {
                CommandEvent::Stdout(frame) => {
                    if let Some(sender) = startup_sender.take() {
                        let parsed = parse_ready_frame(&frame);
                        let valid = parsed.is_ok();
                        let _ = sender.send(parsed);
                        if !valid {
                            break;
                        }
                    }
                }
                CommandEvent::Stderr(_) => {
                    monitor_app.state::<CoreRuntime>().trace(
                        "sidecar-diagnostic-event",
                        "local service wrote a diagnostic",
                    );
                }
                CommandEvent::Error(_) => {
                    if let Some(sender) = startup_sender.take() {
                        let _ =
                            sender.send(Err("The local service startup channel failed.".into()));
                    }
                    break;
                }
                CommandEvent::Terminated(_) => {
                    let runtime = monitor_app.state::<CoreRuntime>();
                    if let Some(sender) = startup_sender.take() {
                        let _ =
                            sender.send(Err("The local service exited before readiness.".into()));
                    }
                    runtime.sidecar_pid.store(0, Ordering::SeqCst);
                    runtime.trace(
                        "sidecar-termination-event",
                        "Tauri shell reported sidecar termination",
                    );
                    if !runtime.shutting_down.load(Ordering::SeqCst) {
                        let mut connection =
                            runtime.connection.lock().expect("core connection lock");
                        connection.status = CoreStatus::Error;
                        connection.message = Some("The local service stopped unexpectedly. Use Retry startup to restart it.".into());
                        connection.address = None;
                        connection.token = None;
                    }
                    break;
                }
            }
        }
    });
    startup_rx
        .recv_timeout(STARTUP_TIMEOUT)
        .map_err(|_| "The local service did not become ready within 15 seconds.".to_string())?
}

#[cfg(debug_assertions)]
fn spawn_core(
    app: &AppHandle,
    data_dir: &std::path::Path,
    token: &str,
) -> Result<ReadyHandshake, String> {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let repository = manifest
        .join("../../..")
        .canonicalize()
        .map_err(|error| error.to_string())?;
    let python = repository.join(".venv/Scripts/python.exe");
    if validate_executable(&python).is_err() {
        return Err(
            "Development Python environment is missing. Create .venv and install .[dev].".into(),
        );
    }
    let qa_mode = app.state::<CoreRuntime>().qa_mode;
    let launch = launch_message(token)?;
    let mut command = StdCommand::new(python);
    command
        .current_dir(&repository)
        .env("PYTHONPATH", repository.join("services/local-core"))
        .arg("-m")
        .arg("devpulse_core")
        .args(sidecar_arguments(data_dir, qa_mode))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::piped());
    if qa_mode {
        let runtime = app.state::<CoreRuntime>();
        let root = runtime
            .qa_root
            .as_ref()
            .ok_or("The development local core requires a validated QA root.")?;
        command
            .env("DEVPULSE_QA_MODE", "1")
            .env(
                "DEVPULSE_INSTALL_QA",
                if runtime.install_qa { "1" } else { "0" },
            )
            .env("DEVPULSE_QA_ROOT", root)
            .env("DEVPULSE_DATA_DIR", root);
        if std::env::var("DEVPULSE_QA_FAIL_START").as_deref() == Ok("1") {
            command.env("DEVPULSE_QA_FAIL_START", "1");
        }
    } else {
        command.env("DEVPULSE_DEV_PROJECT_DIR", &repository);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let mut child = command
        .spawn()
        .map_err(|error| format!("Could not start development local core: {error}"))?;
    let write_result = child
        .stdin
        .take()
        .ok_or("The local service did not provide a launch channel.")
        .and_then(|mut stdin| {
            stdin
                .write_all(&launch)
                .and_then(|_| stdin.flush())
                .map_err(|_| "Could not write the local service launch frame.")
        });
    if let Err(error) = write_result {
        let _ = child.kill();
        let _ = child.wait();
        return Err(error.into());
    }
    let stdout = child
        .stdout
        .take()
        .ok_or("The local service did not provide a startup channel.")?;
    if let Some(mut stderr) = child.stderr.take() {
        std::thread::spawn(move || {
            let _ = std::io::copy(&mut stderr, &mut std::io::sink());
        });
    }
    let (tx, rx) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let reader = BufReader::new(stdout);
        let mut bounded = reader.take((MAX_READY_FRAME_BYTES + 2) as u64);
        let mut line = Vec::new();
        let result = bounded
            .read_until(b'\n', &mut line)
            .map_err(|_| "The local service startup channel failed.".to_string())
            .and_then(|count| {
                if count == 0 || line.len() > MAX_READY_FRAME_BYTES + 1 || !line.ends_with(b"\n") {
                    return Err("The local service returned an invalid readiness frame.".into());
                }
                line.pop();
                parse_ready_frame(&line)
            });
        let _ = tx.send(result);
    });
    let pid = child.id();
    app.state::<CoreRuntime>()
        .sidecar_pid
        .store(pid, Ordering::SeqCst);
    *app.state::<CoreRuntime>()
        .child
        .lock()
        .expect("core child lock") = Some(ManagedChild::Development(child));
    rx.recv_timeout(STARTUP_TIMEOUT)
        .map_err(|_| "The local service did not become ready within 15 seconds.".to_string())?
}

fn new_session_token() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

fn diagnostics_path(data_dir: &std::path::Path) -> PathBuf {
    data_dir.join("logs").join("local-core.log")
}

fn validate_qa_root(path: &std::path::Path) -> Result<PathBuf, String> {
    if !path.is_absolute() || path.as_os_str().is_empty() {
        return Err("QA mode requires a non-empty absolute data root.".into());
    }
    if path
        .components()
        .any(|part| matches!(part, std::path::Component::ParentDir))
    {
        return Err("QA data root cannot contain parent traversal.".into());
    }
    if path.parent().is_none() {
        return Err("QA data root cannot be a filesystem root.".into());
    }
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    if name != ".qa-runtime" && !name.starts_with("DevPulse-QA") {
        return Err("QA data root must be a clearly named DevPulse QA directory.".into());
    }
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        if let Ok(metadata) = std::fs::symlink_metadata(&current) {
            #[cfg(windows)]
            let is_reparse_point = metadata.file_attributes() & 0x400 != 0;
            #[cfg(not(windows))]
            let is_reparse_point = false;
            if metadata.file_type().is_symlink() || is_reparse_point {
                return Err("QA data root cannot cross a symbolic link or junction.".into());
            }
        }
    }
    if path.join(".git").exists() {
        return Err("QA data root cannot be source controlled.".into());
    }
    Ok(path.to_path_buf())
}

fn validate_qa_descendant(path: &std::path::Path, root: &std::path::Path) -> Result<(), String> {
    if !path.starts_with(root) || path == root {
        return Err("A QA runtime path is not a descendant of the validated QA root.".into());
    }
    let mut current = root.to_path_buf();
    for component in path
        .strip_prefix(root)
        .map_err(|_| "A QA runtime path escaped the validated QA root.")?
        .components()
    {
        if matches!(component, std::path::Component::ParentDir) {
            return Err("A QA runtime path cannot contain parent traversal.".into());
        }
        current.push(component.as_os_str());
        if let Ok(metadata) = std::fs::symlink_metadata(&current) {
            #[cfg(windows)]
            let is_reparse_point = metadata.file_attributes() & 0x400 != 0;
            #[cfg(not(windows))]
            let is_reparse_point = false;
            if metadata.file_type().is_symlink() || is_reparse_point {
                return Err("A QA runtime path cannot cross a symbolic link or junction.".into());
            }
        }
    }
    Ok(())
}

fn classify_startup_error(message: &str) -> &'static str {
    if message.contains("credential") {
        "authentication_failed"
    } else if message.contains("15 seconds") {
        "startup_timeout"
    } else if message.contains("unavailable") || message.contains("missing") {
        "sidecar_unavailable"
    } else {
        "sidecar_startup_failed"
    }
}

pub fn write_qa_marker(data_dir: &std::path::Path, name: &str, payload: &serde_json::Value) {
    if !matches!(
        name,
        "qa-startup-failure.json"
            | "qa-frontend-checkpoint.json"
            | "installed-smoke-result.json"
            | "qa-path-report.json"
            | "qa-visual-checkpoint.json"
    ) {
        return;
    }
    let temporary = data_dir.join(format!("{name}.tmp"));
    let destination = data_dir.join(name);
    if let Ok(content) = serde_json::to_string_pretty(payload) {
        if std::fs::write(&temporary, format!("{content}\n")).is_ok() {
            let _ = std::fs::rename(temporary, destination);
        }
    }
}

pub fn qa_path_report(app: &AppHandle) -> Result<serde_json::Value, String> {
    let runtime = app.state::<CoreRuntime>();
    if !runtime.qa_mode {
        return Err("QA path reporting is unavailable outside QA mode.".into());
    }
    let root = runtime
        .qa_root
        .clone()
        .ok_or("QA path reporting requires a validated QA root.")?;
    let expected = QaPathPlan::new(root.clone())?;
    let environment_app_data = std::env::var_os("APPDATA").map(PathBuf::from);
    let environment_local_app_data = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    let environment_webview = std::env::var_os("WEBVIEW2_USER_DATA_FOLDER").map(PathBuf::from);
    let environment_data_dir = std::env::var_os("DEVPULSE_DATA_DIR").map(PathBuf::from);
    let writable_paths = vec![
        expected.tauri_config.clone(),
        expected.tauri_data.clone(),
        expected.tauri_local_data.clone(),
        expected.tauri_cache.clone(),
        expected.tauri_log.clone(),
        expected.webview2_user_data.clone(),
        root.clone(),
        root.join("cache"),
        root.join("logs"),
        root.join("test-lab"),
        root.join("diagnostics"),
        root.join("activity/events-v1.json"),
    ];
    let environment_matches_plan = environment_app_data.as_ref()
        == Some(&expected.roaming_app_data)
        && environment_local_app_data.as_ref() == Some(&expected.local_app_data)
        && environment_webview.as_ref() == Some(&expected.webview2_user_data)
        && environment_data_dir.as_ref() == Some(&root);
    let window_configs = &app.config().app.windows;
    let tauri_webview_matches_plan = !window_configs.is_empty()
        && window_configs.iter().all(|config| {
            !config.create
                && config.data_directory.is_none()
                && app.get_webview_window(&config.label).is_some()
        });
    let all_under_qa_root = environment_matches_plan
        && tauri_webview_matches_plan
        && writable_paths.iter().all(|path| path.starts_with(&root))
        && [
            environment_app_data.as_ref(),
            environment_local_app_data.as_ref(),
            environment_webview.as_ref(),
            environment_data_dir.as_ref(),
        ]
        .iter()
        .all(|path| path.is_some_and(|value| value.starts_with(&root)));
    Ok(serde_json::json!({
        "schemaVersion": 2,
        "qaMode": true,
        "installQa": runtime.install_qa,
        "tauriIdentifier": TAURI_IDENTIFIER,
        "qaRoot": root,
        "tauriAppConfigurationDirectory": expected.tauri_config,
        "tauriAppDataDirectory": expected.tauri_data,
        "tauriLocalDataDirectory": expected.tauri_local_data,
        "tauriCacheDirectory": expected.tauri_cache,
        "tauriLogDirectory": expected.tauri_log,
        "tauriPathResolutionSource": "DevPulse explicit QA resolver; Tauri Known Folder resolvers bypassed",
        "tauriBuiltInAppDataResolversUsed": false,
        "webView2UserDataDirectory": expected.webview2_user_data,
        "webView2ResolutionSource": "Tauri WebviewWindowBuilder absolute data_directory",
        "configuredWindowLabels": window_configs.iter().map(|config| &config.label).collect::<Vec<_>>(),
        "pythonLocalCoreConfigurationDirectory": root,
        "pythonCacheDirectory": root.join("cache"),
        "pythonLogDirectory": root.join("logs"),
        "qaRepositoryDirectory": root.join("test-lab"),
        "diagnosticsExportDirectory": root.join("diagnostics"),
        "activityStorage": root.join("activity/events-v1.json"),
        "updaterStorage": { "enabled": false, "path": null },
        "pluginStorage": {
            "dialog": null,
            "shell": null,
            "singleInstance": null,
            "windowState": serde_json::Value::Null
        },
        "processEnvironment": {
            "appData": environment_app_data,
            "localAppData": environment_local_app_data,
            "webView2UserDataFolder": environment_webview,
            "devpulseDataDirectory": environment_data_dir,
            "qaRoot": std::env::var_os("DEVPULSE_QA_ROOT").map(PathBuf::from),
            "qaModePresent": std::env::var("DEVPULSE_QA_MODE").ok().as_deref() == Some("1"),
            "installQaPresent": std::env::var("DEVPULSE_INSTALL_QA").ok().as_deref() == Some("1")
        },
        "environmentMatchesCanonicalPlan": environment_matches_plan,
        "tauriWebViewDirectoryMatchesCanonicalPlan": tauri_webview_matches_plan,
        "allWritablePathsUnderQaRoot": all_under_qa_root
    }))
}

pub fn write_qa_path_report(app: &tauri::App) -> Result<(), String> {
    if !app.state::<CoreRuntime>().qa_mode {
        return Ok(());
    }
    let root = app
        .state::<CoreRuntime>()
        .qa_root
        .clone()
        .ok_or("QA path reporting requires a validated QA root.")?;
    let report = qa_path_report(app.handle())?;
    write_qa_marker(&root, "qa-path-report.json", &report);
    Ok(())
}

#[cfg(debug_assertions)]
fn validate_executable(path: &std::path::Path) -> Result<(), String> {
    if path.is_file() {
        Ok(())
    } else {
        Err(format!(
            "Local service executable is missing: {}",
            path.display()
        ))
    }
}

fn verify_health(handshake: &ReadyHandshake, token: &str) -> Result<String, String> {
    if !valid_loopback_address(&handshake.address) || handshake.instance_id.is_empty() {
        return Err("The local service returned an unsafe address.".into());
    }
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(1))
        .build()
        .map_err(|error| error.to_string())?;
    for _ in 0..20 {
        if let Ok(response) = client
            .get(format!("{}/health", handshake.address))
            .header("X-DevPulse-Token", token)
            .send()
        {
            if response.status().is_success() {
                let payload: serde_json::Value =
                    response.json().map_err(|error| error.to_string())?;
                if payload.get("instance_id").and_then(|value| value.as_str())
                    == Some(handshake.instance_id.as_str())
                {
                    return Ok(payload
                        .get("version")
                        .and_then(|value| value.as_str())
                        .unwrap_or("unknown")
                        .to_string());
                }
            }
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    Err("The local service started but did not pass its health check.".into())
}

fn record_lifecycle_event(address: &str, token: &str, event: &str) {
    let _ = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(1))
        .build()
        .and_then(|client| {
            client
                .post(format!("{address}/internal/events/{event}"))
                .header("X-DevPulse-Token", token)
                .send()
        });
}

fn request_shutdown(address: &str, token: &str) {
    let _ = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(1))
        .build()
        .and_then(|client| {
            client
                .post(format!("{address}/internal/shutdown"))
                .header("X-DevPulse-Token", token)
                .send()
        });
}

fn valid_loopback_address(address: &str) -> bool {
    let Ok(url) = reqwest::Url::parse(address) else {
        return false;
    };
    url.scheme() == "http"
        && url.host_str() == Some("127.0.0.1")
        && url.port().is_some_and(|port| port > 0)
        && url.path() == "/"
        && url.query().is_none()
        && url.fragment().is_none()
        && url.username().is_empty()
        && url.password().is_none()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{mpsc, Arc};

    #[test]
    fn runtime_prevents_unbounded_restart_loops() {
        let runtime = CoreRuntime::default();
        assert!(runtime.prepare_restart().is_ok());
        assert!(runtime.prepare_restart().is_ok());
        assert!(runtime.prepare_restart().is_ok());
        assert!(runtime.prepare_restart().is_err());
    }

    #[test]
    fn runtime_starts_without_a_child_process() {
        let runtime = CoreRuntime::default();
        assert_eq!(runtime.snapshot().status, CoreStatus::Starting);
        assert!(runtime.child.lock().expect("child lock").is_none());
    }

    #[test]
    fn session_address_requires_a_valid_loopback_port() {
        assert!(valid_loopback_address("http://127.0.0.1:49152"));
        assert!(!valid_loopback_address("http://0.0.0.0:49152"));
        assert!(!valid_loopback_address("http://127.0.0.1:0"));
        assert!(!valid_loopback_address("http://127.0.0.1:49152/path"));
        assert!(!valid_loopback_address("http://user@127.0.0.1:49152"));
    }

    #[test]
    fn shutdown_is_idempotent_and_only_uses_an_owned_child() {
        let runtime = CoreRuntime::default();
        runtime.shutdown();
        runtime.shutdown();
        assert_eq!(runtime.snapshot().status, CoreStatus::Stopped);
        assert!(runtime.child.lock().expect("child lock").is_none());
    }

    #[test]
    fn shutdown_waits_for_startup_to_release_its_process() {
        let runtime = Arc::new(CoreRuntime::default());
        let startup_guard = runtime.start_lock.lock().expect("startup lock");
        let (started_tx, started_rx) = mpsc::sync_channel(1);
        let (finished_tx, finished_rx) = mpsc::sync_channel(1);
        let shutdown_runtime = Arc::clone(&runtime);
        let worker = std::thread::spawn(move || {
            started_tx.send(()).expect("announce shutdown");
            shutdown_runtime.shutdown();
            finished_tx.send(()).expect("announce completion");
        });

        started_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("shutdown thread started");
        assert!(finished_rx
            .recv_timeout(Duration::from_millis(100))
            .is_err());
        drop(startup_guard);
        finished_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("shutdown completed after startup");
        worker.join().expect("shutdown thread joined");
        assert_eq!(runtime.snapshot().status, CoreStatus::Stopped);
    }

    #[test]
    fn desktop_status_reports_owned_process_state() {
        let runtime = CoreRuntime::default();
        assert_eq!(runtime.desktop_status().sidecar_process_status, "stopped");
    }

    #[test]
    fn session_tokens_are_ephemeral_and_not_empty() {
        let first = new_session_token();
        let second = new_session_token();
        assert_eq!(first.len(), 64);
        assert!(first.bytes().all(|value| value.is_ascii_hexdigit()));
        assert_ne!(first, second);
    }

    #[test]
    fn sidecar_arguments_and_environment_do_not_carry_the_token() {
        let token = "a".repeat(64);
        let arguments = sidecar_arguments(std::path::Path::new(r"C:\sandbox\data"), true);
        assert!(!arguments.iter().any(|argument| argument == &token));
        assert!(!arguments.iter().any(|argument| argument == "--token"));
        assert!(!arguments
            .iter()
            .any(|argument| argument == "--handshake-file"));
        let source = include_str!("lifecycle.rs");
        assert!(!source.contains(".env(\"DEVPULSE_TOKEN\""));
    }

    #[test]
    fn launch_frame_is_versioned_bounded_and_contains_the_ephemeral_token_once() {
        let token = "b".repeat(64);
        let frame = launch_message(&token).expect("valid launch frame");
        assert!(frame.starts_with(LAUNCH_FRAME_PREFIX.as_bytes()));
        assert!(frame.ends_with(b"\n"));
        assert!(frame.len() <= MAX_LAUNCH_FRAME_BYTES);
        let text = String::from_utf8(frame).expect("UTF-8 launch frame");
        assert_eq!(text.matches(&token).count(), 1);
        assert!(text.contains(&format!("\"protocol_version\":{STARTUP_PROTOCOL_VERSION}")));
    }

    #[test]
    fn readiness_frame_is_strict_non_secret_and_loopback_only() {
        let frame = format!(
            "{READY_FRAME_PREFIX}{{\"protocol_version\":1,\"port\":43210,\"pid\":42,\"status\":\"ready\",\"instance_id\":\"{}\"}}",
            "c".repeat(32)
        );
        let ready = parse_ready_frame(frame.as_bytes()).expect("valid readiness frame");
        assert_eq!(ready.address, "http://127.0.0.1:43210");
        assert!(!frame.to_ascii_lowercase().contains("token"));

        let old_secret_handshake = format!(
            "{READY_FRAME_PREFIX}{{\"address\":\"http://127.0.0.1:1\",\"token\":\"{}\",\"instance_id\":\"{}\"}}",
            "d".repeat(64),
            "e".repeat(32)
        );
        assert!(parse_ready_frame(old_secret_handshake.as_bytes()).is_err());
        assert!(parse_ready_frame(&vec![b'x'; MAX_READY_FRAME_BYTES + 1]).is_err());
    }

    #[test]
    fn diagnostics_are_resolved_below_application_data() {
        let root = PathBuf::from(r"C:\Users\fixture\AppData\Roaming\DevPulse");
        assert_eq!(diagnostics_path(&root), root.join("logs/local-core.log"));
    }

    #[test]
    fn invalid_sidecar_executable_is_actionable() {
        let missing = PathBuf::from(r"Z:\definitely-missing\devpulse-local-core.exe");
        assert!(validate_executable(&missing)
            .expect_err("missing executable")
            .contains("missing"));
    }

    #[test]
    fn qa_mode_requires_the_explicit_launch_value() {
        for value in [None, Some("0")] {
            let mode = RuntimeMode::from_values(value, None, None, None, None);
            assert!(!mode.enabled);
            assert!(!mode.automation);
            assert!(!mode.install_qa);
            assert!(mode.root.is_none());
            assert!(mode.error.is_none());
        }
        for value in [Some(""), Some("true"), Some("yes")] {
            let mode = RuntimeMode::from_values(value, None, None, None, None);
            assert!(mode.enabled);
            assert!(mode.error.is_some());
        }

        let missing_root = RuntimeMode::from_values(Some("1"), None, None, None, None);
        assert!(missing_root.enabled);
        assert!(missing_root.root.is_none());
        assert!(missing_root.error.is_some());

        let mode = RuntimeMode::from_values(
            Some("1"),
            Some(r"C:\sandbox\DevPulse-QA"),
            Some("1"),
            None,
            None,
        );
        assert!(mode.enabled);
        assert!(mode.automation);
        assert!(!mode.install_qa);
        assert!(mode.error.is_none());
    }

    #[test]
    fn installed_qa_requires_the_normal_qa_gate() {
        let refused = RuntimeMode::from_values(None, None, Some("1"), Some("1"), None);
        assert!(refused.enabled);
        assert!(!refused.install_qa);
        assert!(refused.error.is_some());
        assert!(refused.root.is_none());

        let one_variable = RuntimeMode::from_values(None, None, None, Some("1"), None);
        assert!(one_variable.enabled);
        assert!(one_variable.error.is_some());

        let enabled = RuntimeMode::from_values(
            Some("1"),
            Some(r"C:\runner\DevPulse-QA-installed"),
            Some("1"),
            Some("1"),
            None,
        );
        assert!(enabled.enabled);
        assert!(enabled.automation);
        assert!(enabled.install_qa);
        assert!(enabled.error.is_none());
    }

    #[test]
    fn qa_root_validation_rejects_unsafe_locations() {
        assert!(validate_qa_root(std::path::Path::new("")).is_err());
        assert!(validate_qa_root(std::path::Path::new(r"C:\")).is_err());
        assert!(
            validate_qa_root(std::path::Path::new(r"C:\sandbox\DevPulse-QA\..\outside")).is_err()
        );
        assert!(validate_qa_root(std::path::Path::new(r"C:\Users\fixture\DevPulse")).is_err());
    }

    #[test]
    fn qa_path_plan_places_tauri_webview_and_platform_data_below_one_root() {
        let root = PathBuf::from(r"C:\runner\DevPulse-QA-installed");
        let plan = QaPathPlan::new(root.clone()).expect("valid QA plan");
        assert_eq!(plan.roaming_app_data, root.join("process-env/roaming"));
        assert_eq!(plan.local_app_data, root.join("process-env/local"));
        assert_eq!(plan.tauri_config, root.join("tauri/config"));
        assert_eq!(plan.tauri_data, root.join("tauri/data"));
        assert_eq!(plan.tauri_local_data, root.join("tauri/local-data"));
        assert_eq!(plan.tauri_cache, root.join("tauri/cache"));
        assert_eq!(plan.tauri_log, root.join("tauri/logs"));
        assert_eq!(plan.webview2_user_data, root.join("webview2"));
        assert!([
            plan.roaming_app_data,
            plan.local_app_data,
            plan.tauri_config,
            plan.tauri_data,
            plan.tauri_local_data,
            plan.tauri_cache,
            plan.tauri_log,
            plan.webview2_user_data,
        ]
        .iter()
        .all(|path| path.starts_with(&root)));
    }

    #[cfg(windows)]
    #[test]
    fn qa_root_rejects_a_directory_link_escape_where_supported() {
        use std::os::windows::fs::symlink_dir;

        let fixture =
            std::env::temp_dir().join(format!("DevPulse-QA-link-test-{}", Uuid::new_v4()));
        let outside = fixture.join("outside");
        let linked_root = fixture.join("DevPulse-QA-linked");
        std::fs::create_dir_all(&outside).expect("create link fixture");
        if symlink_dir(&outside, &linked_root).is_err() {
            let _ = std::fs::remove_dir_all(&fixture);
            return;
        }
        assert!(validate_qa_root(&linked_root).is_err());
        std::fs::remove_dir(&linked_root).expect("remove test link");
        std::fs::remove_dir_all(&fixture).expect("remove link fixture");
    }

    #[test]
    fn qa_data_directory_never_falls_back_to_production_data() {
        let qa_root = PathBuf::from(r"C:\sandbox\DevPulse-QA");
        let mode = RuntimeMode::from_values(
            Some("1"),
            Some(qa_root.to_string_lossy().as_ref()),
            None,
            None,
            None,
        );
        let runtime = CoreRuntime {
            child: Mutex::new(None),
            connection: Mutex::new(CoreConnection {
                status: CoreStatus::Starting,
                address: None,
                token: None,
                version: None,
                message: None,
                diagnostics_path: None,
                qa_mode: true,
                qa_automation: false,
                install_qa: false,
            }),
            start_lock: Mutex::new(()),
            data_dir: Mutex::new(None),
            restart_count: AtomicU8::new(0),
            shutting_down: AtomicBool::new(false),
            sidecar_pid: AtomicU32::new(0),
            startup_duration_ms: AtomicU32::new(0),
            started: Instant::now(),
            qa_mode: true,
            qa_automation: false,
            install_qa: false,
            qa_root: mode.root,
            mode_error: mode.error,
        };
        assert_eq!(runtime.data_dir_for(None).unwrap(), qa_root);
    }

    #[test]
    fn production_data_directory_behaviour_remains_unchanged() {
        let production = PathBuf::from(r"C:\Users\fixture\AppData\Roaming\com.devpulse.desktop");
        assert_eq!(
            select_runtime_data_directory(false, None, Some(&production)).unwrap(),
            production
        );
        assert!(select_runtime_data_directory(false, None, None).is_err());
    }

    #[test]
    fn lifecycle_never_uses_global_process_termination() {
        let source = include_str!("lifecycle.rs").to_ascii_lowercase();
        for forbidden in [
            ["task", "kill"].concat(),
            ["stop", "-process"].concat(),
            ["kill", "all"].concat(),
            ["wmic", " process"].concat(),
        ] {
            assert!(!source.contains(&forbidden));
        }
    }

    #[test]
    fn qa_webview_uses_the_validated_absolute_builder_directory() {
        let source = include_str!("lib.rs");
        assert!(source.contains("window.create = false"));
        assert!(source.contains("WebviewWindowBuilder::from_config"));
        assert!(source.contains(".data_directory(data_directory.clone())"));
    }

    #[test]
    fn startup_errors_are_safe_and_actionable() {
        assert_eq!(
            classify_startup_error("invalid session credential"),
            "authentication_failed"
        );
        assert_eq!(
            classify_startup_error("did not become ready within 15 seconds"),
            "startup_timeout"
        );
        assert_eq!(
            classify_startup_error("sidecar executable is missing"),
            "sidecar_unavailable"
        );
    }
}
