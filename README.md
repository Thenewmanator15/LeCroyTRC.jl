# LeCroyTRC.jl

[![CI](https://github.com/Thenewmanator15/LeCroyTRC.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Thenewmanator15/LeCroyTRC.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/Thenewmanator15/LeCroyTRC.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/Thenewmanator15/LeCroyTRC.jl)
[![docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://thenewmanator15.github.io/LeCroyTRC.jl/dev/)

Read LeCroy oscilloscope waveform files (`.trc`) in Julia: the binary format a LeCroy
scope writes when a trace is saved to disk, and its reply to `WF? ALL`. One dependency
beyond the standard library: PrecompileTools, so the first read in a session is not spent
compiling.

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

## Reading a long trace in parts

```julia
info = trcinfo("C1--capture--00000.trc")         # the descriptor; no samples read
codes = trcread("C1--capture--00000.trc", 4_000_001:4_010_000)   # a window, 1-based
v = volts(info, codes); t = times(info, 4_000_001:4_010_000)

out = Vector{Float32}(undef, 2^20)
trcblocks("C1--capture--00000.trc"; blocksize = 2^20) do codes, offset
    # codes: the next block (one buffer, reused); offset: 0-based index of codes[1]
    volts!(view(out, 1:length(codes)), info, codes)
end
```

`trcmap(file)` is `readtrc` with the samples mapped from the file rather than read: a
record of any size opens at once, and the operating system reads only the pages that
are touched. Its `data1` and `data2` are read-only. While such a waveform is alive, do
not let anything change the file (on Windows it cannot be deleted or replaced at all);
for a file still being written, use `readtrc`.

`trcread` skips to the window in a file or buffer and reads its way there on any other
stream. `trcblocks` also takes `memory`, a byte budget for its buffer.
`readtrc(file; memory)` refuses a record whose samples would take more than `memory`
bytes (default: the machine's memory, `Sys.total_memory()`) before reading any of them.

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
- **Long records.** Every run writes a 100 MB record in both byte orders and a sequence
  of 1000 segments, and checks that a window at the far end is skipped to, not read
  through, and that blocks and the memory budget hold. `LECROYTRC_STRESS=1` adds a
  record at the template's largest data array (2 GB, the file past 2^31 bytes).
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

## AI disclosure

Written with Claude Code (Claude Opus 5.5) assisting. The test and measurement work is
mine: the WavePro 740Zi captures, and checking the reader against them and against the
reader it replaces. I reviewed every change by hand before committing it, and the
commits Claude contributed to carry a `Co-Authored-By: Claude` trailer. See
[AI_DISCLOSURE.md](AI_DISCLOSURE.md).
