-- lagom
-- generative midi sequencer
-- 8 tracks, always in harmony
--
-- K3 play / stop
-- midimix: faders = density
-- knobs = range / division / length
-- mute buttons = mute
--
-- v0.2 (step 2: 8 tracks + midimix)

local K = include("lib/const")
local MU = require "musicutil"
local Out = include("lib/out")
local C = include("lib/clockio")
local Track = include("lib/track")
local Seq = include("lib/seq")
local Mix = include("lib/midimix")

local tracks = {}
local redraw_coro

local function fmt_pct(p) return p:get() .. "%" end

local function fmt_range(p)
  local v = p:get()
  if v % 12 == 0 then return (v // 12) .. " oct" end
  return v .. " st"
end

local function add_global_params(names)
  params:add_separator("lagom_density_sep", "density")
  params:add_number("global_density", "density offset", -100, 100, 0, fmt_pct)
  params:add_number("deadzone", "deadzone", 0, 15, 6, function(p) return "±" .. p:get() .. "%" end)
  params:add_separator("lagom_ctrl_sep", "controller")
  params:add_option("controller_port", "controller port", names, 1)
  params:set_action("controller_port", function() Mix.refresh() end)
end

local function add_track_params(names)
  for i = 1, K.NUM_TRACKS do
    local pre = "t" .. i .. "_"
    params:add_group("track_" .. i, "track " .. i, 10)
    params:add_number(pre .. "density", "density", 0, 100, 0, fmt_pct)
    params:add_binary(pre .. "mute", "mute", "toggle", 0)
    params:set_action(pre .. "mute", function(x)
      if x == 1 then Seq.flush_track(i) end
      Mix.led_mute(i, x == 1)
    end)
    params:add_trigger(pre .. "reroll", "re-roll")
    params:set_action(pre .. "reroll", function() tracks[i]:roll() end)
    params:add_number(pre .. "len", "length", 1, K.MAX_STEPS, 16)
    params:add_option(pre .. "div", "division", K.DIV_NAMES, K.DIV_DEFAULT)
    params:add_number(pre .. "range", "range", 1, K.MAX_RANGE, 24, fmt_range)
    params:add_number(pre .. "gate", "gate", 5, 100, 50, fmt_pct)
    params:add_option(pre .. "port", "port", names, 2)
    params:add_number(pre .. "ch", "channel", 1, 16, i)
    params:add_number(pre .. "base", "base note", 0, 127, 48,
      function(p) return MU.note_num_to_name(p:get(), true) end)
  end
end

function init()
  math.randomseed(os.time())
  Out.init()
  Mix.init(Out)
  for i = 1, K.NUM_TRACKS do tracks[i] = Track.new(i) end

  local names = Out.port_names()
  params:add_separator("lagom", "lagom")
  C.add_params(names)
  add_global_params(names)
  add_track_params(names)

  C.init(Out,
    function() Seq.reset(); Seq.catch_up() end,
    function() Seq.stop_all() end)
  Seq.init(Out, C, tracks)

  -- route all midi input through one dispatcher
  for i = 1, 16 do
    Out.ports[i].event = function(data)
      C.midi_in(i, data)
      if i == Mix.port() then Mix.event(data) end
    end
  end

  params:bang()
  Mix.refresh()
  Seq.start()

  redraw_coro = clock.run(function()
    while true do
      clock.sleep(1 / 15)
      redraw()
    end
  end)
  -- handle for REPL introspection while developing
  _lagom = {tracks = tracks, C = C, Seq = Seq, Out = Out, Mix = Mix}
  print("lagom: init ok")
end

function key(n, z)
  if n == 3 and z == 1 then
    params:set("play", 1 - params:get("play"))
  end
end

function enc(n, d) end

-- temporary step 2 screen: one row per track (polished in step 7)
local function draw_track(i, y)
  local t = tracks[i]
  local muted = t:p("mute") == 1
  local len = t:p("len")
  t:update_order(len)
  local dens = t:density()

  screen.level(muted and 2 or 8)
  screen.move(0, y + 4)
  screen.text(i)

  for s = 1, len do
    local audible = t:is_audible(s, len, dens)
    local lvl = audible and 9 or 2
    if C.playing and s == t.pos then lvl = audible and 15 or 6 end
    if muted then lvl = math.min(lvl, 3) end
    screen.level(lvl)
    screen.rect(6 + (s - 1) * 2, y, 1, 4)
    screen.fill()
  end

  -- density bar: fill = fader, tick = effective
  local bx, bw = 72, 22
  screen.level(1)
  screen.rect(bx, y + 1, bw, 2)
  screen.fill()
  screen.level(muted and 3 or 6)
  screen.rect(bx, y + 1, math.floor(t:p("density") / 100 * bw + 0.5), 2)
  screen.fill()
  screen.level(15)
  screen.rect(bx + math.min(bw - 1, math.floor(dens * bw + 0.5)), y, 1, 4)
  screen.fill()

  screen.level(muted and 2 or 5)
  screen.move(97, y + 4)
  screen.text(muted and "MUTE" or K.DIV_NAMES[t:p("div")])
end

local function draw_global_meter()
  local cx, cy, h = 126, 36, 27
  local raw = params:get("global_density") / 100
  local eff = Track.global_offset()
  local dz = math.floor(params:get("deadzone") / 100 * h + 0.5)
  screen.level(1)
  screen.rect(cx, cy - h, 2, 2 * h)
  screen.fill()
  screen.level(3)
  screen.rect(cx, cy - dz, 2, 2 * dz + 1)
  screen.fill()
  local y = cy - math.floor(raw * h + 0.5)
  screen.level(eff == 0 and 6 or 15)
  screen.rect(cx - 1, y, 3, 1)
  screen.fill()
end

function redraw()
  screen.clear()
  screen.font_face(25)
  screen.font_size(6)

  screen.level(15)
  screen.move(0, 6)
  if C.warning then
    screen.text("! " .. C.warning)
  elseif not Mix.synced then
    screen.text("PRESS SEND ALL ON MIDIMIX")
  else
    screen.text("LAGOM")
    screen.level(6)
    screen.move(28, 6)
    local state = C.playing and "PLAY" or (C.pending_start and "WAIT" or "STOP")
    screen.text(state .. "  " .. math.floor(clock.get_tempo() + 0.5) .. " BPM  " ..
      (C.is_slave() and "EXT" or "INT"))
  end

  for i = 1, K.NUM_TRACKS do draw_track(i, 9 + (i - 1) * 7) end
  draw_global_meter()
  screen.update()
end

function cleanup()
  if redraw_coro then clock.cancel(redraw_coro) end
  if C.playing and not C.is_slave() then
    for _, p in ipairs(C.out_ports()) do Out.send_byte(p, 0xFC) end
  end
  Seq.cleanup()
end
