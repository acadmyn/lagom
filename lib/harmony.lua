-- root, scale and the current chord; builds pitch-class sets per tension
-- root/scale param changes are staged and land on the next bar (apply())
local MU = require "musicutil"

local H = {
  root = 0,          -- active pitch class 0..11
  scale = 1,         -- active index into MU.SCALES
  degree = 1,        -- current chord degree (1-based), set by the conductor
  chord = {d = 1, acc = 0, q = 1},  -- current chord (a copy), set by the conductor
  version = 0,       -- bumps whenever any of the above change (pool caches)
  pending = false,
}

H.TENSIONS = {"root", "5th", "chord", "scale", "color"}
H.TENSION_SHORT = {"ROT", "5TH", "CHD", "SCL", "COL"}

-- chord qualities: {name, intervals in importance order (voicing keeps the
-- first ones when voices run short), label suffix, box figure}
-- `auto` = the diatonic triad of the degree (with an accidental: maj for flat,
-- dim for sharp)
H.QUALITIES = {
  {"auto"},
  {"maj", {0, 4, 7}, "", ""},
  {"min", {0, 3, 7}, "m", ""},
  {"dim", {0, 3, 6}, "dim", ""},
  {"aug", {0, 4, 8}, "+", ""},
  {"sus2", {0, 2, 7}, "SUS2", "S2"},
  {"sus4", {0, 5, 7}, "SUS4", "S4"},
  {"6", {0, 4, 9, 7}, "6", "6"},
  {"m6", {0, 3, 9, 7}, "m6", "6"},
  {"7", {0, 4, 10, 7}, "7", "7"},
  {"maj7", {0, 4, 11, 7}, "M7", "M7"},
  {"m7", {0, 3, 10, 7}, "m7", "7"},
  {"m7b5", {0, 3, 6, 10}, "m7b5", "7b5"},
  {"dim7", {0, 3, 6, 9}, "dim7", "7"},
  {"mMaj7", {0, 3, 11, 7}, "mM7", "M7"},
  {"9", {0, 4, 10, 14, 7}, "9", "9"},
  {"maj9", {0, 4, 11, 14, 7}, "M9", "M9"},
  {"m9", {0, 3, 10, 14, 7}, "m9", "9"},
  {"7b9", {0, 4, 10, 13, 7}, "7b9", "7b9"},
  {"7#9", {0, 4, 10, 15, 7}, "7#9", "7#9"},
  {"11", {0, 10, 17, 14, 7}, "11", "11"},
  {"13", {0, 4, 10, 21, 14, 7}, "13", "13"},
}
local Q_INDEX = {}
for i, q in ipairs(H.QUALITIES) do Q_INDEX[q[1]] = i end
function H.quality_index(name) return Q_INDEX[name] end

-- interval -> chord position (0 root, 1 3rd, 2 5th, 3 7th, 4 9th, 5 11th, 6 13th)
local POS = {[0] = 0, [2] = 1, [3] = 1, [4] = 1, [5] = 1, [6] = 2, [7] = 2, [8] = 2,
             [9] = 6, [10] = 3, [11] = 3, [13] = 4, [14] = 4, [15] = 4, [17] = 5, [21] = 6}

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

-- diatonic chord tone j (0 = root, 1 = 3rd, 2 = 5th, 3 = 7th, 4 = 9th) of a degree
function H.chord_tone(degree, j) return pc(degree - 1 + 2 * j) end

