-- the norns drum machine: slagverk (acadmyn/slagverk) as a library, #37.
-- only when slagverk is installed: then a drum track's port can be `norns`
-- (port option 17), lane n plays voice n of the track's own kit, and the
-- kits are saved in the set. without slagverk lagom stays MIDI-only.
local Drums = {
  PORT = 17,
  API = 1,            -- the slagverk library API this file is written for
  available = false,  -- slagverk installed, its plugin in place, engine loading
  problem = nil,      -- why not: "restart" (SYSTEM > RESTART) or "old slagverk"
  kits = {},          -- track -> slagverk kit (drum tracks on the norns port)
  states = {},        -- track -> kit state (kept for tracks not using it now)
  on_change = nil,    -- a kit changed (autosave)
}

local SV                -- slagverk's library
local tracks

-- top level of lagom.lua, before norns loads the engine. true when the
-- engine should be Slagverk
function Drums.load()
  if not util.file_exists(_path.code .. "slagverk/lib/slagverk.lua") then return false end
  SV = include("slagverk/lib/slagverk")
  if (SV.API or 0) < Drums.API then
    Drums.problem = "old slagverk"
    print("lagom: slagverk is too old for lagom, update it")
    return false
  end
  if not SV.check() then
    Drums.problem = SV.problem()
    print("lagom: slagverk needs " .. tostring(Drums.problem))
    return false
  end
  Drums.available = true
  return true
end

function Drums.init(trs) tracks = trs end

function Drums.ready() return Drums.available and SV.ready() end

local function uses_norns(i)
  local t = tracks[i]
  return t:is_drums() and t:p("port") == Drums.PORT
end

-- make or free track i's kit to match its type and port
function Drums.sync(i)
  if not Drums.ready() then return end
  local k = Drums.kits[i]
  if uses_norns(i) then
    if not k then
      k = SV.Kit.new({id = i, preset = "808"})
      if Drums.states[i] then k:load_state(Drums.states[i]) end
      Drums.kits[i] = k
    end
  elseif k then
    Drums.states[i] = k:state()
    k:free()
    Drums.kits[i] = nil
  end
end

function Drums.sync_all()
  for i = 1, #tracks do Drums.sync(i) end
end

-- lane l of track i, MIDI velocity 1-127
function Drums.hit(i, l, vel)
  local k = Drums.kits[i]
  if k then k:trig(l, vel / 127) end
end

function Drums.preset_names()
  return Drums.available and SV.Kit.preset_names() or {"808", "909"}
end

function Drums.load_preset(i, name)
  local k = Drums.kits[i]
  if k and k:load_preset(name) then
    Drums.states[i] = k:state()
    if Drums.on_change then Drums.on_change() end
    return true
  end
  return false
end

-- the set: one kit per track
function Drums.export()
  local t = {}
  for i = 1, #tracks do
    local k = Drums.kits[i]
    if k then Drums.states[i] = k:state() end
    t[i] = Drums.states[i]
  end
  return t
end

function Drums.import(t)
  if type(t) ~= "table" then return end
  for i = 1, #tracks do
    Drums.states[i] = type(t[i]) == "table" and t[i] or nil
    local k = Drums.kits[i]
    if k then k:load_state(Drums.states[i] or SV.Kit.preset("808")) end
  end
end

function Drums.cleanup()
  for i, k in pairs(Drums.kits) do k:free() Drums.kits[i] = nil end
end

return Drums
