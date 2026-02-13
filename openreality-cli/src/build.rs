use std::path::Path;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;

use crate::state::{Backend, Platform};

#[derive(Debug)]
pub enum BuildEvent {
    StdoutLine(String),
    StderrLine(String),
    Finished { exit_code: Option<i32> },
    Error(String),
}

pub async fn spawn_build(
    project_root: &Path,
    backend: Backend,
    platform: Platform,
    tx: mpsc::UnboundedSender<BuildEvent>,
) -> anyhow::Result<tokio::task::JoinHandle<()>> {
    let (program, args, cwd): (&str, Vec<&str>, _) = match backend {
        Backend::Metal => (
            "swift",
            vec!["build", "-c", "release"],
            project_root.join("metal_bridge"),
        ),
        Backend::WebGPU => (
            "cargo",
            vec!["build", "--release"],
            project_root.join("openreality-wgpu"),
        ),
        Backend::WasmExport => (
            "wasm-pack",
            vec!["build", "--target", "web", "--release"],
            project_root.join("openreality-web"),
        ),
        Backend::OpenGL | Backend::Vulkan => {
            let _ = tx.send(BuildEvent::Error(format!(
                "{} requires no build step.",
                backend.label()
            )));
            anyhow::bail!("{} requires no build step", backend.label());
        }
    };

    let _ = tx.send(BuildEvent::StdoutLine(format!(
        "$ cd {} && {} {}",
        cwd.display(),
        program,
        args.join(" ")
    )));

    let program = program.to_string();
    let args: Vec<String> = args.into_iter().map(|s| s.to_string()).collect();
    let _ = platform; // used for future platform-specific tweaks

    let handle = tokio::spawn(async move {
        let result = Command::new(&program)
            .args(&args)
            .current_dir(&cwd)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn();

        match result {
            Ok(mut child) => {
                let stdout = child.stdout.take().unwrap();
                let stderr = child.stderr.take().unwrap();
                let tx_out = tx.clone();
                let tx_err = tx.clone();

                let stdout_task = tokio::spawn(async move {
                    let reader = BufReader::new(stdout);
                    let mut lines = reader.lines();
                    while let Ok(Some(line)) = lines.next_line().await {
                        let _ = tx_out.send(BuildEvent::StdoutLine(line));
                    }
                });

                let stderr_task = tokio::spawn(async move {
                    let reader = BufReader::new(stderr);
                    let mut lines = reader.lines();
                    while let Ok(Some(line)) = lines.next_line().await {
                        let _ = tx_err.send(BuildEvent::StderrLine(line));
                    }
                });

                let _ = stdout_task.await;
                let _ = stderr_task.await;

                let status = child.wait().await;
                let exit_code = status.ok().and_then(|s| s.code());
                let _ = tx.send(BuildEvent::Finished { exit_code });
            }
            Err(e) => {
                let _ = tx.send(BuildEvent::Error(format!("Failed to spawn {program}: {e}")));
            }
        }
    });

    Ok(handle)
}
