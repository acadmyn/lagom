-- clock master/slave, raw clock thru, clock out, transport
local K = include("lib/const")

local C = {
  playing = false,
  pending_start = false,
  origin = 0,        -- absolute tick of step 1 / beat 1
  warning = nil,
}

local Out          -- injected
local on_start, on_stop

local RT = {[0xF8] = true, [0xFA] = true, [0xFB] = true, [0xFC] = true}

function C.init(out, start_cb, stop_cb)
  Out = out
  on_start, on_stop = start_cb, stop_cb

  clock.transport.start = function()
    if not C.is_slave() then return end
    C.origin = math.floor(clock.get_beats() * K.PPQN + 0.5)
    C.playing = true
    C.pending_start = false
    params:set("play", 1, true)
    on_start()
  end

  clock.transport.stop = function()
    if not C.is_slave() then return end
    C.halt()
  end
end

function C.is_slave() return params:get("lagom_clock_mode") == 2 end

function C.add_params(names)
  params:add_separator("lagom_clock_sep", "clock")
  params:add_option("lagom_clock_mode", "clock mode", {"master", "slave"}, 1)
  params:set_action("lagom_clock_mode", function(x)
    C.halt()
    params:set("clock_source", x == 1 and 1 or 2)
    C.apply_clock_in()
  end)
  params:add_option("lagom_clock_in", "clock in port", names, 2)
  params:set_action("lagom_clock_in", function() C.apply_clock_in() end)
  params:add_binary("play", "play", "toggle", 0)
  params:set_action("play", function(x)
    if x == 1 then C.request_start() else C.request_stop() end
  end)
  params:add_group("lagom_clock_out", "clock out ports", 16)
  for i = 1, 16 do
    params:add_binary("lagom_clk_out_" .. i, "→ " .. names[i], "toggle", 0)
    params:set_action("lagom_clk_out_" .. i, function() C.check_conflicts() end)
  end
end

-- in slave mode, tell the system clock to only listen to our clock-in port
function C.apply_clock_in()
  if C.is_slave() then
    params:set("clock_midi_in", params:get("lagom_clock_in") + 2)
  end
  C.check_conflicts()
end

-- the system "midi clock out" regenerates clock; if it is on for a port we
-- also feed, that port gets doubled ticks
function C.check_conflicts()
  C.warning = nil
  for i = 1, 16 do
    if params:get("lagom_clk_out_" .. i) == 1 and params:get("clock_midi_out_" .. i) == 1 then
      C.warning = "sys clk out on port " .. i
      print("lagom: WARNING system midi clock out is enabled on port " .. i ..
            " - disable it in PARAMETERS > CLOCK to avoid doubled clock")
    end
  end
end

function C.out_ports()
  local t = {}
  for i = 1, 16 do
    if params:get("lagom_clk_out_" .. i) == 1 then t[#t + 1] = i end
  end
  return t
end

local function send_all(b, skip)
  for _, p in ipairs(C.out_ports()) do
    if p ~= skip then Out.send_byte(p, b) end
  end
end

function C.request_start()
  if C.playing or C.pending_start then return end
  C.pending_start = true
end

function C.request_stop()
  if not (C.playing or C.pending_start) then return end
  if not C.is_slave() then send_all(0xFC) end
  C.halt()
end

function C.halt()
  local was = C.playing
  C.playing = false
  C.pending_start = false
  params:set("play", 0, true)
  if was then on_stop() end
end

-- called once per internal tick (absolute tick index t)
function C.tick(t)
  if C.is_slave() then
    -- local start while slaved (no external Start received): begin on a beat
    if C.pending_start and t % K.PPQN == 0 then
      C.origin = t
      C.playing = true
      C.pending_start = false
      on_start()
    end
  else
    if t % 2 == 0 then   -- 24 ppqn
      if C.pending_start then
        send_all(0xFA)
        C.origin = t
        C.playing = true
        C.pending_start = false
        on_start()
      end
      send_all(0xF8)
    end
  end
end

-- raw midi from any port; forwards realtime bytes from the clock-in port
function C.midi_in(port, data)
  local b = data[1]
  if RT[b] and C.is_slave() and port == params:get("lagom_clock_in") then
    send_all(b, port)
  end
end

return C
