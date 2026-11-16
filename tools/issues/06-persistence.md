Step 6: persistence, sets and scenes
Design reference: `docs/design.md` (Persistence section).

## Scope
- [ ] A set file (8 tracks × 16 slots with working copies and anchors, the conductor, scenes) bound to the norns pset number via `params.action_write/read/delete`
- [ ] Autosave of working copies on slot change, on script exit and every 30 s; restored at boot
- [ ] Scenes 1–8: store and recall every track's slot number (recall lands on the next bar)
- [ ] Confirmations on the norns screen (K3 yes / K2 no) before:
  - loading a set while anchors are unsaved
  - clearing a slot
  - overwriting a set
  - the undo history dropping a version that was never saved

## Test by ear
- [ ] Reboot the norns mid-jam and pick up exactly where you left off
- [ ] Recalling a scene switches every track to its stored slot on the next bar
