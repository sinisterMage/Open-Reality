use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph};

use crate::state::{AppState, BuildStatus, ProcessStatus};
use crate::ui::log_panel;

pub fn render(frame: &mut Frame, state: &AppState, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(26), Constraint::Min(0)])
        .split(area);

    // Left: backend selector
    let left_chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(5)])
        .split(chunks[0]);

    let items: Vec<ListItem> = state
        .backends
        .iter()
        .enumerate()
        .map(|(i, bs)| {
            let marker = if i == state.build_selected {
                "> "
            } else {
                "  "
            };
            let style = match &bs.build_status {
                BuildStatus::Built { .. } | BuildStatus::NotNeeded => {
                    Style::default().fg(Color::Green)
                }
                BuildStatus::Building => Style::default().fg(Color::Yellow),
                BuildStatus::BuildFailed { .. } => Style::default().fg(Color::Red),
                BuildStatus::NotBuilt => Style::default().fg(Color::White),
            };
            ListItem::new(format!("{marker}{}", bs.backend.label())).style(style)
        })
        .collect();

    let list = List::new(items).block(
        Block::default()
            .borders(Borders::ALL)
            .title(" Backend ")
            .border_style(Style::default().fg(Color::Cyan)),
    );
    frame.render_widget(list, left_chunks[0]);

    // Hint box
    let process_hint = match &state.build_process {
        ProcessStatus::Running => "Building...",
        ProcessStatus::Finished { exit_code } => {
            if *exit_code == Some(0) {
                "Build OK"
            } else {
                "Build FAILED"
            }
        }
        ProcessStatus::Idle => "Idle",
        ProcessStatus::Failed { .. } => "Error",
    };

    let hints = vec![
        Line::styled(
            format!("Status: {process_hint}"),
            Style::default().bold(),
        ),
        Line::raw(""),
        Line::raw("[Enter/b] Build"),
        Line::raw("[g/G] Top/Bottom"),
    ];
    let hint_box = Paragraph::new(hints).block(Block::default().borders(Borders::ALL));
    frame.render_widget(hint_box, left_chunks[1]);

    // Right: build log
    log_panel::render(frame, &state.build_log, chunks[1], " Build Log ");
}
