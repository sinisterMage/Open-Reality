use std::path::PathBuf;

use chrono::{DateTime, Local};

// ─── Platform ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Linux,
    MacOS,
    Windows,
}

impl Platform {
    pub fn detect() -> Self {
        if cfg!(target_os = "macos") {
            Self::MacOS
        } else if cfg!(target_os = "windows") {
            Self::Windows
        } else {
            Self::Linux
        }
    }

    pub fn supports_metal(&self) -> bool {
        matches!(self, Self::MacOS)
    }

    pub fn supports_vulkan(&self) -> bool {
        !matches!(self, Self::MacOS)
    }

    pub fn label(&self) -> &'static str {
        match self {
            Self::Linux => "Linux",
            Self::MacOS => "macOS",
            Self::Windows => "Windows",
        }
    }
}

// ─── Tool/Dependency Status ──────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolStatus {
    Found { version: String, path: PathBuf },
    NotFound,
}

impl ToolStatus {
    pub fn is_available(&self) -> bool {
        matches!(self, Self::Found { .. })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryStatus {
    Found,
    NotFound,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct ToolSet {
    pub julia: ToolStatus,
    pub cargo: ToolStatus,
    pub swift: ToolStatus,
    pub wasm_pack: ToolStatus,
    pub vulkaninfo: ToolStatus,
    pub glfw: LibraryStatus,
    pub opengl_dev: LibraryStatus,
}

impl Default for ToolSet {
    fn default() -> Self {
        Self {
            julia: ToolStatus::NotFound,
            cargo: ToolStatus::NotFound,
            swift: ToolStatus::NotFound,
            wasm_pack: ToolStatus::NotFound,
            vulkaninfo: ToolStatus::NotFound,
            glfw: LibraryStatus::Unknown,
            opengl_dev: LibraryStatus::Unknown,
        }
    }
}

// ─── Backend ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Backend {
    OpenGL,
    Metal,
    Vulkan,
    WebGPU,
    WasmExport,
}

impl Backend {
    pub fn label(&self) -> &'static str {
        match self {
            Self::OpenGL => "OpenGL",
            Self::Metal => "Metal",
            Self::Vulkan => "Vulkan",
            Self::WebGPU => "WebGPU",
            Self::WasmExport => "WASM Export",
        }
    }

    pub fn available_on(platform: Platform) -> Vec<Backend> {
        let mut v = vec![Backend::OpenGL];
        if platform.supports_metal() {
            v.push(Backend::Metal);
        }
        if platform.supports_vulkan() {
            v.push(Backend::Vulkan);
        }
        v.push(Backend::WebGPU);
        v.push(Backend::WasmExport);
        v
    }

    pub fn needs_build(&self) -> bool {
        matches!(self, Self::Metal | Self::WebGPU | Self::WasmExport)
    }
}

// ─── Build Status ────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuildStatus {
    NotNeeded,
    NotBuilt,
    Built {
        artifact_path: PathBuf,
        modified: Option<String>,
    },
    Building,
    BuildFailed {
        exit_code: Option<i32>,
    },
}

#[derive(Debug, Clone)]
pub struct BackendState {
    pub backend: Backend,
    pub build_status: BuildStatus,
    pub deps_satisfied: bool,
}

// ─── Example Metadata ────────────────────────────────────────────────

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct ExampleEntry {
    pub filename: String,
    pub path: PathBuf,
    pub description: String,
    pub required_backend: Option<Backend>,
}

// ─── Process Status ──────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum ProcessStatus {
    Idle,
    Running,
    Finished { exit_code: Option<i32> },
    Failed { error: String },
}

// ─── Log Buffer ──────────────────────────────────────────────────────

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct LogLine {
    pub timestamp: DateTime<Local>,
    pub text: String,
    pub is_stderr: bool,
}

pub struct LogBuffer {
    pub lines: Vec<LogLine>,
    pub scroll_offset: usize,
    pub auto_scroll: bool,
    max_lines: usize,
}

impl LogBuffer {
    pub fn new(max_lines: usize) -> Self {
        Self {
            lines: Vec::new(),
            scroll_offset: 0,
            auto_scroll: true,
            max_lines,
        }
    }

    pub fn push(&mut self, text: String, is_stderr: bool) {
        if self.lines.len() >= self.max_lines {
            self.lines.remove(0);
            self.scroll_offset = self.scroll_offset.saturating_sub(1);
        }
        self.lines.push(LogLine {
            timestamp: chrono::Local::now(),
            text,
            is_stderr,
        });
        if self.auto_scroll {
            self.scroll_to_bottom();
        }
    }

    pub fn scroll_to_bottom(&mut self) {
        self.scroll_offset = self.lines.len().saturating_sub(1);
    }

