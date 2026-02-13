use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph};

use crate::state::{AppState, Backend, ProcessStatus};
use crate::ui::log_panel;

pub fn render(frame: &mut Frame, state: &AppState, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
        .split(area);

    let left_chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(5)])
        .split(chunks[0]);

    // Example list
    let items: Vec<ListItem> = state
        .examples
        .iter()
        .enumerate()
        .map(|(i, ex)| {
            let marker = if i == state.run_selected {
                "> "
            } else {
                "  "
            };
            let backend_tag = match &ex.required_backend {
                Some(Backend::Metal) => " [Metal]",
                Some(Backend::Vulkan) => " [Vulkan]",
                Some(Backend::WebGPU) => " [WebGPU]",
                _ => "",
            };
            let style = if i == state.run_selected {
                Style::default().fg(Color::Yellow).bold()
            } else {
                Style::default()
            };
            ListItem::new(format!("{marker}{}{backend_tag}", ex.filename)).style(style)
        })
        .collect();

    let list = List::new(items).block(
        Block::default()
            .borders(Borders::ALL)
            .title(" Examples ")
            .border_style(Style::default().fg(Color::Cyan)),
    );
    frame.render_widget(list, left_chunks[0]);

    // Bottom info: backend selector + hints
    let runnable = state.runnable_backends();
    let backend_label = runnable
        .get(state.run_backend_idx)
        .map(|b| b.backend.label())
        .unwrap_or("None");

    let process_hint = match &state.run_process {
        ProcessStatus::Running => "Running...",
        ProcessStatus::Finished { exit_code } => {
            if *exit_code == Some(0) {
                "Finished OK"
            } else {
                "Exited"
            }
        }
        ProcessStatus::Idle => "Idle",
        ProcessStatus::Failed { .. } => "Error",
    };

    // Description of selected example
    let desc = state
        .examples
        .get(state.run_selected)
        .map(|e| e.description.as_str())
        .unwrap_or("");

    let hints = vec![
        Line::from(vec![
            Span::raw("Backend: < "),
            Span::styled(backend_label, Style::default().fg(Color::Cyan).bold()),
            Span::raw(" >  [h/l] switch"),
        ]),
        Line::styled(
            format!("Status: {process_hint}"),
            Style::default().bold(),
        ),
        Line::raw(format!("{desc}")),
    ];
    let hint_box = Paragraph::new(hints).block(Block::default().borders(Borders::ALL));
    frame.render_widget(hint_box, left_chunks[1]);

    // Right: output log
    log_panel::render(frame, &state.run_log, chunks[1], " Output ");
}
