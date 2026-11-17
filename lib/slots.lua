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

local function lanes_equal(a, b)
  for l = 1, #a do
    local sa, sb = a[l].steps, b[l].steps
    for s = 1, #sa do
      local x, y = sa[s], sb[s]
      for _, f in ipairs(STEP_FIELDS) do
        if x[f] ~= y[f] then return false end
      end
    end
  end
  return true
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

  -- undo -------------------------------------------------------------------

  function Track:push_undo(kind, snap)
    table.insert(self.undo, {slot = self.slot, kind = kind, pass = self.passes,
                             snap = snap or self:snapshot()})
    if #self.undo > UNDO_MAX then table.remove(self.undo, 1) end
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

  -- pending actions (land on the next bar) ----------------------------------

  -- kind: "reroll" | "revert" | "undo" | "slot" (arg = target slot)
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
    elseif pd.kind == "slot" then
      if pd.arg ~= self.slot then self:load_slot(pd.arg) end
    end
  end
end
