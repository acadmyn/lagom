-- lagom
-- generative midi sequencer
-- 8 tracks, always in harmony
--
-- K3 play / stop
-- midimix: faders = density
-- knobs = range / division / length
-- mute buttons = mute
-- bank right: tap next chord,
--   hold home
-- solo+bank right: tap play,
--   hold save progression
--
-- v0.4 (step 4: track types + feel)

local K = include("lib/const")
local MU = require "musicutil"
local Out = include("lib/out")
local C = include("lib/clockio")
local Track = include("lib/track")
local Seq = include("lib/seq")
local Mix = include("lib/midimix")
local H = include("lib/harmony")
local Cd = include("lib/conductor")

local tracks = {}
local redraw_coro
local flash, flash_until = nil, 0

local function show(msg)
  flash, flash_until = msg, util.time() + 1
end

-- default templates: type, tension, base note, range
local TEMPLATE = {
  {3, 4, 36, 24},   -- T1 drums
  {1, 2, 36, 12},   -- T2 bass
  {2, 3, 48, 24},   -- T3 chord
  {1, 4, 60, 24},   -- T4 lead
  {1, 4, 48, 24}, {1, 4, 48, 24}, {1, 4, 60, 24}, {1, 4, 60, 24},
}

local function add_harmony_params()
  local function stage()
    H.stage(params:get("root") - 1, params:get("scale"), not C.playing)
  end
  params:add_separator("lagom_harmony_sep", "harmony")
  params:add_option("root", "root", MU.NOTE_NAMES, 1)
  params:set_action("root", stage)
  params:add_option("scale", "scale", H.scale_names(), 1)
  params:set_action("scale", stage)
  params:add_option("progression", "progression", Cd.mode_names(), 2)
  params:set_action("progression", function() Cd.reroll() end)
  params:add_number("chords", "chords", 2, 8, 4)
  params:set_action("chords", function() if Cd.mode() == 2 then Cd.reroll() end end)
  params:add_option("chord_rate", "chord rate", Cd.RATE_NAMES, 2)
  params:add_number("harmony_drift", "harmony drift", 0, 100, 0, fmt_pct)
  params:add_number("harmony_gravity", "harmony gravity", 0, 100, 50, fmt_pct)
  params:add_trigger("next_chord", "next chord")
  params:set_action("next_chord", function() Cd.request_next(not C.playing) end)
  params:add_trigger("home", "home")
  params:set_action("home", function() Cd.request_home(not C.playing) end)
  params:add_trigger("reroll_progression", "re-roll progression")
  params:set_action("reroll_progression", function() Cd.reroll() end)
  params:add_trigger("save_progression", "save progression")
  params:set_action("save_progression", function() Cd.save(); show("PROGRESSION SAVED") end)
end

local function add_global_params(names)
  params:add_separator("lagom_density_sep", "density")
  params:add_number("global_density", "density offset", -100, 100, 0, fmt_pct)
  params:add_number("deadzone", "deadzone", 0, 15, 6, function(p) return "±" .. p:get() .. "%" end)
  params:add_separator("lagom_ctrl_sep", "controller")
  params:add_option("controller_port", "controller port", names, 1)
  params:set_action("controller_port", function() Mix.refresh() end)
end

-- show only the params that matter for a track's type
local PITCH_PARAMS = {"range", "tension", "base", "legato", "legprob"}
local function update_visibility(i)
  local pre = "t" .. i .. "_"
  local ty = params:get(pre .. "type")
  local drums = ty == 3
  local function vis(id, on)
    if on then params:show(pre .. id) else params:hide(pre .. id) end
  end
  vis("voices", ty ~= 1)
  for _, id in ipairs(PITCH_PARAMS) do vis(id, not drums) end
  for l = 1, 8 do
    vis("lane" .. l .. "_note", drums)
    vis("lane" .. l .. "_role", drums)
  end
  if _menu and _menu.rebuild_params then _menu.rebuild_params() end
