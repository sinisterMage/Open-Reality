"""Bzlmod module extension for the Julia toolchain."""

load("//bazel/julia:julia_repository.bzl", "julia_download")

_DEFAULT_NAME = "julia_toolchains"

# Label() resolves at load time relative to this .bzl file's repo (main module).
# str() produces the canonical form (@@_main//...) usable from external repos.
_TOOLCHAIN_TYPE = str(Label("//bazel/julia:toolchain_type"))

def _julia_extension_impl(module_ctx):
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            julia_download(
                name = _DEFAULT_NAME,
                version = toolchain.version,
                toolchain_type = _TOOLCHAIN_TYPE,
            )

_toolchain_tag = tag_class(
    attrs = {
        "version": attr.string(mandatory = True),
    },
)

julia = module_extension(
    implementation = _julia_extension_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
    },
)
