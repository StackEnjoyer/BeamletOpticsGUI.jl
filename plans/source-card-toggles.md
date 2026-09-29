# Source card toggles: beam on/off, polarization, ray count

**Status:** implemented · **Tier:** full

## Goal

Cards of all beams, beamlets and beam groups get an on/off toggle (trace and display) and, for
polarized beams, a polarization toggle; `live_view` gets `beams_off` and `auto_trace = false` skips
the initial solve; the ray slider stays as it is.

## What exists already

- **Auto trace:** `live_view(...; auto_trace = false)` and the toolbar toggle "auto trace"
  (`gui.trace.auto`, LiveView.jl:722, LiveLayout.jl:244). The initial solve always runs.
- **Ray slider:** `card_rows(::Union{CollimatedSource, PointSource})` with `_ray_rows`
  (LiveCardRows.jl:56, 213-245), for sources whose rays BMO can regenerate (`min_num_rays` not
  `nothing`): ring and sunflower sources. Wrapped groups (`NoSampling`, which includes every
  polarized ray group) and `AstigmaticBeamGroup` have no `set_num_rays!` in BMO.
- **Source markers** are separate object handles; the "sources" toggle and the card action "hide"
  hide only markers (LiveSelection.jl:295-350). Beams themselves are never hidden today.
- BMO draws polarization for **every rendered beam** of a group (`render_every` is the only
  selector) and stores the kwargs in the draw closures, so a handle can not change them later.

## Change map

| Path | Change |
|---|---|
| `src/LiveView.jl` | edit: `_BeamState` field `beams` in `LiveView`, initial state from `beam_kwargs` |
| `src/LiveBeamSwitch.jl` | new: on/off state and `_set_beam_on!` |
| `src/LiveTrace.jl` | edit: skip beams that are off, one iterator for all beam plots |
| `src/LiveMeasure.jl` | edit: `_inspect_beam` skips beams that are off |
| `src/LivePolarization.jl` | new: polarizability, central beam, polarization overlay handles |
| `src/LiveClip.jl` | edit: clip overlays like beams |
| `src/LiveCardRows.jl` | edit: `beam_card_rows`, rows for all beam types, ray count of enabled beams |
| `src/BeamletOpticsGUI.jl`, `src/API.jl` | edit: include the new files, export and document `beam_card_rows` |
| `test/TestLiveBeamSwitch.jl`, `test/TestLivePolarization.jl` | new |
| `test/TestLiveCard.jl`, `test/TestLiveCardRows.jl`, `test/runtests.jl` | edit: row counts, includes |
| `docs/src/live_view.md`, `docs/src/widgets.md`, `skills/beamletopticsgui/*` | edit |

## API delta

```diff
+ beam_card_rows(x) -> Tuple{Vararg{CardRow}}      # exported, like pose_card_rows
+ card_rows(b::Union{BMO.AbstractBeam, BMO.AbstractBeamGroup})       # new method
  card_rows(src::Union{BMO.CollimatedSource, BMO.PointSource})       # + beam_card_rows rows
  card_rows(g::BMO.GaussianBeamlet)                                  # + beam_card_rows rows
  live_view(pairs...; beam_kwargs = Dict(), ...)   # :show_polarization in beam_kwargs sets the
                                                   # initial polarization toggle (see D3)
+ live_view(pairs...; beams_off = (), ...)         # beams listed start off (D7)
  live_view(pairs...; auto_trace = false, ...)     # now also skips the initial solve (D2)
```

| Symbol | Status | Breaking | Call sites |
|---|---|---|---|
| `beam_card_rows(x)` | new, exported | no | card_rows methods of beam types, user beam types |
| `card_rows(::Union{AbstractBeam, AbstractBeamGroup})` | new method | no: beams had the pose-only fallback | card building |
| `card_rows(::Union{CollimatedSource, PointSource})`, `card_rows(::GaussianBeamlet)` | more rows | no | card building, row-count tests |
| `live_view(...; beams_off)` | new keyword | no | user scripts |
| `live_view(...; auto_trace = false)` | behavior: no initial solve | yes, visible: the view starts untraced | 5 tests (see W1), docs |
| `LiveView.beams::_BeamState` | new internal field | no | W1, W2 |

