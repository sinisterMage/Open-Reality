# Desktop build pipeline using PackageCompiler.jl
#
# Creates a standalone executable that bundles Julia, OpenReality, and game code
# into a single distributable application.
#
# Usage (called by orcli):
#   desktop_build(entry_file, output_dir, platform, release)

using Pkg

"""
    desktop_build(entry::String, output::String, platform::String, release::Bool)

Build a standalone desktop executable from an OpenReality game entry point.

# Arguments
- `entry`: Path to the Julia entry point file (must call `render()`)
- `output`: Output directory for the compiled application
- `platform`: Target platform ("linux", "macos", "windows")
- `release`: Whether to enable release optimizations (CPU-native, strip debug info)
"""
function desktop_build(entry::String, output::String, platform::String, release::Bool)
    # Ensure PackageCompiler is available
    if !haskey(Pkg.project().dependencies, "PackageCompiler")
        @info "Installing PackageCompiler.jl..."
        Pkg.add("PackageCompiler")
    end

    @eval using PackageCompiler

    if !isfile(entry)
        error("Entry file not found: $entry")
    end

    mkpath(output)

    @info "Building desktop executable..." entry output platform release

    # Create a temporary project that wraps the game
    wrapper_dir = mktempdir()
    wrapper_project = joinpath(wrapper_dir, "Project.toml")
    wrapper_main = joinpath(wrapper_dir, "main.jl")

    # Determine the OpenReality source path
    engine_path = dirname(dirname(@__FILE__))

    # Write a wrapper main.jl that loads OpenReality and the game entry point
    open(wrapper_main, "w") do io
        write(io, """
        # Auto-generated wrapper for desktop build
        using OpenReality

        function julia_main()::Cint
            try
                include("$(escape_string(entry))")
            catch e
                @error "Game error" exception=(e, catch_backtrace())
                return 1
            end
            return 0
        end
        """)
    end

    # Write wrapper Project.toml that depends on the local OpenReality
    open(wrapper_project, "w") do io
        write(io, """
        [deps]
        OpenReality = "$(Pkg.project().uuid)"

        [sources]
        OpenReality = {path = "$(escape_string(engine_path))"}
        """)
    end

    # Collect precompile statements by running the entry briefly
    precompile_file = joinpath(wrapper_dir, "precompile_statements.jl")
    _generate_precompile_statements(entry, precompile_file)

    # Build arguments
    app_name = _app_name_from_entry(entry)

    @info "Compiling application '$app_name'..."
    @info "This may take several minutes on first run..."

    kwargs = Dict{Symbol, Any}(
        :precompile_statements_file => isfile(precompile_file) ? precompile_file : nothing,
        :incremental => !release,
        :filter_stdlibs => release,
        :include_lazy_artifacts => false,
    )

    if release
        kwargs[:cpu_target] = "generic"
    end

    # Remove nothing values
    filter!(p -> !isnothing(p.second), kwargs)

    Base.invokelatest(
        PackageCompiler.create_app,
        engine_path,          # source project
        output;               # output directory
        executables = [app_name => "julia_main"],
        force = true,
        kwargs...
    )

    # Copy assets alongside the executable
    _copy_game_assets(entry, output)

    # Platform-specific post-processing
    _platform_postprocess(output, platform, app_name)

    @info "Build complete!" output
    @info "Run with: $(joinpath(output, "bin", _exe_name(app_name, platform)))"
end

function _generate_precompile_statements(entry::String, output::String)
    @info "Generating precompile statements..."
    try
        # Run the entry file with tracing to collect precompile statements
        trace_file = tempname() * ".jl"
        cmd = `$(Base.julia_cmd()) --project=. --trace-compile=$trace_file -e "
            ENV[\"OPENREALITY_HEADLESS\"] = \"1\"
            include(\"$entry\")
        "`
        # Run with timeout — we just need the startup precompile statements
        proc = run(cmd; wait=false)
        sleep(10)
        if process_running(proc)
            kill(proc)
        end
        if isfile(trace_file)
            cp(trace_file, output; force=true)
            n_statements = countlines(output)
            @info "Collected $n_statements precompile statements"
        end
    catch e
        @warn "Could not generate precompile statements" exception=e
    end
end

function _app_name_from_entry(entry::String)
    name = splitext(basename(entry))[1]
    # Sanitize: lowercase, replace non-alphanumeric with underscore
    name = lowercase(replace(name, r"[^a-zA-Z0-9_]" => "_"))
    isempty(name) ? "openreality_game" : name
end

function _exe_name(app_name::String, platform::String)
    platform == "windows" ? "$app_name.exe" : app_name
end

function _copy_game_assets(entry::String, output::String)
    entry_dir = dirname(abspath(entry))
    assets_dir = joinpath(entry_dir, "assets")

    if isdir(assets_dir)
        dst = joinpath(output, "assets")
        @info "Copying game assets..." assets_dir dst
        cp(assets_dir, dst; force=true)
    end

    # Also check for common asset directories relative to entry
    for dir_name in ["models", "textures", "sounds", "scenes", "fonts"]
        src = joinpath(entry_dir, dir_name)
        if isdir(src)
            dst = joinpath(output, dir_name)
            @info "Copying $dir_name..." src dst
            cp(src, dst; force=true)
        end
    end
end

function _platform_postprocess(output::String, platform::String, app_name::String)
    if platform == "macos"
        _create_macos_app_bundle(output, app_name)
    elseif platform == "linux"
        _create_linux_launcher(output, app_name)
    end
end

function _create_linux_launcher(output::String, app_name::String)
    launcher = joinpath(output, "$app_name.sh")
    open(launcher, "w") do io
        write(io, """
        #!/bin/bash
        SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
        export LD_LIBRARY_PATH="\$SCRIPT_DIR/lib:\$LD_LIBRARY_PATH"
        exec "\$SCRIPT_DIR/bin/$app_name" "\$@"
        """)
    end
    chmod(launcher, 0o755)
    @info "Created Linux launcher: $launcher"
end

function _create_macos_app_bundle(output::String, app_name::String)
    bundle_dir = joinpath(dirname(output), "$app_name.app")
    contents = joinpath(bundle_dir, "Contents")
    macos_dir = joinpath(contents, "MacOS")
    resources = joinpath(contents, "Resources")

    mkpath(macos_dir)
    mkpath(resources)

    # Info.plist
    open(joinpath(contents, "Info.plist"), "w") do io
        write(io, """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>$app_name</string>
            <key>CFBundleIdentifier</key>
            <string>com.openreality.$app_name</string>
            <key>CFBundleName</key>
            <string>$app_name</string>
            <key>CFBundleVersion</key>
            <string>1.0.0</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0.0</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """)
    end

    # Create a launcher script that sets up library paths
    launcher = joinpath(macos_dir, app_name)
    open(launcher, "w") do io
        write(io, """
        #!/bin/bash
        BUNDLE_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
        GAME_DIR="\$BUNDLE_DIR/Resources/game"
        export DYLD_LIBRARY_PATH="\$GAME_DIR/lib:\$DYLD_LIBRARY_PATH"
        exec "\$GAME_DIR/bin/$app_name" "\$@"
        """)
    end
    chmod(launcher, 0o755)

    # Copy the compiled app into Resources/game
    game_dir = joinpath(resources, "game")
    cp(output, game_dir; force=true)

    @info "Created macOS app bundle: $bundle_dir"
end
