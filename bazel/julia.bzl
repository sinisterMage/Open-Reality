"""Custom Bazel rules for Julia projects.

Julia is a JIT-compiled language -- there is no traditional compilation step
that produces a binary artifact. These rules wrap the Julia interpreter for:
  - Precompilation (Pkg.instantiate + Pkg.precompile)
  - Testing (julia --project=. test/runtests.jl)
  - Running scripts (julia --project=. examples/foo.jl)

The Julia binary is resolved from a registered toolchain (see bazel/julia/)
rather than from the host PATH, ensuring hermetic builds.
"""

_TOOLCHAIN_TYPE = "//bazel/julia:toolchain_type"

def _get_julia_bin(ctx):
    """Resolves the Julia binary from the registered toolchain."""
    julia_info = ctx.toolchains[_TOOLCHAIN_TYPE].julia_info
    return julia_info.julia_bin

def _julia_precompile_impl(ctx):
    julia_bin = _get_julia_bin(ctx)
    project_toml = ctx.file.project_toml
    manifest_toml = ctx.file.manifest_toml
    srcs = ctx.files.srcs
    marker = ctx.actions.declare_file(ctx.label.name + ".precompiled")
    depot = ctx.actions.declare_directory(ctx.label.name + "_depot")

    ctx.actions.run_shell(
        inputs = [project_toml, manifest_toml] + srcs,
        tools = [julia_bin],
        outputs = [marker, depot],
        command = """
            set -e
            export JULIA_DEPOT_PATH="{depot}"
            export JULIA_PROJECT="{project_dir}"
            "{julia}" -e '
                using Pkg
                Pkg.instantiate()
                try
                    Pkg.precompile()
                catch e
                    @warn "Some packages failed to precompile (non-fatal)" exception=e
                end
            '
            touch "{marker}"
        """.format(
            depot = depot.path,
            project_dir = project_toml.dirname,
            julia = julia_bin.path,
            marker = marker.path,
        ),
        mnemonic = "JuliaPrecompile",
        progress_message = "Precompiling Julia packages",
        use_default_shell_env = True,
        execution_requirements = {
            "requires-network": "1",
            "no-sandbox": "1",
        },
    )
    return [DefaultInfo(files = depset([marker, depot]))]

julia_precompile = rule(
    implementation = _julia_precompile_impl,
    attrs = {
        "project_toml": attr.label(allow_single_file = True, mandatory = True),
        "manifest_toml": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = [".jl"]),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)

def _julia_test_impl(ctx):
    julia_bin = _get_julia_bin(ctx)
    test_file = ctx.file.src
    project_toml = ctx.file.project_toml
    manifest_toml = ctx.file.manifest_toml
    srcs = ctx.files.srcs
    data = ctx.files.data
    depot_files = ctx.files.depot

    runner = ctx.actions.declare_file(ctx.label.name + "_runner.sh")

    # Build the depot path clause — if a precompiled depot is provided, use it;
    # otherwise fall back to a temp depot that will be populated on first run.
    if depot_files:
        depot_clause = 'export JULIA_DEPOT_PATH="${{RUNFILES_DIR}}/_main/{depot}"'.format(
            depot = depot_files[0].short_path,
        )
    else:
        depot_clause = 'export JULIA_DEPOT_PATH="${TEST_TMPDIR:-.}/.julia"'

    ctx.actions.write(
        output = runner,
        content = """#!/bin/bash
set -e

# Set up Julia environment within the Bazel runfiles sandbox.
RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
PROJECT_DIR="${{RUNFILES_DIR}}/_main"

{depot_clause}
export JULIA_PROJECT="${{PROJECT_DIR}}"

# Forward DISPLAY/WAYLAND_DISPLAY for tests that load GPU/windowing libraries
export DISPLAY="${{DISPLAY:-:0}}"
if [ -n "${{WAYLAND_DISPLAY}}" ]; then
    export WAYLAND_DISPLAY
fi

"${{RUNFILES_DIR}}/_main/{julia}" --project="${{PROJECT_DIR}}" "${{PROJECT_DIR}}/{test_file}"
""".format(
            julia = julia_bin.short_path,
            test_file = test_file.short_path,
            depot_clause = depot_clause,
        ),
        is_executable = True,
    )

    all_runfiles = [project_toml, test_file, julia_bin] + srcs + data + depot_files
    if manifest_toml:
        all_runfiles.append(manifest_toml)

    runfiles = ctx.runfiles(files = all_runfiles)
    return [DefaultInfo(executable = runner, runfiles = runfiles)]

julia_test = rule(
    implementation = _julia_test_impl,
    test = True,
    attrs = {
        "src": attr.label(allow_single_file = [".jl"], mandatory = True),
        "project_toml": attr.label(allow_single_file = True, mandatory = True),
        "manifest_toml": attr.label(allow_single_file = True),
        "srcs": attr.label_list(allow_files = [".jl"]),
        "data": attr.label_list(allow_files = True),
        "depot": attr.label_list(
            allow_files = True,
            doc = "Precompiled Julia depot (output of julia_precompile).",
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)

def _julia_run_impl(ctx):
    julia_bin = _get_julia_bin(ctx)
    script = ctx.file.src
    project_toml = ctx.file.project_toml
    srcs = ctx.files.srcs
    data = ctx.files.data
    depot_files = ctx.files.depot

    if depot_files:
        depot_clause = 'export JULIA_DEPOT_PATH="${{RUNFILES_DIR}}/_main/{depot}"'.format(
            depot = depot_files[0].short_path,
        )
    else:
        depot_clause = 'export JULIA_DEPOT_PATH="${TMPDIR:-/tmp}/.julia-bazel"'

    runner = ctx.actions.declare_file(ctx.label.name + "_runner.sh")
    ctx.actions.write(
        output = runner,
        content = """#!/bin/bash
set -e

RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
PROJECT_DIR="${{RUNFILES_DIR}}/_main"

{depot_clause}
export JULIA_PROJECT="${{PROJECT_DIR}}"

"${{RUNFILES_DIR}}/_main/{julia}" --project="${{PROJECT_DIR}}" "${{PROJECT_DIR}}/{script}"
""".format(
            julia = julia_bin.short_path,
            script = script.short_path,
            depot_clause = depot_clause,
        ),
        is_executable = True,
    )

    all_runfiles = [project_toml, script, julia_bin] + srcs + data + depot_files
    runfiles = ctx.runfiles(files = all_runfiles)
    return [DefaultInfo(executable = runner, runfiles = runfiles)]

julia_run = rule(
    implementation = _julia_run_impl,
    executable = True,
    attrs = {
        "src": attr.label(allow_single_file = [".jl"], mandatory = True),
        "project_toml": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = [".jl"]),
        "data": attr.label_list(allow_files = True),
        "depot": attr.label_list(
            allow_files = True,
            doc = "Precompiled Julia depot (output of julia_precompile).",
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)
