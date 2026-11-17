-- the tick loop: one coroutine drives clock, tracks and note-offs
local K = include("lib/const")

local Seq = {tracks = {}, tick_now = 0}
local Out, C
local offs = {}       -- pending note-offs {at, p, c, n}
local last_tick = nil
local coro

-- garbage collection: the automatic collector can stop the world for 15-40 ms
-- (tens of thousands of small step tables), which is audible. instead the
-- tick loop runs it in small steps right after each tick's work, when
-- nothing is due until the next tick.
local GC_STEP_KB = 16
Seq.gc_max = 0          -- longest gc step seen (s), for tuning

function Seq.init(out, clockio, tracks)
  Out, C, Seq.tracks = out, clockio, tracks
end

function Seq.note(t, p, c, n, v, gate, id)
  Out.note_on(p, c, n, v)
  offs[#offs + 1] = {at = t + gate, p = p, c = c, n = n, id = id}
end

-- end every sounding note of one track now (mute)
function Seq.flush_track(id)
  for i = #offs, 1, -1 do
    local o = offs[i]
    if o.id == id then
      Out.note_off(o.p, o.c, o.n)
      table.remove(offs, i)
    end
  end
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

-- bar lines first (harmony lands there), then every track due on this tick
local function step_tracks(t)
  local rel = t - C.origin
  if rel < 0 then return end
  local bar = params:get("beats_per_bar") * K.PPQN
  if rel % bar == 0 and Seq.on_bar then Seq.on_bar(rel // bar) end
  for _, tr in ipairs(Seq.tracks) do
    local div = K.DIV_TICKS[tr:p("div")]
    if rel % div == 0 then tr:step(t, Seq, rel) end
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
    local t0 = util.time()
    collectgarbage("step", GC_STEP_KB)
    local dt = util.time() - t0
    if dt > Seq.gc_max then Seq.gc_max = dt end
  end
end

function Seq.start()
  collectgarbage("stop")
  coro = clock.run(loop)
end

function Seq.cleanup()
  if coro then clock.cancel(coro) end
  collectgarbage("restart")
  Seq.stop_all()
end

return Seq
