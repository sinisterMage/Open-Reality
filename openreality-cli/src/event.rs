use crossterm::event::{self, Event as CEvent, KeyEvent};
use std::time::Duration;
use tokio::sync::mpsc;

use crate::build::BuildEvent;
use crate::runner::RunEvent;

#[derive(Debug)]
pub enum AppEvent {
    Key(KeyEvent),
    Tick,
    Build(BuildEvent),
    Run(RunEvent),
    Setup(RunEvent),
}

pub fn spawn_event_reader(tx: mpsc::UnboundedSender<AppEvent>) {
    std::thread::spawn(move || loop {
        if event::poll(Duration::from_millis(100)).unwrap_or(false) {
            if let Ok(ev) = event::read() {
                match ev {
                    CEvent::Key(key) => {
                        if tx.send(AppEvent::Key(key)).is_err() {
                            return;
                        }
                    }
                    _ => {}
                }
            }
        } else if tx.send(AppEvent::Tick).is_err() {
            return;
        }
    });
}
