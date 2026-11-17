-- root, scale and the current chord; builds pitch-class sets per tension
-- root/scale param changes are staged and land on the next bar (apply())
local MU = require "musicutil"

local H = {
  root = 0,          -- active pitch class 0..11
  scale = 1,         -- active index into MU.SCALES
  degree = 1,        -- current chord degree (1-based), set by the conductor
  version = 0,       -- bumps whenever any of the above change (pool caches)
  pending = false,
}

H.TENSIONS = {"root", "5th", "chord", "scale", "color"}
H.TENSION_SHORT = {"ROT", "5TH", "CHD", "SCL", "COL"}

local want_root, want_scale = 0, 1

function H.scale_names()
  local t = {}
  for i, s in ipairs(MU.SCALES) do t[i] = s.name end
  return t
end

-- intervals without the closing octave
local function ivs(scale)
  local src = MU.SCALES[scale].intervals
  local t = {}
  for i = 1, #src do
    if src[i] < 12 then t[#t + 1] = src[i] end
  end
  return t
end

function H.size() return #ivs(H.scale) end

-- pitch class of scale step k (0-based, may exceed the scale length)
local function pc(k)
  local iv = ivs(H.scale)
  local n = #iv
  return (H.root + iv[(k % n) + 1]) % 12
end

-- chord tone j (0 = root, 1 = 3rd, 2 = 5th, 3 = 7th, 4 = 9th) of a degree
function H.chord_tone(degree, j) return pc(degree - 1 + 2 * j) end

local function set(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

-- allowed pitch classes for a tension; strong = step falls on a beat
function H.pcs(tension, strong)
  local d = H.degree
  local ct = function(j) return H.chord_tone(d, j) end
  if tension == 1 then return set {ct(0)} end
  if tension == 2 then return set {ct(0), ct(2)} end
  if tension == 3 then return set {ct(0), ct(1), ct(2)} end
  if strong then
    if tension == 4 then return set {ct(0), ct(1), ct(2)} end
    return set {ct(0), ct(1), ct(2), ct(3), ct(4)}
  end
  local all = {}
  for k = 0, H.size() - 1 do all[#all + 1] = pc(k) end
  return set(all)
end

function H.set_degree(d)
  if d ~= H.degree then
    H.degree = d
    H.version = H.version + 1
  end
end

-- stage a root/scale change (applied on the next bar, or now if stopped)
function H.stage(root, scale, now)
  want_root, want_scale = root, scale
  H.pending = (want_root ~= H.root or want_scale ~= H.scale)
  if now then H.apply() end
end

function H.apply()
  if not H.pending then return end
  H.root, H.scale = want_root, want_scale
  if H.degree > H.size() then H.degree = 1 end
  H.pending = false
  H.version = H.version + 1
end

-- display helpers ---------------------------------------------------------

local ROMAN = {"I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"}

function H.quality(degree)
  local r = H.chord_tone(degree, 0)
  local third = (H.chord_tone(degree, 1) - r) % 12
  local fifth = (H.chord_tone(degree, 2) - r) % 12
  if third == 4 and fifth == 7 then return "maj" end
  if third == 3 and fifth == 7 then return "min" end
  if third == 3 and fifth == 6 then return "dim" end
  if third == 4 and fifth == 8 then return "aug" end
  return "?"
end

-- e.g. "ii Dm", "V G", "viio Bdim"
function H.chord_label(degree)
  local q = H.quality(degree)
  local rn = ROMAN[degree] or tostring(degree)
  local suffix = ({maj = "", min = "m", dim = "dim", aug = "+"})[q] or "?"
  if q == "min" or q == "dim" then rn = string.lower(rn) end
  if q == "dim" then rn = rn .. "o" end
  if q == "aug" then rn = rn .. "+" end
  return rn .. " " .. MU.NOTE_NAMES[H.chord_tone(degree, 0) + 1] .. suffix
end

-- "C MAJ", "D NAT MIN"
function H.key_label()
  local words = {}
  for w in string.gmatch(MU.SCALES[H.scale].name, "%S+") do
    words[#words + 1] = string.upper(string.sub(w, 1, 3))
  end
  return MU.NOTE_NAMES[H.root + 1] .. " " .. table.concat(words, " ")
end

return H
