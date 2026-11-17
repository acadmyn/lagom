-- persistence: sets bound to norns pset numbers, autosave, scenes.
-- a set = every track's 16 slots (working copy + anchor + shape), the
-- conductor and the scenes. the autosave file is a set plus lagom's params.
local K = include("lib/const")

local S = {
  scenes = {},        -- [1..8] = {slot per track} or nil
  due = false,        -- autosave soon (slot change)
}

local tracks, Cd, H, Confirm
local first_param       -- index of lagom's first param in params.params
local last_written      -- autosave text last written (skip identical writes)
local SKIP = {play = true}
local AUTOSAVE_EVERY = 30

local function dir() return norns.state.data end
local function autosave_path() return dir() .. "autosave.set" end
local function set_path(number) return dir() .. norns.state.shortname .. "-" .. number .. ".set" end

-- serializer ------------------------------------------------------------------

local function ser(v, out)
  local t = type(v)
  if v == nil then
    out[#out + 1] = "nil"
  elseif t == "number" then
    out[#out + 1] = math.type(v) == "integer" and tostring(v) or string.format("%.6g", v)
  elseif t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "string" then
    out[#out + 1] = string.format("%q", v)
  elseif t == "table" and #v > 8 and type(v[1]) == "number" then
    -- flat number list (step data): one format call
    out[#out + 1] = string.format("{" .. string.rep("%.6g,", #v) .. "}", table.unpack(v))
  elseif t == "table" then
    out[#out + 1] = "{"
    local n = #v
    for i = 1, n do
      ser(v[i], out)
      out[#out + 1] = ","
    end
    -- other keys in sorted order, so equal state gives equal text
    local keys = {}
    for k in pairs(v) do
      if not (math.type(k) == "integer" and k >= 1 and k <= n) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then return a < b end
      return type(a) == "number"
    end)
    for _, k in ipairs(keys) do
      local x = v[k]
      do
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
          out[#out + 1] = k .. "="
        else
          out[#out + 1] = "["
          ser(k, out)
          out[#out + 1] = "]="
        end
        ser(x, out)
        out[#out + 1] = ","
      end
    end
    out[#out + 1] = "}"
  end
end

local function write_atomic(path, text)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then print("lagom: cannot write " .. path); return false end
  f:write(text)
  f:close()
  os.rename(tmp, path)
  return true
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  local chunk, err = load(text, "=" .. path, "t", {})
  if not chunk then print("lagom: bad set file " .. path .. ": " .. err); return nil end
  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" then print("lagom: bad set file " .. path); return nil end
  return data
end

-- state <-> tables ------------------------------------------------------------

local function param_values()
  local v = {}
  for i = first_param, #params.params do
    local p = params.params[i]
    if p.id and p.save and not SKIP[p.id] and p.t ~= params.tTRIGGER
       and p.t ~= params.tSEPARATOR and p.t ~= params.tGROUP then
      v[p.id] = p:get()
    end
  end
  return v
end

-- encoded text per slot. a slot that isn't playing can't change, so its
-- text is reused until the slot's tables are replaced
local slot_cache = setmetatable({}, {__mode = "k"})

local function slot_text(t, n)
  local sl = t.slots[n]
  local c = slot_cache[sl]
  if n ~= t.slot and c and c.work == sl.work and c.anchor == sl.anchor
     and c.shape == sl.shape then
    return c.text, true
  end
  local out = {}
  ser(t:export_slot(n), out)
  local text = table.concat(out)
  slot_cache[sl] = {work = sl.work, anchor = sl.anchor, shape = sl.shape, text = text}
  return text, false
end

-- the whole set as Lua source. `yield` (optional) runs between slots that
-- had to be encoded, so a background save never stalls the tick loop long
local function encode_set(with_params, yield)
  local parts = {"return {version=1,tracks={"}
  for _, t in ipairs(tracks) do
    parts[#parts + 1] = "{slot=" .. t.slot .. ",slots={"
    local ns = {}
    for n in pairs(t.slots) do ns[#ns + 1] = n end
    table.sort(ns)
    for _, n in ipairs(ns) do
      local text, cached = slot_text(t, n)
      parts[#parts + 1] = "[" .. n .. "]=" .. text .. ","
      if yield and not cached then yield() end
    end
    parts[#parts + 1] = "}},"
  end
  local out = {}
  ser({scenes = S.scenes, params = with_params and param_values() or nil,
       conductor = {working = Cd.working, anchor = Cd.anchor, idx = Cd.idx}}, out)
  parts[#parts + 1] = "},"
  parts[#parts + 1] = table.concat(out):sub(2)
  parts[#parts + 1] = "\n"
  return table.concat(parts)
end

local function restore(d)
  if d.params then
    for id, val in pairs(d.params) do
      if params.lookup[id] then params:set(id, val) end
    end
  end
  for i, t in ipairs(tracks) do
    if d.tracks and d.tracks[i] then t:import(d.tracks[i]) end
  end
  local c = d.conductor
  if c and c.working and #c.working > 0 then
    Cd.working, Cd.anchor = c.working, c.anchor or c.working
    Cd.idx = util.clamp(c.idx or 1, 1, #Cd.working)
    Cd.pending_next, Cd.pending_home = false, false
    H.set_degree(Cd.working[Cd.idx])
  end
  S.scenes = d.scenes or {}
end

-- public ----------------------------------------------------------------------

function S.init(trs, conductor, harmony, confirm, first)
  tracks, Cd, H, Confirm, first_param = trs, conductor, harmony, confirm, first
  util.make_dir(dir())
end

function S.anything_unsaved()
  if Cd.unsaved() then return true end
  for _, t in ipairs(tracks) do
    for n in pairs(t.slots) do
      if t:slot_unsaved(n) then return true end
    end
  end
  return false
end

function S.autosave(yield)
  local text = encode_set(true, yield)
  if text == last_written then return end
  if write_atomic(autosave_path(), text) then last_written = text end
end

-- boot: pick up where we left off. returns true if a state was restored
function S.load_autosave()
  local d = read_file(autosave_path())
  if not d then return false end
  restore(d)
  return true
end

-- autosave every 30 s, and within a second of a slot change
function S.start()
  S.coro = clock.run(function()
    local elapsed = 0
    while true do
      clock.sleep(1)
      elapsed = elapsed + 1
      if S.due or elapsed >= AUTOSAVE_EVERY then
        S.due = false
        elapsed = 0
        S.autosave(function() clock.sleep(0.002) end)
      end
    end
  end)
end

function S.stop()
  if S.coro then clock.cancel(S.coro) end
end

-- psets: the .pset file holds the params, the .set file next to it the rest
function S.hook_psets()
  params:set_save("play", false)
  for i = 1, K.NUM_TRACKS do params:set_save("t" .. i .. "_slot", false) end

  params.action_write = function(_, _, number)
    if number then write_atomic(set_path(number), encode_set(false)) end
  end
  params.action_read = function(_, _, number)
    if not number then return end
    local d = read_file(set_path(number))
    if d then restore(d) end
    S.due = true
  end
  params.action_delete = function(_, _, number)
    if number then os.remove(set_path(number)) end
  end

  -- confirm before overwriting a set or loading over unsaved changes
  -- the originals live on the ParamSet class: fields set on `params` itself
  -- survive params:clear(), so S.unhook() must remove them at cleanup
  local ParamSet = getmetatable(params)
  local write, read = ParamSet.write, ParamSet.read
  params.write = function(self, filename, name)
    if type(filename) == "number" and util.file_exists(set_path(string.format("%02d", filename))) then
      Confirm.ask({"OVERWRITE SET " .. filename .. "?"},
        function() write(self, filename, name) end, nil, true)
    else
      write(self, filename, name)
    end
  end
  params.read = function(self, filename, silent)
    if type(filename) == "number" and S.anything_unsaved() then
      Confirm.ask({"LOAD SET " .. filename .. "?", "UNSAVED CHANGES ARE LOST"},
        function() read(self, filename, silent) end, nil, true)
    else
      read(self, filename, silent)
    end
  end
end

function S.unhook()
  rawset(params, "write", nil)
  rawset(params, "read", nil)
end

-- scenes ----------------------------------------------------------------------

function S.store_scene(k)
  local sc = {}
  for i, t in ipairs(tracks) do sc[i] = t:target_slot() end
  S.scenes[k] = sc
  S.due = true
end

-- returns false if the scene is empty
function S.recall_scene(k, now)
  local sc = S.scenes[k]
  if not sc then return false end
  for i, t in ipairs(tracks) do
    if sc[i] then t:request("slot", sc[i], now) end
  end
  return true
end

return S
