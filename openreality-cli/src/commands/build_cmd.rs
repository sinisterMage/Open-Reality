use std::path::PathBuf;

use crate::cli::{BuildTarget, DesktopPlatform, MobilePlatform};
use crate::project::ProjectContext;
use crate::state::Backend;

pub async fn run(target: BuildTarget, ctx: ProjectContext) -> anyhow::Result<()> {
    match target {
        BuildTarget::Backend { name } => build_backend(name, ctx).await,
        BuildTarget::Desktop {
            entry,
            platform,
            output,
            release,
        } => build_desktop(entry, platform, output, release, ctx).await,
        BuildTarget::Web {
            scene,
            output,
            release,
        } => build_web(scene, output, release, ctx).await,
        BuildTarget::Mobile {
            scene,
            platform,
            output,
        } => build_mobile(scene, platform, output, ctx).await,
    }
}

// ---- Backend build (existing behavior) ----

async fn build_backend(backend_str: String, ctx: ProjectContext) -> anyhow::Result<()> {
    let backend = parse_backend(&backend_str)?;

    if !backend.needs_build() {
        println!("{} requires no build step.", backend.label());
        return Ok(());
    }

    let (program, args, cwd) = match backend {
        Backend::Metal => (
            "swift",
            vec!["build", "-c", "release"],
            ctx.engine_path.join("metal_bridge"),
        ),
        Backend::WebGPU => (
            "cargo",
            vec!["build", "--release"],
            ctx.engine_path.join("openreality-wgpu"),
        ),
        Backend::WasmExport => (
            "wasm-pack",
            vec!["build", "--target", "web", "--release"],
            ctx.engine_path.join("openreality-web"),
        ),
        _ => unreachable!(),
    };

    println!(
        "Building {} in {}...",
        backend.label(),
        cwd.display()
    );

    let status = tokio::process::Command::new(program)
        .args(&args)
        .current_dir(&cwd)
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .await?;

    std::process::exit(status.code().unwrap_or(1));
}

// ---- Desktop build via PackageCompiler.jl ----

async fn build_desktop(
    entry: String,
    platform: Option<DesktopPlatform>,
    output: PathBuf,
    release: bool,
    ctx: ProjectContext,
) -> anyhow::Result<()> {
    let platform = platform.unwrap_or_else(DesktopPlatform::detect);

    println!(
        "Building desktop executable for {}...",
        platform.label()
    );
    println!("  Entry point: {}", entry);
    println!("  Output: {}", output.display());

    let build_script = ctx.engine_path.join("build").join("desktop_build.jl");
    if !build_script.exists() {
        anyhow::bail!(
            "Desktop build script not found at {}.\n\
             Run from the engine repo or ensure engine_path is correct.",
            build_script.display()
        );
    }

    let output_abs = if output.is_relative() {
        ctx.project_root.join(&output)
    } else {
        output.clone()
    };

    let entry_abs = if PathBuf::from(&entry).is_relative() {
        ctx.project_root.join(&entry)
    } else {
        PathBuf::from(&entry)
    };

    let julia_code = format!(
        r#"include("{build_script}"); desktop_build("{entry}", "{output}", "{platform}", {release})"#,
        build_script = build_script.display(),
        entry = entry_abs.display(),
        output = output_abs.display(),
        platform = platform.label(),
        release = release,
    );

    let status = tokio::process::Command::new("julia")
        .args(["--project=.", "-e", &julia_code])
        .current_dir(&ctx.engine_path)
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .await?;

    if status.success() {
        println!("Desktop build complete: {}", output_abs.display());
    }

    std::process::exit(status.code().unwrap_or(1));
}

// ---- Web build (WASM + ORSB) ----

