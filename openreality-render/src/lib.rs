//! OpenReality Render — platform-independent deferred PBR renderer.
//!
//! This crate contains all rendering code shared between the native WebGPU
//! backend (openreality-wgpu, used via Julia FFI) and the WASM web runtime
//! (openreality-web). It provides GPU type definitions, pipeline creation,
//! render passes, and a high-level SceneRenderer API.

pub mod types;
pub mod handle;
pub mod pipeline;
pub mod render_targets;
pub mod passes;
pub mod ibl;
pub mod scene_renderer;