Internal interfaces fixed here, so W1 and W2 need not wait for each other's code:

```text
struct _BeamState                       # LiveView.jl, added by W1
    off::Base.IdSet{Any}                # beams (objects in last.(gui.pairs)) that are off
    pol::IdDict{Any, Any}               # beam => polarization overlay handle (W2 fills it)
    pol_kwargs::IdDict{Any, NamedTuple} # beam => kwargs of its overlay (from beam_kwargs)
end
_beam_on(gui, beam)::Bool               # W1
_set_beam_on!(gui, beam, on::Bool)      # W1
_all_beam_handles(gui)                  # W1: beam_handles and values(gui.beams.pol)
_polarizable(beam)::Bool                # W2
_polarization_on(gui, beam)::Bool       # W2
_set_polarization!(gui, beam, on::Bool) # W2
_init_polarization!(gui)                # W2, called by the integration at the end of live_view
```

## Workstreams

| W  | Owns | Needs | Executor | Summary |
|----|------|-------|----------|---------|
| W1 | `src/LiveBeamSwitch.jl`, `src/LiveTrace.jl`, `src/LiveMeasure.jl`, `src/LiveView.jl`, `test/TestLiveBeamSwitch.jl` | – | opus | on/off: skip in trace, hide plots, state |
| W2 | `src/LivePolarization.jl`, `src/LiveClip.jl`, `test/TestLivePolarization.jl` | W1 | opus | polarization overlay handles, central beam |
| –  | `src/LiveCardRows.jl`, `src/BeamletOpticsGUI.jl`, `src/API.jl`, `test/runtests.jl`, `test/TestLiveCard.jl`, `test/TestLiveCardRows.jl`, docs, skill | W1, W2 | lead | card rows, export, docs, full suite |

W1, W2 and the integration run one after the other, e.g. by a single agent.

## Acceptance

W1
- [ ] `test/TestLiveBeamSwitch.jl` passes; it checks for a system with two sources:
  - off: the beam is not traced (`isempty(rays(...))` or all group beams empty), its plots have
    `visible[] == false`, detector hits come from the other source only, its marker stays visible
  - on again: traced and visible; with `auto_trace = false` the toggle marks the trace stale
    instead of solving
  - all beams off: solving does not throw, the status line stays valid
  - `_inspect_beam` ignores beams that are off
  - `beams_off = [src]` starts with `src` off (not traced, hidden); a beam in `beams_off` that is
    not in the pairs throws an `ArgumentError`
  - `auto_trace = false`: no solve at start (beams untraced, detectors empty), trace stale with
    the status "not traced, press t to trace"; `t` or switching auto trace on traces
- [ ] `test/TestLiveView.jl`, `test/TestLiveCustom.jl` and `test/TestLiveProgress.jl` pass; the
  tests with `auto_trace = false` (TestLiveView.jl:578, 607, 682, 1713; TestLiveCustom.jl:151)
  are adapted only where they relied on the initial solve, e.g. by calling `_trace!(gui)` first

W2
- [ ] `test/TestLivePolarization.jl` passes; it checks:
  - `_polarizable` is true for `Beam{T, PolarizedRay}`, `AstigmaticGaussianBeamlet`,
    `AstigmaticBeamGroup`, groups of `PolarizedRay` beams; false for `Beam{T, Ray}`,
    `GaussianBeamlet`, ring/sunflower sources
  - toggle on: exactly one extra visible `Lines` plot; for a group it follows the central beam only
    (D4), after `solve` and `update_render!` it matches the moved beam
  - toggle off: the overlay's plots are deleted from the scene, `gui.beams.pol` has no entry
  - `beam_kwargs = Dict(b => (; show_polarization = true))` starts with the toggle on and the main
    handle draws no polarization curve
  - clip beams applies to the overlay; a beam that is off hides its overlay
- [ ] `test/TestLiveClip*` (clip tests in `test/TestLiveExtras.jl`) pass unchanged

Integration
- [ ] Cards: every beam type has the row `beam` with the toggle `:beam_on`; polarizable ones also
  `:polarization`; ray sources keep `:rays` and `:ray_count`