async fn build_web(
    scene: String,
    output: PathBuf,
    release: bool,
    ctx: ProjectContext,
) -> anyhow::Result<()> {
    println!("Building for web...");
    println!("  Scene: {}", scene);
    println!("  Output: {}", output.display());

    let output_abs = if output.is_relative() {
        ctx.project_root.join(&output)
    } else {
        output.clone()
    };

    // Step 1: Export scene to ORSB
    let orsb_path = output_abs.join("scene.orsb");
    println!("Step 1/3: Exporting scene to ORSB...");

    let scene_abs = if PathBuf::from(&scene).is_relative() {
        ctx.project_root.join(&scene)
    } else {
        PathBuf::from(&scene)
    };

    // The Julia code detects whether the game defines a `scene` variable (simple Scene)
    // or a `GameStateMachine` named `fsm` (FSM-based), and exports accordingly.
    let julia_code = format!(
        r#"using OpenReality; include("{scene}");
if @isdefined(fsm) && fsm isa GameStateMachine
    _sc = scene(fsm.initial_scene_defs)
    export_scene(_sc, "{orsb}")
elseif @isdefined(scene) && scene isa Scene
    export_scene(scene, "{orsb}")
else
    error("No `scene::Scene` or `fsm::GameStateMachine` variable found after including the script.")
end"#,
        scene = scene_abs.display(),
        orsb = orsb_path.display(),
    );

    std::fs::create_dir_all(&output_abs)?;

    let status = tokio::process::Command::new("julia")
        .args(["--project=.", "-e", &julia_code])
        .current_dir(&ctx.engine_path)
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .await?;

    if !status.success() {
        anyhow::bail!("ORSB export failed");
    }

    // Step 2: Build WASM runtime
    println!("Step 2/3: Building WASM runtime...");
    let wasm_dir = ctx.engine_path.join("openreality-web");
    if !wasm_dir.exists() {
        anyhow::bail!(
            "WASM project not found at {}",
            wasm_dir.display()
        );
    }

    let mut wasm_args = vec!["build", "--target", "web"];
    if release {
        wasm_args.push("--release");
    }

    let status = tokio::process::Command::new("wasm-pack")
        .args(&wasm_args)
        .current_dir(&wasm_dir)
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .await?;

    if !status.success() {
        anyhow::bail!("WASM build failed");
    }

    // Step 3: Copy WASM artifacts + generate index.html
    println!("Step 3/3: Assembling web package...");
    let pkg_dir = wasm_dir.join("pkg");
    copy_dir_contents(&pkg_dir, &output_abs)?;

    let template_path = ctx.engine_path.join("build").join("web_template").join("index.html");
    if template_path.exists() {
        std::fs::copy(&template_path, output_abs.join("index.html"))?;
    } else {
        // Generate a minimal index.html
        let html = generate_web_index_html();
        std::fs::write(output_abs.join("index.html"), html)?;
    }

    println!("Web build complete: {}", output_abs.display());
    println!("Serve with: cd {} && python3 -m http.server", output_abs.display());

    Ok(())
}

// ---- Mobile build (WebView shell) ----

async fn build_mobile(
    scene: String,
    platform: MobilePlatform,
    output: PathBuf,
    ctx: ProjectContext,
) -> anyhow::Result<()> {
    println!(
        "Building for mobile ({})...",
        platform.label()
    );
    println!("  Scene: {}", scene);
    println!("  Output: {}", output.display());

    // Mobile builds start with a web build, then wrap in a WebView shell
    println!("Step 1: Building web target first...");

    let web_output = output.join("web");
    build_web(scene, web_output.clone(), true, ctx.clone()).await?;

    // Step 2: Copy Capacitor template files
    println!("Step 2: Setting up native shell...");

    let output_abs = if output.is_relative() {
        ctx.project_root.join(&output)
    } else {
        output.clone()
    };

    let template_dir = ctx.engine_path.join("build").join("mobile_template");
    if template_dir.exists() {
        for entry in std::fs::read_dir(&template_dir)? {
            let entry = entry?;
            let src = entry.path();
            if src.is_file() {
                let dst = output_abs.join(entry.file_name());
                if !dst.exists() {
                    std::fs::copy(&src, &dst)?;
                }
            }
        }
        println!("Capacitor template files copied to {}", output_abs.display());
    }

    println!("\nMobile build ready at: {}", output_abs.display());
    match platform {
        MobilePlatform::Android => {
            println!("\nTo finish Android build:");
            println!("  cd {}", output_abs.display());
            println!("  npm install");
            println!("  npm run build:android");
            println!("\nRequires: Node.js 18+, Android Studio + SDK 24+");
        }
        MobilePlatform::Ios => {
            println!("\nTo finish iOS build:");
            println!("  cd {}", output_abs.display());
            println!("  npm install");
            println!("  npm run build:ios");
            println!("\nRequires: Node.js 18+, Xcode 15+ (macOS only)");
        }
    }

    Ok(())
}

