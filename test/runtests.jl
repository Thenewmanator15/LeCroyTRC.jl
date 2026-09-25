using LeCroyTRC, Test, Dates, Random

include("writer.jl")

# Read `bytes` both ways -- from a file and from memory -- and check they agree.
function read_both(bytes)
    path = tempname() * ".trc"
    write(path, bytes)
    w = readtrc(path)
    m = readtrc(IOBuffer(bytes))
    @test m.data1 == w.data1 && m.data2 == w.data2 && m.info.usertext == w.info.usertext
    rm(path)
    w
end

@testset "LeCroyTRC" begin

@testset "one sweep, word samples: every descriptor field" begin
    codes = Int16.(round.(3000 .* sin.((1:4096) ./ 7)))
    w = read_both(trc_bytes(codes; usertext = ""))
    @test w isa TRCWaveform{Int16}
    @test w.data1 == codes && isempty(w.data2)
    i = w.info
    @test i.template_name == "LECROY_2_3"
    @test i.comm_type === :word && i.comm_order === :little
    @test i.wave_descriptor == 346 && i.user_text == 0 && i.res_desc1 == 0
    @test i.trigtime_array == 0 && i.ris_time_array == 0 && i.res_array1 == 0
    @test i.wave_array_1 == 8192 && i.wave_array_2 == 0 && i.res_array2 == 0 && i.res_array3 == 0
    @test i.instrument_name == "LECROYWP740Zi" && i.instrument_number == 1234
    @test i.trace_label == "C3"
    @test i.wave_array_count == 4096 && i.pnts_per_screen == 4000
    @test i.first_valid_pnt == 0 && i.last_valid_pnt == 4095
    @test i.first_point == 0 && i.sparsing_factor == 1 && i.segment_index == 0
    @test i.subarray_count == 1 && i.sweeps_per_acq == 1
    @test i.points_per_pair == 0 && i.pair_offset == 0
    @test i.vertical_gain === 2.7743299f-5 && i.vertical_offset === -0.56f0
    @test i.max_value === 28_580f0 && i.min_value === -28_836f0
    @test i.nominal_bits == 9 && i.nom_subarray_count == 1
    @test i.horiz_interval === 2.5f-11 && i.horiz_offset === -4.0e-6 && i.pixel_offset === -4.0e-6
    @test i.vertunit == "V" && i.horunit == "S"
    @test i.horiz_uncertainty === 1f-12
    @test i.trigger_time == DateTime(2021, 10, 15, 15, 49, 26, 356)
    @test i.trigger_seconds === 26.356776                     # full precision, not ms
    @test i.acq_duration === 0f0
    @test i.record_type === :single_sweep && i.processing_done === :no_processing
    @test i.ris_sweeps == 1
    @test i.timebase == 1e-3                                  # _27 = 1 ms/div
    @test i.vert_coupling === :DC_50_Ohms
    @test i.probe_att === 1f0
    @test i.fixed_vert_gain == 0.2                            # _16 = 200 mV/div
    @test i.bandwidth_limit === true
    @test i.vertical_vernier === 1f0 && i.acq_vert_offset === 0.56f0
    @test i.wave_source === :channel_3
    @test i.usertext == ""
    @test isempty(i.trigger_times) && isempty(i.trigger_offsets) && isempty(i.ris_offsets)
end

@testset "volts and times" begin
    codes = Int16[-32768, -1, 0, 1, 32767]
    w = readtrc(IOBuffer(trc_bytes(codes)))
    @test volts(w) == Float64(2.7743299f-5) .* codes .- Float64(-0.56f0)
    @test volts(w) isa Vector{Float64}
    t = times(w)
    @test length(t) == 5
    @test t[1] == -4.0e-6
    @test t[5] ≈ -4.0e-6 + 4 * Float64(2.5f-11)
    @test all(diff(collect(t)) .≈ Float64(2.5f-11))
    # in place, into a buffer reused across files; and in a narrower type
    out = fill(NaN, 5)
    @test volts!(out, w) === out && out == volts(w)
    @test volts(Float32, w) isa Vector{Float32}
    @test volts(Float32, w) == Float32(2.7743299f-5) .* codes .- Float32(-0.56f0)
    @test volts!(zeros(Float32, 5), w) == volts(Float32, w)
    @test_throws DimensionMismatch volts!(zeros(4), w)
    w2 = readtrc(IOBuffer(trc_bytes(codes; data2 = reverse(codes))))
    @test volts!(zeros(5), w2, 2) == volts(w2, 2) && volts(Float32, w2, 2) ≈ volts(w2, 2)
    @test (@allocated volts!(out, w)) == 0
