Step 4: track types and feel
Design reference: `docs/design.md` (Track types section).

## Scope
- [ ] Type mono / chord / drums with a `voices` param (chord 2–8, drums 1–8 lanes)
- [ ] Chord: voicing from the current chord or scale with voice leading (smallest total movement)
- [ ] Drums: per lane note (GM defaults) and role kick / snare / hat / perc, with role-based rank maps. Drums ignore harmony
- [ ] `fixed gate` on/off (random per-step length vs gate %)
- [ ] `velocity` on/off (fixed `vel` vs `vel` ± `vel spread`)
- [ ] `legato` off / random / all; `legato prob` sets per-step flags at roll time (saved with the slot); legato note-off is sent just after the next note-on
- [ ] `restart` off / 1 / 2 / 4 / 8 / 16 bars of the master clock; `beats per bar`
- [ ] Default templates: T1 drums, T3 chord

## Test by ear
- [ ] Pad voicings change smoothly between chords
- [ ] Drums thin musically as the fader goes down (kick and backbeat stay longest)
- [ ] Mono synth slides on legato steps in random mode, on every step in all mode, and never in off mode
- [ ] Restart realigns polymetric tracks on the bar
