//! Rhai scripting engine — compiles and runs scripts from ORSB.
//!
//! Each script is a Rhai source string associated with an entity and callback type
//! (on_start, on_update, on_destroy). The engine compiles them into ASTs at load time
//! and evaluates them per-frame.
//!
//! Rhai's `sync` feature requires `Send + Sync` closures, so shared state uses
//! `Arc<Mutex<T>>`. This is fine in single-threaded WASM (no contention).

use rhai::{Engine, AST, Scope, Dynamic, Map, Array, ImmutableString};
use std::sync::{Arc, Mutex};

use openreality_gpu_shared::scene_format::ScriptParsed;
use crate::scene::LoadedScene;
use crate::input::InputState;
use super::game_state::GameState;
use super::host_api;
use super::ui_api::UiCommandBuffer;

/// Callback type matching the ORSB format.
const CB_ON_START: u8 = 0;
const CB_ON_UPDATE: u8 = 1;
const CB_ON_DESTROY: u8 = 2;

/// A compiled script bound to an entity.
struct CompiledScript {
    entity_index: u32,
    #[allow(dead_code)]
    callback_type: u8,
    ast: AST,
}

/// Shared scene bridge state that Rhai host functions read/write.
pub struct SceneBridge {
    /// Positions: [entity_index] -> (x, y, z) in f64
    pub positions: Vec<[f64; 3]>,
    /// Rotations: [entity_index] -> (w, x, y, z) in f64
    pub rotations: Vec<[f64; 4]>,
    /// Scales: [entity_index] -> (x, y, z) in f64
    pub scales: Vec<[f64; 3]>,
    /// Component masks per entity (for has_component / entities_with).
    pub component_masks: Vec<u64>,
    /// Mesh indices per entity.
    pub mesh_indices: Vec<Option<usize>>,
    /// Material indices per entity.
    pub material_indices: Vec<Option<usize>>,
    /// Entities pending spawn (accumulated during script execution).
    pub spawn_queue: Vec<Map>,
    /// Entities pending despawn.
    pub despawn_queue: Vec<u32>,
    /// Active FSM state transition request.
    pub pending_transition: Option<String>,
    /// Number of entities.
    pub num_entities: usize,
}

impl SceneBridge {
    fn new(num_entities: usize) -> Self {
        Self {
            positions: vec![[0.0; 3]; num_entities],
            rotations: vec![[1.0, 0.0, 0.0, 0.0]; num_entities],
            scales: vec![[1.0; 3]; num_entities],
            component_masks: vec![0; num_entities],
            mesh_indices: vec![None; num_entities],
            material_indices: vec![None; num_entities],
            spawn_queue: Vec::new(),
            despawn_queue: Vec::new(),
            pending_transition: None,
            num_entities,
        }
    }

    /// Sync scene data INTO the bridge (call before running scripts).
    fn sync_from_scene(&mut self, scene: &LoadedScene) {
        let n = scene.entities.len();
        if self.num_entities != n {
            self.positions.resize(n, [0.0; 3]);
            self.rotations.resize(n, [1.0, 0.0, 0.0, 0.0]);
            self.scales.resize(n, [1.0; 3]);
            self.component_masks.resize(n, 0);
            self.mesh_indices.resize(n, None);
            self.material_indices.resize(n, None);
            self.num_entities = n;
        }
        for (i, e) in scene.entities.iter().enumerate() {
            self.positions[i] = [
                e.transform.position.x,
                e.transform.position.y,
                e.transform.position.z,
            ];
            self.rotations[i] = [
                e.transform.rotation.w,
                e.transform.rotation.x,
                e.transform.rotation.y,
                e.transform.rotation.z,
            ];
            self.scales[i] = [
                e.transform.scale.x,
                e.transform.scale.y,
                e.transform.scale.z,
            ];
            self.component_masks[i] = e.mask.0;
            self.mesh_indices[i] = e.mesh_index;
            self.material_indices[i] = e.material_index;
        }
        self.spawn_queue.clear();
        self.despawn_queue.clear();
        self.pending_transition = None;
    }

    /// Sync bridge data BACK to the scene (call after running scripts).
    fn sync_to_scene(&self, scene: &mut LoadedScene) {
        for (i, e) in scene.entities.iter_mut().enumerate() {
            if i >= self.num_entities {
                break;
            }
            let p = &self.positions[i];
            let r = &self.rotations[i];
            let s = &self.scales[i];
            e.transform.position = glam::DVec3::new(p[0], p[1], p[2]);
            e.transform.rotation = glam::DQuat::from_xyzw(r[1], r[2], r[3], r[0]);
            e.transform.scale = glam::DVec3::new(s[0], s[1], s[2]);
            e.transform.dirty = true;
        }
    }
}

