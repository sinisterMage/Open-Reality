use std::path::Path;

use tokio::process::Command;

use crate::state::*;

async fn detect_tool(program: &str, version_args: &[&str]) -> ToolStatus {
    let path = match which::which(program) {
        Ok(p) => p,
        Err(_) => return ToolStatus::NotFound,
    };

    let output = Command::new(program)
        .args(version_args)
        .output()
        .await;

    match output {
        Ok(out) => {
            let raw = if out.stdout.is_empty() {
                String::from_utf8_lossy(&out.stderr).to_string()
            } else {
                String::from_utf8_lossy(&out.stdout).to_string()
            };
            let version = raw
                .lines()
                .next()
                .unwrap_or("unknown")
                .trim()
                .to_string();
            ToolStatus::Found { version, path }
        }
        Err(_) => ToolStatus::Found {
            version: "unknown".to_string(),
            path,
        },
    }
}

pub async fn detect_all_tools(platform: Platform) -> ToolSet {
    let (julia, cargo, swift, wasm_pack, vulkaninfo) = tokio::join!(
        detect_tool("julia", &["--version"]),
        detect_tool("cargo", &["--version"]),
        detect_tool("swift", &["--version"]),
        detect_tool("wasm-pack", &["--version"]),
        detect_tool("vulkaninfo", &["--summary"]),
    );

    let glfw = detect_library_glfw(platform).await;
    let opengl_dev = detect_library_opengl(platform).await;

    ToolSet {
        julia,
        cargo,
        swift,
        wasm_pack,
        vulkaninfo,
        glfw,
        opengl_dev,
    }
}

async fn detect_library_glfw(platform: Platform) -> LibraryStatus {
    match platform {
        Platform::Linux => {
            let output = Command::new("pkg-config")
                .args(["--exists", "glfw3"])
                .output()
                .await;
            match output {
                Ok(out) if out.status.success() => LibraryStatus::Found,
                _ => {
                    // Fallback: check ldconfig
                    let output = Command::new("ldconfig")
                        .args(["-p"])
                        .output()
                        .await;
                    match output {
                        Ok(out) => {
                            let text = String::from_utf8_lossy(&out.stdout);
                            if text.contains("libglfw") {
                                LibraryStatus::Found
                            } else {
                                LibraryStatus::NotFound
                            }
                        }
                        Err(_) => LibraryStatus::Unknown,
                    }
                }
            }
        }
        Platform::MacOS => {
            let output = Command::new("brew")
                .args(["--prefix", "glfw"])
                .output()
                .await;
            match output {
                Ok(out) if out.status.success() => LibraryStatus::Found,
                _ => LibraryStatus::Unknown,
            }
        }
        Platform::Windows => LibraryStatus::Unknown,
    }
}

async fn detect_library_opengl(platform: Platform) -> LibraryStatus {
    match platform {
        Platform::Linux => {
            let output = Command::new("pkg-config")
                .args(["--exists", "gl"])
                .output()
                .await;
            match output {
                Ok(out) if out.status.success() => LibraryStatus::Found,
                _ => LibraryStatus::Unknown,
            }
        }
        _ => LibraryStatus::Unknown,
    }
}

pub fn check_backend_artifact(
    project_root: &Path,
    backend: Backend,
    platform: Platform,
) -> BuildStatus {
    match backend {
        Backend::OpenGL | Backend::Vulkan => BuildStatus::NotNeeded,
        Backend::Metal => {
            let lib = project_root.join("metal_bridge/.build/release/libMetalBridge.dylib");
            check_artifact(&lib)
        }
        Backend::WebGPU => {
            let ext = match platform {
                Platform::Linux => "so",
                Platform::MacOS => "dylib",
                Platform::Windows => "dll",
            };
            let prefix = if matches!(platform, Platform::Windows) {
                ""
            } else {
                "lib"
            };
            let lib = project_root.join(format!(
                "openreality-wgpu/target/release/{prefix}openreality_wgpu.{ext}"
            ));
            check_artifact(&lib)
        }
        Backend::WasmExport => {
            let pkg_dir = project_root.join("openreality-web/pkg");
            if pkg_dir.exists() {
                if let Ok(entries) = std::fs::read_dir(&pkg_dir) {
                    let has_wasm = entries
                        .flatten()
                        .any(|e| e.path().extension().map_or(false, |ext| ext == "wasm"));
                    if has_wasm {
                        return BuildStatus::Built {
                            artifact_path: pkg_dir,
                            modified: None,
                        };
                    }
                }
            }
            BuildStatus::NotBuilt
        }
    }
}

