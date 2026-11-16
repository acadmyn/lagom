Step 2: 8 tracks and the MIDImix basics
Design reference: `docs/design.md` (MIDImix and Core model sections).

## Scope
- [ ] All 8 tracks active, each with its own port and channel
- [ ] `lib/midimix.lua`: input map for the factory preset (channel 1) and a `controller port` param
- [ ] Faders 1–8 = track density by rank. Fader 9 = bipolar global offset with a deadzone param (default ±6%)
- [ ] Mute buttons toggle mute instantly (hanging notes get a note-off); mute LEDs
- [ ] Knobs: top = range, middle = division, bottom = length (pickup comes in step 5 with slots)
- [ ] SEND ALL syncs control positions at boot (boot screen hint)
- [ ] Every control is also a norns param (MIDI-mappable)

## Test by ear
- [ ] Raising a fader adds notes, and lowering it removes the same notes in reverse order
- [ ] Fader 9: the middle (deadzone) changes nothing, down thins every track, up fills every track
- [ ] Different lengths give polymeters, and triplet divisions sit right against straight ones
- [ ] Mute is instant, with no stuck notes
