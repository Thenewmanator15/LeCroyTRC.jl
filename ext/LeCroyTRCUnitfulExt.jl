"Unitful for LeCroy waveforms: the units of the time axis and of the scaled samples."
module LeCroyTRCUnitfulExt

using LeCroyTRC: LeCroyTRC, TRCInfo, TRCWaveform
import Unitful

LeCroyTRC.units(w::TRCWaveform) = LeCroyTRC.units(w.info)
LeCroyTRC.units(i::TRCInfo) = (horizontal = _unit(i.horunit), vertical = _unit(i.vertunit))

function _unit(s)
    isempty(s) && return Unitful.NoUnits
    # LeCroy's seconds, alone or in a compound such as "V*S"; uparse would read siemens
    u = try
        Unitful.uparse(replace(s, r"\bS\b" => "s"))
    catch
        nothing
    end
    # uparse also returns numbers ("1", "pi") and quantities ("2V"), which are not units
    u isa Unitful.Units || throw(ArgumentError("Unitful does not read $(repr(s)) as a unit"))
    u
end

end
