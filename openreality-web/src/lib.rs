//! OpenReality WASM Web Runtime
//!
//! Loads .orsb scene bundles exported from the Julia engine and renders them
//! in the browser using WebGPU. Handles physics (via simplified solver),
//! animation, skinning, particles, input, and audio.

#[cfg(target_arch = "wasm32")]
mod app;
mod scene;
mod transform;
mod animation;
mod skinning;
mod particles;
mod input;
mod scripting;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

/// Entry point — called when the WASM module loads.
#[cfg(target_arch = "wasm32")]
#[wasm_bindgen(start)]
pub fn start() {
    console_error_panic_hook::set_once();
    console_log::init_with_level(log::Level::Info).expect("Failed to init logger");
    log::info!("OpenReality Web Runtime initialized");
}

/// Create a new application instance from an ORSB scene file.
///
/// Called from JavaScript after fetching the .orsb binary data.
#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
pub async fn create_app(canvas_id: String, scene_data: Vec<u8>) -> Result<app::App, JsValue> {
    let app = app::App::new(&canvas_id, &scene_data).await?;
    Ok(app)
}
