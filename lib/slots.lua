-- slots, working copy vs anchor, drift/gravity, undo, pending (next bar)
-- actions. adds methods to Track: include("lib/slots")(Track)
local K = include("lib/const")

local NUM_SLOTS = 16
local UNDO_MAX = 16
local DRIFT_COALESCE = 4   -- passes: drift snapshots closer than this merge

-- shape params stored with every slot
local SHAPE = {"len", "div", "range", "drift", "gravity", "gate", "gatemin", "gatemax"}
-- drum lane rhythm (euclid patterns) is stored with every slot too
local LANE_SHAPE = {}
for l = 1, 8 do
  for _, k in ipairs({"mode", "hits", "rotate"}) do
    LANE_SHAPE[#LANE_SHAPE + 1] = "lane" .. l .. "_" .. k
  end
end
local SHAPE_ALL = {}
for _, k in ipairs(SHAPE) do SHAPE_ALL[#SHAPE_ALL + 1] = k end
for _, k in ipairs(LANE_SHAPE) do SHAPE_ALL[#SHAPE_ALL + 1] = k end

local STEP_FIELDS = {"p", "v", "g", "rr", "leg", "r", "x"}

local function copy_lanes(lanes)
  local out = {}
  for l, lane in ipairs(lanes) do
    local steps = {}
    for s, st in ipairs(lane.steps) do
      steps[s] = {p = st.p, v = st.v, g = st.g, rr = st.rr, leg = st.leg, r = st.r,
                  x = st.x == true}
    end
    out[l] = {steps = steps, order = {}}
  end
  return out
end

local function lane_equal(a, b)
  local sa, sb = a.steps, b.steps
  for s = 1, #sa do
    local x, y = sa[s], sb[s]
    for _, f in ipairs(STEP_FIELDS) do
      if x[f] ~= y[f] then return false end
    end
  end
  return true
end

local function lanes_equal(a, b)
  for l = 1, #a do
    if not lane_equal(a[l], b[l]) then return false end
  end
  return true
end

-- lane <-> flat number list (for the set files): p v g rr r flags per step.
-- flags = leg (1) + euclid flip x (2), so older files (0/1) still load
local function flat_lane(lane)
  local f = {}
  for _, st in ipairs(lane.steps) do
    f[#f + 1] = st.p; f[#f + 1] = st.v; f[#f + 1] = st.g; f[#f + 1] = st.rr
    f[#f + 1] = st.r; f[#f + 1] = (st.leg and 1 or 0) + (st.x and 2 or 0)
  end
  return f
end

-- true when a lane still holds exactly the numbers in flat list f
local function lane_matches(lane, f)
  local steps = lane.steps
  if #f ~= #steps * 6 then return false end
  for s = 1, #steps do
    local st, i = steps[s], (s - 1) * 6
    if f[i + 1] ~= st.p or f[i + 2] ~= st.v or f[i + 3] ~= st.g or f[i + 4] ~= st.rr
       or f[i + 5] ~= st.r or f[i + 6] ~= (st.leg and 1 or 0) + (st.x and 2 or 0) then
      return false
    end
  end
  return true
end

-- a lane as {__raw = text} for the serializer, reusing the cached text while
-- the lane's numbers are unchanged (formatting is the slow part of a save)
local function lane_raw(lane, cache, l, fmt)
  local e = cache[l]
  if not (e and lane_matches(lane, e.flat)) then
    local f = flat_lane(lane)
    e = {flat = f, raw = {__raw = fmt(f)}}
    cache[l] = e
  end
  return e.raw
end

local function unflat_lane(f)
  local steps = {}
  for s = 1, #f // 6 do
    local i = (s - 1) * 6
    local fl = math.tointeger(f[i + 6]) or 0
    steps[s] = {p = f[i + 1], v = f[i + 2], g = f[i + 3], rr = f[i + 4],
                r = math.tointeger(f[i + 5]) or f[i + 5], leg = fl & 1 == 1, x = fl & 2 == 2}
  end
  return {steps = steps, order = {}}
end

local function shape_equal(a, b)
  for _, k in ipairs(SHAPE_ALL) do
    if a[k] ~= b[k] then return false end
  end
  return true
end

return function(Track)

  Track.SHAPE = SHAPE
  Track.LANE_SHAPE = LANE_SHAPE
  Track.NUM_SLOTS = NUM_SLOTS
  Track.on_shape_loaded = nil   -- callback(track id): knobs lose pickup
  Track.on_slot_changed = nil   -- callback(track): autosave
  Track.on_slots_swapped = nil  -- callback(track, a, b): scenes follow

  function Track:capture_shape()
    local sh = {}
    for _, k in ipairs(SHAPE_ALL) do sh[k] = self:p(k) end
    return sh
  end

  function Track:apply_shape(sh)
    for _, k in ipairs(SHAPE_ALL) do
      if sh[k] ~= nil then params:set("t" .. self.id .. "_" .. k, sh[k]) end
    end
    if Track.on_shape_loaded then Track.on_shape_loaded(self.id) end
  end

  function Track:snapshot()
    return {lanes = copy_lanes(self.lanes), shape = self:capture_shape()}
  end

  -- make a snapshot the live working copy of the current slot
  function Track:restore(snap)
    self.lanes = copy_lanes(snap.lanes)
    self.steps = self.lanes[1].steps
    self.slots[self.slot].work = self.lanes
    self:release_voicing()
    self:apply_shape(snap.shape)
    self:touch()
  end

  -- slots ------------------------------------------------------------------

  function Track:init_slots()
    self.slots = {}
    self.undo = {}
    self.passes = 0
    self.slot = 1
    self:generate_slot(1)
  end

  -- empty slot: fresh roll with the current shape; the roll is its anchor
  function Track:generate_slot(n)
    self:roll()
    local shape = self:capture_shape()
    self.slots[n] = {work = self.lanes, shape = shape,
                     anchor = {lanes = copy_lanes(self.lanes), shape = shape}}
    self:touch()
  end

  function Track:load_slot(n)
    -- park the shape of the slot we leave
    self.slots[self.slot].shape = self:capture_shape()
    self.slot = n
    if not self.slots[n] then
      self:generate_slot(n)
    else
      self.lanes = self.slots[n].work
      self.steps = self.lanes[1].steps
      for _, lane in ipairs(self.lanes) do lane.order_len = nil end
      self:release_voicing()
      self:apply_shape(self.slots[n].shape)
    end
    params:set("t" .. self.id .. "_slot", n, true)
    self:reset()
    self:touch()
    if Track.on_slot_changed then Track.on_slot_changed(self) end
  end

  -- clear the current slot: a fresh roll becomes its working copy and anchor;
  -- its undo history goes too
  function Track:clear_slot()
    for i = #self.undo, 1, -1 do
      if self.undo[i].slot == self.slot then table.remove(self.undo, i) end
    end
    self:generate_slot(self.slot)
    self:release_voicing()
  end

  function Track:save()
    local snap = self:snapshot()
    self.slots[self.slot].anchor = snap
    self.slots[self.slot].shape = snap.shape
    self:touch()
  end

  function Track:unsaved()
    if self.dirty then
      local a = self.slots[self.slot].anchor
      self.unsaved_cache = not (a and lanes_equal(self.lanes, a.lanes)
                                and shape_equal(self:capture_shape(), a.shape))
      self.dirty = false
    end
    return self.unsaved_cache
  end

  -- any slot: working copy differs from its anchor
  function Track:slot_unsaved(n)
    if n == self.slot then return self:unsaved() end
    local sl = self.slots[n]
    return not (lanes_equal(sl.work, sl.anchor.lanes) and shape_equal(sl.shape, sl.anchor.shape))
  end

  -- undo -------------------------------------------------------------------

  function Track:push_undo(kind, snap)
    table.insert(self.undo, {slot = self.slot, kind = kind, pass = self.passes,
                             snap = snap or self:snapshot()})
    self:trim_undo()
  end

  -- keep the newest UNDO_MAX entries; the oldest drops silently
  function Track:trim_undo()
    while #self.undo > UNDO_MAX do table.remove(self.undo, 1) end
  end

  function Track:undo_depth()
    local n = 0
    for _, e in ipairs(self.undo) do if e.slot == self.slot then n = n + 1 end end
    return n
  end

  function Track:do_undo()
    for i = #self.undo, 1, -1 do
      if self.undo[i].slot == self.slot then
        local e = table.remove(self.undo, i)
        self:restore(e.snap)
        return true
      end
    end
    return false
  end

  function Track:do_revert()
    local a = self.slots[self.slot].anchor
    if not a then return false end
    self:push_undo("revert")
    self:restore(a)
    return true
  end

  function Track:do_reroll()
    self:push_undo("reroll")
    self:roll()
    self.slots[self.slot].work = self.lanes
    self:release_voicing()
  end

  -- move the current slot one position (dir -1 = earlier, +1 = later) by
  -- swapping it with its neighbour; repeated moves reorder like dragging an
  -- item in a list. the content keeps playing; nothing is overwritten.
  function Track:move_slot(dir)
    local a = self.slot
    local b = a + dir
    if b < 1 or b > NUM_SLOTS then return false end
    self.slots[a], self.slots[b] = self.slots[b], self.slots[a]
    for _, e in ipairs(self.undo) do
      if e.slot == a then e.slot = b elseif e.slot == b then e.slot = a end
    end
    if self.pending and self.pending.kind == "slot" then
      if self.pending.arg == a then self.pending.arg = b
      elseif self.pending.arg == b then self.pending.arg = a end
    end
    self.slot = b
    params:set("t" .. self.id .. "_slot", b, true)
    if Track.on_slots_swapped then Track.on_slots_swapped(self, a, b) end
    return true
  end

  -- copy the current slot (working copy, anchor and shape) to slot n. the
  -- target's old content and its undo history are replaced
  function Track:copy_slot_to(n)
    if n == self.slot or n < 1 or n > NUM_SLOTS then return false end
    local sl = self.slots[self.slot]
    for i = #self.undo, 1, -1 do
      if self.undo[i].slot == n then table.remove(self.undo, i) end
    end
    self.slots[n] = {work = copy_lanes(self.lanes), shape = self:capture_shape(),
                     anchor = {lanes = copy_lanes(sl.anchor.lanes), shape = sl.anchor.shape}}
    if Track.on_slot_changed then Track.on_slot_changed(self) end
    return true
  end

  -- shift: rotate the first `len` steps of every lane by one (dir +1 = right).
  -- ranks travel with their steps, so the motif and density order move too.
  -- consecutive shifts share one undo entry.
  function Track:shift(dir)
    local len = self:p("len")
    if len < 2 then return end
    local top = self.undo[#self.undo]
    if not (top and top.kind == "shift" and top.slot == self.slot) then
      self:push_undo("shift")
    end
    for _, lane in ipairs(self.lanes) do
      local st = lane.steps
      if dir > 0 then
        local last = st[len]
        for s = len, 2, -1 do st[s] = st[s - 1] end
        st[1] = last
      else
        local first = st[1]
        for s = 1, len - 1 do st[s] = st[s + 1] end
        st[len] = first
      end
      lane.order_len = nil
    end
    self:touch()
  end

  -- drift ------------------------------------------------------------------

  -- once per pass: each non-motif step mutates with probability `drift`; a
  -- mutation snaps back to the anchor value with probability `gravity`.
  -- mono drifts pitch/velocity/gate; chord and drums also drift rhythm.
  -- euclid drum lanes work differently: drift flips steps that are still on
  -- the pattern (hit <-> rest), and every pass each flipped step snaps back
  -- to the plain euclid pattern with probability `gravity`, even at drift 0.
  -- their motif is the first `motif size` hits, so a four-on-the-floor can
  -- stay put while extra hits come and go.
  function Track:drift(len)
    self.passes = self.passes + 1
    local dr = self:p("drift") / 100
    local gr = self:p("gravity") / 100
    if dr <= 0 and (gr <= 0 or not self:is_drums()) then return end
    local motif = self:p("motif")
    local anchor = self.slots[self.slot].anchor
    local rhythm = self:p("type") ~= 1

    -- one undo entry per run of drift (every DRIFT_COALESCE passes)
    local top = self.undo[#self.undo]
    local need_snap = not (top and top.kind == "drift" and top.slot == self.slot
                           and self.passes - top.pass < DRIFT_COALESCE)
    local before = need_snap and self:snapshot() or nil
    local changed = false

    for l = 1, self:num_lanes() do
      self:update_order(len, l)
      local lane = self.lanes[l]
      local eu = self:is_euclid(l) and self:euclid(l, len)
      local pinned, rerank = {}, false
      for s = 1, len do
        local st = lane.steps[s]
        local home = anchor and anchor.lanes[l].steps[s]
        local in_motif
        if eu and st.x then
          -- off the pattern: gravity pulls it home (velocity/gate from the anchor)
          if math.random() < gr then
            st.x = false
            if home then st.p, st.v, st.g = home.p, home.v, home.g end
            changed = true
          end
          goto next_step
        end
        if eu then in_motif = eu.ins[s] and eu.order[s] <= motif
        else in_motif = lane.order[s] <= motif end
        if in_motif then
          pinned[s] = true
        elseif eu then
          if math.random() < dr then
            st.x = true
            st.p, st.v, st.g = math.random(), math.random(), math.random()
            changed = true
          end
        elseif math.random() < dr then
          if home and math.random() < gr then
            st.p, st.v, st.g = home.p, home.v, home.g
            if rhythm and st.rr ~= home.rr then st.rr = home.rr; rerank = true end
          else
            st.p, st.v, st.g = math.random(), math.random(), math.random()
            if rhythm then st.rr = math.random(); rerank = true end
          end
          changed = true
        end
        ::next_step::
      end
      if rerank then self:rank_lane(l, pinned) end
    end

    if changed then
      self:touch()
      if before then self:push_undo("drift", before) end
    end
  end

  -- persistence ------------------------------------------------------------

  -- plain tables for the set file. a working lane equal to its anchor lane
  -- is stored as `true`
  -- with `cache` ({a = {}, w = {}}, kept by the caller per slot) and `fmt`
  -- (flat list -> text), lanes come back as {__raw = text}
  function Track:export_slot(n, cache, fmt)
    local sl = self.slots[n]
    local work, anchor = {}, {}
    for l, lane in ipairs(sl.anchor.lanes) do
      if cache then
        anchor[l] = lane_raw(lane, cache.a, l, fmt)
        work[l] = lane_equal(sl.work[l], lane) or lane_raw(sl.work[l], cache.w, l, fmt)
      else
        anchor[l] = flat_lane(lane)
        work[l] = lane_equal(sl.work[l], lane) or flat_lane(sl.work[l])
      end
    end
    return {shape = n == self.slot and self:capture_shape() or sl.shape,
            work = work, anchor = {shape = sl.anchor.shape, lanes = anchor}}
  end

  function Track:export()
    local slots = {}
    for n in pairs(self.slots) do slots[n] = self:export_slot(n) end
    return {slot = self.slot, slots = slots}
  end

  function Track:import(d)
    self.slots = {}
    -- slots saved before a shape key existed take its current value
    local now = self:capture_shape()
    local function fill(sh)
      sh = sh or {}
      for _, k in ipairs(SHAPE_ALL) do if sh[k] == nil then sh[k] = now[k] end end
      return sh
    end
    for n, s in pairs(d.slots or {}) do
      s.shape, s.anchor.shape = fill(s.shape), fill(s.anchor.shape)
      local anchor, work = {}, {}
      for l, f in ipairs(s.anchor.lanes) do anchor[l] = unflat_lane(f) end
      for l, w in ipairs(s.work) do
        work[l] = w == true and copy_lanes({anchor[l]})[1] or unflat_lane(w)
      end
      self.slots[n] = {work = work, shape = s.shape,
                       anchor = {lanes = anchor, shape = s.anchor.shape}}
    end
    self.undo, self.pending = {}, nil
    self.slot = util.clamp(d.slot or 1, 1, NUM_SLOTS)
    if not self.slots[self.slot] then
      self:generate_slot(self.slot)
    else
      self.lanes = self.slots[self.slot].work
      self.steps = self.lanes[1].steps
      self:apply_shape(self.slots[self.slot].shape)
    end
    self:release_voicing()
    params:set("t" .. self.id .. "_slot", self.slot, true)
    self:touch()
  end

  -- pending actions (land on the next bar) ----------------------------------

  -- kind: "reroll" | "revert" | "undo" | "clear" | "slot" (arg = target slot)
  function Track:request(kind, arg, now)
    if kind == "slot" then
      self.pending = {kind = "slot", arg = util.clamp(arg, 1, NUM_SLOTS)}
    else
      self.pending = {kind = kind}
    end
    if now then self:apply_pending() end
  end

  -- target slot including any pending slot move (for next/prev stepping)
  function Track:target_slot()
    if self.pending and self.pending.kind == "slot" then return self.pending.arg end
    return self.slot
  end

  function Track:apply_pending()
    local pd = self.pending
    if not pd then return end
    self.pending = nil
    if pd.kind == "reroll" then self:do_reroll()
    elseif pd.kind == "revert" then self:do_revert()
    elseif pd.kind == "undo" then self:do_undo()
    elseif pd.kind == "clear" then self:clear_slot()
    elseif pd.kind == "slot" then
      if pd.arg ~= self.slot then self:load_slot(pd.arg) end
    end
    if Track.on_applied then Track.on_applied(self, pd.kind) end
  end
end
