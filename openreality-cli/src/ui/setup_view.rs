use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph};

use crate::state::{AppState, ProcessStatus, SetupAction};
use crate::ui::log_panel;

pub fn render(frame: &mut Frame, state: &AppState, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(30), Constraint::Min(0)])
        .split(area);

    let left_chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(4)])
        .split(chunks[0]);

    // Action list
    let items: Vec<ListItem> = SetupAction::ALL
        .iter()
        .enumerate()
        .map(|(i, action)| {
            let marker = if i == state.setup_selected {
                "> "
            } else {
                "  "
            };
            let style = if i == state.setup_selected {
                Style::default().fg(Color::Yellow).bold()
            } else {
                Style::default()
            };
            ListItem::new(format!("{marker}{}", action.label())).style(style)
        })
        .collect();

    let list = List::new(items).block(
        Block::default()
            .borders(Borders::ALL)
            .title(" Actions ")
            .border_style(Style::default().fg(Color::Cyan)),
    );
    frame.render_widget(list, left_chunks[0]);

    // Hint box
    let process_hint = match &state.setup_process {
        ProcessStatus::Running => "Running...",
        ProcessStatus::Finished { exit_code } => {
            if *exit_code == Some(0) {
                "Done"
            } else {
                "Failed"
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
        Line::raw("[Enter] Run action"),
    ];
    let hint_box = Paragraph::new(hints).block(Block::default().borders(Borders::ALL));
    frame.render_widget(hint_box, left_chunks[1]);

    // Right: log
    log_panel::render(frame, &state.setup_log, chunks[1], " Log ");
}
