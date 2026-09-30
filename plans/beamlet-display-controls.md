# Beamlet display controls: generating beams, polarization curve sliders

**Status:** approved · **Tier:** short

## Goal

Cards of Gaussian and astigmatic Gaussian beamlets get a toggle "beams" (BMO's `show_beams`, the
generating rays); cards of polarized beams get two sliders for the drawn polarization curve: its
wavelength and its amplitude.

## Change map

| Path | Change |
|---|---|
| `src/LiveBeamOverlays.jl` | new: generating-beams overlay (`show_beams`), same pattern as the polarization overlay |
| `src/LivePolarization.jl` | edit: overlay kwargs from the slider values; a slider change rebuilds the overlay |
| `src/LiveView.jl` | edit: `_BeamState` fields for the new overlays and slider values; `show_beams` of `beam_kwargs` becomes the initial toggle state (stripped from the main handle like `show_polarization`) |
| `src/LiveTrace.jl`, `src/LiveBeamSwitch.jl`, `src/LiveClip.jl` | edit: the new overlays in `_all_beam_handles`, update, dim, clip, on/off like the polarization overlay |
| `src/LiveCardRows.jl`, `src/API.jl` | edit: rows in `beam_card_rows`, docstring |
| `test/TestLiveBeamOverlays.jl`, `test/TestLivePolarization.jl`, `test/TestLiveCardRows.jl`, `test/runtests.jl` | new / edit |
| `docs/src/live_view.md`, `skills/beamletopticsgui/VISUALIZATION.md`, `WIDGETS.md` | edit |

BMO already has everything: `show_beams` (GaussianBeamlet, AstigmaticGaussianBeamlet: one
`linesegments` plot per group chief/divergence/waist), `pol_λ` (visualization wavelength, default
plotted length / 20), `pol_amplitude` (rays, [m], default `pol_λ / 4`, hence the curve shrinks
with the wavelength) and `pol_scale` (astigmatic beamlets, × beam radius). No BMO change.

## API delta

No new export or keyword. `beam_card_rows(b)` returns more widgets (toggle `:show_beams` for
Gaussian beamlets and their groups; sliders `:pol_wavelength`, `:pol_amplitude` for polarizable
beams); `beam_kwargs` keys `show_beams`, `pol_λ`, `pol_amplitude`, `pol_scale` set the initial
values of these widgets.

## Acceptance

- [ ] `test/TestLiveBeamOverlays.jl` passes (both layouts): toggle "beams" on a `GaussianBeamlet`
  and an `AstigmaticGaussianBeamlet` adds visible `LineSegments` plots (3 groups), removes them on
  "off"; they follow a move + solve; hidden while the beam is off; clipped with `clip_beams`;
  `beam_kwargs = Dict(g => (; show_beams = true))` starts with the toggle on and the main handle
  without generating rays
- [ ] `test/TestLivePolarization.jl`: the λ slider changes the period of the drawn curve (count of
  zero crossings of the transverse offset along the beam ×2 when λ is halved, ±1), the amplitude
  slider changes the maximum offset and is independent of the λ slider; nothing is solved
- [ ] `test/TestLiveCardRows.jl`: rows and widget names per beam type
- [ ] Full suite `julia --project=test test/runtests.jl` passes; no change to BMO or `Project.toml`

## Decisions

**D1 — How "beams" is drawn:** a) an overlay handle like the polarization curve: the beamlet
rendered again with `show_beams = true` and the kwargs of the main handle (`_beam_style` and the
user's `beam_kwargs`, e.g. `show_pos`, `transparency`), only its generating-beam plots
(`LineSegments`, and `Scatter` of `show_pos`) visible, envelope at coarse `r_res`/`z_res`. Main
envelope + overlay must look like the static `render!(ax, g; show_beams = true)` (chosen)

**D2 — "beams" on beamlet groups:** a) only the central beamlet, like the polarization curve
(chosen)

**D3 — Units of the two sliders:** a) absolute, logarithmic: "λ" in mm from extent/2000 to
extent/2 (extent = size of the scene), "amp" in mm (rays, `pol_amplitude`) or × beam radius
(astigmatic beamlets, `pol_scale`); start values λ = extent/40, amp = λ/4 resp. 1×, unless
`beam_kwargs` give `pol_λ`, `pol_amplitude`, `pol_scale` (chosen)

**D4 — Place on the card:** a) the toggle "beams" in the row `beam` next to "on"; the sliders in
two rows `pol λ` and `pol amp` with the value as text, only on cards of polarizable beams, also
while the curve is off (the value is kept for the next "on") (chosen)

<details>
<summary>Rationale</summary>

- Rejected (do not implement): D1 b) recreate the main handle (dimming, clipping, picking and
  tree state would have to move to the new handle); D2 b) every rendered beamlet (clutter, cost),
  D2 c) no toggle on groups; D3 b) factors of BMO's defaults (the GUI would redo BMO's
  plotted-length rule per type), D3 c) a BMO keyword `pol_periods` (waits for a release); D4 b)
  a separate controls panel.
- Slider ranges are static in the card declarations, hence the sliders run over 0…1 and `value`
  and `on` map that logarithmically to the length range of the `gui` (they get the `gui`).
</details>
