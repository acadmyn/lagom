-- the conductor: 16 progression slots. each slot is a loop of chords
-- ({d = scale degree, acc = -1/0/1, q = quality index, tr = transpose in
-- scale steps, len = bars}) with a working copy (plays, edited, drifts)
-- and an anchor (what was saved). drift/gravity mutate the working copy once
-- per pass through the loop. slot changes land on the next bar.
local Cd = {
  NUM_SLOTS = 16,
  MAX_CHORDS = 8,
  MAX_LEN = 8,
  slots = {},           -- [n] = {work = {chords}, anchor = {chords}}
  slot = 1,
  working = nil,        -- = slots[slot].work
  anchor = nil,         -- = slots[slot].anchor
  idx = 1,
  bars = 0,             -- bars spent on the current chord
  pending_next = false,
  pending_home = false,
  pending_slot = nil,
  on_change = nil,      -- callback(idx) when the chord changes
  on_slot = nil,        -- callback(n) when the slot changes
}

local H                 -- injected harmony

Cd.RATES = {1, 2, 4, 8}
Cd.RATE_NAMES = {"1 bar", "2 bars", "4 bars", "8 bars"}

Cd.PRESETS = {
  {"I V vi IV", {1, 5, 6, 4}},
  {"I vi IV V", {1, 6, 4, 5}},
  {"ii V I I", {2, 5, 1, 1}},
  {"I IV", {1, 4}},
  {"i VI III VII", {1, 6, 3, 7}},
  {"vi IV I V", {6, 4, 1, 5}},
  {"I IV vi V", {1, 4, 6, 5}},
  {"I iii IV iv", {1, 3, 4, 4}},
  {"i VII VI VII", {1, 7, 6, 7}},
}

