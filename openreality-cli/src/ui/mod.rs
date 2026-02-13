pub mod build_view;
pub mod dashboard;
pub mod help;
pub mod log_panel;
pub mod run_view;
pub mod setup_view;
pub mod status;

use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Paragraph, Tabs};

use crate::state::{AppState, Tab};

pub fn render(frame: &mut Frame, state: &AppState) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3), // tab bar
            Constraint::Min(0),   // main content
            Constraint::Length(1), // status bar
        ])
        .split(frame.area());

    // Tab bar
    let tab_titles: Vec<&str> = Tab::ALL.iter().map(|t| t.label()).collect();
    let tabs = Tabs::new(tab_titles)
        .block(
            Block::default()
                .borders(Borders::BOTTOM)
                .title(" Open Reality ")
                .title_style(Style::default().fg(Color::Cyan).bold()),
        )
        .highlight_style(Style::default().fg(Color::Yellow).bold().underlined())
        .select(state.active_tab.index())
        .divider(" | ");
    frame.render_widget(tabs, chunks[0]);

    // Main content
    match state.active_tab {
        Tab::Dashboard => dashboard::render(frame, state, chunks[1]),
        Tab::Build => build_view::render(frame, state, chunks[1]),
        Tab::Run => run_view::render(frame, state, chunks[1]),
        Tab::Setup => setup_view::render(frame, state, chunks[1]),
    }

    // Status bar
    let status_text = format!(
        " {} | {} | q: quit | ?: help | 1-4: tabs | Tab: next",
        state.platform.label(),
        state.project_root.display()
    );
    let status_bar =
        Paragraph::new(status_text).style(Style::default().bg(Color::DarkGray).fg(Color::White));
    frame.render_widget(status_bar, chunks[2]);

    // Help overlay
    if state.show_help {
        help::render_overlay(frame);
    }
}
