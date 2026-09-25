"""Read the files written by write.jl with lecroyutils (an independent Python reader) and
compare with what LeCroyTRC read. Exit status 1 if any file lecroyutils can read
disagrees. RIS files are expected to differ: lecroyutils starts the samples right after
TRIGTIME, where the template puts the RIS_TIME array.

    python test/crosscheck/read.py <dir>
"""
import sys
import warnings
from pathlib import Path

import numpy as np
from lecroyutils.data import LecroyScopeData

warnings.simplefilter("ignore")  # lecroyutils warns about "clipped" random test data
DIR = Path(sys.argv[1])
PREFIX = {"p": 1e-12, "n": 1e-9, "u": 1e-6, "m": 1e-3, "": 1.0, "k": 1e3}
COUPLING = {"DC50": "DC_50_Ohms", "GND": "ground", "DC1M": "DC_1MOhm", "AC1M": "AC_1MOhm"}
PROCESSING = {"No Processing": "no_processing"}


def per_div(s):  # "200 mV/div" -> 0.2
    num, unit = s.split(" ")
    return float(num) * PREFIX[unit.split("/")[0][:-1]]


agree, differ = 0, []
for line in (DIR / "expected.tsv").read_text().splitlines():
    (name, ris, order, n, nseg, gain, off, dt, t0, bits, inst, instno, rec, proc,
     tb, fvg, coup, bw, src, secs, tmin, ttimes, toffs, vunit, hunit) = line.split("\t")
    problems = []
    d = LecroyScopeData.parse_file(str(DIR / name))
    jl = np.fromfile(DIR / (name + ".volts"), dtype="<f8")
    y = np.asarray(d.y, dtype=np.float64)
    y = y.flatten(order="F") if y.ndim == 2 else y   # lecroyutils puts segments in columns
    scale = abs(float(gain)) * 32768 + abs(float(off))
    if y.shape != jl.shape:
        problems.append(f"volts shape {y.shape} vs {jl.shape}")
    elif not np.allclose(y, jl, rtol=0, atol=2e-6 * scale):   # lecroyutils scales in float32
        problems.append(f"volts differ by up to {np.max(np.abs(y - jl)):.3g} (scale {scale:.3g})")
    checks = [
        ("byte order", d.endianness, "<" if order == "little" else ">"),
        ("count", int(d.count_wave_array), int(n)),
        ("gain", float(d.vertical_gain), float(np.float32(gain))),
        ("offset", float(d.vertical_offset), float(np.float32(off))),
        ("dt", float(d.horizontal_interval), float(np.float32(dt))),
        ("t0", float(d.horizontal_offset), float(t0)),
        ("bits", int(d.nominal_bits), int(bits)),
        ("instrument", d.instrument_name.strip("\x00 "), inst),
        ("instrument number", int(d.instrument_number), int(instno)),
        ("record type", d.record_type, rec),
        ("processing", PROCESSING.get(d.processing_done, d.processing_done), proc),
        ("timebase", per_div(d.timebase), float(tb)),
        ("fixed vertical gain", per_div(d.fixed_vert_gain), float(fvg)),
        ("coupling", COUPLING[d.vertical_coupling], coup),
        ("bandwidth limit", d.bandwidth_limit == "on", bw == "true"),
        ("source", "channel_" + d.wave_source[1], src),
        ("trigger minute", d.trigger_time.strftime("%Y-%m-%d %H:%M"), tmin),
        ("vertical unit", d.y_unit.strip("\x00 "), vunit),
        ("horizontal unit", d.x_unit.strip("\x00 "), hunit),
    ]
    for what, got, want in checks:
        same = np.isclose(got, want, rtol=1e-6, atol=1e-15) if isinstance(want, float) else got == want
        if not same:
            problems.append(f"{what}: lecroyutils {got!r}, LeCroyTRC {want!r}")
    # lecroyutils truncates the seconds to whole microseconds
    if abs(d.trigger_time.second + d.trigger_time.microsecond * 1e-6 - float(secs)) > 1.01e-6:
        problems.append(f"trigger seconds: {d.trigger_time} vs {secs}")
    if int(nseg) > 1:
        if not np.array_equal(d.trigger_times, [float(x) for x in ttimes.split(",")]):
            problems.append("trigger times differ")
        if not np.array_equal(d.trigger_offsets, [float(x) for x in toffs.split(",")]):
            problems.append("trigger offsets differ")
    if problems:
        differ.append((name, ris == "true", problems))
    else:
        agree += 1

other = [x for x in differ if not x[1]]
ris = [x for x in differ if x[1]]
print(f"{agree} files agree in every sample and field")
print(f"{len(ris)} RIS files differ, as expected")
print(f"{len(other)} other files differ")
for name, _, p in other:
    print("  ", name, "; ".join(p))
sys.exit(1 if other or agree == 0 else 0)
