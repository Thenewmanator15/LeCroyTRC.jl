# trcmap: the samples mapped from the file, not read. Uses trc_bytes from writer.jl.
# On Windows a mapped file cannot be rewritten or deleted until its mapping is collected,
# so mappings are checked inside functions that return plain values, and files are
# removed after a GC.gc().

same(a::TRCWaveform, b::TRCWaveform) = a.data1 == b.data1 && a.data2 == b.data2 &&
    all(f -> isequal(getfield(a.info, f), getfield(b.info, f)), fieldnames(TRCInfo))
maps_as_read(p, T) = (m = trcmap(p); same(m, readtrc(p)) && m isa TRCWaveform{T})

@testset "trcmap reads what readtrc reads, for any shape" begin
    rng = MersenneTwister(20261024)
    ps = String[]
    for trial in 1:100
        T = rand(rng, (Int8, Int16))
        nseg = rand(rng, (1, 1, 3))
        d1 = rand(rng, T, nseg == 1 ? (rand(rng, 0:300),) : (rand(rng, 1:100), nseg))
        kw = (order = rand(rng, (:little, :big)), prefix = rand(rng, ("", "#9", "C1:WF ALL,")),
              data2 = rand(rng, Bool) ? rand(rng, T, rand(rng, 1:50)) : nothing,
              usertext = String(rand(rng, 'a':'z', rand(rng, 0:9))),   # odd lengths: odd offsets
              res_array1 = rand(rng, (0, 3)), res_array2 = rand(rng, (0, 4)))
        p = push!(ps, tempname() * ".trc")[end]
        write(p, trc_bytes(d1; kw...))
        ok = maps_as_read(p, T)
        @test ok
        ok || (@info "failed shape" trial T nseg kw; break)
    end
    GC.gc(); foreach(rm, ps)
end

@testset "trcmap: the example capture, scaled, timed, read-only" begin
    p = joinpath(@__DIR__, "example_files", "C2--detector-newamp-comparetoraw--splitcorr--00000.trc")
    m, w = trcmap(p), readtrc(p)
    @test same(m, w) && m isa TRCWaveform{Int16}
    @test volts(m) == volts(w) && volts(Float32, m) == volts(Float32, w) && times(m) == times(w)
    @test segments(m) == segments(w)
    @test_throws Exception (m.data1[1] = 0)
    @test occursin("4002 points", sprint(show, MIME"text/plain"(), m))
end

# two records back to back, mapped from one stream; checked after the file is closed
function two_mapped(p)
    x, y, at, ended = open(p) do io
        x = trcmap(io); at = position(io)
        y = trcmap(io)
        x, y, at, eof(io)
    end
    (x.data1 == 1:100, y.data1 == Int8.(1:7), at, ended)
end

@testset "trcmap on a stream" begin
    a, b = trc_bytes(Int16.(1:100); prefix = "#9"), trc_bytes(Int8.(1:7); order = :big)
    p = tempname() * ".trc"; write(p, vcat(a, b))
    @test two_mapped(p) == (true, true, length(a), true)     # each left at its record's end
    @test_throws MethodError trcmap(IOBuffer(a))              # a file only
    # a file that does not hold its record is refused before anything is mapped
    q = tempname() * ".trc"; write(q, a[1:(end - 2)])
    @test_throws LeCroyTRC.FormatError trcmap(q)
    GC.gc(); rm(p); rm(q)
end