- [ ] `beam_card_rows` exported, docstring in `src/API.jl`, listed in `docs/src/widgets.md` and the
  skill export table (`test/TestAgentSkill.jl` passes)
- [ ] `docs/src/live_view.md` rows table (around line 323) describes the new rows
- [ ] Full suite `julia --project=. -e 'using Pkg; Pkg.test()'` passes
- [ ] No change to BMO, `Project.toml` or the compat entries

## Decisions

**D1 — Meaning of "off":** b) not traced and hidden; its old rays are emptied, so detectors and
measurements ignore it; the source marker stays (chosen)

**D2 — Auto trace:** b) with `auto_trace = false` the view also skips the initial solve and starts
untraced, marked stale ("not traced, press t to trace") (chosen)

**D3 — How the polarization toggle draws:** a) a separate overlay handle per toggled beam, created
on "on", removed on "off"; the main beam handle is never touched; no BMO change (chosen)

**D4 — Central beam of a group:** b) the beam whose start is nearest the group axis, ties broken
by the smallest angle to the group direction (chosen)

**D5 — Ray slider for beam groups:** a) keep the existing slider for sources BMO can regenerate;
no slider for wrapped or beamlet groups (chosen)

**D6 — Custom beam types:** a) export `beam_card_rows(x)` (like `pose_card_rows`) (chosen)

**D7 — Initial on/off state:** b) a `live_view` keyword `beams_off = ()`: beams listed there start
off (chosen)

## Details

<details>
<summary>W1 — beam on/off</summary>

Intent: a beam that is off is neither traced nor drawn, everything else behaves as if it were not
in the view, except its source marker.

1. `src/LiveView.jl`: define `_BeamState` (API delta; `Base.@kwdef`, empty defaults) and the
   field `beams::_BeamState = _BeamState()` in `LiveView`. Fill `pol_kwargs` for each beam from
   `beam_kwargs`: the user's kwargs minus `render_every` (W2 uses them for the overlay). Strip
   `:show_polarization` from the kwargs passed to the main `live_render!` (LiveView.jl:770) and
   keep it in `pol_kwargs[beam]` as the initial toggle state. The call of W2's
   `_init_polarization!(gui)` after the initial solve is added by the integration, so W1 runs
   without W2.
2. `src/LiveBeamSwitch.jl` (new):
   - `_beam_on(gui, beam) = !(beam in gui.beams.off)`
   - `_set_beam_on!(gui, beam, on)`: no-op if unchanged; update `off`; set `visible[]` of
     `render_plots` of every beam handle whose `rendered(h) === beam` (a beam can be in several
     pairs) and of `gui.beams.pol[beam]` if present; when off, empty the beam (`empty!` for beams,
     `foreach(empty!, BMO.beams(bg))` for groups, as `_solve_from_start!` does) and
     `update_render!` its handles so no stale geometry remains; then go through the solve path
     like `_set_num_rays!` (LiveCardRows.jl:236-244: `_change!` + `gui.controls.on_change(beam)`),
     so auto trace off only marks the trace stale.
   - `_all_beam_handles(gui)`: `gui.beam_handles` followed by `values(gui.beams.pol)`.
3. `src/LiveTrace.jl`: filter `pairs` and `handles` together where a job starts (`_start_job`,
   line 173; `_resolve!`, line 153) with `_beam_on`; keep `sinks`, anchors and panels aligned with
   the filtered lists. `_progress_anchor` and `_compute` must handle zero pairs. `_apply!`
   (line 106) updates `_all_beam_handles(gui)`, except handles of beams that are off.
   `_dim_beams!` and `_restore_beams!` iterate `_all_beam_handles(gui)`; `_restore_beams!` must
   skip plots that were deleted (overlay removed while stale).
4. `src/LiveMeasure.jl`: `_inspect_beam` (line 125-132) skips handles of beams that are off.
5. Do not touch `gui.objects.hidden`, the "hide" card action or `_set_show_sources!`: those are
   about markers and objects.
