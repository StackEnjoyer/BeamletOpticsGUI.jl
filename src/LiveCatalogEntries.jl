#=
Entries of the component catalog for the components of BeamletOptics, see `component_catalog`, and
the icons of their groups
=#

const _CATALOG = CatalogEntry[]
# Whether `_CATALOG` got the built-in entries, see `component_catalog`
const _CATALOG_FILLED = Ref(false)

function component_catalog()
    if !_CATALOG_FILLED[]
        _CATALOG_FILLED[] = true
        # before the entries that were added without this function
        prepend!(_CATALOG, _builtin_catalog())
    end
    return _CATALOG
end

# The icons of the groups of the built-in entries, see `_catalog_group_icon`
const _CATALOG_GROUP_ICONS = Dict{String, Symbol}(
    "Sources" => :source,
    "Lenses" => :lens,
    "Mirrors" => :mirror,
    "Curved mirrors" => :spherical_mirror,
    "Beamsplitters" => :beamsplitter,
    "Prisms" => :prism,
    "Polarizers" => :polarizer,
    "Detectors" => :detector,
)

"""
    _catalog_group_icon(entries, group) -> Union{Symbol, BezierPath}

The icon of the `group` of the catalog `entries`: the one of a built-in group (see
`_CATALOG_GROUP_ICONS`), otherwise the icon of its first entry that has one, `:object` without one.
"""
function _catalog_group_icon(entries, group::AbstractString)
    haskey(_CATALOG_GROUP_ICONS, group) && return _CATALOG_GROUP_ICONS[group]
    i = findfirst(e -> e.group == group && !isnothing(e.icon), entries)
    return isnothing(i) ? :object : entries[i].icon
end

"""The icon of the `entry` of the catalog `entries`: its own, otherwise the one of its group."""
_catalog_icon(entries, entry::CatalogEntry) =
    something(entry.icon, _catalog_group_icon(entries, entry.group))

# The laser lines [nm] that the wavelength of a source offers as presets
const _LASER_LINES = (405, 450, 488, 532, 589, 632.8, 780, 850, 1064, 1310, 1550)

# A length in [m], shown in mm
_length_param(name, default; kwargs...) = CatalogParam(name, default; unit = "mm", scale = 1e-3, kwargs...)

