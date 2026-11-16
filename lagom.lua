-- lagom
-- generative midi sequencer
-- 8 tracks, always in harmony
--
-- K3 play / stop
--
-- v0.1 (step 1: clock + one track)

local K = include("lib/const")
local Out = include("lib/out")
local C = include("lib/clockio")
local Track = include("lib/track")
local Seq = include("lib/seq")

local tracks = {}
local redraw_coro

local function add_track_params(names)
  for i = 1, K.NUM_TRACKS do
    local pre = "t" .. i .. "_"
    params:add_group("track_" .. i, "track " .. i, 8)
    params:add_option(pre .. "port", "port", names, 2)
    params:add_number(pre .. "ch", "channel", 1, 16, i)
    params:add_option(pre .. "div", "division", K.DIV_NAMES, K.DIV_DEFAULT)
    params:add_number(pre .. "len", "length", 1, K.MAX_STEPS, 16)
    params:add_number(pre .. "gate", "gate", 5, 100, 50, function(p) return p:get() .. "%" end)
    params:add_number(pre .. "density", "density", 0, 100, 100, function(p) return p:get() .. "%" end)
    params:add_binary(pre .. "mute", "mute", "toggle", i == 1 and 0 or 1)
    params:set_action(pre .. "mute", function(x) if x == 1 then Out.panic() end end)
    params:add_trigger(pre .. "reroll", "re-roll")
    params:set_action(pre .. "reroll", function() tracks[i]:roll() end)
  end
end

function init()
  math.randomseed(os.time())
  Out.init()
  for i = 1, K.NUM_TRACKS do tracks[i] = Track.new(i) end

  local names = Out.port_names()
  params:add_separator("lagom", "lagom")
  C.add_params(names)
  add_track_params(names)

  C.init(Out,
    function() Seq.reset(); Seq.catch_up() end,
    function() Seq.stop_all() end)
  Seq.init(Out, C, tracks)

  -- route all midi input through one dispatcher
  for i = 1, 16 do
    Out.ports[i].event = function(data) C.midi_in(i, data) end
  end

  params:bang()
  Seq.start()

  redraw_coro = clock.run(function()
    while true do
      clock.sleep(1 / 15)
      redraw()
    end
  end)
  -- handle for REPL introspection while developing
  _lagom = {tracks = tracks, C = C, Seq = Seq, Out = Out}
  print("lagom: init ok")
end

function key(n, z)
  if n == 3 and z == 1 then
    params:set("play", 1 - params:get("play"))
  end
end

function enc(n, d) end

function redraw()
  screen.clear()
  screen.font_face(25)
  screen.font_size(6)
  screen.level(15)
  screen.move(0, 6)
  screen.text("LAGOM  STEP 1")
  screen.level(6)
  screen.move(0, 18)
  screen.text(params:string("lagom_clock_mode") .. "  " .. math.floor(clock.get_tempo() + 0.5) .. " BPM")
  screen.move(0, 26)
  screen.text(C.playing and "PLAYING" or (C.pending_start and "WAITING" or "STOPPED"))
  local t = tracks[1]
  screen.move(0, 38)
  screen.text("T1 STEP " .. t.pos .. "/" .. params:get("t1_len"))
  screen.move(0, 46)
  screen.text("NOTE " .. (t.last_note and require("musicutil").note_num_to_name(t.last_note, true) or "-"))
  if C.warning then
    screen.level(15)
    screen.move(0, 62)
    screen.text("! " .. C.warning)
  end
  -- step strip for track 1
  local len = params:get("t1_len")
  for s = 1, len do
    screen.level(s == t.pos and 15 or 3)
    screen.rect(60 + (s - 1) * 2, 36, 1, 4)
    screen.fill()
  end
  screen.update()
end

function cleanup()
  if redraw_coro then clock.cancel(redraw_coro) end
  if C.playing and not C.is_slave() then
    for _, p in ipairs(C.out_ports()) do Out.send_byte(p, 0xFC) end
  end
  Seq.cleanup()
end
