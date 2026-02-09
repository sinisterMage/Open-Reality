# Built-in mesh primitive generators

"""
    cube_mesh(; size::Float32 = 1.0f0) -> MeshComponent

Generate a unit cube mesh centered at the origin.
Each face has its own vertices with proper face normals for correct lighting.
"""
function cube_mesh(; size::Float32 = 1.0f0)
    h = size / 2.0f0

    # 6 faces × 4 vertices = 24 vertices (unshared for correct normals)
    vertices = Point3f[
        # Front face (+Z)
        Point3f(-h, -h,  h), Point3f( h, -h,  h), Point3f( h,  h,  h), Point3f(-h,  h,  h),
        # Back face (-Z)
        Point3f( h, -h, -h), Point3f(-h, -h, -h), Point3f(-h,  h, -h), Point3f( h,  h, -h),
        # Right face (+X)
        Point3f( h, -h,  h), Point3f( h, -h, -h), Point3f( h,  h, -h), Point3f( h,  h,  h),
        # Left face (-X)
        Point3f(-h, -h, -h), Point3f(-h, -h,  h), Point3f(-h,  h,  h), Point3f(-h,  h, -h),
        # Top face (+Y)
        Point3f(-h,  h,  h), Point3f( h,  h,  h), Point3f( h,  h, -h), Point3f(-h,  h, -h),
        # Bottom face (-Y)
        Point3f(-h, -h, -h), Point3f( h, -h, -h), Point3f( h, -h,  h), Point3f(-h, -h,  h),
    ]

    normals = Vec3f[
        # Front
        Vec3f(0, 0, 1), Vec3f(0, 0, 1), Vec3f(0, 0, 1), Vec3f(0, 0, 1),
        # Back
        Vec3f(0, 0, -1), Vec3f(0, 0, -1), Vec3f(0, 0, -1), Vec3f(0, 0, -1),
        # Right
        Vec3f(1, 0, 0), Vec3f(1, 0, 0), Vec3f(1, 0, 0), Vec3f(1, 0, 0),
        # Left
        Vec3f(-1, 0, 0), Vec3f(-1, 0, 0), Vec3f(-1, 0, 0), Vec3f(-1, 0, 0),
        # Top
        Vec3f(0, 1, 0), Vec3f(0, 1, 0), Vec3f(0, 1, 0), Vec3f(0, 1, 0),
        # Bottom
        Vec3f(0, -1, 0), Vec3f(0, -1, 0), Vec3f(0, -1, 0), Vec3f(0, -1, 0),
    ]

    # UVs: same pattern for each face
    face_uvs = Vec2f[Vec2f(0, 0), Vec2f(1, 0), Vec2f(1, 1), Vec2f(0, 1)]
    uvs = Vec2f[]
    for _ in 1:6
        append!(uvs, face_uvs)
    end

    # Two triangles per face, 0-indexed for OpenGL
    indices = UInt32[]
    for face in 0:5
        base = UInt32(face * 4)
        append!(indices, [base, base+1, base+2, base, base+2, base+3])
    end

    return MeshComponent(vertices=vertices, indices=indices, normals=normals, uvs=uvs)
end

"""
    plane_mesh(; width::Float32 = 1.0f0, depth::Float32 = 1.0f0) -> MeshComponent

Generate a horizontal plane mesh centered at the origin, facing up (+Y).
"""
function plane_mesh(; width::Float32 = 1.0f0, depth::Float32 = 1.0f0)
    hw = width / 2.0f0
    hd = depth / 2.0f0

    vertices = Point3f[
        Point3f(-hw, 0, -hd),
        Point3f( hw, 0, -hd),
        Point3f( hw, 0,  hd),
        Point3f(-hw, 0,  hd),
    ]

    normals = Vec3f[
        Vec3f(0, 1, 0), Vec3f(0, 1, 0), Vec3f(0, 1, 0), Vec3f(0, 1, 0),
    ]

    uvs = Vec2f[
        Vec2f(0, 0), Vec2f(1, 0), Vec2f(1, 1), Vec2f(0, 1),
    ]

    indices = UInt32[0, 1, 2, 0, 2, 3]

    return MeshComponent(vertices=vertices, indices=indices, normals=normals, uvs=uvs)
end

"""
    sphere_mesh(; radius::Float32 = 0.5f0, segments::Int = 32, rings::Int = 16) -> MeshComponent

Generate a UV sphere mesh centered at the origin.
`segments` controls longitude subdivisions, `rings` controls latitude subdivisions.
"""
function sphere_mesh(; radius::Float32 = 0.5f0, segments::Int = 32, rings::Int = 16)
    vertices = Point3f[]
    normals = Vec3f[]
    uvs = Vec2f[]
    indices = UInt32[]

    for j in 0:rings
        theta = Float32(j) * Float32(pi) / Float32(rings)
        sin_theta = sin(theta)
        cos_theta = cos(theta)

        for i in 0:segments
            phi = Float32(i) * 2.0f0 * Float32(pi) / Float32(segments)
            sin_phi = sin(phi)
            cos_phi = cos(phi)

            nx = cos_phi * sin_theta
            ny = cos_theta
            nz = sin_phi * sin_theta

            push!(vertices, Point3f(radius * nx, radius * ny, radius * nz))
            push!(normals, Vec3f(nx, ny, nz))
            push!(uvs, Vec2f(Float32(i) / Float32(segments), Float32(j) / Float32(rings)))
        end
    end

    # Generate triangle indices
    for j in 0:(rings - 1)
        for i in 0:(segments - 1)
            row_len = segments + 1
            a = UInt32(j * row_len + i)
            b = UInt32(a + row_len)
            c = UInt32(a + 1)
            d = UInt32(b + 1)

            # Two triangles per quad
            append!(indices, [a, b, c])
            append!(indices, [c, b, d])
        end
    end

    return MeshComponent(vertices=vertices, indices=indices, normals=normals, uvs=uvs)
end