"""
    _builtin_catalog() -> Vector{CatalogEntry}

The entries of [`component_catalog`](@ref): the sources of BeamletOptics and all its components
with a constructor of numbers and glasses, with the defaults of one inch optics. Only these
arguments are parameters, the others keep the defaults of the constructor, e.g. the `stop` of a
`Detector` and the `thickness` and the `hole_diameter` of the curved mirrors. The radii of curvature
follow BeamletOptics: positive if the center of the surface lies behind it (towards +y), i.e.
`R1 > 0` and `R2 < 0` for a biconvex lens, `Inf` for a plane surface of a `SphericalLens`.

The sources (entries with `source = true`) are constructed at the origin along +y with a wavelength
of 632.8 nm, which offers the laser lines `_LASER_LINES` as its presets; the half angle of the point sources is entered in degrees, the numbers of rings and
rays are whole numbers.
"""
function _builtin_catalog()
    inch = 25.4e-3
    len = _length_param
    diameter = len("diameter", inch)
    thickness = len("thickness", 5e-3)
    reflectance = CatalogParam("reflectance", 0.5; keyword = :reflectance)
    flint = "N-SF5"
    entries = CatalogEntry[]
    # The entries of a group, each as (name, icon, constructor, parameters...)
    function group!(group, items...; source::Bool = false)
        for (name, icon, constructor, params...) in items
            push!(entries, CatalogEntry(name, constructor; group, icon, params, source))
        end
        return nothing
    end
    # the parameters of the sources: a helium-neon laser, the numbers of rings and rays of BeamletOptics
    wavelength = CatalogParam("wavelength", 632.8e-9; unit = "nm", scale = 1e-9,
        presets = ["$(_catalog_number_string(nm)) nm" => round(nm * 1e-9; sigdigits = 15)
                   for nm in _LASER_LINES])
    power = CatalogParam("power", 1e-3; unit = "mW", scale = 1e-3, keyword = :P0)
    half_angle = CatalogParam("half angle", deg2rad(5); unit = "°", scale = π / 180)
    rings = CatalogParam("rings", 10; keyword = :num_rings, integer = true)
    rays = CatalogParam("rays", 1000; keyword = :num_rays, integer = true)
    group!("Sources",
        ("Beam", :beam, Beam, wavelength),
        ("Gaussian beamlet", :gaussian_beam, GaussianBeamlet, wavelength, len("waist", 1e-3), power),
        ("Collimated source", :collimated_source, CollimatedSource,
            len("diameter", 10e-3), wavelength, rings),
        ("Uniform disc source", :disc_source, UniformDiscSource,
            len("diameter", 10e-3), wavelength, rays),
        ("Point source", :point_source, PointSource, half_angle, wavelength, rings),
        ("Uniform point source", :uniform_point_source, UniformPointSource,
            half_angle, wavelength, rays),
        ("Astigmatic Gaussian beamlet", :astigmatic_beam, AstigmaticGaussianBeamlet,
            wavelength, len("waist x", 1e-3), len("waist y", 0.5e-3), power);
        source = true)
    group!("Lenses",
        ("Thin lens", :thin_lens, ThinLens,
            len("R1", 50e-3), len("R2", -50e-3), diameter, CatalogGlass()),
        ("Singlet", :singlet, SphericalLens,
            len("R1", 50e-3), len("R2", -50e-3), thickness, diameter, CatalogGlass()),
        # an achromat of 100 mm focal length
        ("Doublet", :doublet, SphericalDoubletLens,
            len("R1", 62.8e-3), len("R2", -45.7e-3), len("R3", -128.2e-3),
            len("thickness 1", 4e-3), len("thickness 2", 2.5e-3), diameter,
            CatalogGlass("glass 1"), CatalogGlass("glass 2"; default = flint)),
        ("Triplet", :triplet, SphericalTripletLens,
            len("R1", 60e-3), len("R2", -45e-3), len("R3", 45e-3), len("R4", -60e-3),
            len("thickness 1", 5e-3), len("thickness 2", 2.5e-3), len("thickness 3", 5e-3), diameter,
            CatalogGlass("glass 1"), CatalogGlass("glass 2"; default = flint), CatalogGlass("glass 3")))
    group!("Mirrors",
        ("Round mirror", :round_mirror, RoundPlanoMirror, diameter, thickness),
        ("Square mirror", :square_mirror, SquarePlanoMirror, len("width", inch), thickness),
        ("Rectangular mirror", :rect_mirror, RectangularPlanoMirror,
            len("width", 2inch), len("height", inch), thickness),
        ("Thin mirror", :thin_mirror, SquarePlanoMirror2D, len("width", inch)),
        ("Prism mirror", :prism_mirror, RightAnglePrismMirror,
            len("leg length", inch), len("height", inch)),
        ("Retroreflector", :retroreflector, Retroreflector, len("edge length", inch)))
    group!("Curved mirrors",
        ("Spherical mirror", :spherical_mirror, SphericalMirror,
            len("radius", 100e-3), len("thickness", 6e-3), diameter),
        ("Parabolic mirror", :parabolic_mirror, ParabolicMirror, len("focal length", 50e-3), diameter),
        ("Off-axis parabolic", :offaxis_parabolic_mirror, OffAxisParabolicMirror,
            len("focal length", 50e-3), diameter, CatalogParam("angle", 90; unit = "°", keyword = :angle)),
        ("Conic mirror", :conic_mirror, ConicMirror,
            len("radius", 100e-3), CatalogParam("conic constant", -1), diameter),
        ("Off-axis conic", :offaxis_conic_mirror, OffAxisConicMirror,
            len("radius", 100e-3), CatalogParam("conic constant", -1), len("offset", 30e-3), diameter),
        ("Ellipsoidal mirror", :ellipsoidal_mirror, EllipsoidalMirror,
            len("s", 100e-3), len("s'", 200e-3), diameter),
        ("Off-axis ellipsoidal", :offaxis_ellipsoidal_mirror, OffAxisEllipsoidalMirror,
            len("s", 100e-3), len("s'", 200e-3), len("offset", 30e-3), diameter),
        ("Hyperbolic mirror", :hyperbolic_mirror, HyperbolicMirror,
            len("s", 100e-3), len("s'", -200e-3), diameter),
        ("Off-axis hyperbolic", :offaxis_hyperbolic_mirror, OffAxisHyperbolicMirror,
            len("s", 100e-3), len("s'", -200e-3), len("offset", 30e-3), diameter))
    group!("Beamsplitters",
        ("Thin beamsplitter", :thin_beamsplitter, ThinBeamsplitter,
            len("width", inch), len("height", inch), reflectance),
        ("Round thin beamsplitter", :round_thin_beamsplitter, RoundThinBeamsplitter,
            diameter, reflectance),
        ("Plate beamsplitter", :plate_beamsplitter, RectangularPlateBeamsplitter,
            len("width", inch), len("height", inch), thickness, CatalogGlass(), reflectance),
        ("Round plate beamsplitter", :round_plate_beamsplitter, RoundPlateBeamsplitter,
            diameter, thickness, CatalogGlass(), reflectance),
        ("Cube beamsplitter", :beamsplitter, CubeBeamsplitter,
            len("leg length", inch), CatalogGlass(), reflectance),
        ("Compensator plate", :compensator, RectangularCompensatorPlate,
            len("width", inch), len("height", inch), thickness, CatalogGlass()))
    group!("Prisms",
        ("Right-angle prism", :prism, RightAnglePrism,
            len("leg length", inch), len("height", inch), CatalogGlass()))
    group!("Polarizers",
        ("Polarization filter", :polarization_filter, PolarizationFilter, len("edge length", inch)),
        ("Round filter", :polarizer, RoundPolarizationFilter, diameter),
        ("Linear polarizer", :linear_polarizer, RoundLinearPolarizer,
            diameter, len("front thickness", 1e-3), len("back thickness", 1e-3), CatalogGlass()))
    group!("Detectors",
        ("Detector", :detector, Detector, len("edge length", 10e-3)))
    return entries
end
