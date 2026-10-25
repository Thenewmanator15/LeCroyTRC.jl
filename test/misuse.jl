# The API used the wrong way: what a careless caller gets. Each case was found by trying
# to break the package; it must give a clear error naming the caller's mistake (not a
# FormatError blaming the file), or the right result. Uses trc_bytes from writer.jl.

const EXAMPLE = joinpath(@__DIR__, "example_files", "C2--detector-newamp-comparetoraw--splitcorr--00000.trc")

@testset "a waveform built by hand, and equality" begin
    w = readtrc(EXAMPLE)
    @test TRCWaveform{Int16}(w.info, w.data1, w.data2) == w      # as before the second parameter
    @test TRCWaveform(w.info, w.data1, w.data2) == w
    # two reads of one file are equal, hash alike, and are one in a Set
    @test readtrc(EXAMPLE) == readtrc(EXAMPLE) && isequal(readtrc(EXAMPLE), readtrc(EXAMPLE))
    @test hash(readtrc(EXAMPLE)) == hash(readtrc(EXAMPLE))
    @test trcinfo(EXAMPLE) == trcinfo(EXAMPLE) && length(Set([trcinfo(EXAMPLE), trcinfo(EXAMPLE)])) == 1
    @test length(unique([readtrc(EXAMPLE), readtrc(EXAMPLE)])) == 1
    @test trcmap(EXAMPLE) == readtrc(EXAMPLE) && hash(trcmap(EXAMPLE)) == hash(readtrc(EXAMPLE))
    @test readtrc(EXAMPLE) != readtrc(IOBuffer(trc_bytes(Int16.(1:10))))
end

@testset "segments of something the wrong length" begin
    w = readtrc(EXAMPLE)
    @test_throws DimensionMismatch segments(w, zeros(7))
    s = readtrc(IOBuffer(trc_bytes(Int16.(reshape(1:40, 10, 4)); data2 = Int16.(1:80))))
    @test_throws DimensionMismatch segments(s, zeros(20))
    @test size(segments(s, volts(s))) == (10, 4)
    @test size(segments(s, s.data2)) == (20, 4)                     # data2's length is fine too
end

@testset "a stream that is closed or not open for reading" begin
    p = tempname() * ".trc"; write(p, trc_bytes(Int16.(1:10)))
    closed = open(p); close(closed)
    appending = open(p, "a")
    for io in (closed, appending), call in (readtrc, trcinfo, trcmap, io -> trcread(io, 1:2),
                                            io -> trcblocks((c, _) -> nothing, io))
        e = try call(io); nothing catch e; e end
        @test e isa ArgumentError && occursin("not open for reading", e.msg)
    end
    close(appending)
    @test_throws LeCroyTRC.FormatError readtrc(IOBuffer(UInt8[]))   # an empty input is still that
    GC.gc(); rm(p)
end

@testset "an empty range reads nothing, wherever it is" begin
    bytes = trc_bytes(Int16.(1:10))
    @test trcread(IOBuffer(bytes), 110:109) == Int16[] && trcread(IOBuffer(bytes), 110:109) isa Vector{Int16}
    @test trcread(IOBuffer(bytes), 0:-1) == Int16[]
    io = IOBuffer(bytes)
    trcread(io, 110:109)
    @test read(io, Int16) == 1                                      # left at the first sample
end

@testset "trcblocks' f reading the stream trcblocks reads" begin
    p = tempname() * ".trc"; write(p, trc_bytes(Int16.(1:1000)))
    for inner in (io -> readtrc(io), io -> trcblocks((c, _) -> nothing, io), io -> trcinfo(io))
        e = open(io -> try trcblocks((c, _) -> inner(io), io; blocksize = 100) catch e; e end, p)
        @test e isa ArgumentError && occursin("open it again", e.msg)
    end
    rm(p)
end

@testset "WAVEDESC may start anywhere in the first 64 bytes" begin
    codes = Int16.(1:5)
    @test readtrc(IOBuffer(trc_bytes(codes; prefix = " "^63))).data1 == codes
    @test_throws LeCroyTRC.FormatError readtrc(IOBuffer(trc_bytes(codes; prefix = " "^64)))
    # back to back, a record whose WAVEDESC starts late still leaves the next one whole
    io = IOBuffer(vcat(trc_bytes(codes; prefix = " "^60), trc_bytes(codes)))
    @test readtrc(io).data1 == codes && readtrc(io).data1 == codes && eof(io)
end
