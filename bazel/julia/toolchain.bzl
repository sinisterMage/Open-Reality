"""Julia toolchain provider and rule."""

JuliaInfo = provider(
    doc = "Information about a Julia toolchain.",
    fields = {
        "julia_bin": "The Julia interpreter binary (File).",
    },
)

def _julia_toolchain_impl(ctx):
    julia_info = JuliaInfo(julia_bin = ctx.file.julia_bin)
    toolchain_info = platform_common.ToolchainInfo(julia_info = julia_info)
    return [toolchain_info]

julia_toolchain = rule(
    implementation = _julia_toolchain_impl,
    attrs = {
        "julia_bin": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The Julia interpreter binary.",
        ),
    },
    provides = [platform_common.ToolchainInfo],
)
