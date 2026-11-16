Step 7: screen UI polish and stress test
Design reference: `docs/design.md` (Screen section). Mockups (private): https://claude.ai/artifact/Hjxc1w5SiS565Vyx37METb

## Scope
- [ ] Main page: one row per track (glyph, step strip with pitch dots, motif underline, playhead, density bar with ghost tick, slot number + `*`), header (chord, progression dots, tempo, source, beat blip) and a fader 9 meter along the right edge
- [ ] Track, harmony (progression boxes and keyboard), clock/IO and scenes pages. E1 page, E2 select, E3 change, K2 back, K3 play/confirm
- [ ] Overlays: SAVED, the global meter on fader 9 movement, confirmations, the boot screen with the SEND ALL hint
- [ ] `bmp/tom-thumb` font; brief flashes on re-roll, slot change and chord change
- [ ] Stress test: 8 tracks at 1/32, 180 BPM, chords with 8 voices; measure timing jitter and tune the redraw rate

## Test by ear
- [ ] No audible timing change while the screen is busy
