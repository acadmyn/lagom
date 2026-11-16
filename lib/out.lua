-- midi output: port connections, note tracking, panic
local Out = {}

Out.ports = {}
local active = {}   -- key -> count of overlapping note-ons

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
