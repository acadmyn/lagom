-- a sequencer track: step data + per-step playback
-- every track has 8 lanes of 32 steps. mono and chord play lane 1; drums
-- play lanes 1..voices, each with its own note and role-based ranking; poly
-- plays lanes 1..voices as independent melodic lines (own pitch and rhythm).
local K = include("lib/const")

local Track = {}
Track.__index = Track

Track.TYPES = {"mono", "chord", "drums", "poly"}
Track.ROLES = {"kick", "snare", "hat", "perc"}
Track.LANE_MODES = {"rank", "euclid"}
Track.LEGATO = {"off", "random", "all"}
Track.RESTART_NAMES = {"off", "1 bar", "2 bars", "4 bars", "8 bars", "16 bars"}
Track.RESTART_BARS = {0, 1, 2, 4, 8, 16}
Track.DRUM_NOTES = {36, 38, 42, 46, 39, 45, 49, 51}
Track.DRUM_ROLES = {1, 2, 3, 4, 4, 4, 4, 4}
local MONO, CHORD, DRUMS, POLY = 1, 2, 3, 4

function Track.new(id)
  local t = setmetatable({id = id, pos = 0, lanes = {}, last_note = nil}, Track)
  t:init_slots()
  return t
end

-- any change to step data or shape: refresh the unsaved check, and bump
-- the revision the save cache keys the current slot on (lib/store.lua)
function Track:touch()
  self.dirty = true
  self.rev = (self.rev or 0) + 1
end

function Track:p(name) return params:get("t" .. self.id .. "_" .. name) end

-- fader 9: raw position -100..100 -> offset -1..1 with a centre deadzone that
-- snaps to 0; the rest of the travel is rescaled so there is no jump at its edge
function Track.global_offset()
  local g = params:get("global_density") / 100
  local dz = params:get("deadzone") / 100
  local a = math.abs(g)
  if a <= dz then return 0 end
  return (g > 0 and 1 or -1) * (a - dz) / (1 - dz)
end

function Track:density()
  return util.clamp(self:p("density") / 100 + Track.global_offset(), 0, 1)
end

function Track:is_drums() return self:p("type") == DRUMS end
function Track:is_poly() return self:p("type") == POLY end

-- lanes that play: drums use `voices` lanes, poly at least 2, the rest lane 1
function Track:num_lanes()
  local ty = self:p("type")
  if ty == DRUMS then return self:p("voices") end
  if ty == POLY then return math.max(2, self:p("voices")) end
  return 1
end

-- drums ---------------------------------------------------------------------

function Track:lane_p(l, name) return params:get("t" .. self.id .. "_lane" .. l .. "_" .. name) end

function Track:is_euclid(l) return self:is_drums() and self:lane_p(l, "mode") == 2 end

-- drums: each lane owns a stretch of the fader (`from`..`to`). below it the
-- lane is silent, across it the lane comes in step by step, above it the
-- lane plays in full. from == to switches the whole lane on at that point.
-- returns 0..1, the share of the lane's steps (rank) or hits (euclid) shown
function Track:drum_level(l, dens)
  if dens <= 0 then return 0 end
  local from, to = self:lane_p(l, "from") / 100, self:lane_p(l, "to") / 100
  if dens < from then return 0 end
  if to <= from then return 1 end
  return math.min(1, (dens - from) / (to - from))
end

-- euclid lane: `hits` spread evenly over the first len steps, rotated right
-- by `rotate`. a step's x flag (written by drift) flips it, so variations
-- live in the step data and repeat every pass. hits are revealed in rank
-- order (kick: the one first). cached until the track's revision changes
function Track:euclid(l, len)
  local lane = self.lanes[l]
  local k = math.min(self:lane_p(l, "hits"), len)
  local rot = self:lane_p(l, "rotate") % len
  local e = lane.eu
  if e and e.len == len and e.k == k and e.rot == rot and e.rev == self.rev then return e end
  e = e or {ins = {}, order = {}, idx = {}}
  local steps, ins, idx, n = lane.steps, e.ins, e.idx, 0
  for s = 1, len do
    local i = (s - 1 - rot) % len
    local hit = k > 0 and (i * k) % len < k
    if steps[s].x then hit = not hit end
    ins[s] = hit
    if hit then n = n + 1; idx[n] = s end
  end
  for j = #idx, n + 1, -1 do idx[j] = nil end
  table.sort(idx, function(a, b) return steps[a].r < steps[b].r end)
  for o, s in ipairs(idx) do e.order[s] = o end
  e.count, e.len, e.k, e.rot, e.rev = n, len, k, rot, self.rev
  lane.eu = e
  return e