end

@testset "byte samples keep their sign and type" begin
    codes = Int8.(vcat(-128:127, 127:-1:-128))
    w = read_both(trc_bytes(codes))
    @test w isa TRCWaveform{Int8}
    @test w.data1 == codes
    @test w.info.comm_type === :byte && w.info.nominal_bits == 8
    @test volts(w) == Float64(w.info.vertical_gain) .* codes .- Float64(w.info.vertical_offset)
end

@testset "HIFIRST (big-endian) reads the same as LOFIRST" begin
    for T in (Int8, Int16)
        codes = T.(rand(MersenneTwister(1), T, 1000))
        seg = reshape(copy(codes), 250, 4)
        for d in (codes, seg)
            lo = readtrc(IOBuffer(trc_bytes(d; usertext = "abc", data2 = reverse(vec(d)))))
            hi = readtrc(IOBuffer(trc_bytes(d; order = :big, usertext = "abc", data2 = reverse(vec(d)))))
            @test hi.info.comm_order === :big && lo.info.comm_order === :little
            @test hi.data1 == lo.data1 == vec(d) && hi.data2 == lo.data2
            for f in fieldnames(TRCInfo)
                f === :comm_order && continue
                @test isequal(getfield(hi.info, f), getfield(lo.info, f))
            end
        end
    end
end

@testset "what may precede WAVEDESC, and what may follow the data" begin
    codes = Int16.(1:300)
    for prefix in ("", "#9", "DESC,#9000000000", "C1:WF ALL,#9000000000")
        @test readtrc(IOBuffer(trc_bytes(codes; prefix))).data1 == codes
    end
    @test readtrc(IOBuffer(trc_bytes(codes; trailer = UInt8['\n']))).data1 == codes
    # WAVEDESC must start in the first 64 bytes; further in, the file is refused
    @test_throws LeCroyTRC.FormatError readtrc(IOBuffer(trc_bytes(codes; prefix = " "^70)))
end

@testset "user text" begin
    w = read_both(trc_bytes(Int16.(1:10); usertext = "probe on C3\nline two"))
    @test w.info.usertext == "probe on C3\nline two"
    @test w.info.user_text == 20
    @test w.data1 == 1:10
    # NUL padding at the end of the block is not part of the text
    w = readtrc(IOBuffer(trc_bytes(Int16.(1:10); usertext = "abc\0\0\0")))
    @test w.info.usertext == "abc" && w.data1 == 1:10
end

@testset "sequence mode: segments, trigger times, per-segment time axes" begin
    seg = Int16.(reshape(1:6000, 2000, 3))
    trig = [(0.0, -1e-6), (1.5e-3, -1e-6), (3.25e-3, -1.5e-6)]
    w = read_both(trc_bytes(seg; trigtime = trig, record_type = 0, horiz_offset = -1e-6))
    @test w.info.subarray_count == 3 && w.info.wave_array_count == 6000
    @test w.data1 == vec(seg)
    @test w.info.trigger_times == [0.0, 1.5e-3, 3.25e-3]
    @test w.info.trigger_offsets == [-1e-6, -1e-6, -1.5e-6]
    @test nsegments(w) == 3
    @test segments(w) == seg
    @test segments(w) isa AbstractMatrix{Int16}
    @test segments(w, volts(w)) == reshape(volts(w), 2000, 3)
    @test times(w, 3)[1] == -1.5e-6                    # from that segment's own trigger
    @test length(times(w, 2)) == 2000
    @test_throws ArgumentError times(w)                # which segment? say so
    @test_throws BoundsError times(w, 4)
    @test times(readtrc(IOBuffer(trc_bytes(Int16.(1:10)))), 1) == times(readtrc(IOBuffer(trc_bytes(Int16.(1:10)))))
end

@testset "RIS: the RIS_TIME array sits between TRIGTIME and the data" begin
    # lecroyutils (Python) and this package's ancestor in HtTofSims start DATA_ARRAY_1
    # right after TRIGTIME, so they read a RIS capture 8*RIS_SWEEPS bytes early.
    codes = Int16.(100:199)
    ris = [1.1e-11, 2.2e-11, -3.3e-11, 4.4e-11]
    w = read_both(trc_bytes(codes; ris, record_type = 8, ris_sweeps = 4))
    @test w.info.ris_offsets == ris
    @test w.info.record_type === :centered_RIS && w.info.ris_sweeps == 4
    @test w.data1 == codes
