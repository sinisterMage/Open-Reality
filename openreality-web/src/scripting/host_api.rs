//! Host API functions registered into the Rhai engine.
//!
//! These bridge the gap between Rhai scripts and the WASM runtime's ECS.
//! Component access, entity lifecycle, math, and input are all exposed here.

use rhai::{Dynamic, Engine, Map, ImmutableString};

/// Register all math helper functions.
pub fn register_math_api(engine: &mut Engine) {
    // vec3(x, y, z) -> object map with x, y, z
    engine.register_fn("vec3", |x: f32, y: f32, z: f32| -> Map {
        let mut m = Map::new();
        m.insert("x".into(), Dynamic::from(x));
        m.insert("y".into(), Dynamic::from(y));
        m.insert("z".into(), Dynamic::from(z));
        m
    });

    // quat(w, x, y, z) -> object map with w, x, y, z
    engine.register_fn("quat", |w: f32, x: f32, y: f32, z: f32| -> Map {
        let mut m = Map::new();
        m.insert("w".into(), Dynamic::from(w));
        m.insert("x".into(), Dynamic::from(x));
        m.insert("y".into(), Dynamic::from(y));
        m.insert("z".into(), Dynamic::from(z));
        m
    });

    // rgb(r, g, b) -> object map with r, g, b
    engine.register_fn("rgb", |r: f32, g: f32, b: f32| -> Map {
        let mut m = Map::new();
        m.insert("r".into(), Dynamic::from(r));
        m.insert("g".into(), Dynamic::from(g));
        m.insert("b".into(), Dynamic::from(b));
        m
    });

    // rgba(r, g, b, a) -> object map
    engine.register_fn("rgba", |r: f32, g: f32, b: f32, a: f32| -> Map {
        let mut m = Map::new();
        m.insert("r".into(), Dynamic::from(r));
        m.insert("g".into(), Dynamic::from(g));
        m.insert("b".into(), Dynamic::from(b));
        m.insert("a".into(), Dynamic::from(a));
        m
    });

    // Math functions (f32 versions)
    engine.register_fn("sqrt", |x: f32| -> f32 { x.sqrt() });
    engine.register_fn("sin", |x: f32| -> f32 { x.sin() });
    engine.register_fn("cos", |x: f32| -> f32 { x.cos() });
    engine.register_fn("tan", |x: f32| -> f32 { x.tan() });
    engine.register_fn("asin", |x: f32| -> f32 { x.asin() });
    engine.register_fn("acos", |x: f32| -> f32 { x.acos() });
    engine.register_fn("atan2", |y: f32, x: f32| -> f32 { y.atan2(x) });
    engine.register_fn("abs", |x: f32| -> f32 { x.abs() });
    engine.register_fn("floor", |x: f32| -> f32 { x.floor() });
    engine.register_fn("ceil", |x: f32| -> f32 { x.ceil() });
    engine.register_fn("round", |x: f32| -> f32 { x.round() });
    engine.register_fn("min", |a: f32, b: f32| -> f32 { a.min(b) });
    engine.register_fn("max", |a: f32, b: f32| -> f32 { a.max(b) });
    engine.register_fn("clamp", |x: f32, lo: f32, hi: f32| -> f32 { x.clamp(lo, hi) });
    engine.register_fn("lerp", |a: f32, b: f32, t: f32| -> f32 { a + (b - a) * t });

    // Vector math utilities
    engine.register_fn("vec3_add", |a: Map, b: Map| -> Map {
        let mut m = Map::new();
        let ax = a.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let ay = a.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let az = a.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let bx = b.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let by = b.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let bz = b.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        m.insert("x".into(), Dynamic::from(ax + bx));
        m.insert("y".into(), Dynamic::from(ay + by));
        m.insert("z".into(), Dynamic::from(az + bz));
        m
    });

    engine.register_fn("vec3_sub", |a: Map, b: Map| -> Map {
        let mut m = Map::new();
        let ax = a.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let ay = a.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let az = a.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let bx = b.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let by = b.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let bz = b.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        m.insert("x".into(), Dynamic::from(ax - bx));
        m.insert("y".into(), Dynamic::from(ay - by));
        m.insert("z".into(), Dynamic::from(az - bz));
        m
    });

    engine.register_fn("vec3_scale", |v: Map, s: f32| -> Map {
        let mut m = Map::new();
        let vx = v.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let vy = v.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let vz = v.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        m.insert("x".into(), Dynamic::from(vx * s));
        m.insert("y".into(), Dynamic::from(vy * s));
        m.insert("z".into(), Dynamic::from(vz * s));
        m
    });

    engine.register_fn("vec3_length", |v: Map| -> f32 {
        let x = v.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let y = v.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let z = v.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        (x * x + y * y + z * z).sqrt()
    });

    engine.register_fn("vec3_normalize", |v: Map| -> Map {
        let x = v.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let y = v.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let z = v.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let len = (x * x + y * y + z * z).sqrt();
        let mut m = Map::new();
        if len > 1e-10 {
            m.insert("x".into(), Dynamic::from(x / len));
            m.insert("y".into(), Dynamic::from(y / len));
            m.insert("z".into(), Dynamic::from(z / len));
        } else {
            m.insert("x".into(), Dynamic::from(0.0_f32));
            m.insert("y".into(), Dynamic::from(0.0_f32));
            m.insert("z".into(), Dynamic::from(0.0_f32));
        }
        m
    });

    engine.register_fn("vec3_dot", |a: Map, b: Map| -> f32 {
        let ax = a.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let ay = a.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let az = a.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let bx = b.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let by = b.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let bz = b.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        ax * bx + ay * by + az * bz
    });

    engine.register_fn("vec3_cross", |a: Map, b: Map| -> Map {
        let ax = a.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let ay = a.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let az = a.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let bx = b.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let by = b.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let bz = b.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let mut m = Map::new();
        m.insert("x".into(), Dynamic::from(ay * bz - az * by));
        m.insert("y".into(), Dynamic::from(az * bx - ax * bz));
        m.insert("z".into(), Dynamic::from(ax * by - ay * bx));
        m
    });

    engine.register_fn("vec3_distance", |a: Map, b: Map| -> f32 {
        let dx = a.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0)
            - b.get("x").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let dy = a.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0)
            - b.get("y").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        let dz = a.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0)
            - b.get("z").and_then(|v| v.as_float().ok()).unwrap_or(0.0);
        (dx * dx + dy * dy + dz * dz).sqrt()
    });

    // Random (deterministic xorshift for WASM reproducibility)
    engine.register_fn("rand_f32", || -> f32 {
        // Use a simple xorshift — matches particles.rs approach
        static mut STATE: u32 = 54321;
        unsafe {
            STATE ^= STATE << 13;
            STATE ^= STATE >> 17;
            STATE ^= STATE << 5;
            (STATE as f32) / (u32::MAX as f32)
        }
    });

    engine.register_fn("rand_range", |lo: f32, hi: f32| -> f32 {
        static mut STATE: u32 = 54321;
        let r = unsafe {
            STATE ^= STATE << 13;
            STATE ^= STATE >> 17;
            STATE ^= STATE << 5;
            (STATE as f32) / (u32::MAX as f32)
        };
        lo + (hi - lo) * r
    });

    // print/log for debugging
    engine.register_fn("print", |s: ImmutableString| {
        log::info!("[script] {}", s);
    });
    engine.register_fn("print", |v: f32| {
        log::info!("[script] {}", v);
    });
    engine.register_fn("print", |v: i64| {
        log::info!("[script] {}", v);
    });
    engine.register_fn("print", |v: bool| {
        log::info!("[script] {}", v);
    });
}
