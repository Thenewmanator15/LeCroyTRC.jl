"""
    LeCroyTRC

Read LeCroy oscilloscope waveform files (`.trc`, template `LECROY_2_3`): the binary
format the scopes write when a trace is saved to disk, and the reply to `WF? ALL`.

    w = readtrc("C1--capture--00000.trc")
    plot(times(w), volts(w))

[`readtrc`](@ref) reads a whole record, [`trcinfo`](@ref) only its descriptor. The
samples stay as the scope stored them (`Int8` or `Int16` codes); [`volts`](@ref) scales
them and [`times`](@ref) gives the horizontal axis. Sequence captures split with
[`segments`](@ref).

The layout follows LeCroy's own template (Remote Control Manual, Appendix II, "Waveform
Template"): every descriptor field, both byte orders, byte and word samples, the user
text, the TRIGTIME (sequence) and RIS_TIME arrays, the reserved blocks, and the second
data array of extrema, complex and peak-detect records. A file that declares something
it does not contain is refused with a [`LeCroyTRC.FormatError`](@ref), never misread.
"""
module LeCroyTRC

using Dates
using MappedArrays: mappedarray
import Mmap
import PrecompileTools

export readtrc, trcinfo, trcread, trcblocks, trcmap, TRCWaveform, TRCInfo, volts, volts!, times,
       segments, nsegments

"""
    LeCroyTRC.FormatError(msg)

The input is not a LeCroy waveform, or its descriptor promises data the input does not
hold (a truncated file, inconsistent block lengths, an unknown sample format).
"""
struct FormatError <: Exception
    msg::String
end
Base.showerror(io::IO, e::FormatError) = print(io, "LeCroyTRC.FormatError: ", e.msg)

const DESCRIPTOR_BYTES = 346   # the LECROY_2_3 WAVEDESC block
const SEARCH_BYTES = 64        # WAVEDESC must start this near the beginning

const RECORD_TYPES = (:single_sweep, :interleaved, :histogram, :graph, :filter_coefficient,
                      :complex, :extrema, :sequence_obsolete, :centered_RIS, :peak_detect)
const PROCESSING = (:no_processing, :fir_filter, :interpolated, :sparsed, :autoscaled,
                    :no_result, :rolling, :cumulative)
const COUPLINGS = (:DC_50_Ohms, :ground, :DC_1MOhm, :ground, :AC_1MOhm)
const STEPS_125 = (1, 2, 5, 10, 20, 50, 100, 200, 500)

"""
    TRCInfo

The descriptor of a LeCroy waveform, with the blocks that travel with it. Fields carry
the template's names in lower case, with their template types, except where decoding
makes them more useful:

- `comm_type` is `:byte` or `:word`, `comm_order` `:little` (LOFIRST) or `:big`;
- `wave_descriptor` ... `res_array3` are block lengths **in bytes**;
- `trigger_time` is a `DateTime` (to the millisecond; `nothing` if the scope stored an
  impossible date) and `trigger_seconds` the seconds field at full precision;
- `record_type`, `processing_done`, `vert_coupling`, `wave_source` are `Symbol`s named as
  in the template (`:enum_N` for a value the template does not list);
- `timebase` is in s/div and `fixed_vert_gain` in V/div (`nothing` for EXTERNAL or an
  unlisted value); `bandwidth_limit` is a `Bool`;
- `usertext` is the USERTEXT block, `trigger_times`/`trigger_offsets` the TRIGTIME
  array (sequence captures: seconds from the first trigger to each one, and from each
  trigger to its segment's first point), `ris_offsets` the RIS_TIME array.
"""
struct TRCInfo
    template_name::String
    comm_type::Symbol
    comm_order::Symbol
    wave_descriptor::Int32
    user_text::Int32
    res_desc1::Int32
    trigtime_array::Int32
    ris_time_array::Int32
    res_array1::Int32
    wave_array_1::Int32
    wave_array_2::Int32
    res_array2::Int32
    res_array3::Int32
    instrument_name::String
    instrument_number::Int32
    trace_label::String
    wave_array_count::Int32
    pnts_per_screen::Int32
    first_valid_pnt::Int32
    last_valid_pnt::Int32
    first_point::Int32
    sparsing_factor::Int32
    segment_index::Int32
    subarray_count::Int32
    sweeps_per_acq::Int32
    points_per_pair::Int16
    pair_offset::Int16
    vertical_gain::Float32
    vertical_offset::Float32
    max_value::Float32
    min_value::Float32
    nominal_bits::Int16
    nom_subarray_count::Int16
    horiz_interval::Float32
    horiz_offset::Float64
    pixel_offset::Float64
    vertunit::String
    horunit::String
    horiz_uncertainty::Float32
    trigger_time::Union{DateTime,Nothing}
    trigger_seconds::Float64
    acq_duration::Float32
    record_type::Symbol
    processing_done::Symbol
    ris_sweeps::Int16
    timebase::Union{Float64,Nothing}
    vert_coupling::Symbol
    probe_att::Float32
    fixed_vert_gain::Union{Float64,Nothing}
    bandwidth_limit::Bool
    vertical_vernier::Float32
    acq_vert_offset::Float32
    wave_source::Symbol
    usertext::String
    trigger_times::Vector{Float64}
    trigger_offsets::Vector{Float64}
    ris_offsets::Vector{Float64}
