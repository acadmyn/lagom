-- midi output: port connections, note tracking, panic
local Out = {}

Out.ports = {}
Out.up = {}         -- port -> a device is plugged in (refreshed by Out.poll)
local active = {}   -- key -> count of overlapping note-ons
local dirty = true  -- devices changed since the last poll
local name_ids = {} -- option params listing port names
local clk_ids = {}  -- port -> param whose name includes the port name

local function key(p, c, n) return p * 4096 + c * 128 + n end

function Out.init()
  for i = 1, 16 do Out.ports[i] = midi.connect(i) end
end

function Out.port_names()
  local t = {}
  for i = 1, 16 do
    local n = midi.vports[i].name
    if n == "none" then n = "-" end
    if string.len(n) > 14 then n = util.acronym(n) end
    t[i] = i .. ": " .. n
  end
  return t
end

-- params to relabel when devices come and go
function Out.name_params(option_ids, named_ids) name_ids, clk_ids = option_ids, named_ids end

-- call from midi.add / midi.remove. norns updates `connected` only after
-- midi.remove returns, so the refresh waits for the next Out.poll
function Out.devices_changed() dirty = true end

-- once per frame. cheap unless devices changed; then refreshes the port
-- names and `up`, and returns a list of ports that went down or up (or nil)
function Out.poll()
  if not dirty then return nil end
  dirty = false
  local names = Out.port_names()
  for _, id in ipairs(name_ids) do
    local p = params:lookup_param(id)
    for i = 1, 16 do p.options[i] = names[i] end
  end
  for i, id in pairs(clk_ids) do params:lookup_param(id).name = "→ " .. names[i] end
  local changed
  for i = 1, 16 do
    local up = midi.vports[i].connected == true
    if Out.up[i] ~= nil and Out.up[i] ~= up then
      changed = changed or {}
      changed[#changed + 1] = i
    end
    Out.up[i] = up
  end
  return changed
end

function Out.note_on(p, c, n, v)
  local k = key(p, c, n)
  active[k] = (active[k] or 0) + 1
  Out.ports[p]:note_on(n, v, c)
end

-- only sends the note-off when the last overlapping instance ends,
-- so retriggered notes are not cut short by an older note-off
function Out.note_off(p, c, n)
  local k = key(p, c, n)
  local cnt = active[k]
  if cnt == nil then return end
  if cnt <= 1 then
    active[k] = nil
    Out.ports[p]:note_off(n, 0, c)
  else
    active[k] = cnt - 1
  end
end

function Out.panic()
  for k, _ in pairs(active) do
    local p = k // 4096
    local c = (k % 4096) // 128
    local n = k % 128
    Out.ports[p]:note_off(n, 0, c)
  end
  active = {}
end

function Out.send_byte(p, b)
  Out.ports[p]:send({b})
end

return Out
