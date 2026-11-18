-- TRS MIDI loopback test (#10). patch the norns' TRS MIDI out into its own
-- TRS MIDI in, then from the REPL:
--   dofile("/home/we/dust/data/lagom/midi_loopback.lua")
--   LB.run(4)            -- vport of the `virtual` device
--   print(LB.report())   -- after it finishes (LB.done == true)
-- tests: (1) spaced single notes: latency and jitter; (2) bursts of n notes
-- sent at once: losses and how long the burst takes to arrive (wire time is
-- about 0.96 ms per 3-byte message at 31250 baud)

LB = LB or {}

local function stats(xs)
  if #xs == 0 then return "no data" end
  local sum, mn, mx = 0, math.huge, -math.huge
  for _, x in ipairs(xs) do sum = sum + x; mn = math.min(mn, x); mx = math.max(mx, x) end
  local mean = sum / #xs
  local var = 0
  for _, x in ipairs(xs) do var = var + (x - mean) ^ 2 end
  table.sort(xs)
  local p99 = xs[math.max(1, math.floor(#xs * 0.99))]
  return string.format("n=%d mean=%.2f min=%.2f max=%.2f p99=%.2f sd=%.2f ms",
                       #xs, mean, mn, mx, p99, math.sqrt(var / #xs))
end

function LB.run(vp, opts)
  opts = opts or {}
  local port = midi.vports[vp]
  LB.prev_event = port.event
  LB.done, LB.sent, LB.recv, LB.extra = false, {}, {}, 0
  LB.lines = {}
  -- key = channel * 128 + note; value = send time
  port.event = function(data)
    local t = util.time()
    local st = data[1]
    if st and st >= 0x90 and st <= 0x9F and data[3] and data[3] > 0 then
      local k = (st - 0x90) * 128 + data[2]
      if LB.sent[k] and not LB.recv[k] then LB.recv[k] = t else LB.extra = LB.extra + 1 end
    end
  end

  clock.run(function()
    -- 1. single notes, 25 ms apart, notes 0..127 on channel 16
    local lat = {}
    LB.sent, LB.recv = {}, {}
    for n = 0, (opts.singles or 128) - 1 do
      local k = 15 * 128 + n
      LB.sent[k] = util.time()
      port:note_on(n, 100, 16)
      clock.sleep(0.012)
      port:note_off(n, 0, 16)
      clock.sleep(0.013)
    end
    clock.sleep(0.3)
    local lost = 0
    for k, t in pairs(LB.sent) do
      if LB.recv[k] then lat[#lat + 1] = (LB.recv[k] - t) * 1000 else lost = lost + 1 end
    end
    LB.lines[#LB.lines + 1] = "singles: " .. stats(lat) .. " lost=" .. lost

    -- 2. bursts: n note-ons at once (then their offs), channels 1..16
    for _, size in ipairs(opts.bursts or {8, 16, 32, 64}) do
      LB.sent, LB.recv = {}, {}
      local t0 = util.time()
      for i = 0, size - 1 do
        local ch, n = i % 16 + 1, 60 + i // 16
        LB.sent[(ch - 1) * 128 + n] = t0
        port:note_on(n, 100, ch)
      end
      clock.sleep(0.5)
      local lost2, last = 0, 0
      for k in pairs(LB.sent) do
        if LB.recv[k] then last = math.max(last, (LB.recv[k] - t0) * 1000) else lost2 = lost2 + 1 end
      end
      for i = 0, size - 1 do port:note_off(60 + i // 16, 0, i % 16 + 1) end
      clock.sleep(0.3)
      LB.lines[#LB.lines + 1] = string.format(
        "burst %2d: last arrived after %.1f ms (wire minimum %.1f ms), lost=%d",
        size, last, size * 0.96, lost2)
    end
    LB.lines[#LB.lines + 1] = "unexpected messages: " .. LB.extra
    port.event = LB.prev_event
    LB.done = true
  end)
end

function LB.report() return table.concat(LB.lines or {}, "\n") end
