# A LECROY_2_3 writer for the tests, built straight from the template (LeCroy WM-RCM-E
# Rev D, Appendix II) and sharing no code with the reader, so a misreading of the
# template in one cannot hide behind the same misreading in the other.
#
# Block order, from the template: WAVEDESC, USERTEXT, RES_DESC1, TRIGTIME, RIS_TIME,
# RES_ARRAY1, DATA_ARRAY_1, DATA_ARRAY_2, RES_ARRAY2, RES_ARRAY3. Reserved blocks are
# filled with 0xA5 so that a reader which forgets to skip one reads garbage, not zeros.

using Dates

# (offset, type) of every WAVEDESC field, as printed in the template
const TEMPLATE = (
    descriptor_name = (0, :string16), template_name = (16, :string16),
    comm_type = (32, Int16), comm_order = (34, Int16),
    wave_descriptor = (36, Int32), user_text = (40, Int32), res_desc1 = (44, Int32),
    trigtime_array = (48, Int32), ris_time_array = (52, Int32), res_array1 = (56, Int32),
    wave_array_1 = (60, Int32), wave_array_2 = (64, Int32), res_array2 = (68, Int32),
    res_array3 = (72, Int32),
    instrument_name = (76, :string16), instrument_number = (92, Int32),
    trace_label = (96, :string16), reserved1 = (112, Int16), reserved2 = (114, Int16),
    wave_array_count = (116, Int32), pnts_per_screen = (120, Int32),
    first_valid_pnt = (124, Int32), last_valid_pnt = (128, Int32), first_point = (132, Int32),
    sparsing_factor = (136, Int32), segment_index = (140, Int32), subarray_count = (144, Int32),
    sweeps_per_acq = (148, Int32), points_per_pair = (152, Int16), pair_offset = (154, Int16),
    vertical_gain = (156, Float32), vertical_offset = (160, Float32),
    max_value = (164, Float32), min_value = (168, Float32), nominal_bits = (172, Int16),
    nom_subarray_count = (174, Int16), horiz_interval = (176, Float32),
    horiz_offset = (180, Float64), pixel_offset = (188, Float64),
    vertunit = (196, :string48), horunit = (244, :string48),
    horiz_uncertainty = (292, Float32), trigger_time = (296, :time_stamp),
    acq_duration = (312, Float32), record_type = (316, Int16), processing_done = (318, Int16),
    reserved5 = (320, Int16), ris_sweeps = (322, Int16), timebase = (324, Int16),
    vert_coupling = (326, Int16), probe_att = (328, Float32), fixed_vert_gain = (332, Int16),
    bandwidth_limit = (334, Int16), vertical_vernier = (336, Float32),
    acq_vert_offset = (340, Float32), wave_source = (344, Int16),
)

# Field values of a real WavePro 740Zi capture (C3, 40 GS/s, 1 ms/div, 50 ohm), serial
# number replaced.
const DEFAULTS = Dict{Symbol,Any}(
    :descriptor_name => "WAVEDESC", :template_name => "LECROY_2_3",
    :instrument_name => "LECROYWP740Zi", :instrument_number => 1234, :trace_label => "",
    :pnts_per_screen => 4000, :first_point => 0, :sparsing_factor => 1, :segment_index => 0,
    :sweeps_per_acq => 1, :points_per_pair => 0, :pair_offset => 0,
    :vertical_gain => 2.7743299f-5, :vertical_offset => -0.56f0,
    :max_value => 28_580f0, :min_value => -28_836f0, :nominal_bits => 8,
    :horiz_interval => 2.5f-11, :horiz_offset => -4.0e-6, :pixel_offset => -4.0e-6,
    :vertunit => "V", :horunit => "S", :horiz_uncertainty => 1f-12,
    :trigger_time => (26.356776, 49, 15, 15, 10, 2021),        # s, min, h, day, month, year
    :acq_duration => 0f0, :record_type => 0, :processing_done => 0, :ris_sweeps => 1,
    :timebase => 27, :vert_coupling => 0, :probe_att => 1f0, :fixed_vert_gain => 16,
    :bandwidth_limit => 1, :vertical_vernier => 1f0, :acq_vert_offset => 0.56f0,
    :wave_source => 2,
)