end

-- what drum lane l plays at density dens. step s plays when
-- (not ins or ins[s]) and order[s] <= shown
function Track:drum_lane(l, len, dens)
  local x = self:drum_level(l, dens)
  if self:lane_p(l, "mode") == 2 then
    local e = self:euclid(l, len)
    return e.order, math.floor(x * e.count + 0.5), e.ins
  end
  self:update_order(len, l)
  return self.lanes[l].order, math.floor(x * self:lane_p(l, "max") / 100 * len + 0.5), nil
end

function Track:drum_plays(l, s, len, dens)
  local order, shown, ins = self:drum_lane(l, len, dens)
  return (not ins or ins[s]) and order[s] <= shown
end

-- poly: the fader brings voices in one by one. voice l starts at
-- (l-1)/n of the travel and reaches full density at the top
function Track:lane_density(dens, l, n)
  if not l or l == 1 or not self:is_poly() then return dens end
  local start = (l - 1) / n
  return util.clamp((dens - start) / (1 - start), 0, 1)
end

-- ranking ------------------------------------------------------------------

-- lower score = revealed earlier. assumes a 16th grid (4 steps per beat)
local ROLE_SCORE = {
  function(i)  -- kick: the one, then beat 3, then other beats, then 8ths
    if i == 0 then return 0 end
    if i % 8 == 0 then return 1 end
    if i % 4 == 0 then return 2 end
    if i % 2 == 0 then return 3 end
    return 4
  end,
  function(i)  -- snare: backbeats, then ghost 16ths, avoid the downbeats
    if i % 8 == 4 then return 0 end
    if i % 2 == 1 then return 2 end
    if i % 4 == 2 then return 2.5 end
    return 4
  end,
  function(i)  -- hat: 8ths, then 16ths
    return i % 2 == 0 and 0 or 1
  end,
  function() return 0 end,  -- perc: random
}

function Track:lane_role(l)
  if not self:is_drums() then return 4 end
  return self:p("lane" .. l .. "_role")
end

-- (re)compute ranks of one lane from its role; the random tie-breaker rr is
-- part of the step data, so re-ranking is repeatable. steps in `pinned`
-- (the motif) keep the top ranks in their current order.
function Track:rank_lane(l, pinned)
  local lane = self.lanes[l]
  local score = ROLE_SCORE[self:lane_role(l)]
  local idx = {}
  for s = 1, K.MAX_STEPS do idx[s] = s end
  local key = function(s)
    if pinned and pinned[s] then return -100 + lane.steps[s].r end
    return score(s - 1) + lane.steps[s].rr * 0.99
  end
  table.sort(idx, function(a, b) return key(a) < key(b) end)
  for r, s in ipairs(idx) do lane.steps[s].r = r end
  lane.order_len = nil
  self:touch()
end

function Track:rank_all()
  for l = 1, 8 do self:rank_lane(l) end
end

-- fresh random content for every lane (always a new table, so a slot's
-- stored copy is never modified in place)
function Track:roll()
  self.lanes = {}
  for l = 1, 8 do
    local steps = {}
    for s = 1, K.MAX_STEPS do
      steps[s] = {p = math.random(), v = math.random(), g = math.random(),
                  rr = math.random(), leg = false, x = false}
    end
    self.lanes[l] = {steps = steps, order = {}}
  end
  self.steps = self.lanes[1].steps
  self:roll_legato()
  self:rank_all()
end

-- per-step legato flags, drawn with `legato prob`
function Track:roll_legato()
  local prob = self:p("legprob") / 100
  for l = 1, 8 do
    for _, st in ipairs(self.lanes[l].steps) do st.leg = math.random() < prob end
  end
  self:touch()
end

