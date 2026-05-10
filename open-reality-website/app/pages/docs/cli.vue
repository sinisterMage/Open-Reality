<script setup lang="ts">
definePageMeta({ layout: 'docs' })
useSeoMeta({
  title: 'CLI Reference - OpenReality Docs',
  ogTitle: 'CLI Reference - OpenReality Docs',
  description: 'Complete reference for the orcli command-line tool: commands, options, TUI guide, and troubleshooting.',
  ogDescription: 'Complete reference for the orcli command-line tool: commands, options, TUI guide, and troubleshooting.',
})

const installCode = `# Build from source (Cargo)
cargo build --release -p openreality-cli
# Binary at target/release/orcli

# Build from source (neomake — github.com/sinisterMage/neomake)
# Install once: cargo install --git https://github.com/sinisterMage/neomake neomake
neomake run cli`

const quickStartCode = `# Create a new project
orcli init myproject
cd myproject

# Install Julia dependencies
orcli setup install

# Run a scene
orcli run examples/hello.jl

# Launch the interactive TUI
orcli`

const initCode = `# Create a user project
orcli init my-game

# Clone for engine development
orcli init openreality-dev --engine-dev

# Use a custom repo URL
orcli init my-game --repo-url https://github.com/my-fork/Open-Reality.git`

const runCode = `# Run a scene
orcli run examples/hello.jl

# Run with shader cache warming
orcli run examples/hello.jl --warm-cache`

const buildCode = `# Build a GPU backend
orcli build backend metal
orcli build backend webgpu
orcli build backend wasm

# Build standalone desktop executable
orcli build desktop main.jl --release
orcli build desktop main.jl --platform linux --output build/linux

# Build for web (WASM + ORSB)
orcli build web scenes/level1.jl --release

# Build for mobile (experimental)
orcli build mobile scenes/level1.jl --platform android`

const exportCode = `# Export to ORSB (binary, for WASM runtime)
orcli export scenes/level1.jl -o build/level1.orsb

# Export to glTF with physics
orcli export scenes/level1.jl -o build/level1.gltf -f gltf --physics`

const packageCode = `# Package desktop build
orcli package desktop --build-dir build/desktop --output dist

# Package web build
orcli package web --build-dir build/web --output dist/web`

const cacheCode = `# Pre-compile shaders
orcli cache shaders --backend opengl

# Clear shader cache
orcli cache clear

# Show cache statistics
orcli cache status`

const setupCode = `# Install/resolve Julia dependencies
orcli setup install

# Show package status
orcli setup status

# Update Julia packages
orcli setup update`

const updateCode = `# Pull latest engine changes and update dependencies
orcli update`

const infoCode = `# Show project info, tools, backends, and examples
orcli info`
</script>

