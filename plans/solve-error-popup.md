# Solve error popup

**Status:** implemented · **Tier:** short

## Goal

A failed solve opens a message in the 3D view; a detector hit by two kinds of beams (e.g.
polarized and unpolarized rays, which BMO rejects by design) gets a readable explanation that
names the detector and the two kinds.

## Change map

| Path | Change |
|---|---|
| `src/LiveSolveError.jl` | new: `_SolveError <: _InfoItem`, recognition of the hit-kind conflict, message text |
| `src/LiveTrace.jl` | edit: `_fail!` shows the message, `_finish!`/`_apply!` close it after a successful solve |
| `src/LiveInfo.jl` | edit only if `_InfoItem` needs a hook for a card without a pin (see D3) |
| `src/BeamletOpticsGUI.jl` | edit: include the new file |
| `test/TestLiveSolveError.jl`, `test/runtests.jl` | new, include |
| `docs/src/live_view.md` ("Manual tracing"), `skills/beamletopticsgui/VISUALIZATION.md` | edit: one paragraph |

Today: `_fail!` (LiveTrace.jl:303) logs the error once (`_log_once`), dims the beams and sets the
status line to "solving the systems failed, see the log". That stays; the message is added.

## Acceptance

- [ ] `test/TestLiveSolveError.jl` passes, in both layouts (`:compact`, `:app`):
  - a `Beam` and a polarized `Beam` (`Beam(pos, dir, λ, E0)`) on one `Detector`: after
    `live_view` a message card is shown at the detector; its text contains the label of the
    detector, "rays" and "polarized rays"
  - `_set_beam_on!(gui, polarized, false)` → the solve succeeds and the card is closed
  - the same failure again (a move while the conflict stays) does not reopen a card closed by
    `Esc` (D4); a different error does
  - a generic failure (`gui.pairs[1] = sys => nothing`, as in TestLiveView "failed solve keeps
    the beams outdated") shows a card with the first line of the error message
- [ ] `test/TestLiveView.jl`, `test/TestLiveBeamSwitch.jl`, `test/TestLiveProgress.jl` pass
  unchanged
- [ ] No change to BMO, `Project.toml` or the public API (no new export, no new keyword)
- [ ] Full suite `julia --project=test test/runtests.jl` passes

## Decisions

**D1 — Which errors open a message:** b) every failed solve; the hit-kind conflict with its own
text, other errors with the first line of their message and "see the log"; cancelled solves
(`Esc`) never open a message (chosen)

**D2 — How the conflict is recognized:** a) after the failure: the error is a `MethodError` of
`convert` to a subtype of `BMO.AbstractDetectorHit`; the detector is the one (among the detectors
of the systems) whose `hits` already have that type, the second kind comes from the rejected hit;
otherwise the generic message of D1 (chosen)

**D3 — Form of the message:** a) an info card like the beam inspection and the measurement
(`_InfoItem`, LiveInfo.jl): title "Solve failed", attached to the detector (to the first source
marker if no detector is known), in the app layout docked like the other info cards; no pin
(chosen)

**D4 — Repetition while moving:** a) one message per distinct error text: `Esc`, a click
elsewhere or a successful solve closes it; the same error does not reopen it until a solve
succeeded or the text changes (chosen)

<details>
<summary>Rationale</summary>

- Rejected (do not implement): D1 a) only the conflict; D2 b) check before each solve (false
  alarms when the beams hit different detectors); D2 c) a descriptive error in BMO's
  `push!(::Detector, hit)` (needs a BMO release; can follow later, D2 a) stays as fallback);
  D3 b) own message box in the middle of the view; D3 c) status line only; D4 b) reopen on
  every failure.
</details>

## Details

<details>
<summary>Deviations</summary>

- The initial solve of `live_view` is wrapped in `try`/`catch` → `_fail!`: `live_view` no longer
  throws when the first solve fails, the window opens with the message.
- New icon `:warning` (own design) for the card head; it is also a valid `add_tool!` icon.
- The pin and the dock button of the message card close it (`_keepable`), instead of keeping it.
</details>
