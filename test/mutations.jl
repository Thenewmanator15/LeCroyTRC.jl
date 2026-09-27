# Mutation pass: each mutation is one plausible misreading of the template. The test
# suite must fail for every one of them; a mutation that survives is a hole in the tests.
# Not part of `Pkg.test()` (each mutation runs the whole suite):
#
#     julia test/mutations.jl [part of a mutation's name]

const SRC = dirname(@__DIR__)
const WORK = joinpath(mktempdir(), "LeCroyTRC")

mutations = [
    ("RIS_TIME not skipped",
     "ris = _read_array(io, Float64, rislen, big, \"RIS_TIME\")",
     "ris = Float64[]"),
    ("RES_DESC1 not skipped", "_discard(io, rd1, \"RES_DESC1\")", "nothing"),
    ("RES_ARRAY1 not skipped", "_discard(io, ra1, \"RES_ARRAY1\")", "nothing"),
    ("extended descriptor not skipped", "_discard(io, wdlen - DESCRIPTOR_BYTES, \"the descriptor\")", "nothing"),
    ("day and month swapped", "d[308], d[307], d[306], d[305], secs", "d[307], d[308], d[306], d[305], secs"),
    ("byte order never swapped", "_swap(big) && map!(_bswap, v, v)", "false && map!(_bswap, v, v)"),
    ("descriptor read little-endian always", "ld(::Type{T}, off) where {T} = _load(T, d, off, big)",
     "ld(::Type{T}, off) where {T} = _load(T, d, off, false)"),
    ("offset added not subtracted", "out[i] = g * data[i] - o", "out[i] = g * data[i] + o"),
    ("1-2-5 enum off by a decade", "e = 3 * (i ÷ 9) + base", "e = 3 * (i ÷ 9) + base + 1"),
    ("trailing NULs kept in user text", "String(_trim_nul(ut))", "String(copy(ut))"),
    ("segment axis from HORIZ_OFFSET", "_axis(w, w.info.trigger_offsets[k], size(segments(w), 1))",
     "_axis(w, w.info.horiz_offset, size(segments(w), 1))"),
    ("TRIGTIME/SUBARRAY_COUNT mismatch ignored", "n == 0 || n == c ||", "true ||"),
    ("second array not read", "data2 = _read_array(io, T, info.wave_array_2, big, \"DATA_ARRAY_2\")",
     "data2 = (_discard(io, Int(info.wave_array_2), \"x\"); T[])"),
    ("block lengths not checked against the input", "left === nothing || left >= n ||", "true ||"),
    ("trailing reserved arrays not consumed", "_discard(io, Int(info.res_array2) + Int(info.res_array3), \"RES_ARRAY2/RES_ARRAY3\")", "nothing"),
    ("count consistency not checked", "a1 == Int(count) * esz ||", "true ||"),
    ("byte samples read as words", "T = info.comm_type === :byte ? Int8 : Int16", "T = Int16"),
    ("sub-millisecond trigger seconds lost", "tstamp, secs, ld(Float32, 312)", "tstamp, round(secs; digits = 3), ld(Float32, 312)"),
]

results = Tuple{String,Bool}[]
for (name, old, new) in filter(m -> isempty(ARGS) || occursin(ARGS[1], m[1]), mutations)
    rm(WORK; force = true, recursive = true)
    cp(SRC, WORK)
    rm(joinpath(WORK, ".git"); force = true, recursive = true)
    f = joinpath(WORK, "src", "LeCroyTRC.jl")
    s = read(f, String)
    n = count(old, s)
    if n != 1
        println("SKIP  $name: pattern found $n times")
        continue
    end
    write(f, replace(s, old => new))
    ok = success(pipeline(`$(Base.julia_cmd()) --project=$WORK -e "using Pkg; Pkg.test()"`;
                          stdout = devnull, stderr = devnull))
    push!(results, (name, ok))
    println(ok ? "SURVIVED  " : "caught    ", name)
end
println("\n", count(!last, results), " of ", length(results), " mutations caught")
