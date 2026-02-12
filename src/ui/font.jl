# Font atlas generation using FreeTypeAbstraction

using FreeTypeAbstraction

# Global font atlas cache: (path, size) → FontAtlas
const _FONT_ATLAS_CACHE = Dict{Tuple{String, Int}, FontAtlas}()

"""
    _find_default_font() -> String

Find a default system font path.
"""
function _find_default_font()
    candidates = [
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/gnu-free/FreeSans.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNSText.ttf",
        "C:/Windows/Fonts/arial.ttf",
        "C:/Windows/Fonts/segoeui.ttf",
    ]
    for path in candidates
        isfile(path) && return path
    end
    return ""
end

"""
    get_or_create_font_atlas!(font_path::String, font_size::Int) -> FontAtlas

Get or create a font atlas for the given font and size.
Uses FreeTypeAbstraction to rasterize glyphs into a texture atlas.
"""
function get_or_create_font_atlas!(font_path::String, font_size::Int)
    key = (font_path, font_size)
    haskey(_FONT_ATLAS_CACHE, key) && return _FONT_ATLAS_CACHE[key]

    actual_path = isempty(font_path) ? _find_default_font() : font_path
    if isempty(actual_path) || !isfile(actual_path)
        @warn "Font not found: $font_path (and no default font available)"
        return FontAtlas()
    end

    face = FreeTypeAbstraction.FTFont(actual_path)

    # Rasterize ASCII printable characters (32-126)
    chars = Char(32):Char(126)
    glyphs = Dict{Char, GlyphInfo}()

    # First pass: measure total atlas size
    padding = 2
    row_height = 0
    total_width = 0
    max_width = 1024  # Max atlas width

    glyph_bitmaps = Dict{Char, Tuple{Matrix{UInt8}, FreeTypeAbstraction.FontExtent{Float32}}}()

    for ch in chars
        extent = FreeTypeAbstraction.get_extent(face, ch)
        result = FreeTypeAbstraction.renderface(face, ch, font_size)

        # renderface returns (Matrix{UInt8}, FontExtent) tuple
        if result isa Tuple
            bitmap = result[1]
            if bitmap === nothing || isempty(bitmap)
                glyph_bitmaps[ch] = (zeros(UInt8, 0, 0), extent)
            else
                glyph_bitmaps[ch] = (bitmap, extent)
            end
        else
            glyph_bitmaps[ch] = (zeros(UInt8, 0, 0), extent)
        end
    end

    # Calculate atlas layout (simple row packing)
    x_cursor = 0
    y_cursor = 0
    row_h = 0
    atlas_width = min(max_width, 512)
    positions = Dict{Char, Tuple{Int, Int}}()

    for ch in chars
        bm, _ = glyph_bitmaps[ch]
        # FreeTypeAbstraction renderface returns matrix as (width, height)
        bw = size(bm, 1)
        bh = size(bm, 2)
        if bw == 0 && bh == 0
            bw = font_size ÷ 3  # Reserve space for invisible chars
            bh = 0
        end

        if x_cursor + bw + padding > atlas_width
            x_cursor = 0
            y_cursor += row_h + padding
            row_h = 0
        end

        positions[ch] = (x_cursor, y_cursor)
        row_h = max(row_h, bh)
        x_cursor += bw + padding
    end

    atlas_height = y_cursor + row_h + padding

    # Power-of-2 height
    atlas_height = max(1, atlas_height)
    atlas_height_pow2 = 1
    while atlas_height_pow2 < atlas_height
        atlas_height_pow2 <<= 1
    end
    atlas_height = atlas_height_pow2

    # Create atlas pixel buffer
    atlas = zeros(UInt8, atlas_width * atlas_height)

    # Second pass: blit glyphs and build glyph info
    for ch in chars
        bm, extent = glyph_bitmaps[ch]
        px, py = positions[ch]
        # FreeTypeAbstraction renderface returns matrix as (width, height)
        bw = size(bm, 1)
        bh = size(bm, 2)

        # Blit bitmap into atlas
        # bm is indexed as bm[x, y] where x=column (width), y=row (height)
        for row in 1:bh, col in 1:bw
            atlas_x = px + col - 1
            atlas_y = py + row - 1
            if atlas_x < atlas_width && atlas_y < atlas_height
                atlas[atlas_y * atlas_width + atlas_x + 1] = bm[col, row]
            end
        end

        # Compute glyph metrics
        # FreeTypeAbstraction extents are in normalized font units
        advance = FreeTypeAbstraction.hadvance(extent)
        bearing_x_val = FreeTypeAbstraction.inkwidth(extent) > 0 ? Float32(extent.horizontal_bearing[1] * font_size) : 0.0f0
        bearing_y_val = Float32(bh)

        glyphs[ch] = GlyphInfo(
            Float32(advance * font_size),
            bearing_x_val,
            bearing_y_val,
            Float32(bw),
            Float32(bh),
            Float32(px) / Float32(atlas_width),
            Float32(py) / Float32(atlas_height),
            Float32(bw) / Float32(atlas_width),
            Float32(bh) / Float32(atlas_height)
        )
    end

    font_atlas = FontAtlas()
    font_atlas.atlas_width = atlas_width
    font_atlas.atlas_height = atlas_height
    font_atlas.glyphs = glyphs
    font_atlas.font_size = Float32(font_size)
    font_atlas.line_height = Float32(font_size) * 1.2f0

    # Upload atlas to GPU (single-channel texture)
    font_atlas.texture_id = _upload_font_atlas(atlas, atlas_width, atlas_height)

    _FONT_ATLAS_CACHE[key] = font_atlas
    return font_atlas
end

"""
    _upload_font_atlas(data::Vector{UInt8}, width::Int, height::Int) -> UInt32

Upload a single-channel font atlas texture to GPU.
"""
function _upload_font_atlas(data::Vector{UInt8}, width::Int, height::Int)
    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    tex_id = tex_ref[]
    glBindTexture(GL_TEXTURE_2D, tex_id)

    # Single channel (GL_RED for core profile)
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RED, width, height, 0,
                 GL_RED, GL_UNSIGNED_BYTE, data)

    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)

    glBindTexture(GL_TEXTURE_2D, GLuint(0))
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
    return UInt32(tex_id)
end

"""
    measure_text(atlas::FontAtlas, text::String; size::Float32 = 0.0f0) -> (width::Float32, height::Float32)

Measure the pixel dimensions of rendered text.
"""
function measure_text(atlas::FontAtlas, text::String; size::Float32 = 0.0f0)
    if isempty(atlas.glyphs)
        return (0.0f0, 0.0f0)
    end

    scale = size > 0.0f0 ? size / atlas.font_size : 1.0f0
    width = 0.0f0
    height = atlas.line_height * scale

    for ch in text
        if ch == '\n'
            height += atlas.line_height * scale
            continue
        end
        glyph = get(atlas.glyphs, ch, nothing)
        if glyph !== nothing
            width += glyph.advance_x * scale
        end
    end

    return (width, height)
end

"""
    reset_font_cache!()

Clear the font atlas cache (for testing).
"""
function reset_font_cache!()
    empty!(_FONT_ATLAS_CACHE)
    return nothing
end
