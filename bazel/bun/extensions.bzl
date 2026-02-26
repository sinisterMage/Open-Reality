"""Bzlmod module extension for the Bun toolchain."""

load("//bazel/bun:bun_repository.bzl", "bun_download")

_DEFAULT_NAME = "bun_toolchains"

# Label() resolves at load time relative to this .bzl file's repo (main module).
# str() produces the canonical form (@@_main//...) usable from external repos.
_TOOLCHAIN_TYPE = str(Label("//bazel/bun:toolchain_type"))

def _bun_extension_impl(module_ctx):
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            bun_download(
                name = _DEFAULT_NAME,
                version = toolchain.version,
                toolchain_type = _TOOLCHAIN_TYPE,
            )

_toolchain_tag = tag_class(
    attrs = {
        "version": attr.string(mandatory = True),
    },
)

bun = module_extension(
    implementation = _bun_extension_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
    },
)
