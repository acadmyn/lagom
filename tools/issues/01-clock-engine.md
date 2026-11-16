Step 1: skeleton, clock engine, one track
**Status:** implemented in 24ccf3e and deployed to the norns. It still needs a listening test.

Design reference: `docs/design.md` (Clock section). Visual proposal (private): https://claude.ai/artifact/Hjxc1w5SiS565Vyx37METb

## Scope
- [x] A 48 PPQN tick loop drives clock out, track steps and note-offs
- [x] Master mode: clock plus Start/Stop to opted-in ports; K3 = play/stop
- [x] Slave mode: system clock source = midi, listening only on `clock in port`; raw `F8 FA FB FC` forwarded to opted-in ports
- [x] Track 1 plays a random mono phrase in C major. Params: port, channel, division, length, gate, density, mute, re-roll
- [x] Warning when the norns system "midi clock out" is also on for a lagom clock port
- [x] `tools/repl.py` and `tools/deploy.sh`

## Setup
- [ ] Assign the `virtual` device (TRS jacks) to vport 2 under SYSTEM › DEVICES › MIDI, then reload lagom
- [ ] Set `track 1 › port` = 2: virtual and `channel` = your synth's channel

## Test by ear
- [ ] Master: K3 gives an even 1/16 loop with no flams or wobble. K3 stops it, with no stuck notes
- [ ] `re-roll`, `division`, `length`, `gate` and `density` all change audibly; density thins the line by rank
- [ ] Clock out on to a clock-following device: it starts and stops with lagom and follows the tempo param
- [ ] Slave: lagom starts on the downbeat of the external master and stays locked through tempo changes
- [ ] Slave thru: a device on a clock out port receives Start, Stop and clock through lagom
- [ ] Compare the timing of TRS output against USB (TRS goes through ttymidi)
