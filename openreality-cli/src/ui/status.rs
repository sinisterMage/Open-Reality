use ratatui::prelude::*;
use ratatui::text::Span;

use crate::state::*;

pub fn tool_status_span(status: &ToolStatus) -> Span<'static> {
    match status {
        ToolStatus::Found { version, .. } => {
            let text = format!(" OK  {version}");
            Span::styled(text, Style::default().fg(Color::Green))
        }
        ToolStatus::NotFound => Span::styled(" MISSING ", Style::default().fg(Color::Red).bold()),
    }
}

pub fn library_status_span(status: &LibraryStatus) -> Span<'static> {
    match status {
        LibraryStatus::Found => Span::styled(" OK ", Style::default().fg(Color::Green)),
        LibraryStatus::NotFound => {
            Span::styled(" MISSING ", Style::default().fg(Color::Red).bold())
        }
        LibraryStatus::Unknown => {
            Span::styled(" N/A ", Style::default().fg(Color::DarkGray))
        }
    }
}

pub fn build_status_span(status: &BuildStatus) -> Span<'static> {
    match status {
        BuildStatus::NotNeeded => Span::styled(
            " READY ",
            Style::default().fg(Color::Green),
        ),
        BuildStatus::Built { modified, .. } => {
            let text = match modified {
                Some(m) => format!(" BUILT ({m}) "),
                None => " BUILT ".to_string(),
            };
            Span::styled(text, Style::default().fg(Color::Green).bold())
        }
        BuildStatus::NotBuilt => {
            Span::styled(" NOT BUILT ", Style::default().fg(Color::Yellow))
        }
        BuildStatus::Building => Span::styled(
            " BUILDING... ",
            Style::default().fg(Color::Yellow).bold(),
        ),
        BuildStatus::BuildFailed { .. } => {
            Span::styled(" FAILED ", Style::default().fg(Color::Red).bold())
        }
    }
}

pub fn deps_span(satisfied: bool) -> Span<'static> {
    if satisfied {
        Span::styled("deps OK", Style::default().fg(Color::Green))
    } else {
        Span::styled("deps missing", Style::default().fg(Color::Red))
    }
}
