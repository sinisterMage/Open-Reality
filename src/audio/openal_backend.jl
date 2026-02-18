# OpenAL backend — ccall wrappers and state management

using OpenAL_jll

# ---- OpenAL constants ----
const AL_NONE = Int32(0)
const AL_SOURCE_RELATIVE = Int32(0x0202)
const AL_LOOPING = Int32(0x1007)
const AL_BUFFER = Int32(0x1009)
const AL_GAIN = Int32(0x100A)
const AL_POSITION = Int32(0x1004)
const AL_VELOCITY = Int32(0x1006)
const AL_ORIENTATION = Int32(0x100F)
const AL_PITCH = Int32(0x1003)
const AL_REFERENCE_DISTANCE = Int32(0x1020)
const AL_MAX_DISTANCE = Int32(0x1023)
const AL_ROLLOFF_FACTOR = Int32(0x1021)
const AL_SOURCE_STATE = Int32(0x1010)
const AL_PLAYING = Int32(0x1012)
const AL_STOPPED = Int32(0x1014)
const AL_FORMAT_MONO8 = Int32(0x1100)
const AL_FORMAT_MONO16 = Int32(0x1101)
const AL_FORMAT_STEREO8 = Int32(0x1102)
const AL_FORMAT_STEREO16 = Int32(0x1103)
const AL_TRUE = Int32(1)
const AL_FALSE = Int32(0)

# ---- OpenAL ccall wrappers ----
const _openal_lib = OpenAL_jll.libopenal

function al_open_device(name::Ptr{Nothing} = C_NULL)
    ccall((:alcOpenDevice, _openal_lib), Ptr{Nothing}, (Ptr{Nothing},), name)
end

function al_close_device(device::Ptr{Nothing})
    ccall((:alcCloseDevice, _openal_lib), Int32, (Ptr{Nothing},), device)
end

function al_create_context(device::Ptr{Nothing}, attrs::Ptr{Nothing} = C_NULL)
    ccall((:alcCreateContext, _openal_lib), Ptr{Nothing}, (Ptr{Nothing}, Ptr{Nothing}), device, attrs)
end

function al_make_context_current(ctx::Ptr{Nothing})
    ccall((:alcMakeContextCurrent, _openal_lib), Int32, (Ptr{Nothing},), ctx)
end

function al_destroy_context(ctx::Ptr{Nothing})
    ccall((:alcDestroyContext, _openal_lib), Cvoid, (Ptr{Nothing},), ctx)
end

function al_gen_buffers(n::Int)
    ids = Vector{UInt32}(undef, n)
    ccall((:alGenBuffers, _openal_lib), Cvoid, (Int32, Ptr{UInt32}), Int32(n), ids)
    return ids
end

function al_delete_buffers(ids::Vector{UInt32})
    ccall((:alDeleteBuffers, _openal_lib), Cvoid, (Int32, Ptr{UInt32}), Int32(length(ids)), ids)
end

function al_buffer_data(buffer::UInt32, format::Int32, data::Vector{UInt8}, size::Int32, freq::Int32)
    ccall((:alBufferData, _openal_lib), Cvoid,
          (UInt32, Int32, Ptr{UInt8}, Int32, Int32),
          buffer, format, data, size, freq)
end

function al_gen_sources(n::Int)
    ids = Vector{UInt32}(undef, n)
    ccall((:alGenSources, _openal_lib), Cvoid, (Int32, Ptr{UInt32}), Int32(n), ids)
    return ids
end

function al_delete_sources(ids::Vector{UInt32})
    ccall((:alDeleteSources, _openal_lib), Cvoid, (Int32, Ptr{UInt32}), Int32(length(ids)), ids)
end

function al_sourcei(source::UInt32, param::Int32, value::Int32)
    ccall((:alSourcei, _openal_lib), Cvoid, (UInt32, Int32, Int32), source, param, value)
end

function al_sourcef(source::UInt32, param::Int32, value::Float32)
    ccall((:alSourcef, _openal_lib), Cvoid, (UInt32, Int32, Float32), source, param, value)
end

