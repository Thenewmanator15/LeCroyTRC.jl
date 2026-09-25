# Cross-check against an independent reader (lecroyutils, Python): write files in every
# shape it reads, plus the RIS shape it does not, and record what LeCroyTRC reads from
# each (fields in expected.tsv, volts as little-endian Float64 beside each file).
# read.py then reads the same files with lecroyutils and compares.
#
#     julia --project=. test/crosscheck/write.jl <dir>
#     python test/crosscheck/read.py <dir>
using LeCroyTRC, Dates, Random
include(joinpath(@__DIR__, "..", "writer.jl"))

out = ARGS[1]
seed = length(ARGS) > 1 ? parse(Int, ARGS[2]) : rand(1:10^6)
println("seed $seed")
rng = MersenneTwister(seed)
rm(out; force = true, recursive = true); mkpath(out)

rows = String[]
k = 0
for order in (:little, :big), T in (Int8, Int16), nseg in (1, 4), ut in ("", "note on C3"),
    prefix in ("", "#9", "C1:WF ALL,#9000000000"), d2 in (false, true), ris in (false, true)
    ris && (nseg > 1 || d2) && continue
    global k += 1
    per = 257
    d1 = rand(rng, T, nseg == 1 ? (per,) : (per, nseg))
    kw = (order = order, usertext = ut, prefix = prefix,
          data2 = d2 ? reverse(vec(d1)) : nothing,
          ris = ris ? [1.0e-11, -2.0e-11, 3.0e-11] : Float64[],
          record_type = ris ? 8 : d2 ? 6 : 0,
          trigtime = nseg > 1 ? [(2.5e-3 * (j - 1), -1e-6 - 1e-9 * j) for j in 1:nseg] : nothing,
          timebase = rand(rng, 0:47), fixed_vert_gain = rand(rng, 0:27),
          vert_coupling = rand(rng, (0, 2, 4)), wave_source = rand(rng, 0:3),
          bandwidth_limit = rand(rng, 0:1),
          vertical_gain = rand(rng, Float32) * 1f-3, vertical_offset = randn(rng, Float32),
          horiz_interval = Float32(rand(rng, (1e-9, 2.5e-11, 5e-10))),
          horiz_offset = -rand(rng) * 1e-5,
          trigger_time = (rand(rng) * 59.999, rand(rng, 0:59), rand(rng, 0:23), rand(rng, 1:28),
                          rand(rng, 1:12), rand(rng, 1990:2030)))
    name = "f$(lpad(k, 3, '0'))_$(order)_$(T)_seg$(nseg)$(d2 ? "_d2" : "")$(ris ? "_ris" : "").trc"
    path = write_trc(joinpath(out, name), d1; kw...)
    w = readtrc(path)
    i = w.info
    write(path * ".volts", htol.(volts(w)))
    push!(rows, join(Any[name, ris, i.comm_order, length(w.data1), nsegments(w),
                         i.vertical_gain, i.vertical_offset, i.horiz_interval, i.horiz_offset,
                         i.nominal_bits, i.instrument_name, i.instrument_number, i.record_type,
                         i.processing_done, i.timebase, i.fixed_vert_gain, i.vert_coupling,
                         i.bandwidth_limit, i.wave_source, i.trigger_seconds,
                         Dates.format(i.trigger_time, "yyyy-mm-dd HH:MM"),
                         join(i.trigger_times, ","), join(i.trigger_offsets, ","),
                         i.vertunit, i.horunit], '\t'))
end
write(joinpath(out, "expected.tsv"), join(rows, '\n') * '\n')
println("wrote $k files to $out")