type SharedBridge = Arc<Mutex<SceneBridge>>;
type SharedGameState = Arc<Mutex<GameState>>;
type SharedInput = Arc<Mutex<InputSnapshot>>;
type SharedUi = Arc<Mutex<UiCommandBuffer>>;

/// A snapshot of input state passed to scripts each frame.
#[derive(Clone)]
pub struct InputSnapshot {
    pub keys_down: [bool; 256],
    pub mouse_dx: f64,
    pub mouse_dy: f64,
    pub mouse_buttons: [bool; 3],
}

impl InputSnapshot {
    pub fn from_input(input: &InputState) -> Self {
        Self {
            keys_down: input.keys_down,
            mouse_dx: input.mouse_dx,
            mouse_dy: input.mouse_dy,
            mouse_buttons: input.mouse_buttons,
        }
    }
}

/// The main scripting engine.
pub struct ScriptEngine {
    engine: Engine,
    on_start_scripts: Vec<CompiledScript>,
    on_update_scripts: Vec<CompiledScript>,
    on_destroy_scripts: Vec<CompiledScript>,
    bridge: SharedBridge,
    game_state: SharedGameState,
    input: SharedInput,
    ui: SharedUi,
    started: bool,
}

impl ScriptEngine {
    /// Create a new ScriptEngine, compile all scripts from the ORSB data.
    pub fn new(
        scripts: &[ScriptParsed],
        game_refs: &[openreality_gpu_shared::scene_format::GameRefParsed],
        num_entities: usize,
    ) -> Self {
        let bridge: SharedBridge = Arc::new(Mutex::new(SceneBridge::new(num_entities)));
        let game_state: SharedGameState = Arc::new(Mutex::new(GameState::from_refs(game_refs)));
        let input: SharedInput = Arc::new(Mutex::new(InputSnapshot {
            keys_down: [false; 256],
            mouse_dx: 0.0,
            mouse_dy: 0.0,
            mouse_buttons: [false; 3],
        }));
        let ui: SharedUi = Arc::new(Mutex::new(UiCommandBuffer::new()));

        let mut engine = Engine::new();

        // Register math/utility host functions
        host_api::register_math_api(&mut engine);

        // Register ECS bridge functions
        Self::register_ecs_api(&mut engine, bridge.clone());

        // Register game state functions
        Self::register_game_state_api(&mut engine, game_state.clone());

        // Register input functions
        Self::register_input_api(&mut engine, input.clone());

        // Register UI functions
        Self::register_ui_api(&mut engine, ui.clone());

        // Register FSM transition
        {
            let b = bridge.clone();
            engine.register_fn("transition", move |state: ImmutableString| {
                b.lock().unwrap().pending_transition = Some(state.to_string());
            });
        }

        // Compile scripts
        let mut on_start_scripts = Vec::new();
        let mut on_update_scripts = Vec::new();
        let mut on_destroy_scripts = Vec::new();

        for script in scripts {
            match engine.compile(&script.rhai_source) {
                Ok(ast) => {
                    let cs = CompiledScript {
                        entity_index: script.entity_index,
                        callback_type: script.callback_type,
                        ast,
                    };
                    match script.callback_type {
                        CB_ON_START => on_start_scripts.push(cs),
                        CB_ON_UPDATE => on_update_scripts.push(cs),
                        CB_ON_DESTROY => on_destroy_scripts.push(cs),
                        _ => log::warn!("Unknown callback type {} for entity {}", script.callback_type, script.entity_index),
                    }
                }
                Err(e) => {
                    log::error!(
                        "Failed to compile script for entity {} (type {}): {}",
                        script.entity_index, script.callback_type, e
                    );
                }
            }
        }

        log::info!(
            "ScriptEngine: compiled {} on_start, {} on_update, {} on_destroy scripts",
            on_start_scripts.len(),
            on_update_scripts.len(),
            on_destroy_scripts.len(),
        );

        Self {
            engine,
            on_start_scripts,
            on_update_scripts,
            on_destroy_scripts,
            bridge,
            game_state,
            input,
            ui,
            started: false,
        }
    }