end

"""
    TRCWaveform{T}

A LeCroy waveform: its [`TRCInfo`](@ref) in `info`, and the samples as stored, `T` being
`Int8` (byte) or `Int16` (word). `data1` is DATA_ARRAY_1 (every segment, one after
another); `data2` is DATA_ARRAY_2, empty unless the record carries one (the floor of an
extrema record, the imaginary part of a complex one, the min/max pairs of peak detect).

They are `Vector{T}`s, or read-only arrays over the mapped file for
[`trcmap`](@ref); the second type parameter is their type.
"""
struct TRCWaveform{T<:Union{Int8,Int16},A<:AbstractVector{T}}
    info::TRCInfo
    data1::A
    data2::A
end

# ── reading ────────────────────────────────────────────────────────────────────

"""
    readtrc(file) -> TRCWaveform
    readtrc(io::IO) -> TRCWaveform

Read a LeCroy waveform from a file name or from any stream. A stream is read forward
only, from its current position to the end of the record, so records that follow one
another (a sequence of `WF? ALL` replies, say) are read by calling `readtrc` again.
Anything before `WAVEDESC` in the first 64 bytes (a `#9…` block header, a `C1:WF ALL,`
echo) is skipped.

`memory` is a byte budget for the samples: a record whose data arrays would take more is
refused with an `ArgumentError` before any of them is read. [`trcread`](@ref) and
[`trcblocks`](@ref) read such a record in parts.

Throws [`LeCroyTRC.FormatError`](@ref) for input that is not a LeCroy waveform or does
not hold what its descriptor declares.
"""
readtrc(file::AbstractString; memory::Integer = Sys.free_memory()) =
    _named(file, () -> open(io -> readtrc(io; memory), file))

function readtrc(io::IO; memory::Integer = Sys.free_memory())
    info = trcinfo(io)
    need = _need_data(io, info)
    need <= memory || throw(ArgumentError("the samples take $need bytes, more than memory = $memory; " *
                                          "read them in parts with trcread or trcblocks, or map them with trcmap"))
    T = _eltype(info)
    big = info.comm_order === :big
    data1 = _read_array(io, T, info.wave_array_1, big, "DATA_ARRAY_1")
    data2 = _read_array(io, T, info.wave_array_2, big, "DATA_ARRAY_2")
    _discard(io, Int(info.res_array2) + Int(info.res_array3), "RES_ARRAY2/RES_ARRAY3")
    TRCWaveform{T,Vector{T}}(info, data1, data2)
end

# The bytes of the data arrays, once the input is known to hold them: a record the
# input cannot hold is a FormatError, whatever the memory budget.
function _need_data(io, info)
    need = Int64(info.wave_array_1) + Int64(info.wave_array_2)
    _need(io, need, info.wave_array_2 > 0 ? "DATA_ARRAY_1 and DATA_ARRAY_2" : "DATA_ARRAY_1")
    need
end

