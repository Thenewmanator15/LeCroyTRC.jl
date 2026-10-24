# Long records: about 100 MB in every run, and one at the template's largest data array
# (WAVE_ARRAY_1 near 2^31 bytes, the file past 2 GB) when LECROYTRC_STRESS=1.
# Uses trc_bytes from writer.jl for the header; the codes follow it in chunks, from a
# formula, so no copy of them is ever held whole and any window can be checked.

code(i) = reinterpret(Int16, UInt16((Int64(i) * 7919) & 0xffff))

"Write a record of `n` word codes `code(1:n)` to `path`; keywords go to `trc_bytes`."
function write_long(path, n; order = :little, kw...)
    swap = order === :big ? hton : htol
    open(path, "w") do io
        write(io, trc_bytes(Int16[]; order, wave_array_1 = 2n, wave_array_count = n,
                            last_valid_pnt = n - 1, kw...))
        buf = Vector{Int16}(undef, 1 << 22)
        for start in 1:length(buf):n
            k = min(length(buf), n - start + 1)
            for j in 1:k
                buf[j] = swap(code(start + j - 1))
            end
            write(io, view(buf, 1:k))
        end
    end
    path
end

# the least of three @allocated readings, as @allocated can count other threads' work
least_alloc(f) = minimum(_ -> (@allocated f()), 1:3)

function check_long(p, n; whole = true)
    i = trcinfo(p)
    @test i.wave_array_count == n
    # a window at the far end, skipped to rather than read through
    r = (n - 9_999):n
    @test trcread(p, r) == code.(r)
    @test least_alloc(() -> trcread(p, r)) < 2 * length(r) + 100_000
    @test volts(i, trcread(p, r)) == Float64(i.vertical_gain) .* code.(r) .- Float64(i.vertical_offset)
    # one pass in blocks, in the memory of one block
    s = Ref(0)
    @test trcblocks((c, _) -> (s[] += sum(Int, c)), p; blocksize = 2^20) == n
    @test s[] == sum(k -> Int(code(k)), 1:n)
    @test least_alloc(() -> trcblocks((c, _) -> nothing, p; blocksize = 2^16)) < 2^17 + 100_000
    # the memory budget refuses before allocating
    @test_throws ArgumentError readtrc(p; memory = 2n - 1)
    @test least_alloc(() -> try readtrc(p; memory = 2n - 1) catch end) < 100_000
    if whole
        w = readtrc(p)
        @test length(w.data1) == n && all(k -> w.data1[k] == code(k), 1:n)
        @test times(w)[r] == times(i, r)
        w = nothing
        GC.gc()
    end
end

@testset "a 100 MB record, both byte orders" begin
    n = 50_000_000
    for order in (:little, :big)
        p = write_long(tempname() * ".trc", n; order, usertext = "long")
        check_long(p, n)
        order === :little && @test least_alloc(() -> readtrc(p)) < 2n + 200_000   # the data once
        rm(p)
    end
    GC.gc()
end

@testset "a sequence of 1000 segments" begin
    nseg, m = 1000, 10_000
    tt = [(1e-3 * (k - 1), -1e-6 * k) for k in 1:nseg]
    p = write_long(tempname() * ".trc", nseg * m; trigtime = tt, subarray_count = nseg,
                   nom_subarray_count = nseg, last_valid_pnt = m - 1)
    w = readtrc(p)
    @test nsegments(w) == nseg && size(segments(w)) == (m, nseg)
    @test segments(w)[:, nseg] == code.(((nseg - 1) * m + 1):(nseg * m))
    @test w.info.trigger_times[end] == 1e-3 * (nseg - 1)
    @test times(w, nseg)[1] == -1e-6 * nseg && length(times(w, nseg)) == m
    @test trcread(p, (m - 1):(m + 2)) == code.((m - 1):(m + 2))      # across a segment boundary
    rm(p)
end

if get(ENV, "LECROYTRC_STRESS", "") == "1"
    @testset "the largest data array the template holds" begin
        n = 2^30 - 1                                    # WAVE_ARRAY_1 = 2^31 - 2 bytes
        p = write_long(tempname() * ".trc", n)
        @test filesize(p) > typemax(Int32)
        check_long(p, n; whole = Sys.free_memory() > 2 * 2^31)   # reads 2 GB once
        rm(p)
    end
end
