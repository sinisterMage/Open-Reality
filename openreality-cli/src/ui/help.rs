use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

pub fn render_overlay(frame: &mut Frame) {
    let area = centered_rect(60, 70, frame.area());
    frame.render_widget(Clear, area);

    let help_text = vec![
        Line::styled("Global", Style::default().bold().fg(Color::Cyan)),
        Line::raw("  q / Ctrl-C    Quit"),
        Line::raw("  ?             Toggle this help"),
        Line::raw("  1-4           Switch tabs"),
        Line::raw("  Tab / S-Tab   Next/prev tab"),
        Line::raw("  Esc           Close overlay"),
        Line::raw(""),
        Line::styled("Navigation", Style::default().bold().fg(Color::Cyan)),
        Line::raw("  j / Down      Move down"),
        Line::raw("  k / Up        Move up"),
        Line::raw("  h / Left      Previous option"),
        Line::raw("  l / Right     Next option"),
        Line::raw(""),
        Line::styled("Build Tab", Style::default().bold().fg(Color::Cyan)),
        Line::raw("  Enter / b     Start build"),
        Line::raw(""),
        Line::styled("Run Tab", Style::default().bold().fg(Color::Cyan)),
        Line::raw("  Enter / r     Run example"),
        Line::raw("  (TUI suspends for GLFW window)"),
        Line::raw(""),
        Line::styled("Setup Tab", Style::default().bold().fg(Color::Cyan)),
        Line::raw("  Enter         Run selected action"),
        Line::raw(""),
        Line::styled("Log Panels", Style::default().bold().fg(Color::Cyan)),
        Line::raw("  g             Scroll to top"),
        Line::raw("  G             Scroll to bottom"),
        Line::raw("  PgUp / PgDn   Scroll by page"),
    ];

    let paragraph = Paragraph::new(help_text).block(
        Block::default()
            .borders(Borders::ALL)
            .title(" Keybindings ")
            .border_style(Style::default().fg(Color::Cyan)),
    );
    frame.render_widget(paragraph, area);
}

fn centered_rect(percent_x: u16, percent_y: u16, area: Rect) -> Rect {
    let popup_layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(area);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(popup_layout[1])[1]
}