"""
    trcmap(file) -> TRCWaveform
    trcmap(io::IOStream) -> TRCWaveform

[`readtrc`](@ref), with the samples mapped from the file rather than read: `data1` and
`data2` are read-only arrays over it, the operating system reads only the pages that are
touched, and a record of any size opens at once. A stream is left at the end of the
record, as `readtrc` leaves it; the arrays stay valid after the file is closed.

The arrays read the file as it is when they are indexed. While the waveform is alive, do
not let anything change the file: on Windows it cannot be deleted, truncated or
replaced; elsewhere a truncated file makes indexing past its new end crash the process.
For a file that may still be written to, use `readtrc`.
"""
trcmap(file::AbstractString) = _named(file, () -> open(trcmap, file))

function trcmap(io::IOStream)
    info = trcinfo(io)
    _need_data(io, info)
    _mapped(io, info, _eltype(info))
end

# a function barrier, so that each T infers on its own
function _mapped(io, info, ::Type{T}) where {T}
    big = info.comm_order === :big
    data1 = _map_array(io, T, info.wave_array_1, big)
    data2 = _map_array(io, T, info.wave_array_2, big)
    _discard(io, Int(info.res_array2) + Int(info.res_array3), "RES_ARRAY2/RES_ARRAY3")
    TRCWaveform{T,typeof(data1)}(info, data1, data2)
end

# The next `nbytes` of a file as read-only `T` codes in this machine's byte order, mapped,
# not read. Byte-wise, then reinterpreted: the data often start at an odd offset.
function _map_array(io::IOStream, ::Type{T}, nbytes, big::Bool) where {T}
    bytes = nbytes == 0 ? UInt8[] :
            Mmap.mmap(io, Vector{UInt8}, (Int(nbytes),), position(io); grow = false)::Vector{UInt8}
    skip(io, nbytes)
    mappedarray(_ByteOrder(_swap(big)), reinterpret(T, bytes))
end

# One function type for both byte orders, so a lazy waveform has one type per T.
struct _ByteOrder
    swap::Bool
end
(o::_ByteOrder)(x) = o.swap ? _bswap(x) : x

_eltype(info) = info.comm_type === :byte ? Int8 : Int16

"""
    trcread(file, r) -> Vector{Int8} or Vector{Int16}
    trcread(io::IO, r)

The codes `r` (1-based) of DATA_ARRAY_1, without reading the others: a window of a long
trace. For a sequence capture, `r` indexes every segment one after another, as `data1`
does. Scale them with [`volts(info, codes)`](@ref volts) and place them with
[`times(info, r)`](@ref times), `info` being [`trcinfo(file)`](@ref trcinfo).

A file or buffer skips to the window; any other stream reads its way there. A stream is
left after the window, inside the record.
"""
trcread(file::AbstractString, r::AbstractUnitRange{<:Integer}) =
    _named(file, () -> open(io -> trcread(io, r), file))

function trcread(io::IO, r::AbstractUnitRange{<:Integer})
    info = trcinfo(io)
    T = _eltype(info)
    n = Int(info.wave_array_count)
    isempty(r) || (1 <= first(r) && last(r) <= n) || throw(BoundsError(1:n, r))
    _discard(io, (first(r) - 1) * sizeof(T), "DATA_ARRAY_1")
    _read_array(io, T, length(r) * sizeof(T), info.comm_order === :big, "DATA_ARRAY_1")
end

"""
    trcblocks(f, file; blocksize = 2^20, memory = nothing) -> number of codes
    trcblocks(f, io::IO; ...)

Read DATA_ARRAY_1 in blocks of `blocksize` codes and call `f(codes, offset)` on each,
`offset` being the 0-based index of `codes[1]`: a pass over a long trace in bounded
memory. `codes` is one buffer, reused from block to block: `copy` it to keep a block.
The last block is shorter, never padded. `memory` is a byte budget for that buffer,
which then holds at most `memory ÷ sizeof(code)` codes. Scale a block with
[`volts!(out, info, codes)`](@ref volts!).

`f` may resize `codes` (the next block is read at its own length all the same), and may
read the same file through a path of its own. It must not read from or move the stream
`trcblocks` reads: on a file or buffer, that is an `ArgumentError` rather than misread
blocks.
"""
trcblocks(f, file::AbstractString; kwargs...) =
    _named(file, () -> open(io -> trcblocks(f, io; kwargs...), file))