end

local function add_track_params(names)
  local note_name = function(p) return MU.note_num_to_name(p:get(), true) end
  for i = 1, K.NUM_TRACKS do
    local pre = "t" .. i .. "_"
    local tpl = TEMPLATE[i]
    local function on_change(f)
      return function(x) if tracks[i] then f(tracks[i], x) end end
    end
    params:add_group("track_" .. i, "track " .. i, 36)
    -- perform
    params:add_number(pre .. "density", "density", 0, 100, 0, fmt_pct)
    params:add_binary(pre .. "mute", "mute", "toggle", 0)
    params:set_action(pre .. "mute", function(x)
      if x == 1 then Seq.flush_track(i) end
      Mix.led_mute(i, x == 1)
    end)
    params:add_trigger(pre .. "reroll", "re-roll")
    params:set_action(pre .. "reroll", on_change(function(t) t:roll() end))
    -- shape
    params:add_number(pre .. "len", "length", 1, K.MAX_STEPS, 16)
    params:add_option(pre .. "div", "division", K.DIV_NAMES, K.DIV_DEFAULT)
    params:add_number(pre .. "range", "range", 1, K.MAX_RANGE, tpl[4], fmt_range)
    params:add_number(pre .. "gate", "gate", 5, 100, 50, fmt_pct)
    -- setup
    params:add_option(pre .. "type", "type", Track.TYPES, tpl[1])
    params:set_action(pre .. "type", on_change(function(t)
      Seq.flush_track(i)
      t:release_voicing()
      t:rank_all()
      update_visibility(i)
    end))
    params:add_number(pre .. "voices", "voices / lanes", 1, 8, 4)
    params:add_option(pre .. "port", "port", names, 2)
    params:add_number(pre .. "ch", "channel", 1, 16, i)
    params:add_number(pre .. "base", "base note", 0, 127, tpl[3], note_name)
    params:add_option(pre .. "tension", "tension", H.TENSIONS, tpl[2])
    params:add_option(pre .. "restart", "restart", Track.RESTART_NAMES, 1)
    -- feel
    params:add_binary(pre .. "fixgate", "fixed gate", "toggle", 1)
    params:add_binary(pre .. "velon", "velocity", "toggle", 0)
    params:add_number(pre .. "vel", "vel", 1, 127, 100)
    params:add_number(pre .. "velspread", "vel spread", 0, 64, 20)
    params:add_option(pre .. "legato", "legato", Track.LEGATO, 1)
    params:add_number(pre .. "legprob", "legato prob", 0, 100, 25, fmt_pct)
    params:set_action(pre .. "legprob", on_change(function(t) t:roll_legato() end))
    -- drum lanes
    for l = 1, 8 do
      params:add_number(pre .. "lane" .. l .. "_note", "lane " .. l .. " note", 0, 127,
        Track.DRUM_NOTES[l], note_name)
      params:add_option(pre .. "lane" .. l .. "_role", "lane " .. l .. " role", Track.ROLES,
        Track.DRUM_ROLES[l])
      params:set_action(pre .. "lane" .. l .. "_role", on_change(function(t) t:rank_lane(l) end))
    end
  end
end