6. `_ray_count`/`_rays_text` belong to the integration (card text), not to W1.
7. D7, `live_view(...; beams_off = ())` (`src/LiveView.jl`, next to `beam_kwargs`): check that
   every entry is `===` a beam in `last.(pairs)`, else `ArgumentError`; put them into
   `gui.beams.off` and hide their plots before the initial solve, so they are never traced.
   Document it in the `live_view` docstring (keyword list near line 685).
8. D2, `src/LiveView.jl` ~847: run the initial `_resolve!(gui, nothing)` only if
   `gui.trace.auto[]`; otherwise `_mark_stale!(gui)` with the status "not traced, press t to
   trace". The first `t` (or switching auto trace on) traces via the existing `_trace!` path.
   Update the docstring (LiveView.jl:562-569, 670), `docs/src/live_view.md:213, 252` and
   `skills/beamletopticsgui/VISUALIZATION.md:75` in the integration step.

Tests (`test/TestLiveBeamSwitch.jl`, module `TestLiveBeamSwitch`, pattern of
`test/TestLiveCardRows.jl`: `_live_view` with `trace_budget = Inf, throttle = false`,
`preview = false`): call `_set_beam_on!` directly, the card row does not exist yet.
</details>

<details>
<summary>W2 — polarization overlay</summary>

Intent: one visible polarization curve per toggled beam; for groups only the central beam.

1. `_polarizable(::BMO.AbstractBeam{<:Any, <:BMO.PolarizedRay}) = true`,
   `_polarizable(::BMO.AbstractBeamGroup{<:Any, <:BMO.PolarizedRay}) = true`, `_polarizable(_) =
   false`. This covers `AstigmaticGaussianBeamlet` (always `PolarizedRay`) and excludes
   `GaussianBeamlet` (its `render!` would pass `show_polarization` on to `mesh!`).
2. `_central_beam(bg)` (D4 b): the axis runs through the mean start point of the beams along
   `BMO.orientation(bg)[:, 2]`; pick the beam with the smallest distance of its start point from
   that axis, ties (`≤ 1e-9` relative to the group size) broken by the smallest angle between
   its first ray direction and the axis. Single beams are their own target.
3. `_set_polarization!(gui, beam, on)`:
   - on: `live_render!(gui.ax, target; gui.beams.pol_kwargs[beam]..., show_polarization = true,
     clip_planes = Plane3f[])`, plus for astigmatic targets `r_res = 3, z_res = 2` (the hidden
     envelope is still computed on every update). Set `visible[] = false` on every plot of the
     handle that is not a `Makie.Lines`; the `Lines` plot follows `_beam_on(gui, beam)`. Store it
     in `gui.beams.pol[beam]`, then `_apply_clip_planes!(gui)`.
   - off: `remove_render!` and delete the entry; never `update_render!` a removed handle.
   - `_polarization_on(gui, beam) = haskey(gui.beams.pol, beam)`.
   - Display only: no solve, no stale marking.
4. `_init_polarization!(gui)`: turns on the overlays whose `pol_kwargs` have
   `show_polarization = true` (the integration calls it at the end of `live_view`). In the
   overlay's `live_render!`, drop that key from the splatted kwargs and pass
   `show_polarization = true` explicitly.
5. `src/LiveClip.jl`: `_apply_clip_planes!` (line 36) collects plots from `_all_beam_handles(gui)`.
6. The overlay of a group renders the central `Beam` object itself. `set_num_rays!` would replace
   it, but no polarized group has a ray slider (all are wrapped, `NoSampling`), so no re-sync is
   needed; state this in a comment at `_set_polarization!`.

Tests (`test/TestLivePolarization.jl`): polarized `Beam` via `Beam(pos, dir, λ, E0)`, a wrapped
`CollimatedSource` of such beams (center beam not first in the vector, so D4 is tested), an
`AstigmaticGaussianBeamlet` and a `SphericalGaussianBeamletSource`; count `Lines` plots in
`gui.ax.scene.plots` and check `visible`.
</details>

<details>
<summary>Integration (lead)</summary>

