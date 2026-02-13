use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Cell, Paragraph, Row, Table};

use crate::state::AppState;
use crate::ui::status;

pub fn render(frame: &mut Frame, state: &AppState, area: Rect) {
    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(55), Constraint::Percentage(45)])
        .split(area);

    let left_chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Percentage(60), Constraint::Percentage(40)])
        .split(columns[0]);

    // Backend status table
    let rows: Vec<Row> = state
        .backends
        .iter()
        .map(|bs| {
            Row::new(vec![
                Cell::from(bs.backend.label()),
                Cell::from(status::build_status_span(&bs.build_status)),
                Cell::from(status::deps_span(bs.deps_satisfied)),
            ])
        })
        .collect();

    let table = Table::new(
        rows,
        [
            Constraint::Length(14),
            Constraint::Length(26),
            Constraint::Min(12),
        ],
    )
    .block(Block::default().borders(Borders::ALL).title(" Backends "))
    .header(
        Row::new(["Backend", "Status", "Dependencies"])
            .style(Style::default().bold().fg(Color::Cyan)),
    );
    frame.render_widget(table, left_chunks[0]);

    // Project info
    let pkg_status = match state.julia_packages_installed {
        Some(true) => "Installed (Manifest.toml exists)",
        Some(false) => "Not installed (run Pkg.instantiate())",
        None => "Unknown (no Project.toml found)",
    };
    let info_text = vec![
        Line::from(vec![
            Span::styled("Project: ", Style::default().bold()),
            Span::raw("OpenReality"),
        ]),
        Line::from(vec![
            Span::styled("Julia Packages: ", Style::default().bold()),
            Span::raw(pkg_status),
        ]),
        Line::from(vec![
            Span::styled("Examples: ", Style::default().bold()),
            Span::raw(format!("{} found", state.examples.len())),
        ]),
        Line::raw(""),
        Line::styled(
            "Use the Build tab (2) to build backends",
            Style::default().fg(Color::DarkGray),
        ),
        Line::styled(
            "Use the Run tab (3) to run examples",
            Style::default().fg(Color::DarkGray),
        ),
    ];
    let info = Paragraph::new(info_text)
        .block(Block::default().borders(Borders::ALL).title(" Project "));
    frame.render_widget(info, left_chunks[1]);

    // Right column: tool detection
    let right_chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Percentage(65), Constraint::Percentage(35)])
        .split(columns[1]);

    // Tools table
    let tool_rows = vec![
        Row::new(vec![
            Cell::from("julia"),
            Cell::from(status::tool_status_span(&state.tools.julia)),
        ]),
        Row::new(vec![
            Cell::from("cargo"),
            Cell::from(status::tool_status_span(&state.tools.cargo)),
        ]),
        Row::new(vec![
            Cell::from("swift"),
            Cell::from(status::tool_status_span(&state.tools.swift)),
        ]),
        Row::new(vec![
            Cell::from("wasm-pack"),
            Cell::from(status::tool_status_span(&state.tools.wasm_pack)),
        ]),
        Row::new(vec![
            Cell::from("vulkaninfo"),
            Cell::from(status::tool_status_span(&state.tools.vulkaninfo)),
        ]),
    ];

    let tools_table = Table::new(
        tool_rows,
        [Constraint::Length(12), Constraint::Min(20)],
    )
    .block(Block::default().borders(Borders::ALL).title(" Tools "))
    .header(
        Row::new(["Tool", "Status"]).style(Style::default().bold().fg(Color::Cyan)),
    );
    frame.render_widget(tools_table, right_chunks[0]);

    // System libraries
    let lib_rows = vec![
        Row::new(vec![
            Cell::from("GLFW"),
            Cell::from(status::library_status_span(&state.tools.glfw)),
        ]),
        Row::new(vec![
            Cell::from("OpenGL Dev"),
            Cell::from(status::library_status_span(&state.tools.opengl_dev)),
        ]),
    ];

    let libs_table = Table::new(
        lib_rows,
        [Constraint::Length(12), Constraint::Min(20)],
    )
    .block(
        Block::default()
            .borders(Borders::ALL)
            .title(" System Libraries "),
    )
    .header(
        Row::new(["Library", "Status"]).style(Style::default().bold().fg(Color::Cyan)),
    );
    frame.render_widget(libs_table, right_chunks[1]);
}
