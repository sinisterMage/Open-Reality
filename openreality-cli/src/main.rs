mod app;
mod build;
mod cli;
mod commands;
mod detect;
mod event;
mod project;
mod runner;
mod state;
mod ui;

use std::io;

use anyhow::Result;
use clap::Parser;
use crossterm::execute;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;
use tokio::sync::mpsc;

use event::AppEvent;
use project::ProjectContext;

struct CleanupGuard;

impl Drop for CleanupGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = cli::Cli::parse();

    match cli.command {
        None => {
            let ctx = project::detect_project_context()?;
            run_tui(ctx).await
        }
        Some(cli::Command::Init {
            name,
            engine_dev,
            repo_url,
        }) => commands::init::run(name, engine_dev, repo_url).await,
        Some(cli::Command::New { kind }) => {
            let ctx = project::detect_project_context()?;
            match kind {
                cli::NewKind::Scene { name } => commands::new::scene(name, ctx).await,
            }
        }
        Some(cli::Command::Run { file }) => {
            let ctx = project::detect_project_context()?;
            commands::run_cmd::run(file, ctx).await
        }
        Some(cli::Command::Build { target }) => {
            let ctx = project::detect_project_context()?;
            commands::build_cmd::run(target, ctx).await
        }
        Some(cli::Command::Export {
            scene,
            output,
            format,
            physics,
            compress_textures,
        }) => {
            let ctx = project::detect_project_context()?;
            commands::export::run(scene, output, format, physics, compress_textures, ctx).await
        }
        Some(cli::Command::Package { target }) => {
            let ctx = project::detect_project_context()?;
            commands::package::run(target, ctx).await
        }
        Some(cli::Command::Test) => {
            let ctx = project::detect_project_context()?;
            commands::test_cmd::run(ctx).await
        }
    }
}

async fn run_tui(ctx: ProjectContext) -> Result<()> {
    // Setup terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let _guard = CleanupGuard;

    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;
    terminal.clear()?;

    // Unified event channel
    let (event_tx, mut event_rx) = mpsc::unbounded_channel::<AppEvent>();

    // Spawn crossterm event reader on a dedicated thread
    event::spawn_event_reader(event_tx.clone());

    // Initialize app (runs detection)
    let mut app = app::App::new(ctx, event_tx).await?;

    // Initial draw
    app.draw(&mut terminal)?;

    // Main loop
    while !app.state.should_quit {
        if let Some(event) = event_rx.recv().await {
            // Check if we need to suspend for example running
            if let AppEvent::Key(key) = &event {
                if app.state.active_tab == state::Tab::Run
                    && !app.state.show_help
                    && matches!(
                        key.code,
                        crossterm::event::KeyCode::Enter | crossterm::event::KeyCode::Char('r')
                    )
                    && !app.state.examples.is_empty()
                    && !matches!(app.state.run_process, state::ProcessStatus::Running)
                {
                    app.run_example_suspended(&mut terminal).await?;
                    app.draw(&mut terminal)?;
                    continue;
                }
            }

            app.handle_event(event).await;
            app.draw(&mut terminal)?;
        }
    }

    Ok(())
}
