Step 3: harmony and the conductor
Design reference: `docs/design.md` (Harmony section).

## Scope
- [ ] `lib/harmony.lua`: root and scale params (musicutil scales; changes land on the next bar)
- [ ] Seed → note mapping through a note pool built from tension, range and base note
- [ ] Tension levels root / 5th / chord / scale (strong beats biased to chord tones) / color
- [ ] `lib/conductor.lua`: a loop of 2–8 chords; progression drone / markov / presets; chord rate 1/2/4/8 bars
- [ ] Conductor working copy and anchor; harmony drift and gravity; re-roll progression
- [ ] BANK RIGHT tap = next chord (next bar); hold = home (chord 1, conductor reverts to its anchor)
- [ ] SOLO + BANK RIGHT hold = save the progression; SOLO + BANK RIGHT tap = play/stop
- [ ] Default templates: T2 bass (5th), T4 lead (scale), T5–T8 mono (scale)

## Test by ear
- [ ] A bass on `5th` and a lead on `scale` move together through chord changes without clashes
- [ ] Turning range re-voices the phrase instead of scrambling it
- [ ] BANK RIGHT pushes the harmony forward on the bar; holding it comes home
- [ ] A scale or root change lands cleanly on the next bar
