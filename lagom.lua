-- lagom
-- generative midi sequencer
-- 8 tracks, always in harmony
--
-- K3 play / stop
-- K2 cancel note learn
-- midimix: faders = density
-- knobs = range / division / length
-- mute = mute, rec arm: tap
--   re-roll, hold save
-- solo+mute/rec: next/prev slot
-- bank left held: alt knobs
--   (drift/gravity/gate),
--   +rec revert, +mute undo
-- bank right: tap next chord,
--   hold home
-- solo+bank right: tap play,
--   hold save progression
-- solo+bank left hold: save all
-- psets = sets (all slots),
-- autosaved; scenes in params
--
-- E1 page, E2 select, E3 change
-- K2 back, K3 play/confirm
-- scenes page: K2 store, K3 recall
--
-- v0.7 (step 7: screen)

local K = include("lib/const")
local MU = require "musicutil"
local Out = include("lib/out")
local C = include("lib/clockio")
local Track = include("lib/track")
include("lib/slots")(Track)
local Seq = include("lib/seq")
local Mix = include("lib/midimix")
local H = include("lib/harmony")
local Cd = include("lib/conductor")
local Learn = include("lib/learn")
local Confirm = include("lib/confirm")
local S = include("lib/store")
local UI = include("lib/ui")
local Trs = include("lib/trs")

local tracks = {}
local redraw_coro

local function show(msg) UI.message(msg) end

local function fmt_pct(p) return p:get() .. "%" end

