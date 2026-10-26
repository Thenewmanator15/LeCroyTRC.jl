"FileIO for LeCroy waveforms: `load(\"x.trc\")` is `readtrc(\"x.trc\")`, keywords included."
module LeCroyTRCFileIOExt

using LeCroyTRC: LeCroyTRC, readtrc
import FileIO

LeCroyTRC.fileio_load(f::FileIO.File{FileIO.DataFormat{:LeCroyTRC}}; kwargs...) =
    readtrc(FileIO.filename(f); kwargs...)
LeCroyTRC.fileio_load(s::FileIO.Stream{FileIO.DataFormat{:LeCroyTRC}}; kwargs...) =
    readtrc(FileIO.stream(s); kwargs...)

end
