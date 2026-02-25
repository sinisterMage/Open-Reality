"""Bun toolchain provider and rule."""

BunInfo = provider(
    doc = "Information about a Bun toolchain.",
    fields = {
        "bun_bin": "The Bun runtime binary (File).",
    },
)

def _bun_toolchain_impl(ctx):
    bun_info = BunInfo(bun_bin = ctx.file.bun_bin)
    toolchain_info = platform_common.ToolchainInfo(bun_info = bun_info)
    return [toolchain_info]

bun_toolchain = rule(
    implementation = _bun_toolchain_impl,
    attrs = {
        "bun_bin": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The Bun runtime binary.",
        ),
    },
    provides = [platform_common.ToolchainInfo],
)
