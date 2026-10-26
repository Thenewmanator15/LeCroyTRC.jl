# Reading a long trace in parts: trcread, trcblocks, readtrc's memory budget, and
# scaling and placing the parts. Uses trc_bytes from writer.jl.

@testset "trcread: a window of the codes" begin
    for T in (Int8, Int16), order in (:little, :big)
        codes = T.(rand(MersenneTwister(3), T, 1000))
        # blocks before the data that the skip must pass over
        bytes = trc_bytes(codes; order, usertext = "abc", res_desc1 = 8, ris = [1e-11],
                          res_array1 = 16, data2 = reverse(codes), res_array2 = 4)
        p = tempname() * ".trc"; write(p, bytes)
        for r in (1:1000, 1:1, 1000:1000, 401:600, 5:4)
            @test trcread(p, r) == codes[r]
            @test trcread(IOBuffer(bytes), r) == codes[r]
            @test trcread(p, r) isa Vector{T}
        end
        pipe = Pipe(); Base.link_pipe!(pipe)                   # a stream that cannot seek
        write(pipe, bytes); close(pipe.in)
        @test trcread(pipe, 901:1000) == codes[901:1000]
        @test_throws BoundsError trcread(p, 0:10)
        @test_throws BoundsError trcread(p, 990:1001)
        rm(p)
    end
    # a sequence: r indexes every segment, one after another
    seg = Int16.(reshape(1:12, 4, 3))
    @test trcread(IOBuffer(trc_bytes(seg)), 3:6) == 3:6
    # the stream is left after the window
    io = IOBuffer(trc_bytes(Int16.(1:10)))
    trcread(io, 2:3)
    @test read(io, Int16) == 4
    # a file that does not hold the data: refused before allocating for it
    bytes = trc_bytes(Int16.(1:10))
    @test_throws LeCroyTRC.FormatError trcread(IOBuffer(bytes[1:(end - 4)]), 1:10)
    @test trcread(IOBuffer(bytes[1:(end - 4)]), 1:8) == 1:8
end

@testset "trcblocks: the codes in blocks, one buffer" begin
    codes = Int16.(rand(MersenneTwister(4), Int16, 1000))
    for order in (:little, :big)
        bytes = trc_bytes(codes; order, usertext = "x", data2 = codes)
        for bs in (1, 7, 100, 1000, 5000)
            got, offsets, bufs = Int16[], Int[], Set{UInt}()
            n = trcblocks(IOBuffer(bytes); blocksize = bs) do c, off
                append!(got, c); push!(offsets, off); push!(bufs, objectid(c))
            end
            @test n == 1000 && got == codes
            @test offsets == 0:bs:999
            @test length(bufs) == 1                            # reused, never reallocated
        end
    end
    p = tempname() * ".trc"; write(p, trc_bytes(codes))
    lens = Int[]
    @test trcblocks((c, _) -> push!(lens, length(c)), p; blocksize = 300) == 1000
    @test lens == [300, 300, 300, 100]                         # the last one short, not padded
    empty!(lens)
    trcblocks((c, _) -> push!(lens, length(c)), p; blocksize = 300, memory = 200)
    @test lens == fill(100, 10)                                # 200 bytes hold 100 Int16 codes
    @test_throws ArgumentError trcblocks((c, _) -> nothing, p; memory = 1)
    @test_throws ArgumentError trcblocks((c, _) -> nothing, p; blocksize = 0)
    pipe = Pipe(); Base.link_pipe!(pipe)
    write(pipe, read(p)); close(pipe.in)
    s = Ref(0)
    trcblocks((c, _) -> (s[] += sum(Int, c)), pipe; blocksize = 64)
    @test s[] == sum(Int, codes)
    rm(p)
    # what f may do with the buffer, and what it may not do with the stream
    bytes = trc_bytes(codes)
    got = Int16[]
    @test trcblocks((c, _) -> (append!(got, c); empty!(c)), IOBuffer(bytes); blocksize = 300) == 1000
    @test got == codes                                         # emptied: the next block is whole
    empty!(got)
    trcblocks((c, _) -> (append!(got, c); append!(c, zeros(Int16, 7))), IOBuffer(bytes); blocksize = 300)
    @test got == codes                                         # grown: the next block is not shifted
    kept = Vector{Int16}[]
    trcblocks((c, _) -> push!(kept, c), IOBuffer(bytes); blocksize = 500)
    @test kept[1] === kept[2] && kept[1] == codes[501:1000]     # one buffer: copy to keep a block
    p = tempname() * ".trc"; write(p, bytes)
    @test trcblocks((c, _) -> trcread(p, 1:10), p; blocksize = 300) == 1000   # the file, opened again
    for io in (IOBuffer(bytes), open(p))
        e = try trcblocks((c, _) -> read(io, 4), io; blocksize = 300) catch e; e end
        @test e isa ArgumentError && occursin("open it again", e.msg)
        close(io)
    end
    rm(p)
    @test trcblocks((c, _) -> error("no block"), IOBuffer(trc_bytes(Int16[]))) == 0
    @test_throws LeCroyTRC.FormatError trcblocks((c, _) -> nothing, IOBuffer(trc_bytes(codes)[1:(end - 2)]))
end

@testset "readtrc's memory budget" begin
    bytes = trc_bytes(Int16.(1:100); data2 = Int16.(1:50))      # 300 bytes of samples
    @test readtrc(IOBuffer(bytes); memory = 300).data1 == 1:100
    e = try readtrc(IOBuffer(bytes); memory = 299) catch e; e end
    @test e isa ArgumentError && occursin("300 bytes", e.msg) && occursin("trcblocks", e.msg)
    p = tempname() * ".trc"; write(p, bytes)
    @test_throws ArgumentError readtrc(p; memory = 10)
    rm(p)
    # a record the input cannot hold is refused as such, not for the budget
    short = trc_bytes(Int16.(1:100); wave_array_1 = 2_000_000_000, wave_array_count = 1_000_000_000)
    @test_throws LeCroyTRC.FormatError readtrc(IOBuffer(short); memory = 10)
end

@testset "scaling and placing parts" begin
    codes = Int16.(rand(MersenneTwister(5), Int16, 1000))
    bytes = trc_bytes(codes)
    w = readtrc(IOBuffer(bytes)); info = w.info
    r = 201:300
    part = trcread(IOBuffer(bytes), r)
    @test volts(info, part) == volts(w)[r]
    @test volts(Float32, info, part) == volts(Float32, w)[r]
    out = zeros(100)
    @test volts!(out, info, part) === out && out == volts(w)[r]
    @test (@allocated volts!(out, info, part)) == 0
    @test_throws DimensionMismatch volts!(zeros(99), info, part)
    @test times(info, r) == times(w)[r]
    @test times(info, 1:1000) == times(w)
    @test_throws BoundsError times(info, 990:1001)
    # a sequence has no single axis; times(w, k) places each segment
    s = trcinfo(IOBuffer(trc_bytes(Int16.(reshape(1:12, 4, 3)))))
    @test_throws ArgumentError times(s, 1:4)
    # a whole-trace pass in blocks matches volts(w)
    v = zeros(1000); buf = zeros(256)
    trcblocks(IOBuffer(bytes); blocksize = 256) do c, off
        v[(off + 1):(off + length(c))] .= volts!(view(buf, 1:length(c)), info, c)
    end
    @test v == volts(w)
end