    /// Run on_start scripts (called once after scene load).
    pub fn run_start(&mut self, scene: &mut LoadedScene) {
        if self.started {
            return;
        }
        self.started = true;
        self.bridge.lock().unwrap().sync_from_scene(scene);

        for script in &self.on_start_scripts {
            let mut scope = Scope::new();
            scope.push("eid", script.entity_index as i64);
            scope.push("dt", 0.0_f32);

            if let Err(e) = self.engine.eval_ast_with_scope::<Dynamic>(&mut scope, &script.ast) {
                log::error!("on_start error (entity {}): {}", script.entity_index, e);
            }
        }

        self.bridge.lock().unwrap().sync_to_scene(scene);
    }

    /// Run on_update scripts for one frame.
    pub fn run_update(&mut self, scene: &mut LoadedScene, input: &InputState, dt: f32) {
        // Sync input snapshot
        {
            let mut inp = self.input.lock().unwrap();
            *inp = InputSnapshot::from_input(input);
        }

        // Clear UI commands for this frame
        self.ui.lock().unwrap().clear();

        // Sync scene -> bridge
        self.bridge.lock().unwrap().sync_from_scene(scene);

        // Run each on_update script
        for script in &self.on_update_scripts {
            let mut scope = Scope::new();
            scope.push("eid", script.entity_index as i64);
            scope.push("dt", dt);

            if let Err(e) = self.engine.eval_ast_with_scope::<Dynamic>(&mut scope, &script.ast) {
                log::error!("on_update error (entity {}): {}", script.entity_index, e);
            }
        }

        // Sync bridge -> scene
        self.bridge.lock().unwrap().sync_to_scene(scene);
    }

    /// Run on_destroy scripts for the given entities.
    pub fn run_destroy(&mut self, scene: &mut LoadedScene, entity_indices: &[u32]) {
        self.bridge.lock().unwrap().sync_from_scene(scene);

        for &eid in entity_indices {
            for script in &self.on_destroy_scripts {
                if script.entity_index == eid {
                    let mut scope = Scope::new();
                    scope.push("eid", eid as i64);
                    scope.push("dt", 0.0_f32);

                    if let Err(e) = self.engine.eval_ast_with_scope::<Dynamic>(&mut scope, &script.ast) {
                        log::error!("on_destroy error (entity {}): {}", eid, e);
                    }
                }
            }
        }

        self.bridge.lock().unwrap().sync_to_scene(scene);
    }

    /// Get pending FSM transition (if any script requested one).
    pub fn pending_transition(&self) -> Option<String> {
        self.bridge.lock().unwrap().pending_transition.clone()
    }

    /// Get the UI command buffer for rendering.
    pub fn ui_commands(&self) -> Arc<Mutex<UiCommandBuffer>> {
        self.ui.clone()
    }

    /// Get the shared game state.
    pub fn game_state(&self) -> Arc<Mutex<GameState>> {
        self.game_state.clone()
    }

    /// Get entities queued for spawn.
    pub fn drain_spawn_queue(&self) -> Vec<Map> {
        let mut b = self.bridge.lock().unwrap();
        std::mem::take(&mut b.spawn_queue)
    }

    /// Get entities queued for despawn.
    pub fn drain_despawn_queue(&self) -> Vec<u32> {
        let mut b = self.bridge.lock().unwrap();
        std::mem::take(&mut b.despawn_queue)
    }

    // ── Private: register host functions ────────────────────────────────

