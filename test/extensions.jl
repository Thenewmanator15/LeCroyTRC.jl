# The package extensions (Julia 1.9 and later): Tables.jl, Unitful and FileIO.
# Uses trc_bytes from writer.jl.
using Tables, Unitful
import FileIO

@testset "a trace is a table of time and volts" begin
    w = readtrc(IOBuffer(trc_bytes(Int16.(1:5))))
    @test Tables.istable(w) && Tables.columnaccess(w)
    @test Tables.columntable(w) == (time = collect(times(w)), volts = volts(w))
    @test [r.volts for r in Tables.rows(w)] == volts(w)
    # a sequence: the segment of each point, and its time from that segment's trigger
    tt = [(0.0, -1e-6), (1e-3, -2e-6)]
    s = readtrc(IOBuffer(trc_bytes(Int16.(reshape(1:6, 3, 2)); trigtime = tt)))
    c = Tables.columntable(s)
    @test c.segment == [1, 1, 1, 2, 2, 2]
    @test c.time == vcat(times(s, 1), times(s, 2))
    @test c.volts == volts(s)
end

@testset "the units of the time axis and of the samples" begin
    w = readtrc(IOBuffer(trc_bytes(Int16.(1:5))))           # horunit "S", vertunit "V"
    @test LeCroyTRC.units(w) == (horizontal = u"s", vertical = u"V")   # seconds, not siemens
    @test LeCroyTRC.units(w.info) == LeCroyTRC.units(w)
    h, v = LeCroyTRC.units(w)
    @test times(w) * h == collect(times(w)) .* u"s"
    @test volts(w) * v == volts(w) .* u"V"
    f = trcinfo(IOBuffer(trc_bytes(Int16[0]; horunit = "Hz", vertunit = "A")))
    @test LeCroyTRC.units(f) == (horizontal = u"Hz", vertical = u"A")
    @test_throws ArgumentError LeCroyTRC.units(trcinfo(IOBuffer(trc_bytes(Int16[0]; vertunit = "Volts"))))
end

@testset "FileIO loads a .trc file" begin
    # until FileIO's registry knows the format, register it here as the registry entry would
    FileIO.add_format(FileIO.format"LeCroyTRC", (), ".trc", [:LeCroyTRC => Base.PkgId(LeCroyTRC).uuid])
    p = tempname() * ".trc"
    write(p, trc_bytes(Int16.(1:5); usertext = "abc"))
    @test FileIO.query(p) isa FileIO.File{FileIO.format"LeCroyTRC"}
    w = FileIO.load(p)
    @test w isa TRCWaveform{Int16} && w.data1 == 1:5 && w.info.usertext == "abc"
    s = open(io -> FileIO.load(FileIO.Stream{FileIO.format"LeCroyTRC"}(io)), p)
    @test s.data1 == 1:5
    # keywords reach readtrc; FileIO prints the error before it rethrows it
    @test_throws Exception redirect_stderr(() -> FileIO.load(p; memory = 1), devnull)
    rm(p)
end
