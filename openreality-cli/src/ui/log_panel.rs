use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState};

use crate::state::LogBuffer;

pub fn render(frame: &mut Frame, log: &LogBuffer, area: Rect, title: &str) {
    let inner_height = area.height.saturating_sub(2) as usize; // borders
    let total_lines = log.lines.len();

    // Calculate visible window
    let start = if log.auto_scroll {
        total_lines.saturating_sub(inner_height)
    } else {
        log.scroll_offset.min(total_lines.saturating_sub(inner_height))
    };

    let lines: Vec<Line> = log
        .lines
        .iter()
        .skip(start)
        .take(inner_height)
        .map(|l| {
            let style = if l.is_stderr {
                Style::default().fg(Color::Red)
            } else {
                Style::default().fg(Color::White)
            };
            Line::styled(l.text.clone(), style)
        })
        .collect();

    let paragraph = Paragraph::new(lines)
        .block(Block::default().borders(Borders::ALL).title(title));

    frame.render_widget(paragraph, area);

    // Scrollbar
    if total_lines > inner_height {
        let mut scrollbar_state =
            ScrollbarState::new(total_lines.saturating_sub(inner_height)).position(start);
        let scrollbar = Scrollbar::new(ScrollbarOrientation::VerticalRight);
        frame.render_stateful_widget(
            scrollbar,
            area.inner(Margin {
                vertical: 1,
                horizontal: 0,
            }),
            &mut scrollbar_state,
        );
    }
}