function trcblocks(f, io::IO; blocksize::Integer = 2^20, memory::Union{Nothing,Integer} = nothing)
    info = trcinfo(io)
    T = _eltype(info)
    if memory !== nothing
        memory >= sizeof(T) || throw(ArgumentError("memory = $memory bytes holds no $T code"))
        blocksize = min(blocksize, memory ÷ sizeof(T))
    end
    blocksize >= 1 || throw(ArgumentError("blocksize = $blocksize"))
    n = Int(info.wave_array_count)
    _need(io, n * sizeof(T), "DATA_ARRAY_1")
    swap = _swap(info.comm_order === :big)
    buf = Vector{T}(undef, min(blocksize, n))
    seekable = _left(io) !== nothing
    done = 0
    while done < n
        k = min(blocksize, n - done)
        length(buf) == k || resize!(buf, k)        # the last block, or one f resized
        try
            read!(io, buf)
        catch e
            e isa EOFError || rethrow()
            throw(FormatError("input ends inside DATA_ARRAY_1, which the descriptor declares as $(n * sizeof(T)) bytes"))
        end
        swap && map!(_bswap, buf, buf)
        at = seekable ? position(io) : 0
        f(buf, done)
        seekable && position(io) != at &&
            throw(ArgumentError("f read from or moved the stream trcblocks is reading; " *
                                "to read the file inside f, open it again"))
        done += k
    end
    n
end

"""
    trcinfo(file) -> TRCInfo
    trcinfo(io::IO) -> TRCInfo

The descriptor of a LeCroy waveform, with its user text and time arrays, without reading
the samples. On a stream, leaves the position at the first sample.
"""
trcinfo(file::AbstractString) = _named(file, () -> open(trcinfo, file))