end

@testset "reserved blocks and a longer descriptor are skipped" begin
    codes = Int16.(-50:49)
    w = read_both(trc_bytes(codes; res_desc1 = 12, res_array1 = 24, res_array2 = 8,
                            res_array3 = 4, wdlen = 380, usertext = "x",
                            trigtime = [(0.0, -2e-6)]))
    @test w.data1 == codes && w.info.usertext == "x"
    @test w.info.trigger_offsets == [-2e-6]
    # the reserved arrays after the data are consumed too: the stream stops exactly at the
    # end of the record (a following record would read anyway -- WAVEDESC may start up to
    # 56 bytes in -- so the position is what shows it)
    first = trc_bytes(codes; res_array2 = 8, res_array3 = 4)
    io = IOBuffer(vcat(first, trc_bytes(Int16.(1:3))))
    @test readtrc(io).data1 == codes
    @test position(io) == length(first)
    @test readtrc(io).data1 == 1:3
    @test eof(io)
end

@testset "second data array: extrema, complex, peak detect" begin
    roof = Int16.(10:10:1000); floor = Int16.(-1000:10:-10)
    w = read_both(trc_bytes(roof; data2 = floor, record_type = 6))
    @test w.info.record_type === :extrema
    @test w.data1 == roof && w.data2 == floor
    @test volts(w, 2) == Float64(w.info.vertical_gain) .* floor .- Float64(w.info.vertical_offset)
    @test_throws ArgumentError volts(w, 3)
    re = Int8.(1:64); im = Int8.(-64:-1)
    w = read_both(trc_bytes(re; data2 = im, record_type = 5, horunit = "Hz", vertunit = "V"))
    @test w.info.record_type === :complex && w.data2 == im && w.info.horunit == "Hz"
    # peak detect: DATA_ARRAY_2 holds min/max pairs, fewer of them than data points
    w = read_both(trc_bytes(Int16.(1:400); data2 = Int16.(1:50), record_type = 9,
                            points_per_pair = 16, pair_offset = 3))
    @test w.info.record_type === :peak_detect
    @test length(w.data1) == 400 && w.data2 == 1:50
    @test w.info.points_per_pair == 16 && w.info.pair_offset == 3
end

@testset "enumerations: every tabled value, and unknown ones kept" begin
    function info(; kw...)
        trcinfo(IOBuffer(trc_bytes(Int16[0]; kw...)))
    end
    rec = (:single_sweep, :interleaved, :histogram, :graph, :filter_coefficient, :complex,
           :extrema, :sequence_obsolete, :centered_RIS, :peak_detect)
    for (k, s) in enumerate(rec)
        @test info(record_type = k - 1).record_type === s
    end
    proc = (:no_processing, :fir_filter, :interpolated, :sparsed, :autoscaled, :no_result,
            :rolling, :cumulative)
    for (k, s) in enumerate(proc)
        @test info(processing_done = k - 1).processing_done === s
    end
    coup = (:DC_50_Ohms, :ground, :DC_1MOhm, :ground, :AC_1MOhm)
    for (k, s) in enumerate(coup)
        @test info(vert_coupling = k - 1).vert_coupling === s
    end
    for (k, s) in enumerate((:channel_1, :channel_2, :channel_3, :channel_4))
        @test info(wave_source = k - 1).wave_source === s
    end
    @test info(wave_source = 9).wave_source === :unknown
    @test info(wave_source = 5).wave_source === :enum_5
    @test info(record_type = 42).record_type === :enum_42
    @test info(bandwidth_limit = 0).bandwidth_limit === false
    # TIMEBASE: _0 = 1 ps/div ... _47 = 5 ks/div in 1-2-5 steps; _100 = EXTERNAL
    tb = [m * 10.0^e for e in -12:3:3 for m in (1, 2, 5, 10, 20, 50, 100, 200, 500)][1:48]
    for k in 0:47
        @test info(timebase = k).timebase ≈ tb[k + 1]
    end
    @test info(timebase = 100).timebase === nothing
    @test info(timebase = 48).timebase === nothing
    # FIXED_VERT_GAIN: _0 = 1 uV/div ... _27 = 1 kV/div
    vg = [m * 10.0^e for e in -6:3:3 for m in (1, 2, 5, 10, 20, 50, 100, 200, 500)][1:28]
    for k in 0:27
        @test info(fixed_vert_gain = k).fixed_vert_gain ≈ vg[k + 1]
    end
    @test info(fixed_vert_gain = 28).fixed_vert_gain === nothing
