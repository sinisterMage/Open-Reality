"""Custom Bazel rules for Bun-based JavaScript/TypeScript projects.

Wraps `bun` commands (test, build, etc.) for projects that use Bun as the
package manager and runtime.

The Bun binary is resolved from a registered toolchain (see bazel/bun/)
rather than from the host PATH, ensuring hermetic builds.
"""

_TOOLCHAIN_TYPE = "//bazel/bun:toolchain_type"

def _get_bun_bin(ctx):
    """Resolves the Bun binary from the registered toolchain."""
    bun_info = ctx.toolchains[_TOOLCHAIN_TYPE].bun_info
    return bun_info.bun_bin

def _bun_install_impl(ctx):
    bun_bin = _get_bun_bin(ctx)
    package_json = ctx.file.package_json
    lockfile = ctx.file.lockfile
    node_modules = ctx.actions.declare_directory(ctx.label.name + "_node_modules")

    inputs = [package_json]
    if lockfile:
        inputs.append(lockfile)

    ctx.actions.run_shell(
        inputs = inputs,
        tools = [bun_bin],
        outputs = [node_modules],
        command = """
            set -e
            # Capture the execroot so relative Bazel paths survive 'cd'
            EXECROOT="$(pwd)"

            WORK_DIR=$(mktemp -d)
            cp "${{EXECROOT}}/{package_json}" "${{WORK_DIR}}/package.json"
            {copy_lockfile}

            cd "${{WORK_DIR}}"
            "${{EXECROOT}}/{bun}" install --frozen-lockfile

            # Move the installed node_modules to the Bazel output
            cp -r "${{WORK_DIR}}/node_modules/." "${{EXECROOT}}/{output}/"
            # Remove Bun cache — it contains dangling symlinks that Bazel
            # rejects inside tree artifacts (declared directories).
            rm -rf "${{EXECROOT}}/{output}/.bun-cache"
            rm -rf "${{WORK_DIR}}"
        """.format(
            package_json = package_json.path,
            bun = bun_bin.path,
            output = node_modules.path,
            copy_lockfile = 'cp "${{EXECROOT}}/{}" "${{WORK_DIR}}/bun.lock"'.format(lockfile.path) if lockfile else "",
        ),
        mnemonic = "BunInstall",
        progress_message = "Installing Bun dependencies for %s" % ctx.label,
        execution_requirements = {
            "requires-network": "1",
        },
    )
    return [DefaultInfo(files = depset([node_modules]))]

bun_install = rule(
    implementation = _bun_install_impl,
    attrs = {
        "package_json": attr.label(allow_single_file = True, mandatory = True),
        "lockfile": attr.label(
            allow_single_file = True,
            doc = "The bun.lock or bun.lockb lockfile.",
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)

def _bun_test_impl(ctx):
    bun_bin = _get_bun_bin(ctx)
    package_json = ctx.file.package_json
    srcs = ctx.files.srcs
    data = ctx.files.data
    node_modules_files = ctx.files.node_modules

    runner = ctx.actions.declare_file(ctx.label.name + "_runner.sh")

    # Determine where node_modules lives in runfiles
    if node_modules_files:
        nm_setup = """
# Symlink the pre-installed node_modules into the project directory
if [ ! -e "${{PROJECT_DIR}}/node_modules" ]; then
    ln -s "${{RUNFILES_DIR}}/_main/{node_modules}" "${{PROJECT_DIR}}/node_modules"
fi
""".format(node_modules = node_modules_files[0].short_path)
    else:
        nm_setup = """
# No pre-installed node_modules provided; install if missing
if [ ! -d "${{PROJECT_DIR}}/node_modules" ]; then
    cd "${{PROJECT_DIR}}" && "${{RUNFILES_DIR}}/_main/{bun}" install --frozen-lockfile
fi
""".format(bun = bun_bin.short_path)

    # Use a working copy so Bun only sees project files + node_modules
    # (prevents test discovery inside the tree artifact's sibling dir).
    ctx.actions.write(
        output = runner,
        content = """#!/bin/bash
set -e

RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
PROJECT_DIR="${{RUNFILES_DIR}}/_main/{pkg_dir}"

# Build a clean working copy with only project sources + node_modules
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Copy project sources (excludes the tree-artifact sibling directory)
cp -r "${{PROJECT_DIR}}/." "$WORK_DIR/"
# Remove any stale node_modules from the copy
rm -rf "$WORK_DIR/node_modules"

{nm_setup_work}

cd "$WORK_DIR"
"${{RUNFILES_DIR}}/_main/{bun}" {command}
""".format(
            pkg_dir = package_json.dirname if package_json.dirname else ".",
            bun = bun_bin.short_path,
            command = ctx.attr.command,
            nm_setup_work = """
# Link pre-installed node_modules into the working copy
ln -s "${{RUNFILES_DIR}}/_main/{node_modules}" "$WORK_DIR/node_modules"
""".format(node_modules = node_modules_files[0].short_path) if node_modules_files else """
# No pre-installed node_modules provided; install if missing
cd "$WORK_DIR" && "${{RUNFILES_DIR}}/_main/{bun}" install --frozen-lockfile
""".format(bun = bun_bin.short_path),
        ),
        is_executable = True,
    )

    all_runfiles = [package_json, bun_bin] + srcs + data + node_modules_files
    runfiles = ctx.runfiles(files = all_runfiles)
    return [DefaultInfo(executable = runner, runfiles = runfiles)]

bun_test = rule(
    implementation = _bun_test_impl,
    test = True,
    attrs = {
        "package_json": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "data": attr.label_list(allow_files = True),
        "command": attr.string(default = "test"),
        "node_modules": attr.label_list(
            allow_files = True,
            doc = "Pre-installed node_modules (output of bun_install).",
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)