function trcinfo(io::IO)
    head = read(io, SEARCH_BYTES)
    isempty(head) && throw(FormatError("empty input: no WAVEDESC"))
    o = _find(head, codeunits("WAVEDESC"))
    o === nothing &&
        throw(FormatError("no WAVEDESC in the first $SEARCH_BYTES bytes: not a LeCroy waveform"))
    d = Vector{UInt8}(undef, DESCRIPTOR_BYTES)
    have = min(length(head) - o, DESCRIPTOR_BYTES)
    copyto!(d, 1, head, o + 1, have)
    if have < DESCRIPTOR_BYTES
        rest = read(io, DESCRIPTOR_BYTES - have)
        length(rest) == DESCRIPTOR_BYTES - have ||
            throw(FormatError("input ends inside WAVEDESC ($(have + length(rest)) of $DESCRIPTOR_BYTES bytes)"))
        copyto!(d, have + 1, rest, 1, length(rest))
    end

    # COMM_ORDER: 1 = LOFIRST, 0 = HIFIRST; as bytes, 01 00 or 00 00 whichever order wrote them
    big = if d[35] == 0x01 && d[36] == 0x00
        false
    elseif d[35] == 0x00 && d[36] == 0x00
        true
    else
        throw(FormatError("COMM_ORDER bytes $(repr(d[35])) $(repr(d[36])) are neither LOFIRST nor HIFIRST"))
    end
    ld(::Type{T}, off) where {T} = _load(T, d, off, big)

    ct = ld(Int16, 32)
    ct in (0, 1) || throw(FormatError("COMM_TYPE = $ct; the template knows 0 (byte) and 1 (word)"))
    esz = ct == 0 ? 1 : 2

    wdlen, utlen, rd1 = ld(Int32, 36), ld(Int32, 40), ld(Int32, 44)
    ttlen, rislen, ra1 = ld(Int32, 48), ld(Int32, 52), ld(Int32, 56)
    a1, a2, ra2, ra3 = ld(Int32, 60), ld(Int32, 64), ld(Int32, 68), ld(Int32, 72)
    count = ld(Int32, 116)
    wdlen >= DESCRIPTOR_BYTES ||
        throw(FormatError("WAVE_DESCRIPTOR = $wdlen bytes, shorter than the $DESCRIPTOR_BYTES of LECROY_2_3"))
    for (name, len) in (("USER_TEXT", utlen), ("RES_DESC1", rd1), ("TRIGTIME_ARRAY", ttlen),
                        ("RIS_TIME_ARRAY", rislen), ("RES_ARRAY1", ra1), ("WAVE_ARRAY_1", a1),
                        ("WAVE_ARRAY_2", a2), ("RES_ARRAY2", ra2), ("RES_ARRAY3", ra3))
        len >= 0 || throw(FormatError("$name = $len bytes"))
    end
    ttlen % 16 == 0 ||
        throw(FormatError("TRIGTIME_ARRAY = $ttlen bytes is not a whole number of 16-byte entries"))
    rislen % 8 == 0 ||
        throw(FormatError("RIS_TIME_ARRAY = $rislen bytes is not a whole number of 8-byte entries"))
    a1 % esz == 0 ||
        throw(FormatError("WAVE_ARRAY_1 = $a1 bytes is not a whole number of $esz-byte samples"))
    a2 % esz == 0 ||
        throw(FormatError("WAVE_ARRAY_2 = $a2 bytes is not a whole number of $esz-byte samples"))
    a1 == Int(count) * esz ||
        throw(FormatError("WAVE_ARRAY_COUNT = $count samples but WAVE_ARRAY_1 = $a1 bytes of $esz-byte samples"))

    # TRIGGER_TIME (offset 296): double seconds, then bytes minutes, hours, days, months, word year
    secs = ld(Float64, 296)
    tstamp = _datetime(ld(Int16, 308), d[308], d[307], d[306], d[305], secs)
    tb, fvg, src = ld(Int16, 324), ld(Int16, 332), ld(Int16, 344)

    # the blocks between the descriptor and the samples, in the template's order
    _discard(io, wdlen - DESCRIPTOR_BYTES, "the descriptor")
    ut = _read_bytes(io, utlen, "USERTEXT")
    _discard(io, rd1, "RES_DESC1")
    tt = _read_array(io, Float64, ttlen, big, "TRIGTIME")
    ris = _read_array(io, Float64, rislen, big, "RIS_TIME")
    _discard(io, ra1, "RES_ARRAY1")

    TRCInfo(_string(d, 16, 16), ct == 0 ? :byte : :word, big ? :big : :little,
            wdlen, utlen, rd1, ttlen, rislen, ra1, a1, a2, ra2, ra3,
            _string(d, 76, 16), ld(Int32, 92), _string(d, 96, 16),
            count, ld(Int32, 120), ld(Int32, 124), ld(Int32, 128), ld(Int32, 132),
            ld(Int32, 136), ld(Int32, 140), ld(Int32, 144), ld(Int32, 148),
            ld(Int16, 152), ld(Int16, 154),
            ld(Float32, 156), ld(Float32, 160), ld(Float32, 164), ld(Float32, 168),
            ld(Int16, 172), ld(Int16, 174), ld(Float32, 176), ld(Float64, 180), ld(Float64, 188),
            _string(d, 196, 48), _string(d, 244, 48), ld(Float32, 292),
            tstamp, secs, ld(Float32, 312),
            _enum(RECORD_TYPES, ld(Int16, 316)), _enum(PROCESSING, ld(Int16, 318)),
            ld(Int16, 322),
            0 <= tb <= 47 ? _step125(tb, -12) : nothing,
            _enum(COUPLINGS, ld(Int16, 326)), ld(Float32, 328),
            0 <= fvg <= 27 ? _step125(fvg, -6) : nothing,
            ld(Int16, 334) != 0, ld(Float32, 336), ld(Float32, 340),
            0 <= src <= 3 ? Symbol("channel_", src + 1) : src == 9 ? :unknown : Symbol("enum_", src),
            String(_trim_nul(ut)), tt[1:2:end], tt[2:2:end], ris)
end

# ── views of a waveform ─────────────────────────────────────────────────────────