"""
    trc_bytes(data1; kwargs...) -> Vector{UInt8}

The bytes of a `.trc` file. `data1` is a vector (one sweep) or a matrix with one column
per segment (sequence mode). Its element type picks COMM_TYPE: `Int8` -> byte, `Int16`
-> word. Keywords:

- `order = :little` (LOFIRST) or `:big` (HIFIRST) -- every multi-byte value follows it;
- `data2`: a second array (extrema floor, complex imaginary part, peak-detect pairs);
- `usertext`, `trigtime` (vector of `(time, offset)` per segment; made up if omitted),
  `ris` (vector of RIS offsets), `res_desc1`, `res_array1`, `res_array2`, `res_array3`
  (lengths of reserved blocks, filled with 0xA5), `wdlen` (descriptor length, >= 346);
- `prefix`: bytes written before WAVEDESC (`"#9"` makes a SCPI block header);
- `trailer`: bytes written after the last block;
- any other keyword overrides the WAVEDESC field of that name.
"""
function trc_bytes(data1::AbstractArray{T}; order = :little, data2 = nothing, usertext = "",
                   trigtime = nothing, ris = Float64[], res_desc1 = 0, res_array1 = 0,
                   res_array2 = 0, res_array3 = 0, wdlen = 346, prefix = "", trailer = UInt8[],
                   fields...) where {T<:Union{Int8,Int16}}
    nseg = ndims(data1) == 2 ? size(data1, 2) : 1
    esz = sizeof(T)
    tt = nseg > 1 ? (trigtime === nothing ? [(1e-3 * (k - 1), -1e-6) for k in 1:nseg] : trigtime) :
                    (trigtime === nothing ? Tuple{Float64,Float64}[] : trigtime)
    d2 = data2 === nothing ? T[] : T.(vec(data2))
    v = merge(DEFAULTS, Dict{Symbol,Any}(
        :comm_type => T === Int8 ? 0 : 1, :comm_order => order === :big ? 0 : 1,
        :wave_descriptor => wdlen, :user_text => ncodeunits(usertext), :res_desc1 => res_desc1,
        :trigtime_array => 16 * length(tt), :ris_time_array => 8 * length(ris),
        :res_array1 => res_array1, :wave_array_1 => esz * length(data1),
        :wave_array_2 => esz * length(d2), :res_array2 => res_array2, :res_array3 => res_array3,
        :wave_array_count => length(data1), :first_valid_pnt => 0,
        :last_valid_pnt => size(data1, 1) - 1, :subarray_count => nseg,
        :nom_subarray_count => nseg, :nominal_bits => T === Int8 ? 8 : 9,
        :trace_label => "C3"),
        Dict{Symbol,Any}(fields))
    swap(x) = order === :big ? hton(x) : htol(x)

    desc = zeros(UInt8, wdlen)
    place!(off, bytes) = (desc[(off + 1):(off + length(bytes))] .= bytes)
    for (name, (off, typ)) in pairs(TEMPLATE)
        haskey(v, name) || continue
        x = v[name]
        if typ === :string16 || typ === :string48
            s = codeunits(x)
            length(s) < (typ === :string16 ? 16 : 48) || error("$name too long")
            place!(off, s)
        elseif typ === :time_stamp
            sec, mi, hr, dy, mo, yr = x
            place!(off, reinterpret(UInt8, [swap(Float64(sec))]))
            place!(off + 8, UInt8[mi, hr, dy, mo])
            place!(off + 12, reinterpret(UInt8, [swap(Int16(yr))]))
        else
            place!(off, reinterpret(UInt8, [swap(typ(x))]))
        end
    end

    io = IOBuffer()
    if prefix == "#9"
        total = wdlen + ncodeunits(usertext) + res_desc1 + 16 * length(tt) + 8 * length(ris) +
                res_array1 + esz * (length(data1) + length(d2)) + res_array2 + res_array3
        write(io, "#9", lpad(string(total), 9, '0'))
    else
        write(io, prefix)
    end
    write(io, desc)
    write(io, usertext)
    write(io, fill(0xa5, res_desc1))
    for (t, o) in tt
        write(io, swap(Float64(t)), swap(Float64(o)))
    end
    for r in ris
        write(io, swap(Float64(r)))
    end
    write(io, fill(0xa5, res_array1))
    write(io, swap.(vec(data1)))
    write(io, swap.(d2))
    write(io, fill(0xa5, res_array2 + res_array3))
    write(io, trailer)
    take!(io)
end

"Write `trc_bytes(data1; kwargs...)` to `path` and return `path`."
write_trc(path, data1; kwargs...) = (write(path, trc_bytes(data1; kwargs...)); path)