- `src/LiveCardRows.jl`:
  - `beam_card_rows(b)`: `CardRow("beam", CardWidget(Toggle; name = :beam_on, value = (gui, b) ->
    _beam_on(gui, b), on = (gui, b, v) -> _set_beam_on!(gui, b, v)), "on", pol...)` where `pol`
    is `CardWidget(Toggle; name = :polarization, ...), "polarization"` if `_polarizable(b)`.
    Pattern: `_panel_row()` in `src/LivePanels.jl:517-523`.
  - `card_rows(b::Union{BMO.AbstractBeam, BMO.AbstractBeamGroup}) = (pose_card_rows(b)...,
    beam_card_rows(b)...)`; the source and Gaussian methods add `beam_card_rows(...)` after the
    λ row. Check that no method ambiguity arises with `card_rows(obj::BMO.AbstractObject)`.
  - `_rays_text` and `_ray_count` count enabled beams only (`_beam_on`).
- `src/LiveView.jl`: call `_init_polarization!(gui)` after the initial solve (LiveView.jl ~847).
- `src/API.jl`: docstring of `beam_card_rows` next to `pose_card_rows`; export in
  `src/BeamletOpticsGUI.jl`; include the two new files after `LiveTrace.jl`.
- Tests: row counts in `test/TestLiveCard.jl` (e.g. line 648 pattern) and
  `test/TestLiveCardRows.jl`; card-level tests that flip `_w(c, :beam_on).active[]` and
  `_w(c, :polarization).active[]` in both layouts (pattern `test/TestLiveWidgetRecipe.jl`).
- Docs: rows table in `docs/src/live_view.md`, the untraced start with `auto_trace = false` (D2: `live_view` docstring LiveView.jl:562-569 and 670, `docs/src/live_view.md:213, 252`, `skills/beamletopticsgui/VISUALIZATION.md:75`), `beams_off` (D7), `beam_card_rows` in
  `docs/src/widgets.md` and the skill (`skills/beamletopticsgui/WIDGETS.md`, `API.md`).
</details>

<details>
<summary>Deviations</summary>

- W1: `_compute` takes a keyword `systems`; `_resolve!` and `_start_job` pass the systems of all
  pairs, so a system whose beams are all off loses its old detector hits too (D1).
- W1: with `auto_trace = false`, beams solved before `live_view` keep their rays (shown dimmed);
  a beam switched on while auto trace is off shows its start ray until `t`.
- W2: astigmatic overlays also drop `show_beams` and `show_waist`, so the overlay has exactly one
  visible `Lines` plot; an overlay created while the trace is stale is dimmed like the beams;
  `_set_polarization!(gui, b, true)` throws an `ArgumentError` for a beam that is not polarizable.
- Integration: `live_view` checks `show_polarization = true` in `beam_kwargs` against
  `_polarizable` before building the window (`ArgumentError`). `show_polarization = true` for a
  beam group now draws only its central beam (D3, D4), where BMO drew every rendered beam.
- Integration: the info label reads "not traced" before the first solve (`_update_info!`, also
  after a beam switch without a solve) and, like the system
  card, counts the rays of the beams that are on only.
- Row order: sources pose, `λ`, `beam`, `rays`; Gaussian beamlets pose, `λ`, `beam`.
- The full suite ran with `julia --project=test test/runtests.jl` (AGENTS.md), not `Pkg.test()`.
</details>

<details>
<summary>Rationale</summary>

- The overlay (D3 a) avoids both limits of BMO's handles: kwargs fixed at creation, and
  polarization drawn for every rendered beam of a group. Hiding the non-`Lines` plots of the
  overlay is cheap for rays; for astigmatic targets the coarse `r_res`/`z_res` keeps the hidden
  envelope small.
- Filtering pairs where the job starts, instead of inside `_compute`, keeps progress sinks,
  anchors and handles aligned by construction.
- Emptying a beam that is switched off prevents stale hits in detectors and stale segments in
  measurements.
- Rejected options of the decisions (do not implement): D1 a) hide only; D2 a) no change, c) a
  per-source auto trace toggle; D3 b) recreate the beam handle with a new BMO keyword; D4 a) the
  first beam; D5 b) a "every k-th beam" display slider, c) regeneration of beamlet groups in BMO;
  D6 b) no export; D7 a) no keyword.
- (rejected, do not implement) Hiding beams via `gui.objects.hidden`: that set drives the markers
  and the object tree and would couple beam display to the "sources" toggle.
</details>