"""
    volts(w::TRCWaveform, array = 1) -> Vector{Float64}
    volts(T, w::TRCWaveform, array = 1) -> Vector{T}
    volts([T,] info::TRCInfo, codes)

The samples of DATA_ARRAY_1 (or `array = 2`: DATA_ARRAY_2) scaled as the template says,
`VERTICAL_GAIN * code - VERTICAL_OFFSET`. The unit is `w.info.vertunit`: volts for a
channel, whatever the scope says for a math or FFT trace. With `info`, scales `codes`
read in parts by [`trcread`](@ref) or [`trcblocks`](@ref).

`T = Float32` holds any 16-bit code exactly and halves the memory. Most of the time of a
long trace goes into the fresh output array itself; [`volts!`](@ref) reuses one.
"""
volts(w::TRCWaveform, array::Integer = 1) = volts(Float64, w, array)
volts(::Type{T}, w::TRCWaveform, array::Integer = 1) where {T<:AbstractFloat} =
    volts(T, w.info, _array(w, array))
volts(info::TRCInfo, codes::AbstractVector{<:Integer}) = volts(Float64, info, codes)
volts(::Type{T}, info::TRCInfo, codes::AbstractVector{<:Integer}) where {T<:AbstractFloat} =
    volts!(Vector{T}(undef, length(codes)), info, codes)

"""
    volts!(out, w::TRCWaveform, array = 1) -> out
    volts!(out, info::TRCInfo, codes) -> out

[`volts`](@ref) into `out`, which must have the array's length: for many captures of
one length, a buffer allocated once.
"""
volts!(out::AbstractVector{<:AbstractFloat}, w::TRCWaveform, array::Integer = 1) =
    volts!(out, w.info, _array(w, array))

function volts!(out::AbstractVector{T}, info::TRCInfo, codes::AbstractVector{<:Integer}) where {T<:AbstractFloat}
    length(out) == length(codes) ||
        throw(DimensionMismatch("out has $(length(out)) elements, the codes $(length(codes))"))
    g, o = T(info.vertical_gain), T(info.vertical_offset)
    @inbounds @simd for i in eachindex(out, codes)
        out[i] = g * codes[i] - o
    end
    out
end

_array(w::TRCWaveform, array::Integer) =
    array == 1 ? w.data1 : array == 2 ? w.data2 : throw(ArgumentError("array must be 1 or 2, not $array"))

"""
    nsegments(w::TRCWaveform) -> Int
    nsegments(info::TRCInfo) -> Int

The number of segments: 1 for a single sweep, SUBARRAY_COUNT for a sequence capture.
Throws [`LeCroyTRC.FormatError`](@ref) if the TRIGTIME array and SUBARRAY_COUNT disagree.
"""
function nsegments(i::TRCInfo)
    n = length(i.trigger_times)
    c = max(Int(i.subarray_count), 1)
    n == 0 || n == c ||
        throw(FormatError("TRIGTIME holds $n segments but SUBARRAY_COUNT is $(i.subarray_count)"))
    c
end
nsegments(w::TRCWaveform) = nsegments(w.info)

"""
    segments(w::TRCWaveform, v = w.data1) -> Matrix

`v` (the codes, or anything of the same length such as `volts(w)`) with one column per
segment. A reshape: no copy.
"""
function segments(w::TRCWaveform, v::AbstractVector = w.data1)
    n = nsegments(w)
    length(v) % n == 0 ||
        throw(FormatError("$(length(v)) points cannot be split into $n equal segments"))
    reshape(v, :, n)
end

"""
    times(w::TRCWaveform) -> AbstractRange
    times(w::TRCWaveform, k) -> AbstractRange
    times(info::TRCInfo, r) -> AbstractRange

The horizontal axis of a single sweep: `HORIZ_OFFSET + i * HORIZ_INTERVAL`, in
`w.info.horunit` (seconds for a time-domain trace). For segment `k` of a sequence
capture, the time of each point from that segment's own trigger (add
`w.info.trigger_times[k]` for the time from the first trigger). With `info`, the times of
points `r` of a single sweep, for codes read by [`trcread`](@ref): `times(w)[r]`.

Throws `ArgumentError` for a sequence without `k`, a sequence without a TRIGTIME array,
and records transferred with a FIRST_POINT or SPARSING_FACTOR that makes their points a
subset of the acquisition.
"""
function times(w::TRCWaveform)
    n = nsegments(w)
    n == 1 || throw(ArgumentError("a sequence of $n segments: use times(w, k) for segment k"))
    _axis(w.info, w.info.horiz_offset, length(w.data1))