local function fmt_range(p)
  local v = p:get()
  if v % 12 == 0 then return (v // 12) .. " oct" end
  return v .. " st"
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
  params:add_number("chords", "chords", 1, 8, 4)
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
  params:set_action("save_progression", function() Cd.save(); UI.saved("SAVED", "PROGRESSION") end)
end

local function add_global_params(names)
  params:add_separator("lagom_density_sep", "density")
  params:add_number("global_density", "density offset", -100, 100, 0, fmt_pct)
  params:set_action("global_density", function() UI.global_moved() end)
  params:add_number("deadzone", "deadzone", 0, 15, 6, function(p) return "±" .. p:get() .. "%" end)
  params:add_separator("lagom_ctrl_sep", "controller")
  params:add_option("controller_port", "controller port", names, 1)
  params:set_action("controller_port", function() Mix.refresh() end)
  params:add_separator("lagom_slots_sep", "slots")
  params:add_trigger("save_all", "save all tracks")
  params:set_action("save_all", function()
    for _, t in ipairs(tracks) do t:save() end
    UI.saved("SAVED", "ALL TRACKS")
  end)
  params:add_group("lagom_scenes", "scenes", 16)
  for k = 1, 8 do
    params:add_trigger("scene_store_" .. k, "store scene " .. k)
    params:set_action("scene_store_" .. k, function()
      S.store_scene(k)
      show("SCENE " .. k .. " STORED")
    end)
  end
  for k = 1, 8 do
    params:add_trigger("scene_recall_" .. k, "recall scene " .. k)
    params:set_action("scene_recall_" .. k, function()
      if S.recall_scene(k, not C.playing) then
        show("SCENE " .. k)
      else
        show("SCENE " .. k .. " IS EMPTY")
      end
    end)
  end
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
  vis("learn_all", drums)
  for l = 1, 8 do
    local eu = params:get(pre .. "lane" .. l .. "_mode") == 2
    vis("lane" .. l .. "_note", drums)
    vis("lane" .. l .. "_role", drums)
    vis("lane" .. l .. "_learn", drums)
    vis("lane" .. l .. "_mode", drums)
    vis("lane" .. l .. "_hits", drums and eu)
    vis("lane" .. l .. "_rotate", drums and eu)
    vis("lane" .. l .. "_max", drums and not eu)
    vis("lane" .. l .. "_from", drums)
    vis("lane" .. l .. "_to", drums)
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
    params:add_group("track_" .. i, "track " .. i, 110)
    params:add_binary(pre .. "enabled", "enabled", "toggle", 1)
    params:set_action(pre .. "enabled", function(x)
      if x == 0 then Seq.flush_track(i) end
      UI.layout_dirty = true
    end)
    -- perform
    params:add_number(pre .. "density", "density", 0, 100, 0, fmt_pct)
    params:add_binary(pre .. "mute", "mute", "toggle", 0)
    params:set_action(pre .. "mute", function(x)
      if x == 1 then Seq.flush_track(i) end
      Mix.led_mute(i, x == 1)
    end)
    local function req(kind, arg_fn)
      return on_change(function(t, x)
        t:request(kind, arg_fn and arg_fn(t, x), not C.playing)
      end)
    end
    params:add_trigger(pre .. "reroll", "re-roll")
    params:set_action(pre .. "reroll", req("reroll"))
    params:add_trigger(pre .. "save", "save")
    params:set_action(pre .. "save", on_change(function(t)
      t:save()
      UI.saved("SAVED", "T" .. i .. " SLOT " .. t.slot)
    end))
    params:add_trigger(pre .. "revert", "revert")
    params:set_action(pre .. "revert", req("revert"))
    params:add_trigger(pre .. "undo", "undo")
    params:set_action(pre .. "undo", req("undo"))
    params:add_number(pre .. "slot", "slot", 1, Track.NUM_SLOTS, 1)
    params:set_action(pre .. "slot", req("slot", function(_, x) return x end))
    params:add_trigger(pre .. "slot_next", "slot next")
    params:set_action(pre .. "slot_next", req("slot", function(t) return t:target_slot() + 1 end))
    params:add_trigger(pre .. "slot_prev", "slot prev")
    params:set_action(pre .. "slot_prev", req("slot", function(t) return t:target_slot() - 1 end))
    params:add_trigger(pre .. "shift_left", "shift left")
    params:set_action(pre .. "shift_left", on_change(function(t) t:shift(-1) end))
    params:add_trigger(pre .. "shift_right", "shift right")
    params:set_action(pre .. "shift_right", on_change(function(t) t:shift(1) end))
    params:add_trigger(pre .. "move_earlier", "move slot earlier")
    params:set_action(pre .. "move_earlier", on_change(function(t)
      if t:move_slot(-1) then show("T" .. i .. " SLOT MOVED TO " .. t.slot) end
    end))
    params:add_trigger(pre .. "move_later", "move slot later")
    params:set_action(pre .. "move_later", on_change(function(t)
      if t:move_slot(1) then show("T" .. i .. " SLOT MOVED TO " .. t.slot) end
    end))
    params:add_number(pre .. "copy_to", "copy to slot", 1, Track.NUM_SLOTS, 2)
    params:add_trigger(pre .. "copy", "copy slot")
    params:set_action(pre .. "copy", on_change(function(t)
      local n = params:get(pre .. "copy_to")
      if n == t.slot then show("PICK ANOTHER SLOT TO COPY TO"); return end
      local function go()
        if t:copy_slot_to(n) then show("T" .. i .. " SLOT " .. t.slot .. " COPIED TO " .. n) end
      end
      if t.slots[n] then
        Confirm.ask({"OVERWRITE T" .. i .. " SLOT " .. n .. "?"}, go, nil, true)
      else
        go()
      end
    end))
    params:add_trigger(pre .. "clear", "clear slot")
    params:set_action(pre .. "clear", on_change(function(t)
      Confirm.ask({"CLEAR T" .. i .. " SLOT " .. t:target_slot() .. "?"},
        function() t:request("clear", nil, not C.playing) end, nil, true)
    end))
    -- shape (stored with each slot)
    local dirty = on_change(function(t) t:touch() end)
    params:add_number(pre .. "len", "length", 1, K.MAX_STEPS, 16)
    params:add_option(pre .. "div", "division", K.DIV_NAMES, K.DIV_DEFAULT)
    params:add_number(pre .. "range", "range", 1, K.MAX_RANGE, tpl[4], fmt_range)
    params:add_number(pre .. "gate", "gate", 5, 100, 50, fmt_pct)
    params:add_number(pre .. "drift", "drift", 0, 100, 0, fmt_pct)
    params:add_number(pre .. "gravity", "gravity", 0, 100, 50, fmt_pct)
    for _, k in ipairs(Track.SHAPE) do params:set_action(pre .. k, dirty) end
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
    params:add_number(pre .. "motif", "motif size", 0, 8, 4)
    -- feel
    params:add_binary(pre .. "fixgate", "fixed gate", "toggle", 1)
    params:add_binary(pre .. "velon", "velocity", "toggle", 0)
    params:add_number(pre .. "vel", "vel", 1, 127, 100)
    params:add_number(pre .. "velspread", "vel spread", 0, 64, 20)
    params:add_option(pre .. "legato", "legato", Track.LEGATO, 1)
    params:add_number(pre .. "legprob", "legato prob", 0, 100, 25, fmt_pct)
    params:set_action(pre .. "legprob", on_change(function(t) t:roll_legato() end))
    -- drum lanes
    params:add_trigger(pre .. "learn_all", "learn all lanes")
    params:set_action(pre .. "learn_all", function() Learn.arm(i, 1, params:get(pre .. "voices")) end)
    for l = 1, 8 do
      params:add_number(pre .. "lane" .. l .. "_note", "lane " .. l .. " note", 0, 127,
        Track.DRUM_NOTES[l], note_name)
      params:add_option(pre .. "lane" .. l .. "_role", "lane " .. l .. " role", Track.ROLES,
        Track.DRUM_ROLES[l])
      params:set_action(pre .. "lane" .. l .. "_role", on_change(function(t) t:rank_lane(l) end))
      params:add_trigger(pre .. "lane" .. l .. "_learn", "lane " .. l .. " learn")
      params:set_action(pre .. "lane" .. l .. "_learn", function() Learn.arm(i, l) end)
      -- rank: steps come in by rank up to `max`; euclid: `hits` evenly
      -- spread, rotated. `from`..`to` is the lane's stretch of the fader
      local lp = pre .. "lane" .. l .. "_"
      params:add_option(lp .. "mode", "lane " .. l .. " mode", Track.LANE_MODES, 1)
      params:set_action(lp .. "mode", function() update_visibility(i) end)
      params:add_number(lp .. "hits", "lane " .. l .. " hits", 0, K.MAX_STEPS, 4)
      params:add_number(lp .. "rotate", "lane " .. l .. " rotate", 0, K.MAX_STEPS - 1, 0)
      params:add_number(lp .. "max", "lane " .. l .. " max", 0, 100, 100, fmt_pct)
      params:add_number(lp .. "from", "lane " .. l .. " from", 0, 100, 0, fmt_pct)
      params:add_number(lp .. "to", "lane " .. l .. " to", 0, 100, 100, fmt_pct)
    end
  end
end

function init()
  math.randomseed(os.time())
  Trs.connect()
  Out.init()
  Mix.init(Out, tracks)
  Track.H = H

  local names = Out.port_names()
  local first_param = #params.params + 1
  params:add_separator("lagom", "lagom")
  C.add_params(names)
  add_harmony_params()
  add_global_params(names)
  add_track_params(names)
  for i = 1, K.NUM_TRACKS do tracks[i] = Track.new(i) end
  Track.on_shape_loaded = function(id) Mix.uncatch(id) end
  Track.on_slot_changed = function() S.due = true end
  Track.on_applied = function(t) UI.track_changed(t.id) end
  Track.on_slots_swapped = function(t, a, b) S.swap_slots(t.id, a, b) end
  Track.ask_drop = function(t, e, answer)
    Confirm.ask({"T" .. t.id .. " UNDO IS FULL", "DROP AN UNSAVED VERSION?"},
      function() answer(true) end, function() answer(false) end)
  end
  S.init(tracks, Cd, H, Confirm, first_param)
  S.hook_psets()

  Cd.init(H)
  Cd.on_change = function() Mix.blink_bank_right(); UI.chord_changed() end
  C.init(Out,
    function() Seq.reset(); Cd.start(); Seq.catch_up() end,
    function() Seq.stop_all() end)
  Seq.init(Out, C, tracks)
  Seq.on_bar = function(n)
    H.apply()
    Cd.bar(n == 0)
    for _, t in ipairs(tracks) do t:apply_pending() end
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
      if i == Mix.port() then
        Mix.event(data)
      else
        Learn.midi_in(data)
      end
    end
  end

  params:bang()
  H.apply()
  Cd.save()
  for _, t in ipairs(tracks) do t:save() end
  if S.load_autosave() then
    H.apply()
    print("lagom: restored autosave")
  end
  Mix.refresh()
  -- a re-plugged controller has lost its led state: push it again once the
  -- device is up (norns resets midi.add when the script exits)
  midi.add = function(dev)
    Out.devices_changed()
    if dev.port ~= nil and dev.port == Mix.port() then
      clock.run(function() clock.sleep(0.5); Mix.refresh() end)
    end
  end
  midi.remove = function() Out.devices_changed() end
  local name_ids, clk_ids = {"controller_port", "lagom_clock_in"}, {}
  for i = 1, K.NUM_TRACKS do name_ids[#name_ids + 1] = "t" .. i .. "_port" end
  for i = 1, 16 do clk_ids[i] = "lagom_clk_out_" .. i end
  Out.name_params(name_ids, clk_ids)
  Out.poll()
  Seq.start()
  S.start()
  UI.init({tracks = tracks, Out = Out, C = C, H = H, Cd = Cd, Mix = Mix, Learn = Learn,
           Confirm = Confirm, S = S, Seq = Seq, Track = Track})

  redraw_coro = clock.run(function()
    while true do
      clock.sleep(1 / 15)
      redraw()
    end
  end)
  -- handle for REPL introspection while developing
  _lagom = {tracks = tracks, C = C, Seq = Seq, Out = Out, Mix = Mix, H = H, Cd = Cd, Learn = Learn,
            S = S, Confirm = Confirm, UI = UI}
  print("lagom: init ok")
end

function key(n, z)
  if z == 1 and Confirm.key(n) then return end
  if UI.key(n, z) then return end
  if n == 2 and z == 1 and Learn.active() then
    Learn.cancel()
  elseif n == 3 and z == 1 then
    params:set("play", 1 - params:get("play"))
  end
end

function enc(n, d) UI.enc(n, d) end

function redraw()
  UI.redraw()
  Mix.update_leds()
end

-- norns resumes a clock thread by id even after it was cancelled when its
-- wake-up was already queued, and core/clock.lua then errors "resume ...
-- thread expected" (#17). on reload that hits the threads cancelled during
-- teardown (ours and the system ones clock.cleanup stops). for 2 s, skip
-- resumes of threads that no longer exist, then put the original back
local function guard_stale_resumes()
  local orig, expires = clock.resume, util.time() + 2
  local guard
  guard = function(id, ...)
    if util.time() > expires and clock.resume == guard then clock.resume = orig end
    if clock.threads[id] == nil then return end
    return orig(id, ...)
  end
  clock.resume = guard
end

-- keep cleanup fast (a few ms): our coroutines stop first, and the autosave
-- runs while the GC is still stopped, with warm caches (lib/store.lua)
function cleanup()
  guard_stale_resumes()
  if redraw_coro then clock.cancel(redraw_coro) end
  S.stop()
  Seq.stop()
  S.autosave()
  S.unhook()
  if C.playing and not C.is_slave() then
    for _, p in ipairs(C.out_ports()) do Out.send_byte(p, 0xFC) end
  end
  Seq.cleanup()
end
