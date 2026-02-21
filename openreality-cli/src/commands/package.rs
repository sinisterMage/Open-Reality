use std::path::PathBuf;

use crate::cli::{DesktopPlatform, PackageTarget};
use crate::project::ProjectContext;

pub async fn run(target: PackageTarget, ctx: ProjectContext) -> anyhow::Result<()> {
    match target {
        PackageTarget::Desktop {
            build_dir,
            output,
            platform,
        } => package_desktop(build_dir, output, platform, ctx).await,
        PackageTarget::Web { build_dir, output } => {
            package_web(build_dir, output, ctx).await
        }
    }
}

async fn package_desktop(
    build_dir: PathBuf,
    output: PathBuf,
    platform: Option<DesktopPlatform>,
    ctx: ProjectContext,
) -> anyhow::Result<()> {
    let platform = platform.unwrap_or_else(DesktopPlatform::detect);

    let build_abs = if build_dir.is_relative() {
        ctx.project_root.join(&build_dir)
    } else {
        build_dir.clone()
    };

    let output_abs = if output.is_relative() {
        ctx.project_root.join(&output)
    } else {
        output.clone()
    };

    if !build_abs.exists() {
        anyhow::bail!(
            "Build directory not found: {}\nRun `orcli build desktop` first.",
            build_abs.display()
        );
    }

    std::fs::create_dir_all(&output_abs)?;

    println!(
        "Packaging desktop build for {}...",
        platform.label()
    );

    let script_name = match platform {
        DesktopPlatform::Linux => "package_linux.sh",
        DesktopPlatform::Macos => "package_macos.sh",
        DesktopPlatform::Windows => "package_windows.sh",
    };

    let package_script = ctx.engine_path.join("build").join(script_name);
    if package_script.exists() {
        let status = tokio::process::Command::new("bash")
            .args([
                package_script.to_str().unwrap(),
                build_abs.to_str().unwrap(),
                output_abs.to_str().unwrap(),
            ])
            .current_dir(&ctx.project_root)
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status()
            .await?;

        if !status.success() {
            anyhow::bail!("Packaging failed");
        }
    } else {
        // Fallback: simple copy + tar
        println!(
            "No packaging script found at {}",
            package_script.display()
        );
        println!("Falling back to simple archive...");

        let archive_name = format!("openreality-{}.tar.gz", platform.label());
        let archive_path = output_abs.join(&archive_name);

        let status = tokio::process::Command::new("tar")
            .args([
                "-czf",
                archive_path.to_str().unwrap(),
                "-C",
                build_abs.parent().unwrap().to_str().unwrap(),
                build_abs
                    .file_name()
                    .unwrap()
                    .to_str()
                    .unwrap(),
            ])
            .status()
            .await?;

        if !status.success() {
            anyhow::bail!("tar archive creation failed");
        }

        println!("Package created: {}", archive_path.display());
    }

    Ok(())
}

async fn package_web(
    build_dir: PathBuf,
    output: PathBuf,
    ctx: ProjectContext,
) -> anyhow::Result<()> {
    let build_abs = if build_dir.is_relative() {
        ctx.project_root.join(&build_dir)
    } else {
        build_dir.clone()
    };

    let output_abs = if output.is_relative() {
        ctx.project_root.join(&output)
    } else {
        output.clone()
    };

    if !build_abs.exists() {
        anyhow::bail!(
            "Build directory not found: {}\nRun `orcli build web` first.",
            build_abs.display()
        );
    }

    std::fs::create_dir_all(&output_abs)?;

    println!("Packaging web build...");

    // Copy all web build files to output
    copy_dir_recursive(&build_abs, &output_abs)?;

    println!("Web package ready at: {}", output_abs.display());
    println!("Deploy contents to any static hosting (Netlify, Vercel, S3, etc.)");

    Ok(())
}

fn copy_dir_recursive(src: &PathBuf, dst: &PathBuf) -> anyhow::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());
        if src_path.is_dir() {
            copy_dir_recursive(&src_path, &dst_path)?;
        } else {
            std::fs::copy(&src_path, &dst_path)?;
        }
    }
    Ok(())
}
