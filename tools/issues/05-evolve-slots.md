Step 5: evolution, slots, save, revert and undo
Design reference: `docs/design.md` (Core model and MIDImix sections).

## Scope
- [ ] 16 slots per track; each slot holds the steps plus length, division, range, drift, gravity and gate
- [ ] Working copy and anchor per slot; an unsaved state (working ≠ anchor)
- [ ] Rec arm tap = re-roll (next bar); hold ≥ 0.6 s = save (working copy → anchor); SAVED overlay
- [ ] SOLO + Mute = next slot, SOLO + Rec arm = previous slot (next bar); an empty slot generates a fresh sequence
- [ ] Drift (Turing Machine style, on the working copy) and gravity (snap back to the anchor); motif size 0–8 immune to drift
- [ ] BANK LEFT held = alternate knob layer (drift / gravity / gate); BANK LEFT + Rec arm = revert; BANK LEFT + Mute = undo
- [ ] Undo history of 16 steps per track
- [ ] SOLO + BANK LEFT hold = save all tracks
- [ ] Pickup on all knobs, with a screen hint showing the stored value and an arrow toward the knob position
- [ ] Rec arm LEDs: off = saved, on = unsaved, blinking = waiting for the next bar. BANK LED states

## Test by ear
- [ ] With drift high and gravity high, a phrase wanders and comes home. Drift 0 freezes it
- [ ] With a fader low you hear only the motif, which stays recognizable while drift runs
- [ ] Re-rolls and slot changes land exactly on the bar
- [ ] Loading a slot restores its length, division and range; knobs do nothing until they pass the stored value
- [ ] Revert brings back exactly the saved sequence
