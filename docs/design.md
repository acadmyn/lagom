# lagom design

A norns script that runs 8 generative MIDI tracks which stay in harmony. It is played from an Akai MIDImix and sends to hardware synths.
The visual proposal with screen mockups is in a private artifact: https://claude.ai/artifact/Hjxc1w5SiS565Vyx37METb

## Core model

- **Seeds, not notes.** Each step stores a pitch seed (0–1), a velocity seed, a gate seed, a legato flag and a priority rank. The seed is mapped to a MIDI note only at play time, through the note pool allowed by the current chord, the track's tension and its range. Range, chord and tension changes therefore re-voice a phrase without scrambling it.
- **Density by rank.** Each of the 32 steps has a fixed rank. Density reveals steps in rank order, so 0 plays nothing and full plays every step. Track density is `clamp(track + global, 0, 1)`.
- **Global density (fader 9)** is bipolar from −100% to +100%, with a deadzone around the middle (default ±6%, adjustable 0–15%) that snaps to 0. It is drawn on screen.
- **Motif.** The top `motif size` ranks (0–8, default 4) are never changed by drift. With a fader low you hear only the motif; pushed up, you hear ornaments around it.
- **Slots.** Each track has 16 slots. A slot holds the 32 steps **and** length, division, range, drift, gravity and gate, so loading a slot gives you exactly what you saved. Stepping onto an empty slot generates a fresh sequence.
- **Working copy vs anchor.** Each slot has a working copy (what plays) and an anchor (what was saved). Drift, re-roll and undo only touch the working copy. Saving is a deliberate action. "Unsaved" means working ≠ anchor. The working copy is autosaved to disk (on slot change, on exit, and every 30 s).
- **Drift and gravity (Turing Machine style).** Drift is the chance per pass that a non-motif step mutates. Gravity is the chance that a mutated step snaps back to its anchor value. Drift writes to the working copy permanently. Undo history: 16 steps per track, covering re-rolls, drift snapshots and reverts.
- **Pickup.** All knobs use pickup: after a slot change, a knob does nothing until it passes the stored value, then it follows. While a knob hasn't caught up, the pop-up shows the stored value, the knob's position and an arrow (see Screen). Press SEND ALL on the MIDImix at boot to sync it.

## Harmony

- A global `root` and `scale` (the musicutil list). Changes land on the next bar.
- **Conductor**: a loop of 1–8 chords drawn from the scale (1 = stay on the home chord). `progression` = drone / markov / preset 1…n. `chord rate` = 1/2/4/8 bars. It has its own working copy and anchor, plus `harmony drift` and `harmony gravity`.
  - Markov mode uses weighted functional moves (tonic → subdominant/dominant → tonic, occasionally deceptive or modal moves).
- **Tension per track**: `root` / `5th` / `chord` / `scale` (strong beats biased to chord tones) / `color` (adds 7ths, 9ths and passing tones on weak beats).
- Default templates: T1 drums, T2 bass (5th), T3 chord, T4 lead (scale), T5–T8 mono (scale).

## Track types

- **mono**: 1 voice.
- **chord**: 2–8 voices stacked from the current chord or scale, with voice leading.
- **drums**: 1–8 lanes. Each lane has its own note (GM defaults 36 38 42 46 39 45 49 51), its own rhythm and a role: kick (downbeats rank first), snare (backbeats first), hat (8ths, then 16ths) or perc (random ranking). Lanes share the track's fader and channel. Drums ignore harmony.
- **poly**: 2–8 independent melodic lines on the track's channel (set the synth part to poly). Each voice has its own pitch, velocity and gate seeds, its own random rhythm ranking, legato flags and motif, and uses the whole range (voices may cross or meet). Voices share length, division, range, tension and the MIDImix knobs. The track fader brings voices in one by one: voice 1 follows the fader, and voice n starts at (n−1)/voices of the travel, so every voice is at full density only at the top. On screen, the track page draws one mark per voice at its pitch; the main strip shows the lowest-numbered voice that plays.
- **feel**:
  - `fixed gate` on/off: off = random length per step, on = gate %.
  - `velocity` on/off: off = fixed `vel`, on = `vel` ± `vel spread`.
  - `legato` off / random / all. `random` sets a legato flag per step at roll time, with probability `legato prob` (default 25%); the flag is saved with the slot. Legato only ties a note into the **directly following step**, and only if that step plays: its note-off is sent just after the next step's note-on. If the next step is silent, the note keeps its normal gate.
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
| Knobs, top row | CC 16 20 24 28 46 50 54 58 | range (alternate layer: drift) |
| Knobs, middle row | CC 17 21 25 29 47 51 55 59 | division (alternate layer: gravity) |
| Knobs, bottom row | CC 18 22 26 30 48 52 56 60 | length (alternate layer: gate) |
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
  - harmony: progression boxes (current one filled, bar-progress line under it), a two-octave keyboard (bright = chord tones, dim = scale), then one param row (root, scale, progression, chords, chord rate, harmony drift/gravity).
  - clock: big tempo, master/slave, playing, beat boxes, clock in/out, then a param list (tempo, mode, ports, beats per bar, controller port, clock out per connected port).
  - scenes: 8 boxes showing each track's slot as a bar. E2/E3 select, **K3 recall, K2 store** (asks before overwriting).
  - K2 on any page except main and scenes goes back to main.
- **Drawing**: the whole frame is drawn in Lua into a 128×64 buffer with a built-in 3×5 font and sent with one `screen.poke`. Per-call screen drawing stalled the tick loop by up to 25 ms. Measured worst-case step jitter at 180 BPM, 8 tracks at 1/32: about 2.5 ms with the screen running, 1 ms without.
- **Confirm before**:
  - loading a set while anchors are unsaved
  - clearing a slot
  - overwriting a set file
  - when the undo history is about to drop a version that was never saved

## Persistence

- A **set** holds 8 tracks × 16 slots (working copy + anchor), the conductor and scenes. It is bound to a norns pset number (`params.action_write/read`).
- **Scenes 1–8** store every track's slot number. Recall lands on the next bar. Params: `store scene n` / `recall scene n`.
- **Autosave** (on slot change, on exit, every 30 s) writes the whole state plus lagom's params; boot restores it, so a reboot picks up where you left off. After a restore the knobs need pickup.
- **Confirmations** (norns screen, K3 yes / K2 no; a question from the menu jumps back to the play screen):
  - loading a set while any slot or the progression is unsaved
  - overwriting a set
  - `clear slot` (the current slot gets a fresh roll as working copy and anchor; lands on the next bar)
  - undo full: dropping a phrase left behind by a re-roll or revert that was never saved. The action itself goes ahead; "no" keeps that version in the history (outside the 16-step limit). Drift steps and saved versions drop silently.

## Params

Every performance control is a norns param, so it can be MIDI-mapped.
- **Per track**:
  - perform: density, mute, reroll, save, revert, undo, slot, slot next/prev
  - shape: length, division, range, drift, gravity, gate
  - setup: type, voices, port, channel, base note, tension, motif size, restart
  - feel: fixed gate, velocity, vel, vel spread, legato, legato prob
  - drum lanes: note and role per lane
- **Global**:
  - density offset, deadzone
  - root, scale, progression, chords, chord rate, harmony drift/gravity, next chord, home
  - play, beats per bar
  - clock mode, clock in port, clock out ports, controller port
  - scenes store/recall
