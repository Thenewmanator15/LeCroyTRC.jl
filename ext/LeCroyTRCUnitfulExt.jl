"Unitful for LeCroy waveforms: the units of the time axis and of the scaled samples."
module LeCroyTRCUnitfulExt

using LeCroyTRC: LeCroyTRC, TRCInfo, TRCWaveform
import Unitful

LeCroyTRC.units(w::TRCWaveform) = LeCroyTRC.units(w.info)
LeCroyTRC.units(i::TRCInfo) = (horizontal = _unit(i.horunit), vertical = _unit(i.vertunit))

function _unit(s)
    s == "S" && return Unitful.u"s"           # LeCroy's seconds; uparse would read siemens
    try
        Unitful.uparse(s)
    catch
        throw(ArgumentError("Unitful does not read the unit $(repr(s))"))
    end
end

end
