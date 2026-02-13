use std::path::Path;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;

#[derive(Debug)]
pub enum RunEvent {
    StdoutLine(String),
    StderrLine(String),
    Finished { exit_code: Option<i32> },
    Error(String),
}

pub async fn spawn_julia_command(
    project_root: &Path,
    julia_args: Vec<String>,
    tx: mpsc::UnboundedSender<RunEvent>,
) -> anyhow::Result<tokio::task::JoinHandle<()>> {
    let cwd = project_root.to_path_buf();

    let cmd_display = format!("$ julia {}", julia_args.join(" "));
    let _ = tx.send(RunEvent::StdoutLine(cmd_display));

    let handle = tokio::spawn(async move {
        let result = Command::new("julia")
            .args(&julia_args)
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
                        let _ = tx_out.send(RunEvent::StdoutLine(line));
                    }
                });

                let stderr_task = tokio::spawn(async move {
                    let reader = BufReader::new(stderr);
                    let mut lines = reader.lines();
                    while let Ok(Some(line)) = lines.next_line().await {
                        let _ = tx_err.send(RunEvent::StderrLine(line));
                    }
                });

                let _ = stdout_task.await;
                let _ = stderr_task.await;

                let status = child.wait().await;
                let exit_code = status.ok().and_then(|s| s.code());
                let _ = tx.send(RunEvent::Finished { exit_code });
            }
            Err(e) => {
                let _ = tx.send(RunEvent::Error(format!("Failed to spawn julia: {e}")));
            }
        }
    });

    Ok(handle)
}

pub async fn spawn_pkg_command(
    project_root: &Path,
    pkg_expr: &str,
    tx: mpsc::UnboundedSender<RunEvent>,
) -> anyhow::Result<tokio::task::JoinHandle<()>> {
    let code = format!(r#"using Pkg; Pkg.activate("."); {pkg_expr}"#);
    spawn_julia_command(
        project_root,
        vec!["--project=.".to_string(), "-e".to_string(), code],
        tx,
    )
    .await
}
