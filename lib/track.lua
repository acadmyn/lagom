-- a sequencer track: step data + per-step playback
local K = include("lib/const")
local MU = require "musicutil"

local Track = {}
Track.__index = Track

local SCALE = MU.generate_scale(0, "major", 11)   -- until step 3: fixed C major

function Track.new(id)
  local t = setmetatable({id = id, pos = 0, steps = {}, order = {}, last_note = nil}, Track)
  t:roll()
  return t
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

-- fresh random content for all 32 steps
function Track:roll()
  local ranks = {}
  for i = 1, K.MAX_STEPS do ranks[i] = i end
  for i = K.MAX_STEPS, 2, -1 do
    local j = math.random(i)
    ranks[i], ranks[j] = ranks[j], ranks[i]
  end
  for s = 1, K.MAX_STEPS do
    self.steps[s] = {p = math.random(), v = math.random(), g = math.random(), r = ranks[s]}
  end
  self.order_len = nil
end

-- order[s] = position of step s in the priority list of the first len steps
function Track:update_order(len)
  if self.order_len == len then return end
  local idx = {}
  for s = 1, len do idx[s] = s end
  table.sort(idx, function(a, b) return self.steps[a].r < self.steps[b].r end)
  self.order = {}
  for o, s in ipairs(idx) do self.order[s] = o end
  self.order_len = len
end

-- scale notes from base note up to base + range (cached)
function Track:pool()
  local base, range = self:p("base"), self:p("range")
  local k = base * 100 + range
  if self.pool_key ~= k then
    local pool = {}
    for _, n in ipairs(SCALE) do
      if n >= base and n <= base + range and n <= 127 then pool[#pool + 1] = n end
    end
    if #pool == 0 then pool[1] = base end
    self.pool_cache, self.pool_key = pool, k
  end
  return self.pool_cache
end

function Track:reset() self.pos = 0 end

function Track:is_audible(s, len, density)
  return self.order[s] <= math.floor(density * len + 0.5)
end

-- called on each step boundary; schedules notes via seq
function Track:step(t, seq)
  local len = self:p("len")
  self.pos = (self.pos % len) + 1
  if self:p("mute") == 1 then return end
  self:update_order(len)
  local st = self.steps[self.pos]
  if not self:is_audible(self.pos, len, self:density()) then return end

  local pool = self:pool()
  local note = pool[math.min(#pool, math.floor(st.p * #pool) + 1)]
  local vel = 100
  local div = K.DIV_TICKS[self:p("div")]
  local gate = math.max(1, math.floor(div * self:p("gate") / 100 + 0.5))
  seq.note(t, self:p("port"), self:p("ch"), note, vel, gate, self.id)
  self.last_note = note
end

return Track
