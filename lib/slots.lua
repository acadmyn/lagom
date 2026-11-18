-- slots, working copy vs anchor, drift/gravity, undo, pending (next bar)
-- actions. adds methods to Track: include("lib/slots")(Track)
local K = include("lib/const")

local NUM_SLOTS = 16
local UNDO_MAX = 16
local DRIFT_COALESCE = 4   -- passes: drift snapshots closer than this merge

-- shape params stored with every slot
local SHAPE = {"len", "div", "range", "drift", "gravity", "gate"}

local STEP_FIELDS = {"p", "v", "g", "rr", "leg", "r"}

local function copy_lanes(lanes)
  local out = {}
  for l, lane in ipairs(lanes) do
    local steps = {}
    for s, st in ipairs(lane.steps) do
      steps[s] = {p = st.p, v = st.v, g = st.g, rr = st.rr, leg = st.leg, r = st.r}
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

-- lane <-> flat number list (for the set files): p v g rr r leg per step
local function flat_lane(lane)
  local f = {}
  for _, st in ipairs(lane.steps) do
    f[#f + 1] = st.p; f[#f + 1] = st.v; f[#f + 1] = st.g; f[#f + 1] = st.rr
    f[#f + 1] = st.r; f[#f + 1] = st.leg and 1 or 0
  end
  return f
end

local function unflat_lane(f)
  local steps = {}
  for s = 1, #f // 6 do
    local i = (s - 1) * 6
    steps[s] = {p = f[i + 1], v = f[i + 2], g = f[i + 3], rr = f[i + 4],
                r = math.tointeger(f[i + 5]) or f[i + 5], leg = f[i + 6] == 1}
  end
  return {steps = steps, order = {}}
end

local function shape_equal(a, b)
  for _, k in ipairs(SHAPE) do
    if a[k] ~= b[k] then return false end
  end
  return true
end

return function(Track)

  Track.SHAPE = SHAPE
  Track.NUM_SLOTS = NUM_SLOTS
  Track.on_shape_loaded = nil   -- callback(track id): knobs lose pickup
  Track.on_slot_changed = nil   -- callback(track): autosave
  Track.on_slots_swapped = nil  -- callback(track, a, b): scenes follow
  Track.ask_drop = nil          -- callback(track, entry, answer(yes)): confirm
                                -- dropping a never-saved version from undo

  function Track:capture_shape()
    local sh = {}
    for _, k in ipairs(SHAPE) do sh[k] = self:p(k) end
    return sh
  end

  function Track:apply_shape(sh)
    for _, k in ipairs(SHAPE) do params:set("t" .. self.id .. "_" .. k, sh[k]) end
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
    self.dirty = true
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
    self.dirty = true
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
    self.dirty = true
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
    self.dirty = true
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

  -- a re-roll or revert left behind a phrase that was never saved
  -- (drift and shift entries are small, reversible steps)
  local function precious(self, e)
    if e.kind == "drift" or e.kind == "shift" then return false end
    local sl = self.slots[e.slot]
    return not (sl and lanes_equal(e.snap.lanes, sl.anchor.lanes))
  end

  -- keep UNDO_MAX entries. drift steps and saved versions drop silently;
  -- dropping a never-saved phrase asks first (one question at a time; the
  -- history grows past the limit until it is answered). kept entries
  -- ("no, keep it") don't count towards the limit.
  function Track:trim_undo()
    while true do
      local n, oldest = 0, nil
      for i, e in ipairs(self.undo) do
        if not e.keep and not e.asking then
          n = n + 1
          oldest = oldest or i
        end
      end
      if n <= UNDO_MAX then return end
      local e = self.undo[oldest]
      if not precious(self, e) or not Track.ask_drop then
        table.remove(self.undo, oldest)
      elseif self.asking then
        return
      else
        e.asking, self.asking = true, e
        Track.ask_drop(self, e, function(yes)
          if self.asking == e then self.asking = nil end
          e.asking = nil
          if yes then
            for i, x in ipairs(self.undo) do
              if x == e then table.remove(self.undo, i); break end
            end
          else
            e.keep = true
          end
          self:trim_undo()
        end)
      end
    end
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
    self.dirty = true
  end

  -- drift ------------------------------------------------------------------

  -- once per pass: each non-motif step mutates with probability `drift`; a
  -- mutation snaps back to the anchor value with probability `gravity`.
  -- mono drifts pitch/velocity/gate; chord and drums also drift rhythm.
  function Track:drift(len)
    self.passes = self.passes + 1
    local dr = self:p("drift") / 100
    if dr <= 0 then return end
    local gr = self:p("gravity") / 100
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
      local pinned, rerank = {}, false
      for s = 1, len do
        if lane.order[s] <= motif then
          pinned[s] = true
        elseif math.random() < dr then
          local st = lane.steps[s]
          local home = anchor and anchor.lanes[l].steps[s]
          if home and math.random() < gr then
            st.p, st.v, st.g = home.p, home.v, home.g
            if rhythm and st.rr ~= home.rr then st.rr = home.rr; rerank = true end
          else
            st.p, st.v, st.g = math.random(), math.random(), math.random()
            if rhythm then st.rr = math.random(); rerank = true end
          end
          changed = true
        end
      end
      if rerank then self:rank_lane(l, pinned) end
    end

    if changed then
      self.dirty = true
      if before then self:push_undo("drift", before) end
    end
  end

  -- persistence ------------------------------------------------------------

  -- plain tables for the set file. a working lane equal to its anchor lane
  -- is stored as `true`
  function Track:export_slot(n)
    local sl = self.slots[n]
    local work, anchor = {}, {}
    for l, lane in ipairs(sl.anchor.lanes) do
      anchor[l] = flat_lane(lane)
      work[l] = lane_equal(sl.work[l], lane) or flat_lane(sl.work[l])
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
    for n, s in pairs(d.slots or {}) do
      local anchor, work = {}, {}
      for l, f in ipairs(s.anchor.lanes) do anchor[l] = unflat_lane(f) end
      for l, w in ipairs(s.work) do
        work[l] = w == true and copy_lanes({anchor[l]})[1] or unflat_lane(w)
      end
      self.slots[n] = {work = work, shape = s.shape,
                       anchor = {lanes = anchor, shape = s.anchor.shape}}
    end
    self.undo, self.pending, self.asking = {}, nil, nil
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
    self.dirty = true
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