    pub fn clear(&mut self) {
        self.lines.clear();
        self.scroll_offset = 0;
    }

    pub fn scroll_up(&mut self, amount: usize) {
        self.scroll_offset = self.scroll_offset.saturating_sub(amount);
        self.auto_scroll = false;
    }

    pub fn scroll_down(&mut self, amount: usize) {
        self.scroll_offset = (self.scroll_offset + amount).min(self.lines.len().saturating_sub(1));
        if self.scroll_offset >= self.lines.len().saturating_sub(1) {
            self.auto_scroll = true;
        }
    }

    pub fn scroll_to_top(&mut self) {
        self.scroll_offset = 0;
        self.auto_scroll = false;
    }
}

// ─── Tabs ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tab {
    Dashboard,
    Build,
    Run,
    Setup,
}

impl Tab {
    pub const ALL: &'static [Tab] = &[Tab::Dashboard, Tab::Build, Tab::Run, Tab::Setup];

    pub fn label(&self) -> &'static str {
        match self {
            Self::Dashboard => "Dashboard",
            Self::Build => "Build",
            Self::Run => "Run",
            Self::Setup => "Setup",
        }
    }

    pub fn index(&self) -> usize {
        match self {
            Self::Dashboard => 0,
            Self::Build => 1,
            Self::Run => 2,
            Self::Setup => 3,
        }
    }

    pub fn next(&self) -> Tab {
        match self {
            Self::Dashboard => Self::Build,
            Self::Build => Self::Run,
            Self::Run => Self::Setup,
            Self::Setup => Self::Dashboard,
        }
    }

    pub fn prev(&self) -> Tab {
        match self {
            Self::Dashboard => Self::Setup,
            Self::Build => Self::Dashboard,
            Self::Run => Self::Build,
            Self::Setup => Self::Run,
        }
    }
}

// ─── Setup Actions ───────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SetupAction {
    PkgInstantiate,
    PkgStatus,
    PkgUpdate,
    RefreshDetection,
}

impl SetupAction {
    pub const ALL: &'static [SetupAction] = &[
        Self::PkgInstantiate,
        Self::PkgStatus,
        Self::PkgUpdate,
        Self::RefreshDetection,
    ];

    pub fn label(&self) -> &'static str {
        match self {
            Self::PkgInstantiate => "Pkg.instantiate()",
            Self::PkgStatus => "Pkg.status()",
            Self::PkgUpdate => "Pkg.update()",
            Self::RefreshDetection => "Refresh tool detection",
        }
    }
}

// ─── Application State ──────────────────────────────────────────────

pub struct AppState {
    pub platform: Platform,
    pub project_root: PathBuf,
    pub active_tab: Tab,

    // Detection
    pub tools: ToolSet,
    pub julia_packages_installed: Option<bool>,

    // Backends
    pub backends: Vec<BackendState>,

    // Build tab
    pub build_selected: usize,
    pub build_log: LogBuffer,
    pub build_process: ProcessStatus,

    // Run tab
    pub examples: Vec<ExampleEntry>,
    pub run_selected: usize,
    pub run_backend_idx: usize,
    pub run_log: LogBuffer,
    pub run_process: ProcessStatus,

    // Setup tab
    pub setup_selected: usize,
    pub setup_log: LogBuffer,
    pub setup_process: ProcessStatus,

    // Global
    pub show_help: bool,
    pub should_quit: bool,
}

impl AppState {
    pub fn new(project_root: PathBuf) -> Self {
        let platform = Platform::detect();
        let backends = Backend::available_on(platform)
            .into_iter()
            .map(|b| BackendState {
                backend: b,
                build_status: if b.needs_build() {
                    BuildStatus::NotBuilt
                } else {
                    BuildStatus::NotNeeded
                },
                deps_satisfied: false,
            })
            .collect();

        Self {
            platform,
            project_root,
            active_tab: Tab::Dashboard,
            tools: ToolSet::default(),
            julia_packages_installed: None,
            backends,
            build_selected: 0,
            build_log: LogBuffer::new(5000),
            build_process: ProcessStatus::Idle,
            examples: Vec::new(),
            run_selected: 0,
            run_backend_idx: 0,
            run_log: LogBuffer::new(5000),
            run_process: ProcessStatus::Idle,
            setup_selected: 0,
            setup_log: LogBuffer::new(5000),
            setup_process: ProcessStatus::Idle,
            show_help: false,
            should_quit: false,
        }
    }

    /// Get backends that can actually run examples (not WASM).
    pub fn runnable_backends(&self) -> Vec<&BackendState> {
        self.backends
            .iter()
            .filter(|b| !matches!(b.backend, Backend::WasmExport))
            .collect()
    }
}