end

function times(info::TRCInfo, r::AbstractUnitRange{<:Integer})
    n = nsegments(info)
    n == 1 || throw(ArgumentError("a sequence of $n segments: times(info, r) places a single sweep"))
    _axis(info, info.horiz_offset, Int(info.wave_array_count))[r]
end

function times(w::TRCWaveform, k::Integer)
    n = nsegments(w)
    1 <= k <= n || throw(BoundsError(1:n, k))
    n == 1 && return times(w)
    isempty(w.info.trigger_offsets) &&
        throw(ArgumentError("$n segments but no TRIGTIME array: their offsets from the trigger are unknown"))
    _axis(w.info, w.info.trigger_offsets[k], size(segments(w), 1))
end

function _axis(i::TRCInfo, start, n)
    i.first_point == 0 && i.sparsing_factor <= 1 ||
        throw(ArgumentError("FIRST_POINT = $(i.first_point), SPARSING_FACTOR = $(i.sparsing_factor): " *
                            "the points are a subset of the acquisition, and their times are not placed"))
    range(start; step = Float64(i.horiz_interval), length = n)
end

# ── display ─────────────────────────────────────────────────────────────────────

Base.show(io::IO, w::TRCWaveform{T}) where {T} =
    print(io, "TRCWaveform{$T}(", length(w.data1), " points, ", w.info.wave_source, ")")
Base.show(io::IO, i::TRCInfo) =
    print(io, "TRCInfo(", i.instrument_name, ", ", i.wave_source, ", ", i.wave_array_count, " points)")

function Base.show(io::IO, ::MIME"text/plain", w::TRCWaveform{T}) where {T}
    print(io, "TRCWaveform{$T}: ")
    _summary(io, w.info)
    isempty(w.data2) || print(io, "\n  second array  ", length(w.data2), " points")
end
Base.show(io::IO, ::MIME"text/plain", i::TRCInfo) = (print(io, "TRCInfo: "); _summary(io, i))

function _summary(io, i::TRCInfo)
    nseg = length(i.trigger_times)
    print(io, i.wave_array_count, " points", nseg > 1 ? " in $nseg segments" : "",
          ", ", i.comm_type, " samples, ", i.record_type)
    print(io, "\n  instrument    ", i.instrument_name, " #", i.instrument_number, ", ", i.wave_source,
          isempty(i.trace_label) ? "" : " ($(i.trace_label))")
    print(io, "\n  trigger       ", something(i.trigger_time, "(no valid date)"))
    print(io, "\n  horizontal    ", i.horiz_interval, " ", i.horunit, " per point, first at ",
          i.horiz_offset, " ", i.horunit)
    print(io, "\n  vertical      ", i.vertical_gain, " * code ", i.vertical_offset > 0 ? "- " : "+ ",
          abs(i.vertical_offset), " ", i.vertunit)
    isempty(i.usertext) || print(io, "\n  user text     ", repr(i.usertext))
end

# ── helpers ─────────────────────────────────────────────────────────────────────

# run f, naming the file in any FormatError it throws
function _named(file, f)
    try
        f()
    catch e
        e isa FormatError ? throw(FormatError("$file: $(e.msg)")) : rethrow()
    end
end

function _find(hay::Vector{UInt8}, needle)
    n = length(needle)
    for o in 0:(length(hay) - n)
        all(k -> hay[o + k] == needle[k], 1:n) && return o
    end
    nothing
end

_unsigned(::Type{T}) where {T} =
    sizeof(T) == 1 ? UInt8 : sizeof(T) == 2 ? UInt16 : sizeof(T) == 4 ? UInt32 : UInt64

"The `T` at byte offset `off` of `d`, in the given byte order."
function _load(::Type{T}, d::Vector{UInt8}, off::Integer, big::Bool) where {T}
    U = _unsigned(T)
    u = zero(U)
    for k in (big ? (1:sizeof(T)) : (sizeof(T):-1:1))
        u = (u << 8) | U(d[off + k])
    end
    reinterpret(T, u)
