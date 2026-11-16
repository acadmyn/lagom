-- a sequencer track: step data + per-step playback
local K = include("lib/const")
local MU = require "musicutil"

local Track = {}
Track.__index = Track

local POOL = MU.generate_scale(48, "major", 2)   -- step 1: fixed C major, 2 oct

function Track.new(id)
  local t = setmetatable({id = id, pos = 0, steps = {}, order = {}, last_note = nil}, Track)
  t:roll()
  return t
end

function Track:p(name) return params:get("t" .. self.id .. "_" .. name) end

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

function Track:reset() self.pos = 0 end

function Track:is_audible(s, len, density)
  return self.order[s] <= math.floor(density * len + 0.5)
end

-- called on each step boundary; returns nothing, schedules via seq
function Track:step(t, seq)
  local len = self:p("len")
  self.pos = (self.pos % len) + 1
  if self:p("mute") == 1 then return end
  self:update_order(len)
  local st = self.steps[self.pos]
  if not self:is_audible(self.pos, len, self:p("density") / 100) then return end

  local note = POOL[math.floor(st.p * #POOL) + 1]
  local vel = 100
  local div = K.DIV_TICKS[self:p("div")]
  local gate = math.max(1, math.floor(div * self:p("gate") / 100 + 0.5))
  local port, ch = self:p("port"), self:p("ch")
  seq.note(t, port, ch, note, vel, gate)
  self.last_note = note
end

return Track