function init()
  math.randomseed(os.time())
  Out.init()
  Mix.init(Out)
  Track.H = H

  local names = Out.port_names()
  params:add_separator("lagom", "lagom")
  C.add_params(names)
  add_harmony_params()
  add_global_params(names)
  add_track_params(names)
  for i = 1, K.NUM_TRACKS do tracks[i] = Track.new(i) end

  Cd.init(H)
  Cd.on_change = function() Mix.blink_bank_right() end
  C.init(Out,
    function() Seq.reset(); Cd.start(); Seq.catch_up() end,
    function() Seq.stop_all() end)
  Seq.init(Out, C, tracks)
  Seq.on_bar = function(n)
    H.apply()
    Cd.bar(n == 0)
    -- restart: realign tracks every n bars of the master clock
    for _, t in ipairs(tracks) do
      local r = Track.RESTART_BARS[t:p("restart")]
      if r > 0 and n > 0 and n % r == 0 then t:reset() end
    end
  end

  -- route all midi input through one dispatcher
  for i = 1, 16 do
    Out.ports[i].event = function(data)
      C.midi_in(i, data)
      if i == Mix.port() then Mix.event(data) end
    end
  end

  params:bang()
  H.apply()
  Cd.save()
  Mix.refresh()
  Seq.start()

  redraw_coro = clock.run(function()
    while true do
      clock.sleep(1 / 15)
      redraw()
    end
  end)
  -- handle for REPL introspection while developing
  _lagom = {tracks = tracks, C = C, Seq = Seq, Out = Out, Mix = Mix, H = H, Cd = Cd}
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
  local lanes = t:num_lanes()
  for l = 1, lanes do t:update_order(len, l) end
  local dens = t:density()

  screen.level(muted and 2 or 8)
  screen.move(0, y + 4)
  screen.text(i)

  for s = 1, len do
    local audible = false
    for l = 1, lanes do audible = audible or t:is_audible(s, len, dens, l) end
    local lvl = audible and 9 or 2
    if C.playing and s == t.pos then lvl = audible and 15 or 6 end
    if muted then lvl = math.min(lvl, 3) end
    screen.level(lvl)
    screen.rect(6 + (s - 1) * 2, y, 1, 4)
    screen.fill()
  end

  -- density bar: fill = fader, tick = effective
  local bx, bw = 72, 10
  screen.level(1)
  screen.rect(bx, y + 1, bw, 2)
  screen.fill()
  screen.level(muted and 3 or 6)
  screen.rect(bx, y + 1, math.floor(t:p("density") / 100 * bw + 0.5), 2)
  screen.fill()
  screen.level(15)
  screen.rect(bx + math.min(bw - 1, math.floor(dens * bw + 0.5)), y, 1, 4)
  screen.fill()

  -- sequence length and division
  screen.level(muted and 3 or 12)
  screen.move(91, y + 4)
  screen.text_right(len)
  screen.level(muted and 3 or 9)
  screen.move(94, y + 4)
  screen.text(K.DIV_SHORT[t:p("div")])

  screen.level(muted and 2 or 5)
  screen.move(112, y + 4)
  local ty = t:p("type")
  local label = ty == 1 and H.TENSION_SHORT[t:p("tension")]
    or ((ty == 2 and "CH" or "DR") .. t:p("voices"))
  screen.text(muted and "MUT" or label)
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

-- chord, progression dots, key, tempo
local function draw_header()
  screen.level(15)
  screen.move(0, 6)
  if C.warning then
    screen.text("! " .. C.warning)
    return
  end
  if util.time() < flash_until then
    screen.text(flash)
    return
  end
  if not Mix.synced then
    screen.text("PRESS SEND ALL ON MIDIMIX")
    return
  end
  local pending = Cd.pending_next or Cd.pending_home
  screen.level(pending and 8 or 15)
  screen.text(string.upper(H.chord_label(H.degree)))

  for i = 1, #Cd.working do
    screen.level(i == Cd.idx and 15 or 3)
    screen.rect(40 + (i - 1) * 3, 3, 2, 2)
    screen.fill()
  end
  if Cd.unsaved() then
    screen.level(8)
    screen.move(40 + #Cd.working * 3, 6)
    screen.text("*")
  end

  screen.level(H.pending and 15 or 5)
  screen.move(70, 6)
  screen.text(H.key_label())
  screen.level(C.playing and 12 or 4)
  screen.move(125, 6)
  screen.text_right(C.is_slave() and "EXT" or math.floor(clock.get_tempo() + 0.5))
end

function redraw()
  screen.clear()
  screen.font_face(25)
  screen.font_size(6)

  draw_header()

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