end

"A NUL-terminated string field of `n` bytes at `off`, without padding."
function _string(d, off, n)
    stop = off
    while stop < off + n && d[stop + 1] != 0x00
        stop += 1
    end
    String(strip(String(d[(off + 1):stop])))
end

_trim_nul(b::Vector{UInt8}) = b[1:something(findlast(!=(0x00), b), 0)]

_enum(table, i) = 0 <= i < length(table) ? table[i + 1] : Symbol("enum_", i)

"Value of a 1-2-5 enum (nine steps per three decades) whose index 0 is 10^base."
function _step125(i, base)
    m = STEPS_125[i % 9 + 1]
    e = 3 * (i ÷ 9) + base
    e >= 0 ? m * 10.0^e : m / 10.0^(-e)
end

function _datetime(year, month, day, hour, minute, secs)
    (isfinite(secs) && 0 <= secs < 60) || return nothing
    ms = floor(Int, secs * 1000)
    try
        DateTime(Int(year), Int(month), Int(day), Int(hour), Int(minute), ms ÷ 1000, ms % 1000)
    catch e
        e isa ArgumentError ? nothing : rethrow()
    end
end

# The bytes left in `io`, where it can tell (a file, a buffer); `nothing` for a pipe or socket.
_left(io::IOBuffer) = bytesavailable(io)
_left(io::IOStream) = (s = stat(io); isfile(s) ? filesize(s) - position(io) : nothing)
_left(io::IO) = nothing

# Refuse a block the input cannot hold before allocating for it: a corrupt length
# would otherwise cost up to 2 GB of memory before the read comes up short.
function _need(io, n, what)
    left = _left(io)
    left === nothing || left >= n ||
        throw(FormatError("input ends inside $what ($left of $n bytes)"))
    nothing
end

function _read_bytes(io, n, what)
    _need(io, n, what)
    b = read(io, n)
    length(b) == n || throw(FormatError("input ends inside $what ($(length(b)) of $n bytes)"))
    b
end

# Pass over `n` bytes: a seek where the input says how much it holds, else reads of at
# most 64 KiB, so a long skip never allocates its length.
function _discard(io, n, what)
    n > 0 || return nothing
    _need(io, n, what)
    _left(io) === nothing || return (skip(io, n); nothing)
    left = n
    while left > 0
        k = length(read(io, min(left, 1 << 16)))
        k == 0 && throw(FormatError("input ends inside $what ($(n - left) of $n bytes)"))
        left -= k
    end
    nothing
end

# the file's byte order differs from this machine's
_swap(big::Bool) = big == (Base.ENDIAN_BOM == 0x04030201)

function _read_array(io, ::Type{T}, nbytes, big::Bool, what) where {T}
    nbytes == 0 && return T[]
    _need(io, nbytes, what)
    v = Vector{T}(undef, nbytes ÷ sizeof(T))
    try
        read!(io, v)
    catch e
        e isa EOFError || rethrow()
        throw(FormatError("input ends inside $what, which the descriptor declares as $nbytes bytes"))
    end
    _swap(big) && map!(_bswap, v, v)
    v
end

_bswap(x::T) where {T} = reinterpret(T, bswap(reinterpret(_unsigned(T), x)))

# ── precompilation ──────────────────────────────────────────────────────────────

# What precompilation runs, so that the first read in a session is not spent compiling:
# the example capture, read from its path and from streams, scaled and timed.
PrecompileTools.@setup_workload begin
    example = joinpath(@__DIR__, "..", "test", "example_files",
                       "C2--detector-newamp-comparetoraw--splitcorr--00000.trc")
    PrecompileTools.@compile_workload begin
        w = readtrc(example)
        volts(w); volts(Float32, w); times(w); segments(w)
        info = trcinfo(example)
        open(readtrc, example)
        readtrc(IOBuffer(read(example)))
        m = trcmap(example)
        volts(m); times(m)
        codes = trcread(example, 1:100)
        volts(info, codes); times(info, 1:100)
        out = zeros(Float32, 64)
        trcblocks((c, _) -> volts!(view(out, 1:length(c)), info, c), example; blocksize = 64)
    end
end

end # module
