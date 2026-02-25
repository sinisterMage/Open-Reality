"""Repository rule that downloads a hermetic Julia binary."""

_JULIA_BASE_URL = "https://julialang-s3.julialang.org/bin"

# Platform matrix: (os, arch) -> (url_path_segment, archive_suffix, sha256)
_JULIA_PLATFORMS = {
    "1.12.4": {
        ("linux", "amd64"): {
            "url": "{base}/linux/x64/1.12/julia-1.12.4-linux-x86_64.tar.gz",
            "strip_prefix": "julia-1.12.4",
            "sha256": "c57baf178fe140926acb1a25396d482f325af9d7908d9b066d2fbc0d6639985d",
        },
        ("linux", "aarch64"): {
            "url": "{base}/linux/aarch64/1.12/julia-1.12.4-linux-aarch64.tar.gz",
            "strip_prefix": "julia-1.12.4",
            "sha256": "a602a2dfee931224fd68e47567dc672743e2fd9e80f39d84cf3c99afc9663ddd",
        },
        ("mac os x", "aarch64"): {
            "url": "{base}/mac/aarch64/1.12/julia-1.12.4-macaarch64.tar.gz",
            "strip_prefix": "julia-1.12.4",
            "sha256": "ea46b20deb5b4102e86f382f2d42313912421333eafa37cf057fdad28edd7e0f",
        },
        ("mac os x", "x86_64"): {
            "url": "{base}/mac/x64/1.12/julia-1.12.4-mac64.tar.gz",
            "strip_prefix": "julia-1.12.4",
            "sha256": "2c34495ab302a0f2ba776a7323924f154608649a19d75e92d68505c5f04bf497",
        },
    },
}

def _detect_platform(repository_ctx):
    """Detects the host platform as (os, arch) tuple."""
    os_name = repository_ctx.os.name.lower()
    arch = repository_ctx.os.arch

    if "linux" in os_name:
        os_key = "linux"
    elif "mac" in os_name:
        os_key = "mac os x"
    else:
        fail("Unsupported OS for Julia toolchain: {}".format(os_name))

    # Normalize arch names
    if arch in ("amd64", "x86_64"):
        arch_key = "amd64"
    elif arch in ("aarch64", "arm64"):
        arch_key = "aarch64"
    else:
        fail("Unsupported architecture for Julia toolchain: {}".format(arch))

    return (os_key, arch_key)

def _julia_download_impl(repository_ctx):
    version = repository_ctx.attr.version
    if version not in _JULIA_PLATFORMS:
        fail("Julia version {} is not supported. Supported: {}".format(
            version,
            ", ".join(_JULIA_PLATFORMS.keys()),
        ))

    platform = _detect_platform(repository_ctx)
    platform_info = _JULIA_PLATFORMS[version].get(platform)
    if not platform_info:
        fail("Julia {} is not available for platform {}/{}".format(
            version,
            platform[0],
            platform[1],
        ))

    url = platform_info["url"].format(base = _JULIA_BASE_URL)

    repository_ctx.download_and_extract(
        url = url,
        sha256 = platform_info["sha256"],
        stripPrefix = platform_info["strip_prefix"],
    )

    # Write the BUILD file that defines the toolchain
    repository_ctx.file("BUILD.bazel", content = """\
load("//bazel/julia:toolchain.bzl", "julia_toolchain")

exports_files(["bin/julia"])

julia_toolchain(
    name = "julia_toolchain_impl",
    julia_bin = "bin/julia",
    visibility = ["//visibility:public"],
)

toolchain(
    name = "julia_toolchain",
    toolchain = ":julia_toolchain_impl",
    toolchain_type = "//bazel/julia:toolchain_type",
    visibility = ["//visibility:public"],
)
""")

julia_download = repository_rule(
    implementation = _julia_download_impl,
    attrs = {
        "version": attr.string(mandatory = True),
    },
    doc = "Downloads a hermetic Julia binary for the host platform.",
)
