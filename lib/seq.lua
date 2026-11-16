-- the tick loop: one coroutine drives clock, tracks and note-offs
local K = include("lib/const")

local Seq = {tracks = {}, tick_now = 0}
local Out, C
local offs = {}       -- pending note-offs {at, p, c, n}
local last_tick = nil
local coro

function Seq.init(out, clockio, tracks)
  Out, C, Seq.tracks = out, clockio, tracks
end

function Seq.note(t, p, c, n, v, gate)
  Out.note_on(p, c, n, v)
  offs[#offs + 1] = {at = t + gate, p = p, c = c, n = n}
end

local function process_offs(t)
  for i = #offs, 1, -1 do
    local o = offs[i]
    if o.at <= t then
      Out.note_off(o.p, o.c, o.n)
      table.remove(offs, i)
    end
  end
end

function Seq.reset()
  for _, tr in ipairs(Seq.tracks) do tr:reset() end
end

function Seq.stop_all()
  offs = {}
  Out.panic()
end

local function step_tracks(t)
  local rel = t - C.origin
  if rel < 0 then return end
  for _, tr in ipairs(Seq.tracks) do
    local div = K.DIV_TICKS[tr:p("div")]
    if rel % div == 0 then tr:step(t, Seq) end
  end
end

local function tick(t)
  Seq.tick_now = t
  process_offs(t)
  C.tick(t)
  if C.playing then step_tracks(t) end
end

-- external Start can arrive just after the loop already handled beat 0;
-- replay any track steps between origin and the last processed tick
function Seq.catch_up()
  if last_tick == nil then return end
  for t = C.origin, last_tick do step_tracks(t) end
end

local function loop()
  while true do
    clock.sync(1 / K.PPQN)
    local now = math.floor(clock.get_beats() * K.PPQN + 0.5)
    if last_tick == nil or now <= last_tick - K.PPQN or now - last_tick > K.PPQN then
      -- first run, or clock jumped (restart / reset): don't burst-catch-up
      last_tick = now - 1
    end
    for t = last_tick + 1, now do tick(t) end
    if now > last_tick then last_tick = now end
  end
end

function Seq.start()
  coro = clock.run(loop)
end

function Seq.cleanup()
  if coro then clock.cancel(coro) end
  Seq.stop_all()
end

return Seq