    fn register_ecs_api(engine: &mut Engine, bridge: SharedBridge) {
        // get_component(eid, type_name) -> object map
        {
            let b = bridge.clone();
            engine.register_fn("get_component", move |eid: i64, type_name: ImmutableString| -> Dynamic {
                let br = b.lock().unwrap();
                let idx = eid as usize;
                if idx >= br.num_entities {
                    return Dynamic::UNIT;
                }
                match type_name.as_str() {
                    "TransformComponent" => {
                        let p = &br.positions[idx];
                        let r = &br.rotations[idx];
                        let s = &br.scales[idx];
                        let mut m = Map::new();

                        let mut pos = Map::new();
                        pos.insert("x".into(), Dynamic::from(p[0] as f32));
                        pos.insert("y".into(), Dynamic::from(p[1] as f32));
                        pos.insert("z".into(), Dynamic::from(p[2] as f32));
                        m.insert("position".into(), Dynamic::from(pos));

                        let mut rot = Map::new();
                        rot.insert("w".into(), Dynamic::from(r[0] as f32));
                        rot.insert("x".into(), Dynamic::from(r[1] as f32));
                        rot.insert("y".into(), Dynamic::from(r[2] as f32));
                        rot.insert("z".into(), Dynamic::from(r[3] as f32));
                        m.insert("rotation".into(), Dynamic::from(rot));

                        let mut sc = Map::new();
                        sc.insert("x".into(), Dynamic::from(s[0] as f32));
                        sc.insert("y".into(), Dynamic::from(s[1] as f32));
                        sc.insert("z".into(), Dynamic::from(s[2] as f32));
                        m.insert("scale".into(), Dynamic::from(sc));

                        Dynamic::from(m)
                    }
                    _ => {
                        log::warn!("get_component: unknown type '{}'", type_name);
                        Dynamic::UNIT
                    }
                }
            });
        }

        // has_component(eid, type_name) -> bool
        {
            let b = bridge.clone();
            engine.register_fn("has_component", move |eid: i64, type_name: ImmutableString| -> bool {
                let br = b.lock().unwrap();
                let idx = eid as usize;
                if idx >= br.num_entities {
                    return false;
                }
                let mask = br.component_masks[idx];
                component_type_to_bit(type_name.as_str())
                    .map(|bit| mask & bit != 0)
                    .unwrap_or(false)
            });
        }

        // entities_with(type_name) -> array of entity IDs
        {
            let b = bridge.clone();
            engine.register_fn("entities_with", move |type_name: ImmutableString| -> Array {
                let br = b.lock().unwrap();
                let bit = match component_type_to_bit(type_name.as_str()) {
                    Some(b) => b,
                    None => return Array::new(),
                };
                let mut result = Array::new();
                for i in 0..br.num_entities {
                    if br.component_masks[i] & bit != 0 {
                        result.push(Dynamic::from(i as i64));
                    }
                }
                result
            });
        }

        // set_component(eid, type_name, field, value) — writes component data back
        {
            let b = bridge.clone();
            engine.register_fn("set_component", move |eid: i64, type_name: ImmutableString, field: ImmutableString, val: Dynamic| {
                let mut br = b.lock().unwrap();
                let idx = eid as usize;
                if idx >= br.num_entities {
                    return;
                }
                match type_name.as_str() {
                    "TransformComponent" => {
                        if let Some(map) = val.try_cast::<Map>() {
                            match field.as_str() {
                                "position" => {
                                    br.positions[idx][0] = map.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0) as f64;
                                    br.positions[idx][1] = map.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0) as f64;
                                    br.positions[idx][2] = map.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0) as f64;
                                }
                                "rotation" => {
                                    br.rotations[idx][0] = map.get("w").and_then(|v| v.as_float().ok()).unwrap_or(1.0) as f64;
                                    br.rotations[idx][1] = map.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0) as f64;
                                    br.rotations[idx][2] = map.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0) as f64;
                                    br.rotations[idx][3] = map.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0) as f64;
                                }
                                "scale" => {
                                    br.scales[idx][0] = map.get("x").and_then(|v| v.as_float().ok()).unwrap_or(1.0) as f64;
                                    br.scales[idx][1] = map.get("y").and_then(|v| v.as_float().ok()).unwrap_or(1.0) as f64;
                                    br.scales[idx][2] = map.get("z").and_then(|v| v.as_float().ok()).unwrap_or(1.0) as f64;
                                }
                                _ => {}
                            }
                        }
                    }
                    _ => {
                        log::warn!("set_component: unknown type '{}'", type_name);
                    }
                }
            });
        }

        // get_ref(component_map, "field_name") -> value
        engine.register_fn("get_ref", |obj: Map, field: ImmutableString| -> Dynamic {
            obj.get(field.as_str()).cloned().unwrap_or(Dynamic::UNIT)
        });

        // spawn(def) -> new entity id
        {
            let b = bridge.clone();
            engine.register_fn("spawn", move |def: Map| -> i64 {
                let mut br = b.lock().unwrap();
                let new_id = br.num_entities as i64;
                br.spawn_queue.push(def);
                new_id
            });
        }

        // despawn(eid)
        {
            let b = bridge.clone();
            engine.register_fn("despawn", move |eid: i64| {
                b.lock().unwrap().despawn_queue.push(eid as u32);
            });
        }
    }

    fn register_game_state_api(engine: &mut Engine, gs: SharedGameState) {
        // game_state_get(name) -> Dynamic
        {
            let g = gs.clone();
            engine.register_fn("game_state_get", move |name: ImmutableString| -> Dynamic {
                g.lock().unwrap().get(name.as_str())
            });
        }

        // game_state_set(name, value)
        {
            let g = gs.clone();
            engine.register_fn("game_state_set", move |name: ImmutableString, val: Dynamic| {
                g.lock().unwrap().set(name.as_str(), val);
            });
        }
    }

    fn register_input_api(engine: &mut Engine, input: SharedInput) {
        // input_key_down(key_code) -> bool
        {
            let inp = input.clone();
            engine.register_fn("input_key_down", move |key: ImmutableString| -> bool {
                let snap = inp.lock().unwrap();
                let code = key_name_to_code(key.as_str());
                if code < 256 { snap.keys_down[code] } else { false }
            });
        }

        // input_mouse_down(button) -> bool
        {
            let inp = input.clone();
            engine.register_fn("input_mouse_down", move |button: i64| -> bool {
                let snap = inp.lock().unwrap();
                let idx = button as usize;
                if idx < 3 { snap.mouse_buttons[idx] } else { false }
            });
        }

        // input_mouse_delta() -> map {x, y}
        {
            let inp = input.clone();
            engine.register_fn("input_mouse_delta", move || -> Map {
                let snap = inp.lock().unwrap();
                let mut m = Map::new();
                m.insert("x".into(), Dynamic::from(snap.mouse_dx as f32));
                m.insert("y".into(), Dynamic::from(snap.mouse_dy as f32));
                m
            });
        }
    }

    fn register_ui_api(engine: &mut Engine, ui: SharedUi) {
        // ui_text(text, x, y, size, r, g, b)
        {
            let u = ui.clone();
            engine.register_fn("ui_text", move |text: ImmutableString, x: f32, y: f32, size: f32, r: f32, g: f32, b: f32| {
                u.lock().unwrap().push_text(text.to_string(), x, y, size, r, g, b);
            });
        }

        // ui_rect(x, y, w, h, r, g, b, a)
        {
            let u = ui.clone();
            engine.register_fn("ui_rect", move |x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32, a: f32| {
                u.lock().unwrap().push_rect(x, y, w, h, r, g, b, a);
            });
        }

        // ui_button(text, x, y, w, h, r, g, b) -> bool
        {
            let u = ui.clone();
            engine.register_fn("ui_button", move |text: ImmutableString, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32| -> bool {
                u.lock().unwrap().push_button(text.to_string(), x, y, w, h, r, g, b)
            });
        }

        // ui_progress_bar(fraction, x, y, w, h, fg_r, fg_g, fg_b, bg_r, bg_g, bg_b)
        {
            let u = ui.clone();
            engine.register_fn("ui_progress_bar", move |frac: f32, x: f32, y: f32, w: f32, h: f32,
                                                        fg_r: f32, fg_g: f32, fg_b: f32,
                                                        bg_r: f32, bg_g: f32, bg_b: f32| {
                u.lock().unwrap().push_progress_bar(frac, x, y, w, h, fg_r, fg_g, fg_b, bg_r, bg_g, bg_b);
            });
        }
    }
}

