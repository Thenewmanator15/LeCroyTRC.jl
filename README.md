# LeCroyTRC.jl

[![CI](https://github.com/Thenewmanator15/LeCroyTRC.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Thenewmanator15/LeCroyTRC.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/Thenewmanator15/LeCroyTRC.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/Thenewmanator15/LeCroyTRC.jl)

Read LeCroy oscilloscope waveform files (`.trc`) in Julia: the binary format a LeCroy
scope writes when a trace is saved to disk, and its reply to `WF? ALL`. No dependencies
beyond the standard library.

```julia
using LeCroyTRC

w = readtrc("C1--capture--00000.trc")
t = times(w)        # seconds from the trigger: HORIZ_OFFSET + i * HORIZ_INTERVAL
v = volts(w)        # VERTICAL_GAIN * code - VERTICAL_OFFSET
w.data1             # the samples as stored: Vector{Int16} (or Int8)
w.info.trigger_time # every descriptor field, by its template name
```

```julia
julia> w
TRCWaveform{Int16}: 10002 points, word samples, single_sweep
  instrument    LECROYWP740Zi #1234, channel_3 (C3)
  trigger       2021-10-15T15:49:26.356
  horizontal    2.5e-11 S per point, first at -4.0e-6 S
  vertical      2.77433e-5 * code + 0.56 V
```

## What it reads

The layout is LeCroy's own template, `LECROY_2_3`, as printed in the Remote Control
Manual (Appendix II, "Waveform Template"):

| | |
|---|---|
| descriptor | every WAVEDESC field, enums decoded (`record_type`, `vert_coupling`, `wave_source`, `timebase` in s/div, `fixed_vert_gain` in V/div, …) |
| byte order | LOFIRST and HIFIRST |
| samples | byte (`Int8`) and word (`Int16`), kept as stored |
| sequence mode | the TRIGTIME array (`trigger_times`, `trigger_offsets`); `segments(w)` gives one column per segment, `times(w, k)` the axis of segment `k` |
| RIS | the RIS_TIME array (`ris_offsets`) |
| second array | extrema floor, complex imaginary part, peak-detect pairs (`data2`, `volts(w, 2)`) |
| user text | `w.info.usertext` |
| framing | `#9…` block headers or a `C1:WF ALL,` echo before WAVEDESC; records one after another on a stream |

`trcinfo(file)` reads the descriptor, user text and time arrays without the samples, for
surveying many captures. `readtrc(io)` reads from any stream (a file, a buffer, a pipe),
forward only, and stops at the end of the record.

`readtrc` runs at the speed of reading the file's bytes. Scaling costs more than reading:
on a 50-million-point trace most of `volts(w)`'s time goes into filling its fresh
`Float64` array. `volts!(buffer, w)` reuses one buffer across captures (about three times
faster there), and `volts(Float32, w)` halves the memory (a 16-bit code is exact in
`Float32`).

Anything a file declares but does not hold (a truncated record, block lengths that do
not add up, a sample format the template does not define) raises
`LeCroyTRC.FormatError` naming the field, rather than returning misread data.
`times` refuses records transferred with a `FIRST_POINT` or `SPARSING_FACTOR` that makes
their points a subset of the acquisition, whose times it cannot place.

## How it is checked

- **The template.** The tests write files byte for byte from the template, with a writer
  that shares no code with the reader: every field, every enum value, both byte orders,
  sequence, RIS, reserved blocks, second arrays, framing, truncation and inconsistent
  descriptors. A property test round-trips 300 random shapes.
- **An independent reader.** CI writes 120 files and reads them with
  [lecroyutils](https://github.com/sibartel/lecroyutils) (Python); every sample and
  field agrees on all 96 files it can read. It reads the other 24, the RIS files,
  wrongly: it starts the samples right after the TRIGTIME array, where the template puts
  the RIS_TIME array.
- **Real captures.** On 1,943 captures from a WavePro 740Zi, LeCroyTRC agrees sample for
  sample with lecroyutils and with the reader it replaces.
- **Mutation.** Each plausible misreading of the template (a block not skipped, day and
  month swapped, the byte order ignored, …) makes the tests fail.

## Notes

- `trigger_time` is a `DateTime`, so it holds milliseconds; `trigger_seconds` keeps the
  scope's seconds field at full precision. A scope with a wrong clock writes a wrong
  date: nothing in the file can tell.
- Values the 2005 template does not list are kept, not guessed: `wave_source` is
  `:enum_4` for the spectrum-analyser traces of a WavePro 740Zi, and `timebase` is
  `nothing` for their index 48.
- `volts` scales into `w.info.vertunit` and `times` into `w.info.horunit`: volts and
  seconds for a channel, whatever the scope records for a math or FFT trace.

## Licence

MIT
