"Tables.jl for LeCroy waveforms: a trace is a table of `time` and `volts`."
module LeCroyTRCTablesExt

using LeCroyTRC: TRCWaveform, nsegments, segments, times, volts
import Tables

Tables.istable(::Type{<:TRCWaveform}) = true
Tables.columnaccess(::Type{<:TRCWaveform}) = true

# A single sweep: time and volts. A sequence: the segment of each point too, and its time
# from that segment's own trigger.
function Tables.columns(w::TRCWaveform)
    n = nsegments(w)
    n == 1 && return (time = times(w), volts = volts(w))
    m = size(segments(w), 1)
    (segment = repeat(1:n; inner = m), time = reduce(vcat, (times(w, k) for k in 1:n)), volts = volts(w))
end

end