/// Map component type name strings to bit flags matching the Julia-side ComponentMask.
fn component_type_to_bit(type_name: &str) -> Option<u64> {
    match type_name {
        "TransformComponent" => Some(1 << 0),
        "MeshComponent" => Some(1 << 1),
        "MaterialComponent" => Some(1 << 2),
        "CameraComponent" => Some(1 << 3),
        "PointLightComponent" => Some(1 << 4),
        "DirectionalLightComponent" => Some(1 << 5),
        "ColliderComponent" => Some(1 << 6),
        "RigidBodyComponent" => Some(1 << 7),
        "AnimationComponent" => Some(1 << 8),
        "SkeletonComponent" => Some(1 << 9),
        "ParticleSystemComponent" => Some(1 << 10),
        "AudioSourceComponent" => Some(1 << 11),
        "ScriptComponent" => Some(1 << 12),
        _ => None,
    }
}

/// Map key name strings to key codes (matching browser KeyboardEvent.code).
fn key_name_to_code(name: &str) -> usize {
    match name {
        "KeyW" | "w" | "W" => 87,
        "KeyA" | "a" | "A" => 65,
        "KeyS" | "s" | "S" => 83,
        "KeyD" | "d" | "D" => 68,
        "KeyE" | "e" | "E" => 69,
        "KeyQ" | "q" | "Q" => 81,
        "KeyR" | "r" | "R" => 82,
        "KeyF" | "f" | "F" => 70,
        "Space" | " " => 32,
        "ShiftLeft" | "Shift" => 16,
        "ControlLeft" | "Control" => 17,
        "AltLeft" | "Alt" => 18,
        "Escape" => 27,
        "Enter" => 13,
        "Tab" => 9,
        "ArrowUp" => 38,
        "ArrowDown" => 40,
        "ArrowLeft" => 37,
        "ArrowRight" => 39,
        "Digit1" | "1" => 49,
        "Digit2" | "2" => 50,
        "Digit3" | "3" => 51,
        "Digit4" | "4" => 52,
        _ => 999,
    }
}
