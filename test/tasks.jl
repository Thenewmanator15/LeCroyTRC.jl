# Calling the readers more than once: on one path from several tasks, and on one shared
# IOStream. With one thread the tasks run one after another; CI runs the tests with
# JULIA_NUM_THREADS=2, so that the shared stream is read from two threads at once.
# Uses trc_bytes from writer.jl.

@testset "one path, many tasks at once" begin
    codes = Int16.(rand(MersenneTwister(6), Int16, 100_000))
    p = tempname() * ".trc"; write(p, trc_bytes(codes))
    @test all(fetch.([Threads.@spawn(readtrc(p).data1 == codes) for _ in 1:8]))
    @test all(fetch.([Threads.@spawn(trcread(p, 99_001:100_000) == codes[99_001:end]) for _ in 1:8]))
    @test all(fetch.([Threads.@spawn(trcblocks((c, _) -> nothing, p; blocksize = 999) == 100_000) for _ in 1:8]))
    @test all(fetch.([Threads.@spawn(maps_as_read(p, Int16)) for _ in 1:8]))
    GC.gc(); rm(p)
end

@testset "one IOStream shared by tasks: each reads whole records" begin
    a, b = Int16.(1:30_000), Int16.(-30_000:-1)
    p = tempname() * ".trc"
    write(p, repeat(vcat(trc_bytes(a), trc_bytes(b; prefix = "#9")), 20))
    results = open(p) do io
        got = Channel{Any}(Inf)
        @sync for _ in 1:4
            Threads.@spawn while true
                w = try
                    readtrc(io)
                catch e
                    put!(got, eof(io) ? :end : e); break
                end
                put!(got, w.data1 == a || w.data1 == b)
            end
        end
        close(got); collect(got)
    end
    @test count(==(true), results) == 40                       # every record, each one whole
    @test all(r -> r === true || r === :end, results)
    GC.gc(); rm(p)
end
