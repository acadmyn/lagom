# lagom: notes for agents

lagom is a norns (Lua) generative MIDI sequencer: 8 tracks that stay in harmony, played from an Akai MIDImix and sent to hardware synths.

- **Every product decision** is in `docs/design.md`. Read it before changing behavior. It came from a long interview with the user, so don't re-ask settled questions.
- **Build plan**: GitHub issues #1–#7 (one per step) and #8–#9 (later). The issue bodies are mirrored in `tools/issues/`.
- **Visual mockups** (private to the user): https://claude.ai/artifact/Hjxc1w5SiS565Vyx37METb. The source of truth is `docs/design.md`.

## Workflow (the user expects this)

1. Implement **one step (issue) at a time**, in small increments.
2. Deploy with `tools/deploy.sh`. It rsyncs to `we@norns.tretiotre.local:~/dust/code/lagom` and reloads the script through `tools/repl.py`, which prints matron output. Look for `lagom: init ok` and the absence of errors or `MISSING INCLUDE`.
3. Smoke-test from the REPL: `python3 tools/repl.py 'print(_lagom.tracks[1].pos)'`. The `_lagom` global exposes tracks, C (clockio), Seq, Out, Mix, H, Cd, Learn, S, Confirm and UI. The REPL runs **each line as its own chunk**, so keep `local`s and multi-statement snippets on one line. Simulate the MIDImix with `_lagom.Mix.event({0xB0, cc, val})`. Screenshot with `screen.export_screenshot("name")` (lands in `~/dust/data/lagom/name.png`). A script load wipes user globals, so never keep a REPL patch of a core function (e.g. a saved original `clock.run`) in a global; store it on the module table, and undo it afterwards.
4. Give the user a **"test by ear" checklist**, then wait for their feedback before the next step.
5. Commit, push, comment on or close issues, and merge PRs; the user allows all of these without asking. Commit messages end with the attribution lines from the system reminder.

## Hardware facts (verified)

- norns shield XL, Pi 4, norns 260102, Raspbian bullseye, Lua 5.3.
- **MIDI devices** (vports): 1 = MIDI Mix, 2 = OP-1, 3 = Waldorf Protein, 4 = `virtual` (the TRS jacks, through ttymidi), 5 = Analog Sweden SWEN2. norns keeps vports by device name, so swapping USB sockets doesn't change them. Since 2026-11-20 the synths sit on a powered USB hub: SWEN2 = bass (T2, ch 1), Protein = poly (T3, ch 2), OP-1 = poly (T4, ch 1), drums (T1) off.
- **TRS MIDI** needs an ALSA connection between ttymidi (client `shieldXL`) and matron's `virtual` port. Nothing on the norns makes it, so `lib/trs.lua` does at init (matron opens `virtual` twice and keeps the newer client). lagom must work on any norns, so never fix things with system services or config. Loopback (TRS out → TRS in, `tools/midi_loopback.lua`): about 2.1 ms round trip, ±0.2 ms jitter, no losses, bursts at wire speed (0.96 ms per note). The user plans to move every synth except the OP-1 to TRS (USB power).
- **Restarting the norns software:** never restart `norns-matron` alone, because it starts before JACK is ready and exits. Use `sudo systemctl stop "norns-*"; sudo systemctl start norns.target` (the same as `~/norns/stop.sh` + `start.sh`).
- **Protein**: Receive Channel **2** (the user wants 2). Now played as a single instrument (one poly track on ch 2). Earlier it ran in Multi mode with **Midi Split** (layers A–D = channels 2–5, sharing 8 voices).
- **USB power**: the Pi 4 supplies about 1.2 A total across its USB ports. It can't power the Protein and the Analog Sweden SWEN2 together (the SWEN2 alone is roughly 1.5–2 A), so they run from a powered hub.
- **Matron holds MIDI devices exclusively**, so `amidi` and `aseqdump` can't open them. To sniff MIDI, hook `midi.devices[id].event` from the REPL instead.
- **The MIDImix map** (factory preset, channel 1) is in `docs/design.md`. The mute, rec arm and BANK LEDs respond to note-ons; SOLO has no LED. Knobs send absolute values.
- **Realtime bytes** (`F8 FA FB FC`) reach Lua `event` callbacks as well as the system clock. lagom's slave thru relies on this (see `matron/src/device/device_midi.c`).
- **The system "midi clock out"** sends only `F8`, never Start/Stop. lagom sends its own clock instead.
- **External MIDI Start**: the norns clock reports beat 0 on the first `F8` after `FA` (`clock_midi.c`). `Seq.catch_up()` covers the race between the transport callback and the tick loop.
- **Pixel font** for the UI: `screen.font_face(25)` (`bmp/tom-thumb`).
- Check APIs against the source on the device (`~/norns/lua/core`, `~/norns/lua/lib`, `~/norns/matron/src`) rather than from memory.

## Code layout

- `lagom.lua`: init, params, keys, temporary step 1 screen.
- `lib/const.lua`: PPQN = 48, divisions.
- `lib/seq.lua`: the single tick loop (clock.sync 1/48) covering note-offs, clock out and track steps. **All timing goes through here.** Don't add per-track clock coroutines.
- `lib/clockio.lua`: master/slave, thru, clock out ports, the `play` param, transport callbacks.
- `lib/track.lua`: step data (pitch, velocity and gate seeds, rank), density ordering, step playback. For now it uses a fixed C major pool; that's replaced in step 3.
- `lib/out.lua`: port connections, note-on/off with overlap counting, panic.
- `lib/slots.lua`: slots, working copy vs anchor, drift/gravity, undo, pending (next bar) actions, export/import.
- `lib/midimix.lua`, `lib/harmony.lua`, `lib/conductor.lua`, `lib/learn.lua` (drum note learn).
- `lib/store.lua`: sets (`<data>/lagom-NN.set` next to each pset), autosave (`<data>/autosave.set`, includes lagom's params, restored at boot), scenes. Background saves yield between slots so the tick loop never stalls (>6 ms).
- `lib/confirm.lua`: K3/K2 dialogs.
- Fields set on `params` itself (e.g. wrapping `params.read`) survive `params:clear()` and stack across reloads; `S.unhook()` removes them in `cleanup()`.
- `lib/ui.lua`: pages, overlays, flashes. Draws into a Lua framebuffer (built-in 3×5 font) and sends it with one `screen.poke` per frame.
- **Timing rules (measured in step 7):**
  - Never call `screen.text_extents`, `screen.peek` or `screen.current_point` in the draw loop; they wait for the screen thread. Keep `screen.*` calls per frame to a handful, since each one takes a lock shared with the screen thread.
  - The automatic Lua GC is stopped while lagom runs; `seq.lua` runs `collectgarbage("step")` after each tick, and `Seq.cleanup()` restarts it. Avoid per-frame allocations in drawing code.
- **Keep `cleanup()` fast (a few ms).** norns cancels its own clock threads only after it, and a wake-up queued meanwhile errors on resume (#17). lagom stops its coroutines first, saves with warm caches, and briefly guards `clock.resume`. Call `Track:touch()` (never set `dirty` directly) whenever step data or shape changes: the save cache keys the current slot on its revision.
- `include()` re-runs the file each time, so each module is included once in `lagom.lua` and passed by reference (`const.lua` is the exception, since it's stateless).
- Never name a module or global `engine`; that name belongs to the norns audio engine.