-- order[s] = position of step s in the priority list of the first len steps
function Track:update_order(len, l)
  local lane = self.lanes[l or 1]
  if lane.order_len == len then return end
  local idx = {}
  for s = 1, len do idx[s] = s end
  table.sort(idx, function(a, b) return lane.steps[a].r < lane.steps[b].r end)
  lane.order = {}
  for o, s in ipairs(idx) do lane.order[s] = o end
  lane.order_len = len
end

function Track:is_audible(s, len, density, l)
  return self.lanes[l or 1].order[s] <= math.floor(density * len + 0.5)
end

-- pitch ---------------------------------------------------------------------

-- notes from base note up to base + range whose pitch class the tension
-- allows on this kind of beat (cached per harmony version). a track that
-- follows transpose uses the transposed chord, its range moved with it
function Track:pool(strong)
  local H = Track.H
  local follow = self:p("follow") == 1
  local base = util.clamp(self:p("base") + H.shift(follow), 0, 127)
  local range, tension = self:p("range"), self:p("tension")
  local k = table.concat({base, range, tension, strong and 1 or 0, follow and 1 or 0, H.version}, ",")
  self.pools = self.pools or {}
  local c = self.pools[strong and 1 or 2]
  if c and c.key == k then return c.notes, k end
  local pcs = H.pcs(tension, strong, follow)
  local notes = {}
  for n = base, math.min(127, base + range) do
    if pcs[n % 12] then notes[#notes + 1] = n end
  end
  -- range too narrow for this tension: take the nearest allowed note above
  local n = base + range + 1
  while #notes == 0 and n <= 127 do
    if pcs[n % 12] then notes[1] = n end
    n = n + 1
  end
  if #notes == 0 then notes[1] = base end
  self.pools[strong and 1 or 2] = {key = k, notes = notes}
  return notes, k
end

local function nearest(pool, target, taken)
  local best, bd
  for _, n in ipairs(pool) do
    if not (taken and taken[n]) then
      local d = math.abs(n - target)
      if not bd or d < bd then best, bd = n, d end
    end
  end
  return best
end

-- chord voicing: n distinct notes from the chord-tone pool. the first voicing
-- is the lowest n notes; after that every voice moves to the nearest free note
-- (smallest total movement), then missing chord tones replace doubled ones
function Track:chord_notes(n)
  local pool, pk = self:pool(true)
  n = math.min(n, #pool)
  local key = pk .. "/" .. n
  if self.voicing_key == key then return self.voicing end

  local prev, v = self.voicing, {}
  if not prev or #prev ~= n then
    for i = 1, n do v[i] = pool[i] end
  else
    local taken = {}
    for i, old in ipairs(prev) do
      v[i] = nearest(pool, old, taken)
      taken[v[i]] = true
    end
    -- chord tones in importance order that exist in the pool, as many as
    -- there are voices
    local in_pool, used, want = {}, {}, {}
    for _, p in ipairs(pool) do in_pool[p % 12] = true end
    for _, pc in ipairs(Track.H.voice_order(self:p("follow") == 1)) do
      if in_pool[pc] and not used[pc] and #want < n then
        want[#want + 1] = pc
        used[pc] = true
      end
    end
    for _, pc in ipairs(want) do
      local count = {}
      for _, x in ipairs(v) do count[x % 12] = (count[x % 12] or 0) + 1 end
      if not count[pc] then
        -- cheapest doubled voice to move onto the missing tone
        local bi, bn, bd
        for i, x in ipairs(v) do
          if count[x % 12] > 1 then
            local cands = {}
            for _, p in ipairs(pool) do
              if p % 12 == pc and not taken[p] then cands[#cands + 1] = p end
            end
            local c = nearest(cands, x)
            if c and (not bd or math.abs(c - x) < bd) then bi, bn, bd = i, c, math.abs(c - x) end
          end
        end
        if bi then
          taken[v[bi]] = nil
          v[bi] = bn
          taken[bn] = true
        end
      end
    end
  end
  table.sort(v)
  self.voicing, self.voicing_key = v, key
  return v
end

-- feel ----------------------------------------------------------------------

function Track:velocity(st)
  local vel = self:p("vel")
  if self:p("velon") == 1 then
    vel = vel + math.floor((st.v * 2 - 1) * self:p("velspread") + 0.5)
  end
  return util.clamp(vel, 1, 127)
end

-- note length in ticks for one step: `gate`, or with fixed gate off somewhere
-- between `gate min` and `gate max` (% of a step, may exceed one step)
function Track:gate_ticks(st, div)
  local pct
  if self:p("fixgate") == 1 then
    pct = self:p("gate")
  else
    local lo, hi = self:p("gatemin"), self:p("gatemax")
    if hi < lo then lo, hi = hi, lo end
    pct = lo + st.g * (hi - lo)
  end
  return math.max(1, math.floor(div * pct / 100 + 0.5))
end

function Track:is_legato(st)
  local mode = self:p("legato")
  return mode == 3 or (mode == 2 and st.leg)
end

-- legato ties into the next step that plays, across any rests: the note
-- lasts until just after that step's note-on (or longer, if its gate is)
function Track:legato_gate(gate, div, len, density, l)
  for k = 1, len - 1 do
    if self:is_audible(((self.pos + k - 1) % len) + 1, len, density, l) then
      return math.max(gate, k * div + 1)
    end
  end
  return gate
end

-- playback ------------------------------------------------------------------

function Track:reset() self.pos = 0; self.looped = false end

function Track:release_voicing() self.voicing, self.voicing_key = nil, nil end

-- called on each step boundary; schedules notes via seq
-- rel = ticks since the transport origin (a step on a beat is "strong")
function Track:step(t, seq, rel)
  local len = self:p("len")
  self.pos = (self.pos % len) + 1
  if self.pos == 1 then
    if self.looped then self:drift(len) end
    self.looped = true
  end
  if self:p("mute") == 1 or self:p("enabled") == 0 then return end
  local dens = self:density()
  local div = K.DIV_TICKS[self:p("div")]
  local port, ch = self:p("port"), self:p("ch")

  -- the norns drum machine (port 17, lib/drums.lua): drum tracks only
  if port == self.Drums.PORT then
    if not self:is_drums() then return end
    for l = 1, self:num_lanes() do
      if self:drum_plays(l, self.pos, len, dens) then
        self.Drums.hit(self.id, self:p("lane" .. l .. "_note"),
                       self:velocity(self.lanes[l].steps[self.pos]))
      end
    end
    return
  end

  if self:is_drums() then
    for l = 1, self:num_lanes() do
      if self:drum_plays(l, self.pos, len, dens) then
        local st = self.lanes[l].steps[self.pos]
        seq.note(t, port, ch, self:p("lane" .. l .. "_note"), self:velocity(st),
                 self:gate_ticks(st, div), self.id)
      end
    end
    return
  end

  if self:is_poly() then
    local n = self:num_lanes()
    local pool = self:pool(rel % K.PPQN == 0)
    for l = 1, n do
      self:update_order(len, l)
      local ld = self:lane_density(dens, l, n)
      if self:is_audible(self.pos, len, ld, l) then
        local st = self.lanes[l].steps[self.pos]
        local gate = self:gate_ticks(st, div)
        if self:is_legato(st) then gate = self:legato_gate(gate, div, len, ld, l) end
        local note = pool[math.min(#pool, math.floor(st.p * #pool) + 1)]
        seq.note(t, port, ch, note, self:velocity(st), gate, self.id)
        if l == 1 then self.last_note = note end
      end
    end
    return
  end

  self:update_order(len)
  if not self:is_audible(self.pos, len, dens) then return end
  local st = self.steps[self.pos]
  local gate = self:gate_ticks(st, div)
  if self:is_legato(st) then gate = self:legato_gate(gate, div, len, dens) end
  local vel = self:velocity(st)

  if self:p("type") == CHORD then
    for _, n in ipairs(self:chord_notes(math.max(2, self:p("voices")))) do
      seq.note(t, port, ch, n, vel, gate, self.id)
    end
    self.last_note = self.voicing[1]
  else
    local pool = self:pool(rel % K.PPQN == 0)
    local note = pool[math.min(#pool, math.floor(st.p * #pool) + 1)]
    seq.note(t, port, ch, note, vel, gate, self.id)
    self.last_note = note
  end
end

return Track