local function set(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

-- the quality entry a chord resolves to, or nil = diatonic (auto, natural)
local function resolve(ch)
  local q = H.QUALITIES[ch.q or 1] or H.QUALITIES[1]
  if q[2] then return q end
  local acc = ch.acc or 0
  if acc < 0 then return H.QUALITIES[Q_INDEX.maj] end
  if acc > 0 then return H.QUALITIES[Q_INDEX.dim] end
  return nil
end

-- chord tones as {pc, position}, in importance order
function H.tones(ch)
  local q = resolve(ch)
  local out = {}
  if not q then
    for j = 0, 2 do out[#out + 1] = {H.chord_tone(ch.d, j), j} end
    return out
  end
  local r = (pc(ch.d - 1) + (ch.acc or 0)) % 12
  for _, iv in ipairs(q[2]) do
    local pos = POS[iv]
    if iv == 9 and q[1] == "dim7" then pos = 3 end
    out[#out + 1] = {(r + iv) % 12, pos}
  end
  return out
end

-- pitch-class sets for the current chord, rebuilt when the version changes.
-- chord scale (scale/color off the beat): the scale plus the chord tones,
-- where scale notes give way to a chord tone a semitone away if that tone is
-- outside the scale, or was altered from them (e.g. the 3rd under a sus4)
local cache = {version = -1}

local function rebuild()
  local ch = H.chord
  local tones = H.tones(ch)
  local has, pos, order = {}, {}, {}
  for _, t in ipairs(tones) do
    has[t[1]] = true
    pos[t[2]] = true
    order[#order + 1] = t[1]
  end
  local root, fifth = tones[1][1], nil
  for _, t in ipairs(tones) do
    if t[2] == 2 then fifth = t[1]; break end
  end
  local in_scale, sc = {}, {}
  for k = 0, H.size() - 1 do in_scale[pc(k)] = true; sc[pc(k)] = true end
  local function give_way(p) if not has[p] then sc[p] = nil end end
  for _, t in ipairs(tones) do
    local p = t[1]
    local from = pc(ch.d - 1 + 2 * t[2])
    if from == (p + 1) % 12 or from == (p + 11) % 12 then give_way(from) end
    if not in_scale[p] then
      give_way((p + 1) % 12)
      give_way((p + 11) % 12)
    end
  end
  for p in pairs(has) do sc[p] = true end
  -- color on the beat: chord tones plus the 7th and 9th the chord lacks
  local col = {}
  for p in pairs(has) do col[p] = true end
  for j = 3, 4 do
    if not pos[j] then
      local p = pc(ch.d - 1 + 2 * j)
      if sc[p] then
        col[p] = true
        if not resolve(ch) then order[#order + 1] = p end
      end
    end
  end
  cache = {
    version = H.version,
    root = set {root},
    fifth = set {root, fifth or root},
    chord = has,
    scale = sc,
    color = col,
    order = order,
  }
end

local function current()
  if cache.version ~= H.version then rebuild() end
  return cache
end

-- allowed pitch classes for a tension; strong = step falls on a beat.
-- the returned sets are shared: don't modify them
function H.pcs(tension, strong)
  local c = current()
  if tension == 1 then return c.root end
  if tension == 2 then return c.fifth end
  if tension == 3 then return c.chord end
  if strong then
    if tension == 4 then return c.chord end
    return c.color
  end
  return c.scale
end

-- chord tones in voicing importance order (auto chords add the 7th and 9th)
function H.voice_order() return current().order end

function H.set_chord(ch)
  local c = H.chord
  local acc, q = ch.acc or 0, ch.q or 1
  if ch.d ~= c.d or acc ~= c.acc or q ~= c.q then
    c.d, c.acc, c.q = ch.d, acc, q
    H.degree = ch.d
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
  if H.degree > H.size() then H.degree = 1; H.chord.d = 1 end
  H.pending = false
  H.version = H.version + 1
end

-- display helpers ---------------------------------------------------------

local ROMAN = {"I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"}
local FLATS = {"C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"}
local ACC = {[-1] = "b", [1] = "#"}

-- triad quality of a diatonic degree
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

-- the key spells with flats when that gives its notes more distinct letters
-- (F major: Bb, not A#); a chord's own accidental picks its spelling
local spell_ver, key_flats = -1, false
local function names(acc)
  if acc < 0 then return FLATS end
  if acc > 0 then return MU.NOTE_NAMES end
  local v = H.root * 1000 + H.scale
  if v ~= spell_ver then
    spell_ver = v
    local sharp, flat, ns, nf = {}, {}, 0, 0
    for k = 0, H.size() - 1 do
      local a, b = MU.NOTE_NAMES[pc(k) + 1]:sub(1, 1), FLATS[pc(k) + 1]:sub(1, 1)
      if not sharp[a] then sharp[a] = true; ns = ns + 1 end
      if not flat[b] then flat[b] = true; nf = nf + 1 end
    end
    key_flats = nf > ns
  end
  return key_flats and FLATS or MU.NOTE_NAMES
end

-- roman numeral (with accidental, case, o/+, and the box figure), note name
local function parts(ch)
  local acc = ch.acc or 0
  local q = resolve(ch)
  local minor, dim, aug, suffix, fig, r
  if q then
    local iv = set(q[2])
    minor, dim, aug = iv[3], iv[3] and iv[6] and not iv[10], iv[8]
    suffix, fig = q[3], q[4]
    r = (pc(ch.d - 1) + acc) % 12
  else
    local tq = H.quality(ch.d)
    minor, dim, aug = tq == "min" or tq == "dim", tq == "dim", tq == "aug"
    suffix = ({maj = "", min = "m", dim = "dim", aug = "+"})[tq] or "?"
    fig = ""
    r = H.chord_tone(ch.d, 0)
  end
  local rn = ROMAN[ch.d] or tostring(ch.d)
  if minor then rn = string.lower(rn) end
  rn = (ACC[acc] or "") .. rn .. (dim and "o" or aug and "+" or "")
  local name = names(acc)[r + 1] .. suffix
  return {rn, rn .. fig, rn .. fig .. " " .. name}
end

-- labels are drawn every frame: cache them per chord until root/scale change
local labels, labels_ver = {}, -1
local function label(ch)
  local v = H.root * 1000 + H.scale
  if v ~= labels_ver then labels, labels_ver = {}, v end
  local k = ch.d * 100 + ((ch.acc or 0) + 1) * 30 + (ch.q or 1)
  local l = labels[k]
  if not l then l = parts(ch); labels[k] = l end
  return l
end

-- e.g. "ii Dm", "V7 G7", "bVII Bb", "viio Bdim"
function H.chord_label(ch) return label(ch)[3] end

-- numeral only ("ii"), and with its figure ("ii7")
function H.numeral(ch)
  local l = label(ch)
  return l[1], l[2]
end

-- quality as shown in the editor: AUTO, MAJ, MIN, else the label suffix
function H.quality_label(q)
  local e = H.QUALITIES[q] or H.QUALITIES[1]
  if e[1] == "auto" or e[1] == "maj" or e[1] == "min" then return string.upper(e[1]) end
  return e[3]
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
