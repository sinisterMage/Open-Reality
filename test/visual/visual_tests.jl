# Visual Regression Tests for Open Reality
#
# Usage:
#   julia test/visual/visual_tests.jl                                 # Run tests
#   OPENREALITY_UPDATE_REFERENCES=true julia test/visual/visual_tests.jl  # Update references
#
# Via neomake (https://github.com/sinisterMage/neomake):
#   neomake run visual-test
#   OPENREALITY_UPDATE_REFERENCES=true neomake --no-cache run visual-test

using OpenReality
using Test

# Clear any stories from previous includes
clear_visual_stories!()

# Load story definitions — each file registers stories via @visual_story / visual_story()
include("stories/pbr_basic.jl")
include("stories/lighting.jl")
include("stories/materials.jl")
include("stories/shadows.jl")
include("stories/transparency.jl")
include("stories/postfx.jl")
include("stories/terrain.jl")
include("stories/instancing.jl")
include("stories/lod.jl")
include("stories/ui.jl")

# Configuration
update_mode = get(ENV, "OPENREALITY_UPDATE_REFERENCES", "false") == "true"
reference_dir = joinpath(@__DIR__, "references")
diff_dir = joinpath(@__DIR__, "diffs")

if update_mode
    @info "Visual regression: UPDATE mode — saving new reference images"
else
    @info "Visual regression: COMPARE mode — testing against references"
end

@testset "Visual Regression" begin
    results = run_visual_tests(
        reference_dir=reference_dir,
        diff_dir=diff_dir,
        update_references=update_mode
    )

    for result in results
        @testset "$(result.story_name)" begin
            if update_mode
                @info "Updated reference" story=result.story_name path=result.reference_path
                @test true
            else
                if result.error_message !== nothing && !result.passed
                    @warn "Visual test failed" story=result.story_name message=result.error_message
                end
                if result.diff !== nothing && result.passed
                    @info "Visual test passed" story=result.story_name psnr="$(round(result.diff.psnr, digits=1))dB"
                end
                @test result.passed
            end
        end
    end

    # Summary
    passed = count(r -> r.passed, results)
    total = length(results)
    if update_mode
        @info "Updated $total reference images in $reference_dir"
    else
        @info "Visual regression: $passed/$total stories passed"
        if passed < total
            failed = filter(r -> !r.passed, results)
            for r in failed
                @warn "FAILED: $(r.story_name)" message=r.error_message
            end
            @info "Diff images saved to $diff_dir"
        end
    end
end
