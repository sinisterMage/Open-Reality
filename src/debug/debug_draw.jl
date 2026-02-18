# Debug drawing utilities — ENV-gated, zero overhead when OPENREALITY_DEBUG != "true"

const OPENREALITY_DEBUG = get(ENV, "OPENREALITY_DEBUG", "false") == "true"

struct DebugLine
    start_pos::Vec3f
    end_pos::Vec3f
    color::RGB{Float32}
end

if OPENREALITY_DEBUG

const _DEBUG_LINES = DebugLine[]

function debug_line!(start_pos::Vec3f, end_pos::Vec3f, color::RGB{Float32} = RGB{Float32}(0,1,0))
    push!(_DEBUG_LINES, DebugLine(start_pos, end_pos, color))
    return nothing
end

function debug_box!(center::Vec3f, half_extents::Vec3f, color::RGB{Float32} = RGB{Float32}(0,1,0))
    hx, hy, hz = half_extents[1], half_extents[2], half_extents[3]
    cx, cy, cz = center[1], center[2], center[3]

    # 8 corners of the AABB
    c000 = Vec3f(cx - hx, cy - hy, cz - hz)
    c001 = Vec3f(cx - hx, cy - hy, cz + hz)
    c010 = Vec3f(cx - hx, cy + hy, cz - hz)
    c011 = Vec3f(cx - hx, cy + hy, cz + hz)
    c100 = Vec3f(cx + hx, cy - hy, cz - hz)
    c101 = Vec3f(cx + hx, cy - hy, cz + hz)
    c110 = Vec3f(cx + hx, cy + hy, cz - hz)
    c111 = Vec3f(cx + hx, cy + hy, cz + hz)

    # Bottom face (y = -hy)
    debug_line!(c000, c100, color)
    debug_line!(c100, c101, color)
    debug_line!(c101, c001, color)
    debug_line!(c001, c000, color)

    # Top face (y = +hy)
    debug_line!(c010, c110, color)
    debug_line!(c110, c111, color)
    debug_line!(c111, c011, color)
    debug_line!(c011, c010, color)

    # Vertical pillars
    debug_line!(c000, c010, color)
    debug_line!(c100, c110, color)
    debug_line!(c101, c111, color)
    debug_line!(c001, c011, color)

    return nothing
end

function debug_sphere!(center::Vec3f, radius::Float32, color::RGB{Float32} = RGB{Float32}(0,1,0))
    segments = 16
    cx, cy, cz = center[1], center[2], center[3]

    for i in 0:segments-1
        a0 = 2π * i / segments
        a1 = 2π * (i + 1) / segments
        c0, s0 = Float32(cos(a0)), Float32(sin(a0))
        c1, s1 = Float32(cos(a1)), Float32(sin(a1))

        # XY plane
        debug_line!(Vec3f(cx + radius * c0, cy + radius * s0, cz),
                    Vec3f(cx + radius * c1, cy + radius * s1, cz), color)
        # XZ plane
        debug_line!(Vec3f(cx + radius * c0, cy, cz + radius * s0),
                    Vec3f(cx + radius * c1, cy, cz + radius * s1), color)
        # YZ plane
        debug_line!(Vec3f(cx, cy + radius * c0, cz + radius * s0),
                    Vec3f(cx, cy + radius * c1, cz + radius * s1), color)
    end

    return nothing
end

function flush_debug_draw!()
    empty!(_DEBUG_LINES)
    return nothing
end

else  # OPENREALITY_DEBUG == false

@inline debug_line!(args...) = nothing
@inline debug_box!(args...) = nothing
@inline debug_sphere!(args...) = nothing
@inline flush_debug_draw!() = nothing

end  # if OPENREALITY_DEBUG