end

@testset "trigger time: sub-millisecond part kept, nonsense dates not invented" begin
    i = trcinfo(IOBuffer(trc_bytes(Int16[0]; trigger_time = (59.9999994, 59, 23, 31, 12, 1999))))
    @test i.trigger_time == DateTime(1999, 12, 31, 23, 59, 59, 999)
    @test i.trigger_seconds === 59.9999994
    i = trcinfo(IOBuffer(trc_bytes(Int16[0]; trigger_time = (0.0, 0, 0, 0, 0, 0))))
    @test i.trigger_time === nothing
end

@testset "malformed files are refused with the reason, never misread" begin
    codes = Int16.(1:100)
    good = trc_bytes(codes)
    err(bytes) = try readtrc(IOBuffer(bytes)); nothing catch e; e end
    e = err(good[1:end-10])
    @test e isa LeCroyTRC.FormatError && occursin("DATA_ARRAY_1", e.msg)
    e = err(good[1:200])
    @test e isa LeCroyTRC.FormatError && occursin("WAVEDESC", e.msg)
    e = err(UInt8[])
    @test e isa LeCroyTRC.FormatError
    e = err(Vector{UInt8}(codeunits("this is not a trace file at all, just some text" ^ 10)))
    @test e isa LeCroyTRC.FormatError && occursin("WAVEDESC", e.msg)
    e = err(trc_bytes(codes; comm_type = 2))
    @test e isa LeCroyTRC.FormatError && occursin("COMM_TYPE", e.msg)
    e = err(trc_bytes(codes; comm_order = 7))
    @test e isa LeCroyTRC.FormatError && occursin("COMM_ORDER", e.msg)
    e = err(trc_bytes(codes; wave_array_count = 99))
    @test e isa LeCroyTRC.FormatError && occursin("WAVE_ARRAY_COUNT", e.msg)
    e = err(trc_bytes(codes; wave_array_1 = 201))
    @test e isa LeCroyTRC.FormatError
    e = err(trc_bytes(codes; wave_descriptor = 300))
    @test e isa LeCroyTRC.FormatError && occursin("WAVE_DESCRIPTOR", e.msg)
    e = err(trc_bytes(codes; user_text = -5))
    @test e isa LeCroyTRC.FormatError
    e = err(trc_bytes(codes; trigtime_array = 20))
    @test e isa LeCroyTRC.FormatError && occursin("TRIGTIME", e.msg)
    e = err(trc_bytes(codes; ris_time_array = 12))
    @test e isa LeCroyTRC.FormatError && occursin("RIS_TIME", e.msg)
    e = err(trc_bytes(codes; wave_array_2 = 3))
    @test e isa LeCroyTRC.FormatError && occursin("WAVE_ARRAY_2", e.msg)
    # a path gets the file name in the message
    p = tempname() * ".trc"; write(p, good[1:end-10])
    e = try readtrc(p); nothing catch e; e end
    @test e isa LeCroyTRC.FormatError && occursin(basename(p), e.msg)
    rm(p)
end

@testset "time axes refuse what they cannot place" begin
    w = readtrc(IOBuffer(trc_bytes(Int16.(1:10); sparsing_factor = 4)))
    @test_throws ArgumentError times(w)
    w = readtrc(IOBuffer(trc_bytes(Int16.(1:10); first_point = 100)))
    @test_throws ArgumentError times(w)
    w = readtrc(IOBuffer(trc_bytes(Int16.(1:10); sparsing_factor = 0)))   # 0 = every point
    @test length(times(w)) == 10
    tt3 = [(0.0, 0.0), (1e-3, 0.0), (2e-3, 0.0)]
    w = readtrc(IOBuffer(trc_bytes(Int16.(1:10); trigtime = tt3, subarray_count = 3)))
    @test nsegments(w) == 3
    @test_throws LeCroyTRC.FormatError segments(w)          # 10 points cannot be 3 segments
    w = readtrc(IOBuffer(trc_bytes(Int16.(reshape(1:10, 5, 2)); subarray_count = 3)))
    @test_throws LeCroyTRC.FormatError nsegments(w)         # 2 trigger times, count says 3
    # segments without a TRIGTIME array: the count alone says how to split them
    w = readtrc(IOBuffer(trc_bytes(Int16.(1:12); subarray_count = 4)))
    @test nsegments(w) == 4 && size(segments(w)) == (3, 4)
    @test_throws ArgumentError times(w, 2)                  # no per-segment offsets to place it