function al_source3f(source::UInt32, param::Int32, v1::Float32, v2::Float32, v3::Float32)
    ccall((:alSource3f, _openal_lib), Cvoid, (UInt32, Int32, Float32, Float32, Float32),
          source, param, v1, v2, v3)
end

function al_source_play(source::UInt32)
    ccall((:alSourcePlay, _openal_lib), Cvoid, (UInt32,), source)
end

function al_source_stop(source::UInt32)
    ccall((:alSourceStop, _openal_lib), Cvoid, (UInt32,), source)
end

function al_get_sourcei(source::UInt32, param::Int32)
    val = Ref{Int32}(0)
    ccall((:alGetSourcei, _openal_lib), Cvoid, (UInt32, Int32, Ptr{Int32}), source, param, val)
    return val[]
end

function al_listener3f(param::Int32, v1::Float32, v2::Float32, v3::Float32)
    ccall((:alListener3f, _openal_lib), Cvoid, (Int32, Float32, Float32, Float32), param, v1, v2, v3)
end

function al_listenerf(param::Int32, value::Float32)
    ccall((:alListenerf, _openal_lib), Cvoid, (Int32, Float32), param, value)
end

function al_listenerfv(param::Int32, values::Vector{Float32})
    ccall((:alListenerfv, _openal_lib), Cvoid, (Int32, Ptr{Float32}), param, values)
end

# ---- OpenAL state ----

mutable struct OpenALState
    device::Ptr{Nothing}
    context::Ptr{Nothing}
    buffers::Dict{String, UInt32}     # audio_path → AL buffer ID
    sources::Dict{EntityID, UInt32}   # entity → AL source ID
    initialized::Bool
end

const _AUDIO_STATE = Ref{OpenALState}(OpenALState(C_NULL, C_NULL, Dict(), Dict(), false))

function get_audio_state()
    return _AUDIO_STATE[]
end

"""
    init_audio!()

Initialize OpenAL device and context. Call once at startup.
"""
function init_audio!()
    state = get_audio_state()
    if state.initialized
        return
    end

    device = al_open_device(C_NULL)
    if device == C_NULL
        @warn "Failed to open OpenAL audio device"
        return
    end

    ctx = al_create_context(device, C_NULL)
    if ctx == C_NULL
        al_close_device(device)
        @warn "Failed to create OpenAL context"
        return
    end

    al_make_context_current(ctx)

    state.device = device
    state.context = ctx
    state.initialized = true
    @info "Audio initialized (OpenAL)"
    return nothing
end

"""
    shutdown_audio!()

Destroy all audio sources and buffers, close OpenAL device.
"""
function shutdown_audio!()
    state = get_audio_state()
    if !state.initialized
        return
    end

    # Delete all sources
    if !isempty(state.sources)
        source_ids = collect(values(state.sources))
        for sid in source_ids
            al_source_stop(sid)
        end
        al_delete_sources(source_ids)
        empty!(state.sources)
    end

    # Delete all buffers
    if !isempty(state.buffers)
        buffer_ids = collect(values(state.buffers))
        al_delete_buffers(buffer_ids)
        empty!(state.buffers)
    end

    al_make_context_current(C_NULL)
    al_destroy_context(state.context)
    al_close_device(state.device)

    state.device = C_NULL
    state.context = C_NULL
    state.initialized = false
    return nothing
end

"""
    reset_audio_state!()

Reset audio state (for testing). Does not touch OpenAL device.
"""
function reset_audio_state!()
    _AUDIO_STATE[] = OpenALState(C_NULL, C_NULL, Dict(), Dict(), false)
    return nothing
end

"""
    clear_audio_sources!()

Stop and delete all OpenAL sources bound to entities, leaving buffers and
the device/context intact. Safe to call across scene switches.
"""
function clear_audio_sources!()
    state = get_audio_state()
    if !state.initialized
        return nothing
    end

    if !isempty(state.sources)
        source_ids = collect(values(state.sources))
        for sid in source_ids
            al_source_stop(sid)
        end
        al_delete_sources(source_ids)
        empty!(state.sources)
    end
    return nothing
