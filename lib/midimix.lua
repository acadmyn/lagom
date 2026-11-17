-- akai midimix: factory preset (channel 1) input map and leds
-- every control just sets a norns param, so the params stay the source of truth
local K = include("lib/const")

local M = {
  synced = false,   -- true once any fader/knob has been received (SEND ALL hint)
  solo = false,     -- SOLO is the shift button
  alt = false,      -- BANK LEFT held: alternate knob layer
  hint = "",        -- pickup hint text for the screen
  hint_until = 0,
}

local Out           -- injected
local tracks        -- injected

local FADER = {19, 23, 27, 31, 49, 53, 57, 61}
local MASTER = 62
local KNOB_ROWS = {
  {16, 20, 24, 28, 46, 50, 54, 58},   -- top
  {17, 21, 25, 29, 47, 51, 55, 59},   -- middle
  {18, 22, 26, 30, 48, 52, 56, 60},   -- bottom
}
local NOTE_MUTE = {1, 4, 7, 10, 13, 16, 19, 22}
local NOTE_SOLO_MUTE = {2, 5, 8, 11, 14, 17, 20, 23}   -- mute row while SOLO held
local NOTE_REC = {3, 6, 9, 12, 15, 18, 21, 24}
local NOTE_BANK_L, NOTE_BANK_R, NOTE_SOLO = 25, 26, 27
local HOLD = 0.6    -- seconds: tap vs hold
local HINT_TIME = 1.5