end

@testset "trcinfo reads the header, not the samples" begin
    bytes = trc_bytes(Int16.(rand(MersenneTwister(2), Int16, 2_000_000)); usertext = "big")
    path = tempname() * ".trc"; write(path, bytes)
    i = trcinfo(path)
    @test i.wave_array_count == 2_000_000 && i.usertext == "big"
    trcinfo(path)
    @test (@allocated trcinfo(path)) < 200_000              # the data are 4 MB
    io = IOBuffer(bytes)
    trcinfo(io)
    @test position(io) == 346 + 3                            # left at DATA_ARRAY_1
    w = readtrc(path)
    @test (@allocated readtrc(path)) < 4_000_000 + 200_000   # the data once, not twice
    rm(path)
end

@testset "reads from any IO, one record after another" begin
    a = trc_bytes(Int16.(1:5); prefix = "#9"); b = trc_bytes(Int8.(1:3); order = :big)
    io = IOBuffer(vcat(a, b))
    @test readtrc(io).data1 == 1:5
    @test readtrc(io).data1 == Int8.(1:3)
    @test eof(io)
    # a stream that cannot seek
    p = Pipe(); Base.link_pipe!(p)
    write(p, a); close(p.in)
    @test readtrc(p).data1 == 1:5
end

@testset "any shape the template allows round-trips (property)" begin
    rng = MersenneTwister(20260925)
    for trial in 1:300
        T = rand(rng, (Int8, Int16))
        nseg = rand(rng, (1, 1, 2, 5))
        per = rand(rng, 1:200)
        d1 = rand(rng, T, nseg == 1 ? (per,) : (per, nseg))
        d2 = rand(rng, Bool) ? rand(rng, T, rand(rng, 0:per)) : nothing
        ris = rand(rng, Bool) ? randn(rng, rand(rng, 1:6)) .* 1e-11 : Float64[]
        ut = String(rand(rng, 'a':'z', rand(rng, 0:160)))
        kw = (order = rand(rng, (:little, :big)), data2 = d2, usertext = ut, ris,
              res_desc1 = rand(rng, (0, 0, 8)), res_array1 = rand(rng, (0, 0, 16)),
              res_array2 = rand(rng, (0, 4)), res_array3 = rand(rng, (0, 4)),
              wdlen = rand(rng, (346, 346, 400)), prefix = rand(rng, ("", "#9")),
              vertical_gain = rand(rng, Float32), vertical_offset = randn(rng, Float32),
              horiz_interval = rand(rng, Float32) * 1f-9, horiz_offset = randn(rng) * 1e-6)
        w = readtrc(IOBuffer(trc_bytes(d1; kw...)))
        ok = w.data1 == vec(d1) && w.data2 == (d2 === nothing ? T[] : d2) &&
             w.info.usertext == ut && w.info.ris_offsets == ris && nsegments(w) == nseg &&
             w.info.vertical_gain === kw.vertical_gain && w.info.horiz_offset === kw.horiz_offset
        @test ok
        ok || (@info "failed shape" trial T nseg per kw; break)
    end
end

@testset "show" begin
    w = readtrc(IOBuffer(trc_bytes(Int16.(1:4096))))
    s = sprint(show, MIME"text/plain"(), w)
    @test occursin("4096", s) && occursin("LECROYWP740Zi", s) && occursin("channel_3", s)
    @test occursin("* code + 0.56 V", s)                    # VERTICAL_OFFSET -0.56: added
    @test occursin("TRCWaveform", sprint(show, w))
end

# Real captures, when a folder of them is named: every file must read, and agree with
# what the descriptor promises.
let dir = get(ENV, "LECROYTRC_REAL", "")
    if !isempty(dir) && isdir(dir)
        @testset "real captures in $dir" begin
            fs = String[]
            for (root, _, files) in walkdir(dir), f in files
                endswith(lowercase(f), ".trc") && push!(fs, joinpath(root, f))
            end
            for f in fs
                w = readtrc(f)
                @test length(w.data1) == w.info.wave_array_count
                @test w.info.last_valid_pnt < length(w.data1) ÷ nsegments(w)
            end
            @info "read $(length(fs)) real captures"
        end
    end
end

end # LeCroyTRC