<template>
  <div class="space-y-12">
    <div>
      <h1 class="text-3xl font-mono font-bold text-or-text">CLI Reference</h1>
      <p class="text-or-text-dim mt-3 leading-relaxed">
        The <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">orcli</code> command-line tool
        manages OpenReality projects, builds, exports, and provides an interactive TUI dashboard.
      </p>
    </div>

    <!-- Installation -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Installation
      </h2>
      <CodeBlock :code="installCode" lang="bash" filename="terminal" />
    </section>

    <!-- Quick Start -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Quick Start
      </h2>
      <CodeBlock :code="quickStartCode" lang="bash" filename="terminal" />
    </section>

    <!-- init -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> orcli init
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Initialize a new OpenReality project. Use <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">--engine-dev</code>
        to clone the full engine repo for development.
      </p>
      <CodeBlock :code="initCode" lang="bash" filename="terminal" />
    </section>

    <!-- run -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> orcli run
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Run a Julia scene or script. The optional <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">--warm-cache</code>
        flag pre-compiles all shaders before launching.
      </p>
      <CodeBlock :code="runCode" lang="bash" filename="terminal" />
    </section>

    <!-- build -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> orcli build
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Build targets for various platforms. Supports GPU backends, desktop executables, web deployment, and mobile (experimental).
      </p>
      <CodeBlock :code="buildCode" lang="bash" filename="terminal" />
    </section>

    <!-- export -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> orcli export
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Export a scene to a portable format. Supports
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">orsb</code> (OpenReality Scene Bundle)
        and <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">gltf</code> (glTF 2.0).
      </p>
      <CodeBlock :code="exportCode" lang="bash" filename="terminal" />
    </section>

    <!-- package -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> orcli package
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Package a built application for distribution. Run after
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">orcli build</code> to create distributable archives.
      </p>
      <CodeBlock :code="packageCode" lang="bash" filename="terminal" />
    </section>

    <!-- cache -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> orcli cache
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Manage the shader cache. Pre-compile shaders for faster startup, or clear stale cache entries.
      </p>
      <CodeBlock :code="cacheCode" lang="bash" filename="terminal" />
    </section>

    <!-- update -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> orcli update
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Pull latest engine changes and sync Julia dependencies. For engine dev projects, pulls in the project root.
        For user projects, pulls in the engine dependency directory.
      </p>
      <CodeBlock :code="updateCode" lang="bash" filename="terminal" />
    </section>

    <!-- setup -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> orcli setup
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Manage the Julia package environment. Install dependencies, check status, or update packages.
      </p>
      <CodeBlock :code="setupCode" lang="bash" filename="terminal" />
    </section>

    <!-- info -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> orcli info
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Show project info, detected tools, backend status, and available examples.
        Prints the same information displayed in the TUI Dashboard tab.
      </p>
      <CodeBlock :code="infoCode" lang="bash" filename="terminal" />
    </section>

    <!-- TUI Guide -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> TUI Guide
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Launch the TUI by running <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">orcli</code>
        with no arguments. The interface has five tabs navigable with
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">Tab</code> /
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">Shift-Tab</code> or keys
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">1</code>-<code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">5</code>.
      </p>

      <div class="space-y-6">
        <div>
          <h3 class="text-lg font-mono font-bold text-or-text mb-2">Dashboard</h3>
          <p class="text-or-text-dim mb-2 leading-relaxed">
            Displays project info, detected tools, Julia package status, and discovered examples.
            Press <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">n</code> to create a new scene.
          </p>
        </div>

        <div>
          <h3 class="text-lg font-mono font-bold text-or-text mb-2">Build</h3>
          <p class="text-or-text-dim mb-2 leading-relaxed">
            Build GPU backends and view build logs. Switch modes with
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">a</code> (backend),
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">d</code> (desktop),
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">w</code> (web),
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">m</code> (mobile),
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">x</code> (export),
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">p</code> (package).
            Press <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">Enter</code> or
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">b</code> to start a build.
          </p>
        </div>

        <div>
          <h3 class="text-lg font-mono font-bold text-or-text mb-2">Run</h3>
          <p class="text-or-text-dim mb-2 leading-relaxed">
            Run example scenes. Select with <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">j/k</code>,
            switch backend with <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">h/l</code>,
            toggle warm cache with <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">c</code>,
            and run with <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">Enter</code> or
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">r</code>.
          </p>
        </div>

        <div>
          <h3 class="text-lg font-mono font-bold text-or-text mb-2">Setup</h3>
          <p class="text-or-text-dim mb-2 leading-relaxed">
            Manage Julia dependencies and shader cache. Includes Install, Status, Update, Warm Shader Cache, Clear Cache, and Cache Status actions.
          </p>
        </div>

        <div>
          <h3 class="text-lg font-mono font-bold text-or-text mb-2">Tests</h3>
          <p class="text-or-text-dim mb-2 leading-relaxed">
            Run the Julia test suite. Press <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">Enter</code> or
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">t</code> to start.
          </p>
        </div>
      </div>
    </section>

    <!-- Global Keys -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Global Keybindings
      </h2>
      <div class="overflow-x-auto">
        <table class="w-full text-sm font-mono">
          <thead>
            <tr class="border-b border-or-border">
              <th class="text-left py-2 pr-6 text-or-text-dim">Key</th>
              <th class="text-left py-2 text-or-text-dim">Action</th>
            </tr>
          </thead>
          <tbody class="text-or-text">
            <tr class="border-b border-or-border/50"><td class="py-2 pr-6">q / Ctrl-C</td><td>Quit</td></tr>
            <tr class="border-b border-or-border/50"><td class="py-2 pr-6">?</td><td>Toggle help overlay</td></tr>
            <tr class="border-b border-or-border/50"><td class="py-2 pr-6">1-5</td><td>Switch to tab</td></tr>
            <tr class="border-b border-or-border/50"><td class="py-2 pr-6">Tab / Shift-Tab</td><td>Next / previous tab</td></tr>
            <tr class="border-b border-or-border/50"><td class="py-2 pr-6">Esc</td><td>Close overlay</td></tr>
            <tr class="border-b border-or-border/50"><td class="py-2 pr-6">g / G</td><td>Scroll log to top / bottom</td></tr>
            <tr><td class="py-2 pr-6">PgUp / PgDn</td><td>Scroll log by page</td></tr>
          </tbody>
        </table>
      </div>
    </section>

    <!-- Troubleshooting -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Troubleshooting
      </h2>
      <div class="space-y-4">
        <div>
          <h3 class="text-lg font-mono font-bold text-or-text mb-1">Julia not found</h3>
          <p class="text-or-text-dim leading-relaxed">
            Ensure Julia 1.9+ is installed and on your <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">PATH</code>.
            Verify with <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">julia --version</code>.
          </p>
        </div>
        <div>
          <h3 class="text-lg font-mono font-bold text-or-text mb-1">Engine path does not exist</h3>
          <p class="text-or-text-dim leading-relaxed">
            Check that <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">.openreality/config.toml</code> has the correct
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">engine_path</code>.
          </p>
        </div>
        <div>
          <h3 class="text-lg font-mono font-bold text-or-text mb-1">WASM build failures</h3>
          <p class="text-or-text-dim leading-relaxed">
            Ensure <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">wasm-pack</code> is installed:
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">cargo install wasm-pack</code>.
          </p>
        </div>
        <div>
          <h3 class="text-lg font-mono font-bold text-or-text mb-1">Shader cache issues</h3>
          <p class="text-or-text-dim leading-relaxed">
            Clear the cache and rebuild:
            <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">orcli cache clear && orcli cache shaders</code>.
          </p>
        </div>
      </div>
    </section>
  </div>
</template>
