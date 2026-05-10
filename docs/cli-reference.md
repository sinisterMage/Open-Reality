# CLI Reference

The `orcli` command-line tool manages OpenReality projects, builds, exports, and provides an interactive TUI dashboard.

## Installation

### Build from source (Cargo)

```bash
cd Open-Reality
cargo build --release -p openreality-cli
# Binary at target/release/orcli
```

### Build from source ([neomake](https://github.com/sinisterMage/neomake))

```bash
# Install neomake once: cargo install --git https://github.com/sinisterMage/neomake neomake
neomake run cli
# Binary at target/release/orcli
```

## Quick Start

```bash
# Create a new project
orcli init myproject
cd myproject

# Install Julia dependencies
orcli setup install

# Run a scene
orcli run examples/hello.jl

# Launch the interactive TUI
orcli
```

## Commands

### `orcli` (no arguments)

Launches the interactive TUI dashboard. See [TUI Guide](#tui-guide) below.

### `orcli init`

Initialize a new OpenReality project.

```bash
orcli init <name> [--engine-dev] [--repo-url <url>]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<name>` | required | Project name (directory to create) |
| `--engine-dev` | `false` | Clone full engine repo for development instead of creating a user project |
| `--repo-url` | `https://github.com/sinisterMage/Open-Reality.git` | Git URL for the engine repository |

**Examples:**

```bash
# Create a user project
orcli init my-game

# Clone for engine development
orcli init openreality-dev --engine-dev
```

### `orcli new scene`

Generate a new scene file from a template.

```bash
orcli new scene <name>
```

Creates `examples/<name>.jl` with a basic scene template.

### `orcli run`

Run a Julia scene or script.

```bash
orcli run <file> [--warm-cache]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<file>` | required | Path to the `.jl` file to run |
| `--warm-cache` | `false` | Pre-compile all shaders before running |

**Example:**

```bash
orcli run examples/hello.jl --warm-cache
```

### `orcli build`

Build targets for various platforms.

#### `orcli build backend`

Build a GPU backend library.

```bash
orcli build backend <name>
```

Supported backends: `metal`, `webgpu`, `wasm`

#### `orcli build desktop`

Build a standalone desktop executable via PackageCompiler.jl.

```bash
orcli build desktop <entry> [--platform <platform>] [--output <dir>] [--release]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<entry>` | required | Entry point Julia file |
| `--platform` | current OS | Target platform: `linux`, `macos`, `windows` |
| `--output` | `build/desktop` | Output directory |
| `--release` | `false` | Enable release optimizations |

#### `orcli build web`

Build for web deployment (WASM + ORSB).

```bash
orcli build web <scene> [--output <dir>] [--release]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<scene>` | required | Scene file to bundle (`.jl`) |
| `--output` | `build/web` | Output directory |
| `--release` | `false` | Enable release optimizations |

#### `orcli build mobile`

Build for mobile via WebView shell (experimental).

```bash
orcli build mobile <scene> --platform <android|ios> [--output <dir>]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<scene>` | required | Scene file to bundle (`.jl`) |
| `--platform` | required | Target: `android` or `ios` |
| `--output` | `build/mobile` | Output directory |

### `orcli export`

Export a scene to a portable format.

```bash
orcli export <scene> -o <output> [--format <fmt>] [--physics] [--compress-textures]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<scene>` | required | Scene file (`.jl`) that creates and returns a Scene |
| `-o, --output` | required | Output file path |
| `-f, --format` | `orsb` | Export format: `orsb` (binary) or `gltf` (glTF 2.0) |
| `--physics` | `false` | Include physics configuration |
| `--compress-textures` | `true` | Compress textures in the output |

**Examples:**

```bash
orcli export scenes/level1.jl -o build/level1.orsb
orcli export scenes/level1.jl -o build/level1.gltf -f gltf --physics
```

### `orcli package`

Package a built application for distribution.

#### `orcli package desktop`

```bash
orcli package desktop [--build-dir <dir>] [--output <dir>] [--platform <platform>]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--build-dir` | `build/desktop` | Build directory from `orcli build desktop` |
| `--output` | `dist` | Output directory for the package |
| `--platform` | current OS | Target platform |

#### `orcli package web`

```bash
orcli package web [--build-dir <dir>] [--output <dir>]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--build-dir` | `build/web` | Build directory from `orcli build web` |
| `--output` | `dist/web` | Output directory for the package |

### `orcli test`

Run the Julia test suite.

```bash
orcli test
```

Equivalent to `julia --project=. -e 'using Pkg; Pkg.test()'`.

### `orcli cache`

Manage the shader cache.

#### `orcli cache shaders`

Pre-compile and cache all shader variants.

```bash
orcli cache shaders [--backend <backend>]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--backend` | `opengl` | Backend to warm cache for: `opengl`, `vulkan` |

#### `orcli cache clear`

Clear the shader cache.

```bash
orcli cache clear
```

#### `orcli cache status`

Show shader cache statistics (file count and total size).

```bash
orcli cache status
```

### `orcli update`

Pull latest engine changes and update Julia dependencies.

```bash
orcli update
```

- **Engine dev projects**: runs `git pull` in the project root
- **User projects**: runs `git pull` in the engine dependency directory

After pulling, runs `julia --project=. -e 'using Pkg; Pkg.instantiate()'` to sync dependencies.

### `orcli setup`

Manage the Julia package environment.

#### `orcli setup install`

Install/resolve Julia dependencies.

```bash
orcli setup install
```

#### `orcli setup status`

Show Julia package status.

```bash
orcli setup status
```

#### `orcli setup update`

Update Julia packages.

```bash
orcli setup update
```

### `orcli info`

Show project info, detected tools, backend status, and available examples.

```bash
orcli info
```

Prints the same information displayed in the TUI Dashboard tab.

## TUI Guide

Launch the TUI by running `orcli` with no arguments. The interface has five tabs navigable with `Tab`/`Shift-Tab` or number keys `1`-`5`.

### Tab 1: Dashboard

Displays project info, detected tools (Julia, Cargo, wasm-pack, etc.), Julia package status, and discovered examples.

| Key | Action |
|-----|--------|
| `n` | Create a new scene (enter name, press Enter to confirm, Esc to cancel) |

### Tab 2: Build

Build GPU backends and view build logs. A mode selector at the top switches between build targets.

| Key | Action |
|-----|--------|
| `a` | Backend mode (build GPU backends) |
| `d` | Desktop mode |
| `w` | Web mode |
| `m` | Mobile mode |
| `x` | Export mode |
| `p` | Package mode |
| `j/k` or `Up/Down` | Select backend (in Backend mode) |
| `Enter` or `b` | Start build |
| `g` / `G` | Scroll log to top / bottom |

### Tab 3: Run

Run example scenes. The TUI suspends to allow the GLFW window to render, then resumes when the scene exits.

| Key | Action |
|-----|--------|
| `j/k` or `Up/Down` | Select example |
| `h/l` or `Left/Right` | Switch backend |
| `c` | Toggle warm shader cache |
| `Enter` or `r` | Run selected example |

### Tab 4: Setup

Manage Julia dependencies and shader cache.

| Key | Action |
|-----|--------|
| `j/k` or `Up/Down` | Select action |
| `Enter` | Run selected action |

Available actions: Install, Status, Update, Warm Shader Cache, Clear Cache, Cache Status.

### Tab 5: Tests

Run the Julia test suite and view output.

| Key | Action |
|-----|--------|
| `Enter` or `t` | Run test suite |

### Global Keybindings

| Key | Action |
|-----|--------|
| `q` / `Ctrl-C` | Quit |
| `?` | Toggle help overlay |
| `1`-`5` | Switch to tab |
| `Tab` / `Shift-Tab` | Next / previous tab |
| `Esc` | Close overlay |
| `g` / `G` | Scroll log to top / bottom |
| `PgUp` / `PgDn` | Scroll log by page |

## Troubleshooting

### "Julia not found"

Ensure Julia 1.9+ is installed and on your `PATH`. Verify with `julia --version`.

### "Engine path does not exist"

Check that `.openreality/config.toml` has the correct `engine_path`. For engine dev projects, make sure you're running from the project root.

### Build failures

- **Backend builds**: Run the Julia build script manually to see full output: `julia --project=. src/backends/<backend>/build.jl`
- **WASM builds**: Ensure `wasm-pack` is installed: `cargo install wasm-pack`
- **Desktop builds**: Ensure PackageCompiler.jl is installed: `julia -e 'using Pkg; Pkg.add("PackageCompiler")'`

### Shader cache issues

Clear the cache and rebuild:

```bash
orcli cache clear
orcli cache shaders --backend opengl
```

### Git pull conflicts during update

If `orcli update` fails due to merge conflicts, resolve them manually in the engine directory, then run `orcli setup install` to sync dependencies.
