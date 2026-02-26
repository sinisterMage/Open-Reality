//! Shared mutable game state — the web runtime equivalent of Julia's `Ref{T}` values.
//!
//! Game scripts read/write named values via `game_state_get` / `game_state_set`.
//! Values are initialized from the ORSB GameRef section.

use rhai::Dynamic;
use std::collections::HashMap;

use openreality_gpu_shared::scene_format::GameRefParsed;

/// Shared game state container — holds named dynamic values.
pub struct GameState {
    values: HashMap<String, Dynamic>,
}

impl GameState {
    /// Create a new empty game state.
    pub fn new() -> Self {
        Self {
            values: HashMap::new(),
        }
    }

    /// Initialize from parsed ORSB game refs.
    pub fn from_refs(refs: &[GameRefParsed]) -> Self {
        let mut values = HashMap::with_capacity(refs.len());
        for r in refs {
            let val = match r.value_type {
                0 => Dynamic::from(r.default_f64.unwrap_or(0.0) as f32),
                1 => Dynamic::from(r.default_bool.unwrap_or(false)),
                2 => Dynamic::from(r.default_i64.unwrap_or(0)),
                3 => Dynamic::from(r.default_string.clone().unwrap_or_default()),
                _ => Dynamic::UNIT,
            };
            values.insert(r.name.clone(), val);
        }
        Self { values }
    }

    /// Get a value by name. Returns `()` if not found.
    pub fn get(&self, name: &str) -> Dynamic {
        self.values.get(name).cloned().unwrap_or(Dynamic::UNIT)
    }

    /// Set a value by name.
    pub fn set(&mut self, name: &str, val: Dynamic) {
        self.values.insert(name.to_string(), val);
    }

    /// Check if a key exists.
    pub fn has(&self, name: &str) -> bool {
        self.values.contains_key(name)
    }
}
