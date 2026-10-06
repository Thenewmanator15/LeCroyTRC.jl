# LeCroyTRC.jl

```@docs
LeCroyTRC
```

## Installing

```julia
using Pkg
Pkg.add(url = "https://github.com/Thenewmanator15/LeCroyTRC.jl")
```

## A first read

```julia
using LeCroyTRC

w = readtrc("C1--capture--00000.trc")
t = times(w)        # seconds from the trigger: HORIZ_OFFSET + i * HORIZ_INTERVAL
v = volts(w)        # VERTICAL_GAIN * code - VERTICAL_OFFSET
w.data1             # the samples as stored: Vector{Int16} (or Int8)
w.info.trigger_time # every descriptor field, by its template name
```

Every function and type is described in the [Reference](@ref).

What the reader covers and how it is checked is in the
[README](https://github.com/Thenewmanator15/LeCroyTRC.jl#readme).
