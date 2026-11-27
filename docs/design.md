# lagom design

A norns script that runs 8 generative MIDI tracks which stay in harmony. It is played from an Akai MIDImix and sends to hardware synths.
The visual proposal with screen mockups is in a private artifact: https://claude.ai/artifact/Hjxc1w5SiS565Vyx37METb

## Core model

- **Seeds, not notes.** Each step stores a pitch seed (0–1), a velocity seed, a gate seed, a legato flag and a priority rank. The seed is mapped to a MIDI note only at play time, through the note pool allowed by the current chord, the track's tension and its range. Range, chord and tension changes therefore re-voice a phrase without scrambling it.
- **Density by rank.** Each of the 32 steps has a fixed rank. Density reveals steps in rank order, so 0 plays nothing and full plays every step. Track density is `clamp(track + global, 0, 1)`.
- **Global density (fader 9)** is bipolar from −100% to +100%, with a deadzone around the middle (default ±6%, adjustable 0–15%) that snaps to 0. It is drawn on screen.
- **Motif.** The top `motif size` ranks (0–8, default 4) are never changed by drift. With a fader low you hear only the motif; pushed up, you hear ornaments around it.
- **Slots.** Each track has 16 slots. A slot holds the 32 steps **and** length, division, range, drift, gravity, gate and the drum lanes' mode/hits/rotate, so loading a slot gives you exactly what you saved. Stepping onto an empty slot generates a fresh sequence.
- **Working copy vs anchor.** Each slot has a working copy (what plays) and an anchor (what was saved). Drift, re-roll and undo only touch the working copy. Saving is a deliberate action. "Unsaved" means working ≠ anchor. The working copy is autosaved to disk (on slot change, on exit, and every 30 s).
- **Drift and gravity (Turing Machine style).** Drift is the chance per pass that a non-motif step mutates. Gravity is the chance that a mutated step snaps back to its anchor value. Drift writes to the working copy permanently. Undo history: 16 steps per track, covering re-rolls, drift snapshots and reverts. When it is full the oldest entry drops silently (no confirmation; the user found it got in the way).
- **Pickup.** All knobs use pickup: after a slot change, a knob does nothing until it passes the stored value, then it follows. While a knob hasn't caught up, the pop-up shows the stored value, the knob's position and an arrow (see Screen). Press SEND ALL on the MIDImix at boot to sync it.

## Harmony

