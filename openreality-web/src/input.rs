use std::sync::{Arc, Mutex};

/// Browser input state — keyboard, mouse, and touch events.
///
/// Shared via `Arc<Mutex<>>` so browser event closures can write to it.
pub struct InputState {
    pub keys_down: [bool; 256],
    pub mouse_x: f64,
    pub mouse_y: f64,
    pub mouse_dx: f64,
    pub mouse_dy: f64,
    pub mouse_buttons: [bool; 3],
    /// Whether the previous frame had a mouse click (for UI hit testing).
    pub mouse_clicked: bool,
}

impl InputState {
    pub fn new() -> Self {
        Self {
            keys_down: [false; 256],
            mouse_x: 0.0,
            mouse_y: 0.0,
            mouse_dx: 0.0,
            mouse_dy: 0.0,
            mouse_buttons: [false; 3],
            mouse_clicked: false,
        }
    }

    /// Reset per-frame deltas. Call at the start of each frame.
    pub fn update(&mut self) {
        self.mouse_dx = 0.0;
        self.mouse_dy = 0.0;
        self.mouse_clicked = false;
    }

    pub fn is_key_down(&self, key_code: u8) -> bool {
        self.keys_down[key_code as usize]
    }
}

/// Map a browser KeyboardEvent.code string to our key code index (0-255).
pub fn key_code_from_str(code: &str) -> Option<u8> {
    match code {
        "KeyA" => Some(65), "KeyB" => Some(66), "KeyC" => Some(67), "KeyD" => Some(68),
        "KeyE" => Some(69), "KeyF" => Some(70), "KeyG" => Some(71), "KeyH" => Some(72),
        "KeyI" => Some(73), "KeyJ" => Some(74), "KeyK" => Some(75), "KeyL" => Some(76),
        "KeyM" => Some(77), "KeyN" => Some(78), "KeyO" => Some(79), "KeyP" => Some(80),
        "KeyQ" => Some(81), "KeyR" => Some(82), "KeyS" => Some(83), "KeyT" => Some(84),
        "KeyU" => Some(85), "KeyV" => Some(86), "KeyW" => Some(87), "KeyX" => Some(88),
        "KeyY" => Some(89), "KeyZ" => Some(90),
        "Digit0" => Some(48), "Digit1" => Some(49), "Digit2" => Some(50),
        "Digit3" => Some(51), "Digit4" => Some(52), "Digit5" => Some(53),
        "Digit6" => Some(54), "Digit7" => Some(55), "Digit8" => Some(56), "Digit9" => Some(57),
        "Space" => Some(32),
        "Enter" => Some(13),
        "Escape" => Some(27),
        "Tab" => Some(9),
        "ShiftLeft" | "ShiftRight" => Some(16),
        "ControlLeft" | "ControlRight" => Some(17),
        "AltLeft" | "AltRight" => Some(18),
        "ArrowUp" => Some(38),
        "ArrowDown" => Some(40),
        "ArrowLeft" => Some(37),
        "ArrowRight" => Some(39),
        "Backspace" => Some(8),
        _ => None,
    }
}

/// Bind keyboard and mouse event listeners on the canvas/document.
///
/// This wires up browser events to write into the shared `InputState`.
#[cfg(target_arch = "wasm32")]
pub fn bind_events(
    canvas: &web_sys::HtmlCanvasElement,
    document: &web_sys::Document,
    input: Arc<Mutex<InputState>>,
) {
    use wasm_bindgen::prelude::*;
    use wasm_bindgen::JsCast;
    use web_sys::{KeyboardEvent, PointerEvent};

    // Keyboard: keydown
    {
        let inp = input.clone();
        let cb = Closure::<dyn FnMut(KeyboardEvent)>::new(move |e: KeyboardEvent| {
            if let Some(code) = key_code_from_str(&e.code()) {
                inp.lock().unwrap().keys_down[code as usize] = true;
            }
            // Prevent default for game keys to avoid scrolling etc.
            e.prevent_default();
        });
        document.add_event_listener_with_callback("keydown", cb.as_ref().unchecked_ref()).ok();
        cb.forget();
    }

    // Keyboard: keyup
    {
        let inp = input.clone();
        let cb = Closure::<dyn FnMut(KeyboardEvent)>::new(move |e: KeyboardEvent| {
            if let Some(code) = key_code_from_str(&e.code()) {
                inp.lock().unwrap().keys_down[code as usize] = false;
            }
        });
        document.add_event_listener_with_callback("keyup", cb.as_ref().unchecked_ref()).ok();
        cb.forget();
    }

    // Mouse: pointermove (for mouse delta — works with pointer lock)
    {
        let inp = input.clone();
        let cb = Closure::<dyn FnMut(PointerEvent)>::new(move |e: PointerEvent| {
            let mut state = inp.lock().unwrap();
            state.mouse_dx += e.movement_x() as f64;
            state.mouse_dy += e.movement_y() as f64;
            state.mouse_x = e.offset_x() as f64;
            state.mouse_y = e.offset_y() as f64;
        });
        canvas.add_event_listener_with_callback("pointermove", cb.as_ref().unchecked_ref()).ok();
        cb.forget();
    }

    // Mouse: pointerdown
    {
        let inp = input.clone();
        let cb = Closure::<dyn FnMut(PointerEvent)>::new(move |e: PointerEvent| {
            let btn = e.button() as usize;
            let mut state = inp.lock().unwrap();
            if btn < 3 {
                state.mouse_buttons[btn] = true;
            }
            state.mouse_clicked = true;
        });
        canvas.add_event_listener_with_callback("pointerdown", cb.as_ref().unchecked_ref()).ok();
        cb.forget();
    }

    // Mouse: pointerup
    {
        let inp = input.clone();
        let cb = Closure::<dyn FnMut(PointerEvent)>::new(move |e: PointerEvent| {
            let btn = e.button() as usize;
            if btn < 3 {
                inp.lock().unwrap().mouse_buttons[btn] = false;
            }
        });
        canvas.add_event_listener_with_callback("pointerup", cb.as_ref().unchecked_ref()).ok();
        cb.forget();
    }

    // Click on canvas -> request pointer lock (for FPS-style mouse control)
    {
        let canvas_clone = canvas.clone();
        let cb = Closure::<dyn FnMut()>::new(move || {
            canvas_clone.request_pointer_lock();
        });
        canvas.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()).ok();
        cb.forget();
    }
}
