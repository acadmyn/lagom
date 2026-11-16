-- akai midimix: factory preset (channel 1) input map and leds
-- every control just sets a norns param, so the params stay the source of truth
local K = include("lib/const")

local M = {
  synced = false,   -- true once any fader/knob has been received (SEND ALL hint)
}

local Out           -- injected

local FADER = {19, 23, 27, 31, 49, 53, 57, 61}
local MASTER = 62
local KNOB_TOP = {16, 20, 24, 28, 46, 50, 54, 58}
local KNOB_MID = {17, 21, 25, 29, 47, 51, 55, 59}
local KNOB_BOT = {18, 22, 26, 30, 48, 52, 56, 60}
local NOTE_MUTE = {1, 4, 7, 10, 13, 16, 19, 22}
local NOTE_REC = {3, 6, 9, 12, 15, 18, 21, 24}
local NOTE_BANK_L, NOTE_BANK_R = 25, 26

-- cc number -> function(value 0..127)
local cc_map = {}
-- note number -> function() on press
local note_map = {}

-- 0..127 -> 1..n in equal-width buckets
local function bucket(v, n) return math.min(n, v * n // 128 + 1) end

local function tp(i, name) return "t" .. i .. "_" .. name end

for i = 1, K.NUM_TRACKS do
  cc_map[FADER[i]] = function(v)
    params:set(tp(i, "density"), util.round(v / 127 * 100))
  end
  cc_map[KNOB_TOP[i]] = function(v)
    params:set(tp(i, "range"), bucket(v, K.MAX_RANGE))
  end
  cc_map[KNOB_MID[i]] = function(v)
    params:set(tp(i, "div"), bucket(v, #K.DIV_NAMES))
  end
  cc_map[KNOB_BOT[i]] = function(v)
    params:set(tp(i, "len"), bucket(v, K.MAX_STEPS))
  end
  note_map[NOTE_MUTE[i]] = function()
    params:set(tp(i, "mute"), 1 - params:get(tp(i, "mute")))
  end
end

cc_map[MASTER] = function(v)
  params:set("global_density", util.round(v / 127 * 200 - 100))
end

function M.init(out)
  Out = out
end

function M.port() return params:get("controller_port") end

function M.event(data)
  local msg = midi.to_msg(data)
  if msg.ch ~= 1 then return end
  if msg.type == "cc" then
    local f = cc_map[msg.cc]
    if f then
      M.synced = true
      f(msg.val)
    end
  elseif msg.type == "note_on" then
    local f = note_map[msg.note]
    if f then f() end
  end
end

local function led(note, on)
  Out.ports[M.port()]:note_on(note, on and 127 or 0, 1)
end

function M.led_mute(i, on) led(NOTE_MUTE[i], on) end

-- push every led to match current state
function M.refresh()
  for i = 1, K.NUM_TRACKS do
    led(NOTE_MUTE[i], params:get(tp(i, "mute")) == 1)
    led(NOTE_REC[i], false)
  end
  led(NOTE_BANK_L, false)
  led(NOTE_BANK_R, false)
end

return M