function Cd.mode_names()
  local t = {"drone", "markov"}
  for i, p in ipairs(Cd.PRESETS) do t[#t + 1] = i .. ": " .. p[1] end
  return t
end

-- functional moves for a 7-note scale: from degree -> {to, weight}
-- mostly tonic -> pre-dominant/dominant -> tonic, with a few deceptive
-- (V -> vi) and modal (-> VII, -> iii) moves
local MOVES = {
  [1] = {{4, 3}, {5, 3}, {6, 2}, {2, 2}, {3, 1}, {7, 0.5}},
  [2] = {{5, 4}, {4, 1}, {7, 1}},
  [3] = {{6, 3}, {4, 2}, {2, 0.5}},
  [4] = {{5, 3}, {1, 2}, {2, 1}, {7, 0.5}},
  [5] = {{1, 5}, {6, 2}, {4, 1}, {3, 0.5}},
  [6] = {{4, 3}, {2, 2}, {5, 1}, {3, 0.5}},
  [7] = {{1, 3}, {3, 1}, {6, 0.5}},
}

local function wrap(d)
  local n = H.size()
  return ((d - 1) % n) + 1
end

local function markov_step(from)
  local moves = MOVES[((from - 1) % 7) + 1]
  local total = 0
  for _, m in ipairs(moves) do total = total + m[2] end
  local r = math.random() * total
  for _, m in ipairs(moves) do
    r = r - m[2]
    if r <= 0 then return wrap(m[1]) end
  end
  return wrap(moves[1][1])
end

local function markov_chain(n)
  local best
  for _ = 1, 8 do
    local c = {1}
    for i = 2, n do c[i] = markov_step(c[i - 1]) end
    best = c
    -- prefer loops whose last chord leads home
    local last = c[n]
    if last == wrap(5) or last == wrap(4) or last == wrap(7) or last == wrap(2) then break end
  end
  return best
end

local function chord(d, len, acc, q, tr)
  return {d = d, acc = acc or 0, q = q or 1, tr = tr or 0, len = len}
end

local function copy(t)
  local c = {}
  for i, ch in ipairs(t) do c[i] = chord(ch.d, ch.len, ch.acc, ch.q, ch.tr) end
  return c
end

local function same(a, b) return a.d == b.d and a.acc == b.acc and a.q == b.q and a.tr == b.tr end

local function equal(a, b)
  if #a ~= #b then return false end
  for i, ch in ipairs(a) do
    if not same(b[i], ch) or b[i].len ~= ch.len then return false end
  end
  return true
end

local function default_len() return Cd.RATES[params:get("chord_rate")] end

function Cd.mode() return params:get("progression") end

-- a fresh loop from the `progression` generator; n chords for markov
function Cd.generate(n)
  local m = Cd.mode()
  local degs
  if m == 1 then degs = {1}
  elseif m == 2 then degs = markov_chain(n or params:get("chords"))
  else
    degs = {}
    for i, d in ipairs(Cd.PRESETS[m - 2][2]) do degs[i] = wrap(d) end
  end
  local len, c = default_len(), {}
  for i, d in ipairs(degs) do c[i] = chord(d, len) end
  return c
end

local function sync_params()
  params:set("chords", #Cd.working, true)
  params:set("harmony_slot", Cd.slot, true)
end

local function bind(n)
  Cd.slot = n
  Cd.working, Cd.anchor = Cd.slots[n].work, Cd.slots[n].anchor
  if Cd.idx > #Cd.working then Cd.idx = 1 end
  sync_params()
end

local function new_slot(n)
  local c = Cd.generate()
  Cd.slots[n] = {work = c, anchor = copy(c)}
end

function Cd.init(harmony)
  H = harmony
  Cd.slots = {}
  new_slot(1)
  Cd.idx = 1
  bind(1)
  H.set_chord(Cd.working[1])
end

function Cd.current() return Cd.working[Cd.idx] end

-- editing the working copy -------------------------------------------------

function Cd.reroll()
  local c = Cd.generate(#Cd.working)
  Cd.slots[Cd.slot].work = c
  bind(Cd.slot)
  H.set_chord(Cd.working[Cd.idx])
end

function Cd.set_degree(i, d)
  local ch = Cd.working[i]
  if not ch then return end
  ch.d = wrap(d)
  if i == Cd.idx then H.set_chord(ch) end
end

function Cd.set_acc(i, a)
  local ch = Cd.working[i]
  if not ch then return end
  ch.acc = util.clamp(a, -1, 1)
  if i == Cd.idx then H.set_chord(ch) end
end

Cd.MAX_TR = 14

function Cd.set_tr(i, v)
  local ch = Cd.working[i]
  if not ch then return end
  ch.tr = util.clamp(v, -Cd.MAX_TR, Cd.MAX_TR)
  if i == Cd.idx then H.set_chord(ch) end
end

function Cd.set_quality(i, q)
  local ch = Cd.working[i]
  if not ch then return end
  ch.q = util.clamp(q, 1, #H.QUALITIES)
  if i == Cd.idx then H.set_chord(ch) end
end

function Cd.set_len(i, len)
  local ch = Cd.working[i]
  if ch then ch.len = util.clamp(len, 1, Cd.MAX_LEN) end
end

-- grow (markov step from the last chord, default length) or shrink the loop
function Cd.set_count(n)
  n = util.clamp(n, 1, Cd.MAX_CHORDS)
  local w = Cd.working
  while #w < n do
    local last = w[#w]
    if Cd.mode() == 2 then
      w[#w + 1] = chord(markov_step(last.d), default_len())
    else
      w[#w + 1] = chord(last.d, default_len(), last.acc, last.q, last.tr)
    end
  end
  while #w > n do w[#w] = nil end
  if Cd.idx > #w then Cd.idx = 1; H.set_chord(w[1]) end
  params:set("chords", #w, true)
end

function Cd.save()
  Cd.slots[Cd.slot].anchor = copy(Cd.working)
  Cd.anchor = Cd.slots[Cd.slot].anchor
end

function Cd.slot_unsaved(n)
  local sl = Cd.slots[n]
  return sl ~= nil and not equal(sl.work, sl.anchor)
end

function Cd.unsaved() return Cd.slot_unsaved(Cd.slot) end

function Cd.target_slot() return Cd.pending_slot or Cd.slot end

-- one pass of drift: each chord after the first may mutate (to a plain
-- diatonic chord); a mutation snaps back to the anchor chord with probability
-- `gravity`. lengths stay.
local function drift()
  if Cd.mode() == 1 then return end
  local dr = params:get("harmony_drift") / 100
  local gr = params:get("harmony_gravity") / 100
  if dr <= 0 then return end
  for i = 2, #Cd.working do
    if math.random() < dr then
      local ch, a = Cd.working[i], Cd.anchor[i]
      if math.random() < gr and a then
        ch.d, ch.acc, ch.q, ch.tr = a.d, a.acc, a.q, a.tr
      else
        ch.d, ch.acc, ch.q, ch.tr = markov_step(Cd.working[i - 1].d), 0, 1, 0
      end
    end
  end
end

local function go(idx)
  if idx > #Cd.working then
    idx = 1
    drift()
  end
  Cd.idx = idx
  Cd.bars = 0
  H.set_chord(Cd.working[idx])
  if Cd.on_change then Cd.on_change(idx) end
end

-- slots ----------------------------------------------------------------------

local function load_slot(n)
  if not Cd.slots[n] then new_slot(n) end
  Cd.idx = 1
  bind(n)
  go(1)
  if Cd.on_slot then Cd.on_slot(n) end
end

function Cd.request_slot(n, now)
  n = util.clamp(n, 1, Cd.NUM_SLOTS)
  if n == Cd.slot and not Cd.pending_slot then return end
  Cd.pending_slot = n
  if now then Cd.bar(true) end
end

function Cd.request_next(now)
  Cd.pending_next = true
  if now then Cd.bar(true) end
end

function Cd.request_home(now)
  Cd.pending_home = true
  if now then Cd.bar(true) end
end

function Cd.start()
  Cd.bars = 0
  Cd.idx = 1
  Cd.pending_next = false
  H.set_chord(Cd.working[1])
end

-- called on every bar line after the first; `forced` = only handle requests
function Cd.bar(forced)
  if Cd.pending_slot then
    local n = Cd.pending_slot
    Cd.pending_slot, Cd.pending_next, Cd.pending_home = nil, false, false
    load_slot(n)
    return
  end
  if Cd.pending_home then
    Cd.pending_home, Cd.pending_next = false, false
    Cd.slots[Cd.slot].work = copy(Cd.anchor)
    bind(Cd.slot)
    Cd.idx = 0
    go(1)
    return
  end
  if Cd.pending_next then
    Cd.pending_next = false
    go(Cd.idx + 1)
    return
  end
  if forced then return end
  Cd.bars = Cd.bars + 1
  if Cd.bars >= Cd.working[Cd.idx].len and #Cd.working > 1 then
    go(Cd.idx + 1)
  end
end

-- persistence ------------------------------------------------------------------

-- chords are saved with the quality's name (acc/q left out when plain)
local function out_chords(list)
  local out = {}
  for i, ch in ipairs(list) do
    out[i] = {d = ch.d, len = ch.len, acc = ch.acc ~= 0 and ch.acc or nil,
              q = ch.q ~= 1 and H.QUALITIES[ch.q][1] or nil, tr = ch.tr ~= 0 and ch.tr or nil}
  end
  return out
end

function Cd.export()
  local slots = {}
  for n, sl in pairs(Cd.slots) do slots[n] = {work = out_chords(sl.work), anchor = out_chords(sl.anchor)} end
  return {slot = Cd.slot, idx = Cd.idx, slots = slots}
end

-- also reads the old format ({working, anchor, idx}: degrees, one chord rate)
function Cd.import(c)
  local function chords(list)
    local out = {}
    for i, ch in ipairs(list or {}) do
      if type(ch) == "number" then out[i] = chord(ch, default_len())
      else
        local q = type(ch.q) == "string" and H.quality_index(ch.q) or 1
        out[i] = chord(ch.d, util.clamp(ch.len or 1, 1, Cd.MAX_LEN),
                       util.clamp(ch.acc or 0, -1, 1), q,
                       util.clamp(ch.tr or 0, -Cd.MAX_TR, Cd.MAX_TR))
      end
    end
    return out
  end
  Cd.slots = {}
  if c.slots then
    for n, sl in pairs(c.slots) do
      local w = chords(sl.work)
      if #w > 0 then
        local a = chords(sl.anchor)
        Cd.slots[n] = {work = w, anchor = #a > 0 and a or copy(w)}
      end
    end
  elseif c.working and #c.working > 0 then
    local w = chords(c.working)
    local a = chords(c.anchor)
    Cd.slots[1] = {work = w, anchor = #a > 0 and a or copy(w)}
  end
  local n = util.clamp(c.slot or 1, 1, Cd.NUM_SLOTS)
  if not Cd.slots[n] then new_slot(n) end
  Cd.pending_next, Cd.pending_home, Cd.pending_slot = false, false, nil
  Cd.idx = math.max(1, c.idx or 1)
  bind(n)
  H.set_chord(Cd.working[Cd.idx])
end

return Cd
