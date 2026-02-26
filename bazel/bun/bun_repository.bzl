"""Repository rule that downloads a hermetic Bun binary."""

_BUN_BASE_URL = "https://github.com/oven-sh/bun/releases/download"

# Platform matrix: (os, arch) -> download info
_BUN_PLATFORMS = {
    "1.3.8": {
        ("linux", "amd64"): {
            "url": "{base}/bun-v1.3.8/bun-linux-x64.zip",
            "strip_prefix": "bun-linux-x64",
            "sha256": "0322b17f0722da76a64298aad498225aedcbf6df1008a1dee45e16ecb226a3f1",
        },
        ("linux", "aarch64"): {
            "url": "{base}/bun-v1.3.8/bun-linux-aarch64.zip",
            "strip_prefix": "bun-linux-aarch64",
            "sha256": "4e9deb6814a7ec7f68725ddd97d0d7b4065bcda9a850f69d497567e995a7fa33",
        },
        ("mac os x", "aarch64"): {
            "url": "{base}/bun-v1.3.8/bun-darwin-aarch64.zip",
            "strip_prefix": "bun-darwin-aarch64",
            "sha256": "672a0a9a7b744d085a1d2219ca907e3e26f5579fca9e783a9510a4f98a36212f",
        },
        ("mac os x", "x86_64"): {
            "url": "{base}/bun-v1.3.8/bun-darwin-x64.zip",
            "strip_prefix": "bun-darwin-x64",
            "sha256": "4a0ecd703b37d66abaf51e5bc24fd1249e8dc392c17ee6235710cf51a0988b85",
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
        fail("Unsupported OS for Bun toolchain: {}".format(os_name))

    if arch in ("amd64", "x86_64"):
        arch_key = "amd64"
    elif arch in ("aarch64", "arm64"):
        arch_key = "aarch64"
    else:
        fail("Unsupported architecture for Bun toolchain: {}".format(arch))

    return (os_key, arch_key)

def _bun_download_impl(repository_ctx):
    version = repository_ctx.attr.version
    if version not in _BUN_PLATFORMS:
        fail("Bun version {} is not supported. Supported: {}".format(
            version,
            ", ".join(_BUN_PLATFORMS.keys()),
        ))

    platform = _detect_platform(repository_ctx)
    platform_info = _BUN_PLATFORMS[version].get(platform)
    if not platform_info:
        fail("Bun {} is not available for platform {}/{}".format(
            version,
            platform[0],
            platform[1],
        ))

    url = platform_info["url"].format(base = _BUN_BASE_URL)

    repository_ctx.download_and_extract(
        url = url,
        sha256 = platform_info["sha256"],
    )

    # Find the bun binary regardless of archive internal structure
    result = repository_ctx.execute(["find", ".", "-name", "bun", "-type", "f"])
    if result.return_code != 0 or not result.stdout.strip():
        # Debug: show what was actually extracted
        ls_result = repository_ctx.execute(["find", ".", "-maxdepth", "3"])
        fail("Could not find bun binary after extracting {}. Contents:\n{}".format(
            url,
            ls_result.stdout,
        ))

    bun_path = result.stdout.strip().split("\n")[0]
    if bun_path != "./bun":
        repository_ctx.execute(["mv", bun_path, "bun"])

    # Clean up extracted subdirectories
    subdir = platform_info["strip_prefix"]
    repository_ctx.execute(["rm", "-rf", subdir])
    repository_ctx.execute(["chmod", "+x", "bun"])

    toolchain_type = repository_ctx.attr.toolchain_type

    # Generate the toolchain rule locally so we don't need cross-repo loads.
    repository_ctx.file("defs.bzl", content = """\
\"\"\"Generated Bun toolchain rule.\"\"\"

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
""")

    # Write the BUILD file that defines the toolchain
    repository_ctx.file("BUILD.bazel", content = """\
load(":defs.bzl", "bun_toolchain")

exports_files(["bun"])

bun_toolchain(
    name = "bun_toolchain_impl",
    bun_bin = "bun",
    visibility = ["//visibility:public"],
)

toolchain(
    name = "bun_toolchain",
    toolchain = ":bun_toolchain_impl",
    toolchain_type = "{toolchain_type}",
    visibility = ["//visibility:public"],
)
""".format(toolchain_type = toolchain_type))

bun_download = repository_rule(
    implementation = _bun_download_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "toolchain_type": attr.string(mandatory = True),
    },
    doc = "Downloads a hermetic Bun binary for the host platform.",
)
