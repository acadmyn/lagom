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
- **Pickup.** All knobs use pickup: after a slot change, a knob does nothing until it passes the stored value, then it follows. While a knob hasn't caught up, the screen shows the stored value and an arrow pointing to the knob's position. Press SEND ALL on the MIDImix at boot to sync it.

## Harmony

- A global `root` and `scale` (the musicutil list). Changes land on the next bar.
- **Conductor**: a loop of 2–8 chords drawn from the scale. `progression` = drone / markov / preset 1…n. `chord rate` = 1/2/4/8 bars. It has its own working copy and anchor, plus `harmony drift` and `harmony gravity`.
  - Markov mode uses weighted functional moves (tonic → subdominant/dominant → tonic, occasionally deceptive or modal moves).
- **Tension per track**: `root` / `5th` / `chord` / `scale` (strong beats biased to chord tones) / `color` (adds 7ths, 9ths and passing tones on weak beats).
- Default templates: T1 drums, T2 bass (5th), T3 chord, T4 lead (scale), T5–T8 mono (scale).

## Track types

- **mono**: 1 voice.
- **chord**: 2–8 voices stacked from the current chord or scale, with voice leading.
- **drums**: 1–8 lanes. Each lane has its own note (GM defaults 36 38 42 46 39 45 49 51), its own rhythm and a role: kick (downbeats rank first), snare (backbeats first), hat (8ths, then 16ths) or perc (random ranking). Lanes share the track's fader and channel. Drums ignore harmony.
- **feel**:
  - `fixed gate` on/off: off = random length per step, on = gate %.
  - `velocity` on/off: off = fixed `vel`, on = `vel` ± `vel spread`.
  - `legato` off / random / all. `random` sets a legato flag per step at roll time, with probability `legato prob` (default 25%); the flag is saved with the slot. A legato note-off is sent just after the next note-on.
- `length` 1–32. `division` 1/32 1/16T 1/16 1/8T 1/8 1/4T 1/4 1/2 1/1 2bar. `range` 1 semitone to 4 octaves above `base note`.
- `restart` off / 1 / 2 / 4 / 8 / 16 **bars of the master clock**, so polymeters can realign.

## Clock

- A single 48 PPQN tick loop drives clock out, every track and note-offs.
- **Master**: lagom sends clock plus Start/Stop to opted-in ports (`clock out → port n`). K3 or SOLO + BANK RIGHT toggles play.
- **Slave**: the system clock source is set to midi and listens only on `clock in port`. lagom forwards raw `F8 FA FB FC` to opted-in ports as a real thru, and follows external Start/Stop.
- Keep the norns system "midi clock out" **off** for ports lagom feeds, or those ports get doubled ticks. lagom warns about this.
- The 3.5 mm TRS jacks show up as the MIDI device `virtual` (through ttymidi) and must be assigned to a vport under SYSTEM › DEVICES › MIDI.

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
  - a 32 × 2 px step strip with pitch as dot height (bright = playing, dim = hidden), the motif underlined, and an inverted playhead column
  - a density bar with a tick for the effective level
  - the slot number, with `*` for unsaved changes
- **Header**: chord, progression dots, tempo, clock source, beat blip. A fader 9 meter runs along the right edge.
- **Overlays**: SAVED, the global meter, confirmations (K3 yes / K2 no). Confirmations appear only on the norns, never blocking the MIDImix.
- **Confirm before**:
  - loading a set while anchors are unsaved
  - clearing a slot
  - overwriting a set file
  - when the undo history is about to drop a version that was never saved

## Persistence

- A **set** holds 8 tracks × 16 slots (working copy + anchor), the conductor and scenes. It is bound to a norns pset number (`params.action_write/read`).
- **Scenes 1–8** store every track's slot number. Recall lands on the next bar.

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
