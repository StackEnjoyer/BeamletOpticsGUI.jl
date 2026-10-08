using BeamletOptics
using BeamletOpticsGUI
using GLMakie
using Documenter

DocMeta.setdocmeta!(
    BeamletOpticsGUI,
    :DocTestSetup,
    :(using BeamletOptics, BeamletOpticsGUI);
    recursive=true
)

# The examples open a GLMakie screen (invisible, to save figures). On a headless Linux machine,
# run this script under `xvfb-run -a`, as the CI does.
makedocs(;
    modules=[BeamletOpticsGUI],
    authors="Hugo Uittenbosch <hugo.uittenbosch@dlr.de>, Oliver Kliebisch <oliver.kliebisch@dlr.de> and contributors",
    sitename="BeamletOpticsGUI.jl",
    format=Documenter.HTML(;
        repolink="https://github.com/StackEnjoyer/BeamletOpticsGUI.jl",
        canonical="https://stackenjoyer.github.io/BeamletOpticsGUI.jl",
        edit_link="main",
    ),
    pagesonly=true,
    checkdocs=:exports,
    # `missing_docs`: the docstrings of the GUI names are moved by the package, not by the docs.
    # `cross_references`: those docstrings link to names of BeamletOptics (e.g. `solve_system!`),
    # which are documented on the BeamletOptics site and are not resolvable here.
    warnonly=[:missing_docs, :cross_references],
    pages=[
        "Home" => "index.md",
        "Live view" => "live_view.md",
        "Adding and removing components" => "components.md",
        "Kinematic controls" => "kinematic_controls.md",
        "View cube" => "view_cube.md",
        "Cards and widgets" => "widgets.md",
        "Examples" => Any[
            "Interactive Michelson" => joinpath("examples", "live_michelson.md"),
            "Empty table" => joinpath("examples", "live_empty_table.md"),
        ],
        "API" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/StackEnjoyer/BeamletOpticsGUI.jl.git",
    devbranch="main",
    push_preview=false,
)
