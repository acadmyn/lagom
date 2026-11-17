-- the conductor: a loop of chords (scale degrees) that advances every
-- `chord rate` bars. working copy plays, anchor is what was saved.
-- drift/gravity mutate the working copy once per pass through the loop.
local Cd = {
  working = {1},
  anchor = {1},
  idx = 1,
  bars = 0,             -- bars spent on the current chord
  pending_next = false,
  pending_home = false,
  on_change = nil,      -- callback(idx) when the chord changes
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

local function copy(t)
  local c = {}
  for i, v in ipairs(t) do c[i] = v end
  return c
end

function Cd.init(harmony)
  H = harmony
  Cd.working = Cd.generate()
  Cd.anchor = copy(Cd.working)
  Cd.idx = 1
  H.set_degree(Cd.working[1])
end

function Cd.mode() return params:get("progression") end

function Cd.generate()
  local m = Cd.mode()
  if m == 1 then return {1} end
  if m == 2 then return markov_chain(params:get("chords")) end
  local c = copy(Cd.PRESETS[m - 2][2])
  for i, d in ipairs(c) do c[i] = wrap(d) end
  return c
end

function Cd.reroll()
  Cd.working = Cd.generate()
  if Cd.idx > #Cd.working then Cd.idx = 1 end
  H.set_degree(Cd.working[Cd.idx])
end

function Cd.save()
  Cd.anchor = copy(Cd.working)
end

function Cd.unsaved()
  if #Cd.working ~= #Cd.anchor then return true end
  for i, v in ipairs(Cd.working) do
    if Cd.anchor[i] ~= v then return true end
  end
  return false
end

-- one pass of drift: each chord after the first may mutate; a mutation
-- snaps back to the anchor with probability `gravity`
local function drift()
  if Cd.mode() == 1 then return end
  local dr = params:get("harmony_drift") / 100
  local gr = params:get("harmony_gravity") / 100
  if dr <= 0 then return end
  for i = 2, #Cd.working do
    if math.random() < dr then
      if math.random() < gr and Cd.anchor[i] then
        Cd.working[i] = Cd.anchor[i]
      else
        Cd.working[i] = markov_step(Cd.working[i - 1])
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
  H.set_degree(Cd.working[idx])
  if Cd.on_change then Cd.on_change(idx) end
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
  H.set_degree(Cd.working[1])
end

-- called on every bar line after the first; `forced` = only handle requests
function Cd.bar(forced)
  if Cd.pending_home then
    Cd.pending_home, Cd.pending_next = false, false
    Cd.working = copy(Cd.anchor)
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
  if Cd.bars >= Cd.RATES[params:get("chord_rate")] and #Cd.working > 1 then
    go(Cd.idx + 1)
  end
end

return Cd