fn check_artifact(path: &Path) -> BuildStatus {
    if path.exists() {
        let modified = std::fs::metadata(path)
            .ok()
            .and_then(|m| m.modified().ok())
            .map(|t| {
                let dt: chrono::DateTime<chrono::Local> = t.into();
                dt.format("%Y-%m-%d %H:%M").to_string()
            });
        BuildStatus::Built {
            artifact_path: path.to_path_buf(),
            modified,
        }
    } else {
        BuildStatus::NotBuilt
    }
}

pub fn check_julia_packages(project_root: &Path) -> Option<bool> {
    let manifest = project_root.join("Manifest.toml");
    let project = project_root.join("Project.toml");
    if !project.exists() {
        return None;
    }
    Some(manifest.exists())
}

pub fn check_deps_for_backend(backend: Backend, tools: &ToolSet, platform: Platform) -> bool {
    match backend {
        Backend::OpenGL => {
            tools.julia.is_available() && matches!(tools.glfw, LibraryStatus::Found | LibraryStatus::Unknown)
        }
        Backend::Metal => {
            platform.supports_metal()
                && tools.julia.is_available()
                && tools.swift.is_available()
        }
        Backend::Vulkan => {
            platform.supports_vulkan()
                && tools.julia.is_available()
                && tools.vulkaninfo.is_available()
        }
        Backend::WebGPU => tools.julia.is_available() && tools.cargo.is_available(),
        Backend::WasmExport => tools.cargo.is_available() && tools.wasm_pack.is_available(),
    }
}

pub fn discover_examples(project_root: &Path) -> Vec<ExampleEntry> {
    let examples_dir = project_root.join("examples");
    let mut entries = Vec::new();

    let Ok(dir) = std::fs::read_dir(&examples_dir) else {
        return entries;
    };

    let mut files: Vec<_> = dir
        .flatten()
        .filter(|e| {
            e.path().extension().map_or(false, |ext| ext == "jl")
                && !e.file_name().to_string_lossy().starts_with('_')
        })
        .collect();

    files.sort_by_key(|e| e.file_name());

    for entry in files {
        let path = entry.path();
        let filename = entry.file_name().to_string_lossy().to_string();

        let content = std::fs::read_to_string(&path).unwrap_or_default();
        let description = content
            .lines()
            .find(|l| l.starts_with('#'))
            .map(|l| l.trim_start_matches('#').trim().to_string())
            .unwrap_or_default();

        let required_backend = if content.contains("MetalBackend()") {
            Some(Backend::Metal)
        } else if content.contains("VulkanBackend()") {
            Some(Backend::Vulkan)
        } else if content.contains("WebGPUBackend()") {
            Some(Backend::WebGPU)
        } else {
            None
        };

        entries.push(ExampleEntry {
            filename,
            path,
            description,
            required_backend,
        });
    }

    entries
}

pub fn detect_all_backends(project_root: &Path, tools: &ToolSet, platform: Platform) -> Vec<BackendState> {
    Backend::available_on(platform)
        .into_iter()
        .map(|b| {
            let build_status = check_backend_artifact(project_root, b, platform);
            let deps_satisfied = check_deps_for_backend(b, tools, platform);
            BackendState {
                backend: b,
                build_status,
                deps_satisfied,
            }
        })
        .collect()
}
