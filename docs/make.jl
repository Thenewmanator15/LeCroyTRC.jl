using Documenter, LeCroyTRC

makedocs(;
    sitename = "LeCroyTRC.jl",
    modules = [LeCroyTRC],
    checkdocs = :exports,   # the internal helpers carry docstrings too
    pages = ["Home" => "index.md", "Reference" => "reference.md"],
)

deploydocs(; repo = "github.com/Thenewmanator15/LeCroyTRC.jl.git", devbranch = "main")
