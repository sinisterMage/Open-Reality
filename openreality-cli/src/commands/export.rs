use std::path::PathBuf;

use crate::cli::ExportFormat;
use crate::project::ProjectContext;

pub async fn run(
    scene: String,
    output: PathBuf,
    format: ExportFormat,
    physics: bool,
    compress_textures: bool,
    ctx: ProjectContext,
) -> anyhow::Result<()> {
    let format_label = match format {
        ExportFormat::Orsb => "ORSB",
        ExportFormat::Gltf => "glTF",
    };

    println!("Exporting scene as {}...", format_label);
    println!("  Scene: {}", scene);
    println!("  Output: {}", output.display());

    let scene_abs = if PathBuf::from(&scene).is_relative() {
        ctx.project_root.join(&scene)
    } else {
        PathBuf::from(&scene)
    };

    let output_abs = if output.is_relative() {
        ctx.project_root.join(&output)
    } else {
        output.clone()
    };

    // Ensure parent directory exists
    if let Some(parent) = output_abs.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let physics_kwarg = if physics {
        ", physics_config=PhysicsWorldConfig()"
    } else {
        ""
    };

    let julia_code = match format {
        ExportFormat::Orsb => {
            format!(
                r#"using OpenReality; include("{scene}"); export_scene(scene, "{output}"; compress_textures={compress}{physics})"#,
                scene = scene_abs.display(),
                output = output_abs.display(),
                compress = compress_textures,
                physics = physics_kwarg,
            )
        }
        ExportFormat::Gltf => {
            format!(
                r#"using OpenReality; include("{scene}"); export_gltf(scene, "{output}")"#,
                scene = scene_abs.display(),
                output = output_abs.display(),
            )
        }
    };

    let status = tokio::process::Command::new("julia")
        .args(["--project=.", "-e", &julia_code])
        .current_dir(&ctx.engine_path)
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .await?;

    if status.success() {
        println!(
            "Export complete: {} ({})",
            output_abs.display(),
            format_label
        );
    }

    std::process::exit(status.code().unwrap_or(1));
}
