-- TRS MIDI jacks (shields that run ttymidi on the UART): connect ttymidi's
-- ALSA ports to matron's `virtual` MIDI device, both ways, so the jacks work
-- as the `virtual` vport. nothing does this by default, and the matron client
-- number changes on every start, so lagom does it at init. on a norns
-- without ttymidi this does nothing.
local Trs = {}

local function proc_name(pid)
  local f = io.open("/proc/" .. pid .. "/comm")
  if not f then return nil end
  local s = f:read("l")
  f:close()
  return s
end

local function self_pid()
  local f = io.open("/proc/self/stat")
  if not f then return nil end
  local s = f:read("l")
  f:close()
  return s and s:match("^(%d+)")
end

-- aconnect -l -> list of {id, pid, ports = {[name] = number}}
local function clients()
  local p = io.popen("aconnect -l 2>/dev/null")
  if not p then return {} end
  local out, cur = {}, nil
  for line in p:lines() do
    local id, attrs = line:match("^client (%d+): '.-' %[(.-)%]")
    if id then
      cur = {id = tonumber(id), pid = attrs:match("pid=(%d+)"), ports = {}}
      out[#out + 1] = cur
    elseif cur then
      local port, name = line:match("^%s+(%d+) '(.-)%s*'")
      if port then cur.ports[name] = tonumber(port) end
    end
  end
  p:close()
  return out
end

function Trs.connect()
  local me = self_pid()
  local tty, virt
  for _, c in ipairs(clients()) do
    if c.pid and c.pid == me and c.ports["Virtual RawMIDI"] then
      -- matron opens `virtual` twice and keeps the second (newest) client
      if not virt or c.id > virt.id then virt = c end
    elseif c.pid and proc_name(c.pid) == "ttymidi" then
      tty = c
    end
  end
  if not (tty and virt) then return false end
  local tin, tout = tty.ports["MIDI In"], tty.ports["MIDI Out"]
  local v = virt.id .. ":" .. virt.ports["Virtual RawMIDI"]
  -- already-connected pairs just fail quietly
  if tin then os.execute("aconnect " .. tty.id .. ":" .. tin .. " " .. v .. " 2>/dev/null") end
  if tout then os.execute("aconnect " .. v .. " " .. tty.id .. ":" .. tout .. " 2>/dev/null") end
  print("lagom: TRS MIDI (ttymidi " .. tty.id .. ") <-> virtual (" .. v .. ")")
  return true
end

return Trs