end

# ---- WAV loader ----

"""
    load_wav(path::String) -> (data::Vector{UInt8}, format::Int32, sample_rate::Int32)

Parse a WAV file and return raw PCM data, OpenAL format, and sample rate.
Supports 8-bit and 16-bit PCM, mono and stereo.
"""
function load_wav(path::String)
    data = read(path)
    length(data) < 44 && error("WAV file too small: $path")

    # RIFF header
    String(data[1:4]) == "RIFF" || error("Not a RIFF file: $path")
    String(data[9:12]) == "WAVE" || error("Not a WAVE file: $path")

    # Find "fmt " chunk
    fmt_offset = _find_wav_chunk(data, "fmt ")
    fmt_offset === nothing && error("Missing fmt chunk: $path")

    channels = reinterpret(UInt16, data[fmt_offset+2:fmt_offset+3])[1]
    sample_rate = reinterpret(UInt32, data[fmt_offset+4:fmt_offset+7])[1]
    bits_per_sample = reinterpret(UInt16, data[fmt_offset+14:fmt_offset+15])[1]

    # Find "data" chunk
    data_offset = _find_wav_chunk(data, "data")
    data_offset === nothing && error("Missing data chunk: $path")

    # data chunk size is at data_offset - 4 (in the chunk header)
    chunk_header_pos = data_offset - 4
    data_size = reinterpret(UInt32, data[chunk_header_pos:chunk_header_pos+3])[1]
    pcm_data = data[data_offset:data_offset + Int(data_size) - 1]

    # Determine AL format
    format = if channels == 1 && bits_per_sample == 8
        AL_FORMAT_MONO8
    elseif channels == 1 && bits_per_sample == 16
        AL_FORMAT_MONO16
    elseif channels == 2 && bits_per_sample == 8
        AL_FORMAT_STEREO8
    elseif channels == 2 && bits_per_sample == 16
        AL_FORMAT_STEREO16
    else
        error("Unsupported WAV format: $(channels)ch $(bits_per_sample)bit in $path")
    end

    return pcm_data, format, Int32(sample_rate)
end

function _find_wav_chunk(data::Vector{UInt8}, id::String)
    id_bytes = Vector{UInt8}(id)
    pos = 13  # Skip RIFF header (12 bytes), start searching chunks
    while pos + 7 <= length(data)
        if data[pos:pos+3] == id_bytes
            # Chunk data starts after 8-byte header (4 id + 4 size)
            return pos + 8
        end
        chunk_size = reinterpret(UInt32, data[pos+4:pos+7])[1]
        pos += 8 + Int(chunk_size)
        # WAV chunks are word-aligned
        if pos % 2 != 1
            pos += 1
        end
    end
    return nothing
end

"""
    get_or_load_buffer!(path::String) -> UInt32

Load a WAV file into an OpenAL buffer, or return cached buffer.
"""
function get_or_load_buffer!(path::String)
    state = get_audio_state()
    haskey(state.buffers, path) && return state.buffers[path]

    pcm_data, format, sample_rate = load_wav(path)
    buffer_id = al_gen_buffers(1)[1]
    al_buffer_data(buffer_id, format, pcm_data, Int32(length(pcm_data)), sample_rate)
    state.buffers[path] = buffer_id
    return buffer_id
end

"""
    get_or_create_source!(entity_id::EntityID) -> UInt32

Get or create an OpenAL source for the given entity.
"""
function get_or_create_source!(entity_id::EntityID)
    state = get_audio_state()
    haskey(state.sources, entity_id) && return state.sources[entity_id]

    source_id = al_gen_sources(1)[1]
    state.sources[entity_id] = source_id
    return source_id
end

"""
    remove_source!(entity_id::EntityID)

Remove and delete the OpenAL source for the given entity.
"""
function remove_source!(entity_id::EntityID)
    state = get_audio_state()
    if haskey(state.sources, entity_id)
        sid = state.sources[entity_id]
        al_source_stop(sid)
        al_delete_sources([sid])
        delete!(state.sources, entity_id)
    end
    return nothing
end
