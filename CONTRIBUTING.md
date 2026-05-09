# Contributing to OpenReality

Thank you for your interest in contributing to OpenReality! Whether you're fixing a typo, reporting a bug, adding a feature, or improving documentation — every contribution is valued.

This guide will help you get set up and make your first contribution.

## Table of Contents

- [Development Environment Setup](#development-environment-setup)
- [Project Structure](#project-structure)
- [Development Workflow](#development-workflow)
- [Coding Standards](#coding-standards)
- [Making Changes](#making-changes)
- [Submitting a Pull Request](#submitting-a-pull-request)
- [Areas for Contribution](#areas-for-contribution)

---

## Development Environment Setup

### Julia

OpenReality requires **Julia 1.9** or later.

**juliaup (recommended):**

```bash
curl -fsSL https://install.julialang.org | sh
```

Or download directly from [julialang.org/downloads](https://julialang.org/downloads/).

Verify your installation:

```bash
julia --version
```

### System Dependencies

| Dependency | Required | Installation |
|-----------|----------|-------------|
| **GLFW** | Yes | Ubuntu/Debian: `sudo apt install libglfw3 libglfw3-dev`<br>Arch: `sudo pacman -S glfw-x11` (or `glfw-wayland`)<br>Fedora: `sudo dnf install glfw glfw-devel`<br>macOS: `brew install glfw`<br>Windows: download from [glfw.org](https://www.glfw.org/download.html) |
| **Vulkan SDK** | Recommended on Linux/Windows (Vulkan is the default backend) | [lunarg.com](https://vulkan.lunarg.com/sdk/home) or `sudo apt install vulkan-tools libvulkan-dev` |
| **OpenAL** | No (audio only) | Ubuntu: `sudo apt install libopenal-dev`<br>macOS: included with system<br>Windows: bundled via jll |

### Clone and Install

```bash
git clone https://github.com/sinisterMage/Open-Reality.git
cd OpenReality
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

The first load will precompile all dependencies — this may take a minute.

### Bazel (Optional)

The project uses [Bazel 6](https://bazel.build/) for cross-language builds (Julia + Rust + Swift). Most Julia contributors won't need Bazel, but it's useful for full-project builds and CI.

1. Install via [bazelisk](https://github.com/bazelbuild/bazelisk) (recommended — it manages Bazel versions automatically)
2. Run tests: `bazel test //:julia_tests`
3. Build CLI: `bazel build //:cli`
4. Precompile: `bazel build //:precompile`

> **Note:** Bazel tests require a display server (X11/Wayland) for GLFW. The `.bazelrc` forwards the `DISPLAY` environment variable automatically.

### Rust / Cargo (WebGPU and CLI Only)

If you're contributing to the WebGPU backend or CLI tool, you'll need Rust:

1. Install via [rustup](https://rustup.rs/): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
2. Build WebGPU backend:
   ```bash
   cd openreality-wgpu && cargo build --release
   ```
3. Build CLI:
   ```bash
   cargo build -p openreality-cli --release
   ```

---

## Project Structure

```
OpenReality/
├── src/                        # Julia engine source
│   ├── OpenReality.jl          # Main module — all includes and exports
│   ├── ecs.jl                  # Entity Component System (Ark.jl)
│   ├── scene.jl                # Immutable, functional scene graph
│   ├── state.jl                # Game state
│   ├── threading.jl            # Opt-in multithreading
│   ├── components/             # Component types (transform, mesh, material, camera, ...)
│   ├── systems/                # Game systems (physics, animation, audio, particles, ...)
│   ├── rendering/              # Rendering pipeline (shaders, PBR, post-processing, shadows)
│   ├── backend/                # Rendering backends
│   │   ├── abstract.jl         # Backend interface (all backends implement this)
│   │   ├── vulkan/             # Vulkan (default on Linux/Windows)
│   │   ├── metal/              # Metal (default on macOS, via Swift bridge)
│   │   ├── opengl/             # OpenGL 3.3+ (legacy / fallback)
│   │   └── webgpu/             # WebGPU (via Rust FFI)
│   ├── physics/                # Physics engine (GJK+EPA, PGS solver, joints, CCD)
│   ├── audio/                  # OpenAL 3D audio backend
│   ├── ui/                     # Immediate-mode UI (font atlas, widgets)
│   ├── loading/                # Asset loaders (glTF 2.0, OBJ)
│   ├── math/                   # Math utilities (transforms)
│   ├── game/                   # Gameplay systems (FSM, events, quests, inventory, dialogue)
│   ├── debug/                  # Debug tools (console, draw)
│   ├── export/                 # Scene export (ORSB binary format)
│   ├── serialization/          # Save/load system
│   └── windowing/              # GLFW window management and input
├── test/runtests.jl            # Test suite (~940 tests)
├── examples/                   # Example scenes (26 demos)
├── docs/                       # Documentation (getting-started, API, architecture, examples)
├── openreality-wgpu/           # Rust — WebGPU rendering backend (cdylib)
├── openreality-cli/            # Rust — CLI tool (orcli)
├── openreality-gpu-shared/     # Shared GPU code (WGSL shaders)
├── openreality-web/            # Web export tooling
├── metal_bridge/               # Swift — Metal backend bridge (macOS)
├── bazel/                      # Bazel build rules (julia.bzl, bun.bzl, platforms.bzl)
├── open-reality-website/       # Project website (Nuxt)
├── Project.toml                # Julia project dependencies
├── Cargo.toml                  # Rust workspace manifest
├── BUILD.bazel                 # Root Bazel build file
└── MODULE.bazel                # Bazel module definition
```

**Key architectural rule:** All Julia `using`/`import` statements and `export` declarations are centralized in `src/OpenReality.jl`. Individual source files under `src/` should not contain their own `using` statements for external packages.

---

## Development Workflow

### Running Examples

```bash
julia --project=. examples/basic_scene.jl
julia --project=. examples/physics_demo.jl
julia --project=. examples/pbr_showcase.jl
```

See the full list in the `examples/` directory.

### Running Tests

**Julia (quickest for most development):**

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

**Bazel (full build system):**

```bash
bazel test //:julia_tests
```

### Building the WebGPU Backend

```bash
cd openreality-wgpu
cargo build --release
```

The resulting shared library (`libopenreality_wgpu.so` / `.dylib` / `.dll`) is loaded at runtime via Julia's `ccall` FFI. If the library isn't found, the engine gracefully falls back to OpenGL.

### Building the CLI

```bash
cargo build -p openreality-cli --release
# Binary: target/release/orcli
```

### Checking Rust Code

```bash
cargo check --workspace
cargo clippy --workspace -- -D warnings
cargo fmt --all -- --check
```

---

## Coding Standards

### Julia

| Convention | Example |
|-----------|---------|
| Functions and variables | `snake_case` — `create_entity!`, `mesh_data` |
| Types and structs | `PascalCase` — `TransformComponent`, `RigidBodyComponent` |
| Constants | `SCREAMING_SNAKE_CASE` — `BODY_STATIC`, `MAX_CASCADES` |
| Mutating functions | Suffix with `!` — `reset_component_stores!()`, `add_component!()` |

**Imports and exports:** All `using`/`import` and `export` declarations belong in `src/OpenReality.jl`. Do not add `using` statements in individual source files.

**Components:** Define as a struct that subtypes `Component`:

```julia
struct MyComponent <: Component
    value::Float64
    name::String
end
```

Use `Observable{T}` for fields that need reactive updates (see `TransformComponent` for an example).

**Docstrings:** Use triple-quoted Julia docstrings:

```julia
"""
    my_function(x::Float64) -> Vec3f

Brief description of what this function does.
"""
function my_function(x::Float64)
    # ...
end
```

**Section headers:** Use `# === Section Name ===` comment blocks to delineate major sections within a file.

### Rust

Follow standard Rust conventions. CI enforces:
- `cargo clippy -- -D warnings` (no warnings)
- `cargo fmt -- --check` (standard formatting)

### Swift (Metal Bridge)

Follow standard Swift conventions. The Metal bridge lives in `metal_bridge/`.

---

## Making Changes

### Branch Naming

Create branches from `main` using descriptive prefixes:

| Prefix | Use | Example |
|--------|-----|---------|
| `feature/` | New features | `feature/terrain-texturing` |
| `fix/` | Bug fixes | `fix/shadow-map-bias` |
| `docs/` | Documentation | `docs/api-reference-update` |
| `refactor/` | Code cleanup | `refactor/ecs-storage` |

### Commit Messages

Use **imperative, lowercase** style — consistent with the project's existing convention:

```
add terrain chunk LOD system
fix shadow map cascade splitting
update vulkan pipeline to support MSAA
refactor physics broadphase to use spatial hashing
```

Keep the first line under 72 characters. Add a blank line and a body paragraph for complex changes.

### Writing Tests

Tests live in `test/runtests.jl`. Add new tests inside the appropriate `@testset` block, or create a new one for a new subsystem:

```julia
@testset "Your Feature" begin
    @test your_function(input) == expected_output
    @test_throws ErrorException bad_input()
end
```

Always run the full suite before submitting:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

### Updating Documentation

| Change type | File to update |
|------------|----------------|
| New or changed API | `docs/api-reference.md` |
| New feature with usage examples | `docs/examples.md` |
| Architecture or design changes | `docs/architecture.md` |
| New example scene | Add a file to `examples/` |

---

## Submitting a Pull Request

1. **Fork** the repository and create your branch from `main`.
2. **Make your changes** following the coding standards above.
3. **Run the test suite** and confirm all tests pass.
4. **Push** your branch to your fork.
5. **Open a PR** against `main` on [sinisterMage/Open-Reality](https://github.com/sinisterMage/Open-Reality).

### PR Description

Please include:
- **What** the PR does (brief summary)
- **Why** the change is needed
- **How to test** it (specific steps, example commands, or test cases)
- Any **breaking changes** or migration notes

### Review Process

- A maintainer will review your PR, usually within a few days.
- Small fixes and documentation changes are typically merged quickly.
- Larger features may need design discussion — feel free to open a **draft PR** early to get feedback on your approach before investing too much time.

---

## Areas for Contribution

Looking for something to work on? Here are areas where help is especially welcome:

### Good First Issues

- Improve docstrings for functions in `src/components/` and `src/systems/`
- Add more example scenes to `examples/`
- Expand or clarify documentation in `docs/`
- Fix typos and improve README clarity

### Intermediate

- Add unit tests for under-tested subsystems (audio, terrain, UI)
- Improve error messages and validation in asset loaders
- Add new primitive shapes to `src/components/primitives.jl`
- Extend the immediate-mode UI widget set in `src/ui/`

### Advanced

- Optimize physics solver performance
- Contribute to rendering backends (Vulkan, Metal, WebGPU)
- Implement new post-processing effects
- Improve the animation blend tree system
- Work on the Rust CLI tool (`openreality-cli/`)

If you're unsure where to start, open a [Question issue](https://github.com/sinisterMage/Open-Reality/issues/new?template=question.yml) and we'll help point you in the right direction!