// ---- Helpers ----

fn parse_backend(s: &str) -> anyhow::Result<Backend> {
    match s.to_lowercase().as_str() {
        "metal" => Ok(Backend::Metal),
        "webgpu" | "wgpu" => Ok(Backend::WebGPU),
        "wasm" | "wasm-export" => Ok(Backend::WasmExport),
        "opengl" | "gl" => Ok(Backend::OpenGL),
        "vulkan" | "vk" => Ok(Backend::Vulkan),
        _ => anyhow::bail!("Unknown backend: {s}. Options: opengl, metal, vulkan, webgpu, wasm"),
    }
}

fn copy_dir_contents(src: &PathBuf, dst: &PathBuf) -> anyhow::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());
        if src_path.is_file() {
            std::fs::copy(&src_path, &dst_path)?;
        }
    }
    Ok(())
}

fn generate_web_index_html() -> String {
    r#"<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OpenReality</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
        canvas { width: 100%; height: 100%; display: block; }
        #loading {
            position: absolute; top: 0; left: 0; width: 100%; height: 100%;
            display: flex; flex-direction: column; align-items: center; justify-content: center;
            color: #aaa; font-family: monospace; font-size: 16px; background: #111;
        }
        #loading .spinner {
            width: 40px; height: 40px; border: 3px solid #333;
            border-top-color: #aaa; border-radius: 50%;
            animation: spin 0.8s linear infinite; margin-bottom: 16px;
        }
        @keyframes spin { to { transform: rotate(360deg); } }
        #error { color: #e55; display: none; text-align: center; padding: 20px; }
    </style>
</head>
<body>
    <div id="loading">
        <div class="spinner"></div>
        <div id="status">Checking WebGPU support...</div>
    </div>
    <div id="error"></div>
    <canvas id="canvas" style="display: none;"></canvas>

    <script type="module">
        const statusEl = document.getElementById('status');
        const errorEl = document.getElementById('error');
        const loadingEl = document.getElementById('loading');
        const canvas = document.getElementById('canvas');

        function showError(msg) {
            loadingEl.style.display = 'none';
            errorEl.style.display = 'block';
            errorEl.textContent = msg;
        }

        // Check WebGPU support
        if (!navigator.gpu) {
            showError(
                'WebGPU is not supported in this browser. ' +
                'Please use Chrome 113+, Edge 113+, or a browser with WebGPU enabled.'
            );
        } else {
            (async () => {
                try {
                    statusEl.textContent = 'Loading WASM runtime...';
                    const { default: init, create_app } = await import('./openreality_web.js');
                    await init();

                    statusEl.textContent = 'Loading scene...';
                    const resp = await fetch('./scene.orsb');
                    if (!resp.ok) throw new Error('Failed to fetch scene.orsb: ' + resp.status);
                    const data = new Uint8Array(await resp.arrayBuffer());

                    // Set canvas size to match window
                    canvas.width = window.innerWidth;
                    canvas.height = window.innerHeight;

                    statusEl.textContent = 'Initializing renderer...';
                    const app = await create_app('canvas', data);

                    // Show canvas, hide loading
                    loadingEl.style.display = 'none';
                    canvas.style.display = 'block';

                    // Handle resize
                    window.addEventListener('resize', () => {
                        canvas.width = window.innerWidth;
                        canvas.height = window.innerHeight;
                        app.resize(canvas.width, canvas.height);
                    });

                    // Game loop
                    function loop(time) {
                        app.frame(time);
                        requestAnimationFrame(loop);
                    }
                    requestAnimationFrame(loop);

                } catch (e) {
                    console.error(e);
                    showError('Failed to start: ' + e.message);
                }
            })();
        }
    </script>
</body>
</html>
"#
    .to_string()
}
