//! UI host functions for Rhai scripts.
//!
//! Scripts call `ui_text(...)`, `ui_rect(...)`, `ui_button(...)`, `ui_progress_bar(...)`.
//! These accumulate draw commands that the renderer consumes each frame.

/// A single UI draw command produced by scripts.
#[derive(Clone, Debug)]
pub enum UiCommand {
    Text {
        text: String,
        x: f32,
        y: f32,
        size: f32,
        r: f32,
        g: f32,
        b: f32,
    },
    Rect {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    },
    Button {
        text: String,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        r: f32,
        g: f32,
        b: f32,
    },
    ProgressBar {
        fraction: f32,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fg_r: f32,
        fg_g: f32,
        fg_b: f32,
        bg_r: f32,
        bg_g: f32,
        bg_b: f32,
    },
}

/// Accumulates UI commands from scripts during a frame.
pub struct UiCommandBuffer {
    pub commands: Vec<UiCommand>,
    /// Tracks which buttons were clicked (by index in commands vec).
    pub button_results: Vec<bool>,
}

impl UiCommandBuffer {
    pub fn new() -> Self {
        Self {
            commands: Vec::new(),
            button_results: Vec::new(),
        }
    }

    /// Clear all commands for a new frame.
    pub fn clear(&mut self) {
        self.commands.clear();
        self.button_results.clear();
    }

    pub fn push_text(&mut self, text: String, x: f32, y: f32, size: f32, r: f32, g: f32, b: f32) {
        self.commands.push(UiCommand::Text { text, x, y, size, r, g, b });
    }

    pub fn push_rect(&mut self, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32, a: f32) {
        self.commands.push(UiCommand::Rect { x, y, w, h, r, g, b, a });
    }

    pub fn push_button(&mut self, text: String, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32) -> bool {
        let idx = self.commands.len();
        self.commands.push(UiCommand::Button { text, x, y, w, h, r, g, b });
        // Return whether this button was clicked (from previous frame's hit test)
        self.button_results.get(idx).copied().unwrap_or(false)
    }

    pub fn push_progress_bar(
        &mut self, fraction: f32, x: f32, y: f32, w: f32, h: f32,
        fg_r: f32, fg_g: f32, fg_b: f32, bg_r: f32, bg_g: f32, bg_b: f32,
    ) {
        self.commands.push(UiCommand::ProgressBar {
            fraction, x, y, w, h, fg_r, fg_g, fg_b, bg_r, bg_g, bg_b,
        });
    }

    /// Hit-test a mouse click against all buttons from the previous frame.
    pub fn hit_test(&mut self, mouse_x: f32, mouse_y: f32, canvas_w: f32, canvas_h: f32) {
        self.button_results.clear();
        for cmd in &self.commands {
            match cmd {
                UiCommand::Button { x, y, w, h, .. } => {
                    // Convert normalized coords to pixels for hit test
                    let bx = x * canvas_w;
                    let by = y * canvas_h;
                    let bw = w * canvas_w;
                    let bh = h * canvas_h;
                    let hit = mouse_x >= bx && mouse_x <= bx + bw
                        && mouse_y >= by && mouse_y <= by + bh;
                    self.button_results.push(hit);
                }
                _ => {
                    self.button_results.push(false);
                }
            }
        }
    }
}

/// Register UI functions into a Rhai engine.
///
/// The UiCommandBuffer is accessed through a shared pointer so scripts can
/// push commands during execution.
pub fn register_ui_api(engine: &mut rhai::Engine) {
    // UI functions are registered by the ScriptEngine which provides the
    // UiCommandBuffer via closure capture. See engine.rs for registration.
    let _ = engine; // Placeholder — actual registration happens in engine.rs
}