-- 0..127 -> 1..n in equal-width buckets
local function bucket(v, n) return math.min(n, v * n // 128 + 1) end
local function pct(v) return util.round(v / 127 * 100) end

-- knob layers: [layer][row] = {param suffix, short name, map cc -> value, show}
local LAYERS = {
  {
    {"range", "RANGE", function(v) return bucket(v, K.MAX_RANGE) end},
    {"div", "DIV", function(v) return bucket(v, #K.DIV_NAMES) end,
     function(x) return K.DIV_SHORT[x] end},
    {"len", "LEN", function(v) return bucket(v, K.MAX_STEPS) end},
  },
  {
    {"drift", "DRIFT", pct},
    {"gravity", "GRAVITY", pct},
    {"gate", "GATE", function(v) return util.round(5 + v / 127 * 95) end},
  },
}

-- lookups: cc -> {track, row}; note -> track
local knob_at, fader_at, note_index = {}, {}, {}
for i = 1, K.NUM_TRACKS do
  fader_at[FADER[i]] = i
  for r = 1, 3 do knob_at[KNOB_ROWS[r][i]] = {i, r} end
  note_index[NOTE_MUTE[i]] = {"mute", i}
  note_index[NOTE_SOLO_MUTE[i]] = {"solo_mute", i}
  note_index[NOTE_REC[i]] = {"rec", i}
end

local function tp(i, name) return "t" .. i .. "_" .. name end

-- pickup ----------------------------------------------------------------------

local last_cc = {}     -- cc -> last raw value
local caught = {}      -- "t3_len" -> true once the knob has met the value

for i = 1, K.NUM_TRACKS do
  for _, layer in ipairs(LAYERS) do
    for _, k in ipairs(layer) do caught[tp(i, k[1])] = true end
  end
end

-- after a slot load / revert / undo the stored values win until each knob
-- passes them
function M.uncatch(i)
  for _, layer in ipairs(LAYERS) do
    for _, k in ipairs(layer) do caught[tp(i, k[1])] = false end
  end
end

local function knob(cc, v)
  local i, row = knob_at[cc][1], knob_at[cc][2]
  local k = LAYERS[M.alt and 2 or 1][row]
  local id = tp(i, k[1])
  local map = k[3]
  local new = map(v)
  local prev = last_cc[cc] and map(last_cc[cc])
  last_cc[cc] = v
  local cur = params:get(id)
  if not caught[id] then
    local crossed = prev and (prev - cur) * (new - cur) < 0
    if new == cur or crossed then
      caught[id] = true
    else
      local show = k[4] or tostring
      M.hint = "T" .. i .. " " .. k[2] .. " " .. show(cur) .. "  " ..
        (new < cur and "< " or "> ") .. show(new)
      M.hint_until = util.time() + HINT_TIME
      return
    end
  end
  params:set(id, new)
end

-- tap / hold ------------------------------------------------------------------

-- the action fires on release (tap) or at HOLD (hold)
local held = {}

local function press(note, tap, hold)
  local h = {fired = false}
  h.coro = clock.run(function()
    clock.sleep(HOLD)
    h.fired = true
    if hold then hold() end
  end)
  h.tap = tap
  held[note] = h
end

local function release(note)
  local h = held[note]
  if not h then return end
  held[note] = nil
  if not h.fired then
    clock.cancel(h.coro)
    if h.tap then h.tap() end
  end
end

-- input -----------------------------------------------------------------------

local function on_press(note)
  if note == NOTE_SOLO then
    M.solo = true
  elseif note == NOTE_BANK_L then
    if M.solo then
      press(note, nil, function() params:set("save_all", 1) end)
    else
      M.alt = true
    end
  elseif note == NOTE_BANK_R then
    if M.solo then
      press(note, function() params:set("play", 1 - params:get("play")) end,
            function() params:set("save_progression", 1) end)
    else
      press(note, function() params:set("next_chord", 1) end,
            function() params:set("home", 1) end)
    end
  else
    local n = note_index[note]
    if not n then return end
    local kind, i = n[1], n[2]
    if kind == "solo_mute" then
      params:set(tp(i, "slot_next"), 1)
    elseif kind == "mute" then
      if M.alt then
        params:set(tp(i, "undo"), 1)
      else
        params:set(tp(i, "mute"), 1 - params:get(tp(i, "mute")))
      end
    elseif kind == "rec" then
      if M.solo then
        params:set(tp(i, "slot_prev"), 1)
      elseif M.alt then
        params:set(tp(i, "revert"), 1)
      else
        press(note, function() params:set(tp(i, "reroll"), 1) end,
              function() params:set(tp(i, "save"), 1) end)
      end
    end
  end
end

local function on_release(note)
  if note == NOTE_SOLO then
    M.solo = false
  elseif note == NOTE_BANK_L then
    M.alt = false
  end
  release(note)
end

function M.init(out, trs)
  Out, tracks = out, trs
end

function M.port() return params:get("controller_port") end

function M.event(data)
  local msg = midi.to_msg(data)
  if msg.ch ~= 1 then return end
  if msg.type == "cc" then
    if fader_at[msg.cc] then
      M.synced = true
      params:set(tp(fader_at[msg.cc], "density"), pct(msg.val))
    elseif knob_at[msg.cc] then
      M.synced = true
      knob(msg.cc, msg.val)
    elseif msg.cc == MASTER then
      M.synced = true
      params:set("global_density", util.round(msg.val / 127 * 200 - 100))
    end
  elseif msg.type == "note_on" then
    on_press(msg.note)
  elseif msg.type == "note_off" then
    on_release(msg.note)
  end
end

-- leds ------------------------------------------------------------------------

local led_state = {}   -- note -> last sent on/off (only send changes)

local function led(note, on)
  led_state[note] = on
  Out.ports[M.port()]:note_on(note, on and 127 or 0, 1)
end

local function led_lazy(note, on)
  if led_state[note] ~= on then led(note, on) end
end

function M.led_mute(i, on) led(NOTE_MUTE[i], on) end

-- short blink of BANK RIGHT on chord changes
function M.blink_bank_right()
  led(NOTE_BANK_R, true)
  clock.run(function()
    clock.sleep(0.12)
    led(NOTE_BANK_R, false)
  end)
end

-- rec arm: off = saved, on = unsaved, blinking = waiting for the next bar.
-- BANK LEFT lit while the alternate layer is held. called every frame.
function M.update_leds()
  if not tracks then return end
  local blink = math.floor(util.time() * 4) % 2 == 0
  for i, t in ipairs(tracks) do
    local on
    if t.pending then on = blink else on = t:unsaved() end
    led_lazy(NOTE_REC[i], on)
  end
  led_lazy(NOTE_BANK_L, M.alt)
end

-- push every led to match current state
function M.refresh()
  led_state = {}
  for i = 1, K.NUM_TRACKS do
    led(NOTE_MUTE[i], params:get(tp(i, "mute")) == 1)
    led(NOTE_REC[i], false)
  end
  led(NOTE_BANK_L, false)
  led(NOTE_BANK_R, false)
  M.update_leds()
end

return M
