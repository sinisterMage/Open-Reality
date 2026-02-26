//! Rhai scripting engine for the WASM runtime.
//!
//! Scripts are transpiled from Julia to Rhai by the Julia-side `script_transpiler.jl`
//! and embedded in the ORSB binary. This module compiles and runs them at runtime.

pub mod engine;
pub mod host_api;
pub mod game_state;
pub mod ui_api;

pub use engine::ScriptEngine;
pub use game_state::GameState;