- A global `root` and `scale` (the musicutil list). Changes land on the next bar.
- **Conductor**: 16 **progression slots** (a song is a collection of slots, so harmony is slotted too). Each slot is a loop of 1–8 chords; each chord is a scale degree with an accidental (♭/♮/♯, relative to the scale's own degree), a quality, a transpose and its **own length** (1–8 bars). Each slot has its own working copy and anchor, plus `harmony drift` and `harmony gravity` (drift swaps a chord for a plain diatonic one, never touching lengths; gravity pulls back to the anchor chord).
  - `progression` = drone / markov / preset 1…n is the generator: it fills an empty slot and is what a re-roll (or changing `progression`) uses. `chord length` (param id `chord_rate`, 1/2/4/8 bars) is the length new chords get.
  - `chords` grows or shrinks the current loop (new chords: a markov step from the last one in markov mode, else a copy of it).
  - `progression slot` switches slots; the change lands on the next bar. There is no MIDImix control for it (user's choice): use the harmony page or scenes.
  - Qualities: `auto` (the diatonic triad; with ♭ it's major, with ♯ diminished), maj, min, dim, aug, sus2, sus4, 6, m6, 7, maj7, m7, m7♭5, dim7, mMaj7, 9, maj9, m9, 7♭9, 7♯9, 11 (no 3rd), 13. Chord tones have an importance order for voicing (root, 3rd, 7th/6th, extensions, 5th last).
  - **Transpose** (−14…+14 scale steps, 0 = off), like the Metropolix's in-scale transpose: the chord and the notes move N scale steps. I +2 plays as iii (accidental and quality carry over, so `auto` stays diatonic), and tracks that follow move their range by the same distance as the chord root, so +7 is the same chord an octave up. Tracks with `follow transpose` off ignore it entirely (untransposed chord and register; polychords allowed on purpose). Drift resets a mutated chord's transpose to 0; gravity restores the anchor's.
  - Labels: roman numeral with accidental, case (lowercase = minor 3rd), `o`/`+` and figure (`ii7`, `bVIIM7`), then the chord name. The key spells with flats when that gives its notes distinct letters (F minor: A♭, not G♯).
  - Markov mode uses weighted functional moves (tonic → subdominant/dominant → tonic, occasionally deceptive or modal moves).
- **Tension per track**: `root` / `5th` / `chord` / `scale` (strong beats biased to chord tones) / `color` (adds 7ths, 9ths and passing tones on weak beats). Tensions follow the chord:
  - `root` and `5th` use the chord's root and fifth; `chord` uses all its tones (an `auto` chord is a triad).
  - `scale` and `color` on weak beats use the **chord scale**: the scale plus the chord tones, where a scale note gives way when it's a semitone from a chord tone outside the scale, or is the note that chord tone was altered from (the 3rd under a sus4). Diatonic `auto` chords therefore sound exactly as before. `color` on strong beats adds the 7th and 9th the chord lacks, if they're in the chord scale.
- Default templates: T1 drums, T2 bass (5th), T3 chord, T4 lead (scale), T5–T8 mono (scale).

## Track types

- **mono**: 1 voice.
- **chord**: 2–8 voices stacked from the current chord or scale, with voice leading.
- **drums**: 1–8 lanes. Each lane has its own note (GM defaults 36 38 42 46 39 45 49 51), its own rhythm and a role: kick (downbeats rank first), snare (backbeats first), hat (8ths, then 16ths) or perc (random ranking). Lanes share the track's fader and channel. Drums ignore harmony. Each lane's `velocity` is `track` (the track's `vel`, ± `vel spread` when velocity is on) or a fixed 1–127 that the lane always plays (user, 2026-11-27). A euclid lane's `ghost vel` (off or 1–127) is the velocity of the hits drift added (steps flipped on from rests), for ghost notes around a steady pattern; the pattern's own hits keep the lane velocity.
  - **Fader layers**: each lane owns a stretch of the fader, `from`..`to` (defaults 0–100%, so every lane follows the whole fader). Below `from` the lane is silent; across the stretch it comes in step by step in rank order; above `to` it plays in full. `from` = `to` switches the whole lane on at that point. Example: kick 0–20, closed hat 20–40, open hat 40–60, perc 60–80, fill 80–100. 0% is always silent.
  - **Lane mode**: `rank` (as above; `max` = the lane's density at the top of its stretch) or `euclid`: `hits` spread evenly over the track length, rotated right by `rotate` (4 hits = steps 1 5 9 13; 4 hits rotate 2 = 3 7 11 15). Hits come in on the fader in rank order, so a kick builds 1, then 9, then 5 and 13.
  - **Euclid drift** (Turing Machine style): drift flips steps that are still on the pattern (hit ↔ rest) and stores the flip in the step data, so the variation repeats every pass. **Gravity pulls back to the plain euclid pattern** (not the anchor): every pass, each flipped step returns to the pattern with probability `gravity`, even at drift 0. Drift 0 + gravity up = the pattern comes home over a few bars; drift 0 + gravity 0 freezes the current variation. The motif is the first `motif size` hits, so with motif 4 a four-on-the-floor never loses a kick while extra kicks come and go. Flips are saved in the set files (the legato flag field: leg = 1, flip = 2, so older files still load).
  - **Per slot**: each lane's mode, hits and rotate are stored with the slot (like length and division), so slots can hold different euclid patterns. Slots saved before this took the lane settings current at the time. Note, role, max, from and to stay per-track params.
  - **norns port** (#37): when slagverk (acadmyn/slagverk) is installed, a drum track's port can be `17: norns`, the built-in drum machine (808/909 voices). A lane plays the voice(s) of the track's own kit whose note is the lane's note, as on a MIDI drum machine: each kit voice has a note, GM by default (36 BD, 38 SD, 42 CH, 46 OH, 39 clap, 45 tom, 49 cymbal/crash, 51 cowbell/ride), so lane notes pick the voice (decided by the user 2026-11-27; it replaced lane n = voice n). The lane note param shows the voice it plays. The channel is ignored; velocity passes through. The `kit` param loads a kit preset (808, 909, or a kit saved in slagverk). Each drum track on the norns port has its own kit, saved in the set (and autosave), not per slot. Without slagverk the option doesn't exist and lagom stays MIDI-only. Other track types on the norns port are silent.
- **poly**: 2–8 independent melodic lines on the track's channel (set the synth part to poly). Each voice has its own pitch, velocity and gate seeds, its own random rhythm ranking, legato flags and motif, and uses the whole range (voices may cross or meet). Voices share length, division, range, tension and the MIDImix knobs. The track fader brings voices in one by one: voice 1 follows the fader, and voice n starts at (n−1)/voices of the travel, so every voice is at full density only at the top. On screen, the track page draws one mark per voice at its pitch; the main strip shows the lowest-numbered voice that plays.
- **feel**:
  - `fixed gate` on/off: on = every note lasts `gate`; off = each step's gate seed picks a length between `gate min` and `gate max` (defaults 0.1 and 1 step). All three are in steps (0.05–8, shown as `0.5 st`), stored per slot, and may exceed one step, so notes can ring over the following ones. The track page shows `gate` or `gate min`/`gate max`, whichever applies.
  - `velocity` on/off: off = fixed `vel`, on = `vel` ± `vel spread`.
  - `legato` off / random / all. `random` sets a legato flag per step at roll time, with probability `legato prob` (default 25%); the flag is saved with the slot. Legato ties a note into the **next step that plays**, across any rests: its note-off is sent just after that step's note-on (or later, if its own gate is longer). If nothing else in the loop plays, the note keeps its normal gate.
- **shift left / right** (params, and the `shift` row on the track page with E3) rotates the first `length` steps of every lane by one; ranks move with their steps, so the motif and density order follow. Instant; consecutive shifts share one undo entry.
- **move slot earlier / later** (params, and the `move slot` row on the track page with E3) swaps the current slot with its neighbour, so repeated moves reorder slots like dragging an item in a list (8 → 2 pushes 2–7 up by one). The slot keeps playing, nothing is overwritten, and scenes follow the moved music.
- **copy to slot** (params `copy to slot` + `copy slot`, and the `copy to` row on the track page: E3 picks the target, K3 copies) duplicates the current slot (working copy, anchor and shape) into the target. Asks before overwriting a slot that has content.
- `length` 1–32. `division` 1/32 1/16T 1/16 1/8T 1/8 1/4T 1/4 1/2 1/1 2bar. `range` 1 semitone to 4 octaves above `base note`.
- `restart` off / 1 / 2 / 4 / 8 / 16 **bars of the master clock**, so polymeters can realign.

## Clock

- A single 48 PPQN tick loop drives clock out, every track and note-offs.
- **Master**: lagom sends clock plus Start/Stop to opted-in ports (`clock out → port n`). K3 or SOLO + BANK RIGHT toggles play.
- **Slave**: the system clock source is set to midi and listens only on `clock in port`. lagom forwards raw `F8 FA FB FC` to opted-in ports as a real thru, and follows external Start/Stop.
- Keep the norns system "midi clock out" **off** for ports lagom feeds, or those ports get doubled ticks. lagom warns about this.
- The 3.5 mm TRS jacks show up as the MIDI device `virtual` (through ttymidi) and must be assigned to a vport under SYSTEM › DEVICES › MIDI. Nothing connects ttymidi to matron by default, so lagom does it at init (`lib/trs.lua`); on a norns without ttymidi it does nothing.
- One DIN/TRS output carries about 1,000 notes per second, shared by every synth on it. Notes of one step go out one after another (about 1 ms each), so a busy step spreads over a few ms.

## MIDImix (factory preset, channel 1, verified on hardware)

| Control | Message | Action |
|---|---|---|
| Faders 1–8 | CC 19 23 27 31 49 53 57 61 | track density |
| Master fader | CC 62 | global density (bipolar) |
| Knobs, top row | CC 16 20 24 28 46 50 54 58 | range (alternate layer: drift); on the voice page P1–P8 |
| Knobs, middle row | CC 17 21 25 29 47 51 55 59 | division (alternate layer: gravity); on the voice page knobs 1–5 = Level, Tune, Pan, Choke, Tape |
| Knobs, bottom row | CC 18 22 26 30 48 52 56 60 | length (alternate layer: gate, 5%–8 steps, squared so the first third of the travel covers up to 1 step) |
| Mute 1–8 | notes 1 4 7 10 13 16 19 22 (LED) | mute toggle, instant |
| Solo held + Mute | notes 2 5 8 … 23 | next slot (lands on next bar) |
| Rec arm 1–8 | notes 3 6 9 … 24 (LED) | tap = re-roll (next bar), hold ≥ 0.6 s = **save** |
| Solo held + Rec arm | the same notes, with Solo known to be held | previous slot (next bar) |
| Solo | note 27 (no LED) | shift |
| Bank Left | note 25 (LED) | hold = alternate knob layer, + Rec arm = revert to anchor, + Mute = undo |
| Bank Right | note 26 (LED) | tap = next chord, hold = home (chord 1, conductor reverts to its anchor) |
| Solo + Bank Right | | tap = play/stop, hold = save the progression |
| Solo + Bank Left | | hold = save all tracks |
| Send All | sends every control's position | sync at boot |

**LEDs**
- Mute LED on = muted.
- Rec arm LED: off = matches the anchor, on = unsaved changes, blinking = a change is waiting for the next bar.
- Bank Left LED lights while the alternate layer is held. Bank Right blinks on chord changes.

## Screen

- 128×64 pixels, `bmp/tom-thumb` pixel font (face 25), brightness levels as depth.
- **E1** = page (main / track / harmony / clock / scenes). **E2** = select. **E3** = change. **K2** = back/cancel. **K3** = play/stop, or confirm in a dialog.
- **Main page**: one row per track, showing:
  - the track number and type glyph
  - a step strip that always spans the full width (short sequences get wider steps) with pitch as dot height (bright = playing, dim = hidden), the motif underlined, and an inverted playhead column
  - a density bar with a tick for the effective level
  - the slot number, with `*` for unsaved changes
- **Header**: chord, progression dots, tempo, clock source, beat blip. A fader 9 meter runs along the right edge.
- **Overlays**: SAVED, the global meter, confirmations (K3 yes / K2 no). Confirmations appear only on the norns, never blocking the MIDImix.
- **Fader/knob pop-up**: moving a track fader or knob shows a box like the global meter for 1 s: `T3 LENGTH`, the value large, and a bar over the param's range with min/max labels. While a knob hasn't picked up, the bar is dim, a blinking tick marks the knob's position, `KNOB > 26` says which way to turn it, and the box stays 1.5 s. Whichever of the master fader and a track control moved last is shown.
- **Pages** (as built in step 7):
  - main: E2 selects a track (its number is inverted), E3 steps its slot. Each row also shows length and division as numbers (the user asked for this).
  - track: the selected track's step graph (drums: one row per lane), then a param list (E2 select, E3 change, `clear slot` at the end).
  - harmony: the chord editor. Progression boxes, their width following each chord's length (at least 12 px), the current one filled with a bar-progress line under it, each box labelled with its numeral (plus figure and transpose when they fit, e.g. `ii7`, `i+2`), a dot per bar under each box; the header shows key and progression (presets as `P8`; header text is cut before the corner), the slot number top right (`*` = unsaved, blinking = pending). A two-octave keyboard (bright = chord tones, dim = chord scale, both as transposed), then one row. E2 steps through five stops per chord (degree, accidental, quality, transpose: bright frame around the box; length: its bar dots light up), then progression slot, chords, progression, re-roll, chord length, root, scale, harmony drift/gravity. E3 changes the selected item.
  - clock: big tempo, master/slave, playing, beat boxes, clock in/out, then a param list (tempo, mode, ports, beats per bar, controller port, clock out per connected port).
  - voice (only when slagverk is installed; E1 order main, track, voice, harmony, clock, scenes): slagverk's voice page for the kit of the selected track, or of the first drum track on the norns port. E2 picks a control, E3 changes it, K2 + E2 picks the voice, K2 + E3 the track (among drum tracks on the norns port), K3 plays the selected voice. While this page is shown, the MIDImix top knobs are P1–P8 and the middle knobs 1–5 are Level, Tune, Pan, Choke, Tape of the selected voice (with slagverk's pickup); faders, the bottom row and the buttons keep their track functions. Afterwards the track knobs that were used pick up again.
  - scenes: 8 boxes showing each track's slot as a bar. E2/E3 select, **K3 recall, K2 store** (asks before overwriting).
  - K2 on any page except main and scenes goes back to main (on release, so K2 can be held for a combo).
  - harmony: **K2 + E2** jumps to the same stop of the previous / next chord (from the rows below the chords: to the first chord), as slagverk's K2 + E2 picks the voice (user, 2026-11-28).
- **Drawing**: the whole frame is drawn in Lua into a 128×64 buffer with a built-in 3×5 font and sent with one `screen.poke`. Per-call screen drawing stalled the tick loop by up to 25 ms. Measured worst-case step jitter at 180 BPM, 8 tracks at 1/32: about 2.5 ms with the screen running, 1 ms without.
- **Confirm before**:
  - loading a set while anchors are unsaved
  - clearing a slot
  - overwriting a set file

## Persistence

- A **set** holds 8 tracks × 16 slots (working copy + anchor), the conductor, scenes and the drum kits (one per drum track on the norns port). It is bound to a norns pset number (`params.action_write/read`).
- **Scenes 1–8** store every track's slot number and the progression slot (shown as `H n` on the scenes page; scenes stored before this leave the progression alone). Recall lands on the next bar. Params: `store scene n` / `recall scene n`.
- **Autosave** (on slot change, on exit, every 30 s) writes the whole state plus lagom's params; boot restores it, so a reboot picks up where you left off. After a restore the knobs need pickup.
- **Confirmations** (norns screen, K3 yes / K2 no; a question from the menu jumps back to the play screen):
  - loading a set while any slot or the progression is unsaved
  - overwriting a set
  - `clear slot` (the current slot gets a fresh roll as working copy and anchor; lands on the next bar)

## Params

Every performance control is a norns param, so it can be MIDI-mapped.
- **Per track**:
  - perform: density, mute, reroll, save, revert, undo, slot, slot next/prev
  - shape: length, division, range, drift, gravity, gate, gate min, gate max
  - setup: type, voices, port, channel, base note, tension, follow transpose, motif size, restart
  - feel: fixed gate, velocity, vel, vel spread, legato, legato prob
  - drum lanes: note, role, mode (rank/euclid), hits, rotate, max, fader from/to per lane
- **Global**:
  - density offset, deadzone
  - root, scale, progression slot, progression, chords, chord length, harmony drift/gravity, next chord, home
  - play, beats per bar
  - clock mode, clock in port, clock out ports, controller port
  - scenes store/recall
