-- screen: pages (main / track / harmony / clock / scenes), overlays, flashes.
-- E1 page, E2 select, E3 change, K2 back (to main), K3 play/stop or confirm.
local K = include("lib/const")

local UI = {
  page = 1,
  sel = 1,              -- selected track (main page E2, shown on the track page)
  sel_param = {1, 1, 1, 1},   -- per page: selected param row
  sel_scene = 1,
}

local D                 -- deps: tracks, C, H, Cd, Mix, Learn, Confirm, S, Seq, Track
local VERSION = "V0.7"
local PAGES = {"MAIN", "TRACK", "HARMONY", "CLOCK", "SCENES"}
local GLYPH = {"M", "C", "D"}

local msg, msg_until = nil, 0             -- header message
local saved_title, saved_sub, saved_until = nil, nil, 0
local global_until = 0
local chord_flash_until = 0
local track_flash = {}                    -- track id -> time
local boot_until = 0

local now = util.time

-- drawing helpers ---------------------------------------------------------------
-- the whole frame is drawn in Lua into a 128x64 buffer of levels and sent with
-- one screen.poke. every screen.* call goes through a queue locked against
-- the screen thread; a frame of hundreds of calls could stall the tick loop
-- by 10-25 ms, which is audible.

local FB, ZERO = {}, {}
for k = 1, 128 * 64 do FB[k], ZERO[k] = 0, 0 end

local function rect(x, y, w, h, lvl)
  x, y = math.floor(x), math.floor(y)
  local x0, x1 = math.max(0, x), math.min(127, x + w - 1)
  for j = math.max(0, y), math.min(63, y + h - 1) do
    local row = j * 128 + 1
    for i = x0, x1 do FB[row + i] = lvl end
  end
end

local function px(x, y, lvl)
  if x >= 0 and x < 128 and y >= 0 and y < 64 then FB[y * 128 + x + 1] = lvl end
end

local function frame(x, y, w, h, lvl)
  rect(x, y, w, 1, lvl)
  rect(x, y + h - 1, w, 1, lvl)
  rect(x, y, 1, h, lvl)
  rect(x + w - 1, y, 1, h, lvl)
end

-- 3x5 pixel font (rows top to bottom, 3 bits each), 4 px per glyph
local GLYPHS = {
  A = "010101111101101", B = "110101110101110", C = "011100100100011", D = "110101101101110",
  E = "111100110100111", F = "111100110100100", G = "011100101101011", H = "101101111101101",
  I = "111010010010111", J = "001001001101010", K = "101101110101101", L = "100100100100111",
  M = "101111111101101", N = "110101101101101", O = "010101101101010", P = "110101110100100",
  Q = "010101101110011", R = "110101110101101", S = "011100010001110", T = "111010010010010",
  U = "101101101101111", V = "101101101101010", W = "101101111111101", X = "101101010101101",
  Y = "101101010010010", Z = "111001010100111",
  ["0"] = "111101101101111", ["1"] = "010110010010111", ["2"] = "110001010100111",
  ["3"] = "110001010001110", ["4"] = "101101111001001", ["5"] = "111100110001110",
  ["6"] = "011100111101111", ["7"] = "111001010010010", ["8"] = "111101111101111",
  ["9"] = "111101111001110",
  [" "] = "000000000000000", ["."] = "000000000000010", [":"] = "000010000010000",
  ["-"] = "000000111000000", ["+"] = "000010111010000", ["*"] = "000101010101000",
  ["/"] = "001001010100100", ["%"] = "101001010100101", [">"] = "100010001010100",
  ["<"] = "001010100010001", ["|"] = "010010010010010", ["#"] = "101111101111101",
  ["?"] = "110001010000010", ["("] = "010100100100010", [")"] = "010001001001010",
  ["="] = "000111000111000", ["^"] = "010101000000000", ["_"] = "000000000000111",
  ["["] = "110100100100110", ["]"] = "011001001001011", ["!"] = "010010010000010",
  [","] = "000000000010100", ["'"] = "010010000000000",
  -- lowercase only where case carries meaning (minor/dim chords)
  i = "010000010010010", v = "000000101101010", m = "000000111111101",
  o = "000000010101010", d = "001001011101011",
}
-- glyph -> list of {dx, dy} lit pixels
local GLYPH_PX = {}
for ch, bits in pairs(GLYPHS) do
  local list = {}
  for r = 0, 4 do
    for c = 0, 2 do
      if bits:sub(r * 3 + c + 1, r * 3 + c + 1) == "1" then list[#list + 1] = {c, r} end
    end
  end
  GLYPH_PX[ch] = list
end

local function glyph_of(ch)
  return GLYPH_PX[ch] or GLYPH_PX[string.upper(ch)] or GLYPH_PX["?"]
end

local function clean(s)
  s = tostring(s):gsub("\226\134\146", ">"):gsub("\194\177", "+-")
  return (s:gsub("[\128-\255]", ""))
end

local function width(s, scale)
  scale = scale or 1
  return #clean(s) * 4 * scale - scale
end

local function draw_text(x, y, s, lvl, scale)
  s = clean(s)
  scale = scale or 1
  x, y = math.floor(x), math.floor(y)
  for k = 1, #s do
    local g = glyph_of(s:sub(k, k))
    if scale == 1 then
      if x >= 0 and x <= 124 and y >= 0 and y <= 58 then
        local base = y * 128 + x + 1
        for n = 1, #g do
          local p = g[n]
          FB[base + p[2] * 128 + p[1]] = lvl
        end
      else
        for n = 1, #g do px(x + g[n][1], y + g[n][2], lvl) end
      end
    else
      for n = 1, #g do rect(x + g[n][1] * scale, y + g[n][2] * scale, scale, scale, lvl) end
    end
    x = x + 4 * scale
  end
end

-- glyph top-left at (x, y)
local function txt(x, y, s, lvl) draw_text(x, y, s, lvl) end
local function txt_r(x, y, s, lvl) draw_text(x - width(s), y, s, lvl) end
local function txt_c(x, y, s, lvl) draw_text(x - width(s) // 2, y, s, lvl) end

local function big(x, y, s, lvl, align, scale)
  scale = scale or 2
  local w = width(s, scale)
  if align == "c" then x = x - w // 2 elseif align == "r" then x = x - w end
  draw_text(x, y, s, lvl, scale)
end

local function dotted(y)
  for x = 0, 121, 2 do px(x, y, 2) end
end

-- a centred box with a 1 px border; returns its top-left
local function box(w, h)
  local x, y = (128 - w) // 2, (64 - h) // 2
  rect(x - 1, y - 1, w + 2, h + 2, 0)
  frame(x, y, w, h, 15)
  return x, y
end

local function blink(rate) return math.floor(now() * (rate or 4)) % 2 == 0 end

-- ticks since the transport started (for bar/beat positions)
local function rel_ticks()
  if not D.C.playing or not D.C.origin then return 0 end
  return math.max(0, D.Seq.tick_now - D.C.origin)
end

-- public: events -----------------------------------------------------------------

function UI.init(deps)
  D = deps
  boot_until = now() + 6
end

function UI.message(s) msg, msg_until = s, now() + 1 end

function UI.saved(title, sub)
  saved_title, saved_sub, saved_until = title, sub, now() + 0.8
end

function UI.global_moved() global_until = now() + 1 end
function UI.chord_changed() chord_flash_until = now() + 0.15 end
function UI.track_changed(id) track_flash[id] = now() + 0.15 end

-- step data for drawing ---------------------------------------------------------

-- per step: dot height 0..1 and whether it plays at the current density
-- (buffers are reused every frame: drawing must not make garbage)
local strip_buf = {}

local function strip(t)
  local len = t:p("len")
  local lanes = t:num_lanes()
  for l = 1, lanes do t:update_order(len, l) end
  local dens = t:density()
  local ty = t:p("type")
  local out = strip_buf[t.id]
  if not out then
    out = {}
    for s = 1, K.MAX_STEPS do out[s] = {} end
    strip_buf[t.id] = out
  end
  local shown = math.floor(dens * len + 0.5)   -- same rule as Track:is_audible
  local motif = t:p("motif")
  local order1, steps1 = t.lanes[1].order, t.lanes[1].steps
  for s = 1, len do
    local lit, h = false, 0.5
    if ty == 3 then
      -- drums: height = lowest lane that plays (kick at the bottom)
      for l = lanes, 1, -1 do
        if t.lanes[l].order[s] <= shown then lit, h = true, (l - 1) / 7 end
      end
    else
      lit = order1[s] <= shown
      h = ty == 1 and steps1[s].p or 0.5
    end
    local o = out[s]
    o.h, o.lit, o.motif = h, lit, order1[s] <= motif
  end
  return out, len, dens
end

-- header -------------------------------------------------------------------------

local function beat_blip(x)
  local on = D.C.playing and (rel_ticks() % K.PPQN) < K.PPQN / 4
  rect(x, 1, 3, 5, on and 15 or 2)
end

local function tempo_src(right)
  local tempo = math.floor(clock.get_tempo() + 0.5)
  txt_r(right - 15, 1, tempo, D.C.playing and 12 or 5)
  txt(right - 12, 1, D.C.is_slave() and "EXT" or "INT", 4)
end

-- a message replaces the header; returns true if one was drawn
local function header_message()
  local s
  if D.C.warning then s = "! " .. D.C.warning
  elseif D.Learn.active() then s = D.Learn.prompt()
  elseif now() < D.Learn.done_until then s = D.Learn.done_msg
  elseif now() < msg_until then s = msg
  elseif now() < D.Mix.hint_until then s = D.Mix.hint
  end
  if not s then return false end
  txt(0, 1, string.upper(s), 15)
  return true
end

local function header_main()
  if not header_message() then
    local H, Cd = D.H, D.Cd
    local label = H.chord_label(H.degree)
    local w = width(label)
    local pending = Cd.pending_next or Cd.pending_home
    if now() < chord_flash_until then
      rect(0, 0, w + 2, 7, 15)
      txt(1, 1, label, 0)
    else
      txt(0, 1, label, (pending and blink()) and 4 or 15)
    end
    local x = w + 5
    for i = 1, #Cd.working do
      rect(x + (i - 1) * 4, 2, 3, 3, i == Cd.idx and 15 or 3)
    end
    if Cd.unsaved() then txt(x + #Cd.working * 4, 1, "*", 10) end
    if not D.Mix.synced then txt(x + #Cd.working * 4 + 6, 1, "SEND ALL", 6) end
    tempo_src(121)
  end
  beat_blip(123)
  dotted(7)
end

local function header_page(title, info)
  if not header_message() then
    txt(0, 1, title, 15)
    if info then txt(width(title) + 5, 1, info, 6) end
  end
  dotted(7)
end

-- main page ------------------------------------------------------------------

local function draw_row(i, y, selected)
  local t = D.tracks[i]
  local muted = t:p("mute") == 1
  local st, len, dens = strip(t)

  if selected then
    rect(0, y, 4, 6, muted and 4 or 10)
    txt(0, y, i, 0)
  else
    txt(0, y, i, muted and 3 or 10)
  end
  txt(4, y, GLYPH[t:p("type")], muted and 2 or 6)

  if track_flash[i] and now() < track_flash[i] then rect(9, y, len * 2 - 1, 6, 4) end
  for s = 1, len do
    local x = 9 + (s - 1) * 2
    local d = st[s]
    local py = y + 4 - math.floor(d.h * 4 + 0.5)
    if D.C.playing and s == t.pos and not muted then
      rect(x, y, 1, 6, d.lit and 15 or 6)
      px(x, py, 0)
    else
      px(x, py, d.lit and (muted and 3 or 12) or (muted and 1 or 3))
    end
    if d.motif then px(x, y + 6, muted and 1 or 5) end
  end

  -- density: fill = fader, tick = effective level after fader 9
  local bx, bw = 74, 10
  frame(bx, y, bw, 5, muted and 1 or 3)
  rect(bx + 1, y + 1, math.floor((bw - 2) * t:p("density") / 100 + 0.5), 3, muted and 2 or 9)
  rect(bx + 1 + math.min(bw - 3, math.floor((bw - 2) * dens + 0.5)), y, 1, 5, muted and 3 or 15)

  -- length and division
  txt_r(92, y, len, muted and 3 or 12)
  txt(95, y, K.DIV_SHORT[t:p("div")], muted and 2 or 7)

  -- slot: blinks while a change waits for the bar, * = unsaved
  local lvl = (t.pending and blink()) and 2 or (muted and 3 or 11)
  txt(112, y, t:target_slot(), lvl)
  if t:unsaved() then txt(112 + width(t:target_slot()) + 1, y, "*", muted and 2 or 15) end
end

local function global_meter()
  local x, top, h = 125, 9, 55
  local mid = top + h // 2
  rect(x, top, 2, h, 1)
  local dz = math.floor(params:get("deadzone") / 100 * h / 2 + 0.5)
  rect(x, mid - dz, 2, 2 * dz + 1, 3)
  local raw = params:get("global_density") / 100
  local v = math.floor(raw * h / 2 + 0.5)
  local lvl = D.Track.global_offset() == 0 and 5 or 12
  if v > 0 then rect(x, mid - v, 2, v, lvl) elseif v < 0 then rect(x, mid + 1, 2, -v, lvl) end
  rect(x - 1, mid, 4, 1, 8)
end

local function page_main()
  header_main()
  for i = 1, K.NUM_TRACKS do draw_row(i, 9 + (i - 1) * 7, i == UI.sel) end
  global_meter()
end

-- param lists (track / harmony / clock pages) -------------------------------------

-- rows: list of param ids. draws `n` rows from y, scrolled to the selection
local function param_list(page, rows, y, n)
  local sel = util.clamp(UI.sel_param[page], 1, #rows)
  UI.sel_param[page] = sel
  local first = util.clamp(sel - n // 2, 1, math.max(1, #rows - n + 1))
  for r = 0, n - 1 do
    local id = rows[first + r]
    if not id then break end
    local ry = y + r * 6
    local on = first + r == sel
    if on then rect(0, ry - 1, 122, 7, 2) end
    local p = params:lookup_param(id)
    txt(2, ry, string.upper(p.name), on and 15 or 5)
    txt(62, ry, string.upper(params:string(id)), on and 15 or 9)
  end
  -- scroll position
  if #rows > n then
    local h = math.max(2, math.floor(n / #rows * n * 6))
    local sy = y - 1 + math.floor((first - 1) / (#rows - n) * (n * 6 - h))
    rect(124, sy, 1, h, 4)
  end
end

local TRACK_ROWS = {
  "type", "voices", "len", "div", "range", "base", "tension", "gate", "fixgate",
  "velon", "vel", "velspread", "legato", "legprob", "drift", "gravity", "motif",
  "restart", "port", "ch",
}

local function track_rows()
  local pre = "t" .. UI.sel .. "_"
  local rows = {}
  for _, k in ipairs(TRACK_ROWS) do
    if params:visible(pre .. k) then rows[#rows + 1] = pre .. k end
  end
  if params:get(pre .. "type") == 3 then
    for l = 1, params:get(pre .. "voices") do
      rows[#rows + 1] = pre .. "lane" .. l .. "_note"
      rows[#rows + 1] = pre .. "lane" .. l .. "_role"
    end
  end
  rows[#rows + 1] = pre .. "clear"
  return rows
end

local HARMONY_ROWS = {"root", "scale", "progression", "chords", "chord_rate",
                      "harmony_drift", "harmony_gravity"}

local function clock_rows()
  local rows = {"clock_tempo", "lagom_clock_mode", "lagom_clock_in", "beats_per_bar",
                "controller_port"}
  for i = 1, 16 do
    if midi.vports[i].name ~= "none" then rows[#rows + 1] = "lagom_clk_out_" .. i end
  end
  return rows
end

-- track page -------------------------------------------------------------------

local function page_track()
  local i = UI.sel
  local t = D.tracks[i]
  local ty = t:p("type")
  header_page("T" .. i, string.upper(D.Track.TYPES[ty]) .. "  P" .. t:p("port") .. " CH" .. t:p("ch"))
  txt_r(121, 1, t:target_slot() .. (t:unsaved() and "*" or " "),
        (t.pending and blink()) and 2 or 11)

  local st, len, dens = strip(t)
  if track_flash[i] and now() < track_flash[i] then rect(0, 9, 97, 28, 3) end
  if ty == 3 then
    -- drums: one row per lane
    local lanes = t:num_lanes()
    for l = 1, lanes do t:update_order(len, l) end
    for l = 1, lanes do
      local ly = 34 - l * 3
      for s = 1, K.MAX_STEPS do
        local x = 1 + (s - 1) * 3
        local lvl = 1
        if s <= len then
          local on = t:is_audible(s, len, dens, l)
          lvl = on and ((D.C.playing and s == t.pos) and 15 or 10) or 3
        end
        rect(x, ly, 2, 2, lvl)
      end
    end
  else
    for s = 1, K.MAX_STEPS do
      local x = 1 + (s - 1) * 3
      local h, lvl = 2, 1
      if s <= len then
        local d = st[s]
        h = math.floor(d.h * 22 + 0.5) + 2
        lvl = d.lit and ((D.C.playing and s == t.pos) and 15 or 10) or 3
      else
        h = math.floor(t.lanes[1].steps[s].p * 22 + 0.5) + 2
      end
      rect(x, 34 - h, 2, h, lvl)
    end
  end
  for s = 1, len do
    if st[s].motif then rect(1 + (s - 1) * 3, 36, 2, 1, 8) end
  end
  if D.C.playing and t.pos >= 1 and t.pos <= len then
    rect(1 + (t.pos - 1) * 3, 37, 2, 1, 15)
  end

  txt(100, 10, "LEN", 4)
  txt(100, 16, len, 12)
  txt(100, 23, "DIV", 4)
  txt(100, 29, K.DIV_SHORT[t:p("div")], 12)

  param_list(2, track_rows(), 40, 4)
end

-- harmony page -------------------------------------------------------------------

local WHITE = {0, 2, 4, 5, 7, 9, 11}
local BLACK = {{1, 1}, {3, 2}, {6, 4}, {8, 5}, {10, 6}}   -- pc, after white key n

local function page_harmony()
  local H, Cd = D.H, D.Cd
  local mode = params:string("progression")
  header_page("HARMONY", H.key_label() .. "  " .. string.upper(mode))

  -- progression boxes
  local n = #Cd.working
  local w = math.floor(124 / n) - 2
  local rate = Cd.RATES[params:get("chord_rate")]
  local bar = params:get("beats_per_bar") * K.PPQN
  for i, deg in ipairs(Cd.working) do
    local x, y = 1 + (i - 1) * (w + 2), 11
    local label = H.chord_label(deg):match("^(%S+)")
    if i == Cd.idx then
      local flash = now() < chord_flash_until
      rect(x, y, w, 13, flash and 8 or 15)
      txt_c(x + w / 2, y + 4, label, 0)
      -- progress through this chord's bars
      local frac = ((Cd.bars + (rel_ticks() % bar) / bar) / rate)
      rect(x, 26, math.floor(w * math.min(1, frac) + 0.5), 1, 10)
    else
      local pend = (Cd.pending_next and i == (Cd.idx % n) + 1) and blink()
      frame(x, y, w, 13, pend and 12 or 4)
      txt_c(x + w / 2, y + 4, label, Cd.anchor[i] ~= deg and 15 or 7)
    end
  end

  -- keyboard: bright = chord tones, dim = scale
  local chord = H.pcs(3, true)
  local scale = H.pcs(4, false)
  local function lvl_of(pc, white)
    if chord[pc] then return 13 end
    if scale[pc] then return 5 end
    return white and 1 or 0
  end
  for o = 0, 1 do
    for k, pc in ipairs(WHITE) do
      rect(1 + (o * 7 + k - 1) * 9, 31, 8, 20, lvl_of(pc, true))
    end
  end
  for o = 0, 1 do
    for _, b in ipairs(BLACK) do
      local x = 1 + (o * 7 + b[2]) * 9 - 3
      rect(x, 31, 5, 12, 0)
      rect(x + 1, 31, 3, 11, lvl_of(b[1], false))
    end
  end

  param_list(3, HARMONY_ROWS, 56, 1)
  txt_r(121, 56, UI.sel_param[3] .. "/" .. #HARMONY_ROWS, 3)
end

-- clock page -----------------------------------------------------------------------

local function page_clock()
  local C = D.C
  header_page("CLOCK + IO")
  big(1, 11, math.floor(clock.get_tempo() + 0.5), 15, nil, 3)
  txt(42, 10, "BPM", 5)
  txt(42, 17, C.is_slave() and "SLAVE" or "MASTER", 10)
  txt(42, 24, C.playing and "PLAYING" or "STOPPED", C.playing and 12 or 4)

  local bpb = params:get("beats_per_bar")
  local shown = math.min(bpb, 8)
  local beat = math.floor(rel_ticks() / K.PPQN) % bpb
  local bw = math.floor(38 / shown) - 1
  for b = 0, shown - 1 do
    rect(2 + b * (bw + 1), 30, bw, 3, (C.playing and beat == b) and 15 or 3)
  end

  local outs = {}
  for _, p in ipairs(C.out_ports()) do outs[#outs + 1] = p end
  txt(80, 10, "CLOCK IN", 4)
  txt(80, 16, C.is_slave() and ("PORT " .. params:get("lagom_clock_in")) or "-", 10)
  txt(80, 23, "CLOCK OUT", 4)
  txt(80, 29, #outs > 0 and table.concat(outs, " ") or "NONE", 10)

  param_list(4, clock_rows(), 40, 4)
end

-- scenes page ------------------------------------------------------------------------

local function scene_is_current(sc)
  for i, t in ipairs(D.tracks) do
    if sc[i] ~= t:target_slot() then return false end
  end
  return true
end

local function page_scenes()
  header_page("SCENES")
  txt_r(121, 1, "K2 STORE K3 RECALL", 4)
  for k = 1, 8 do
    local x, y = 1 + ((k - 1) % 4) * 31, 10 + ((k - 1) // 4) * 27
    local sc = D.S.scenes[k]
    local sel = k == UI.sel_scene
    if sel then rect(x, y, 29, 25, 4) end
    frame(x, y, 29, 25, sc and 9 or 3)
    txt(x + 3, y + 3, k, sel and 15 or (sc and 9 or 4))
    if sc then
      if scene_is_current(sc) then rect(x + 23, y + 3, 3, 3, 15) end
      for i = 1, K.NUM_TRACKS do
        local h = math.floor((sc[i] or 1) / 16 * 13 + 0.5) + 1
        rect(x + 3 + (i - 1) * 3, y + 22 - h, 2, h, sel and 12 or 6)
      end
    end
  end
end

-- overlays -------------------------------------------------------------------------

local function overlay_saved()
  local x, y = box(70, 24)
  big(64, y + 3, "SAVED", 15, "c")
  txt_c(64, y + 16, saved_sub or "", 6)
end

local function overlay_global()
  local x, y = box(104, 40)
  txt(x + 4, y + 4, "GLOBAL", 8)
  local g = params:get("global_density")
  big(x + 100, y + 3, (g > 0 and "+" or "") .. g .. "%", 15, "r")
  local bx, bw, by = x + 6, 92, y + 17
  local mid = bx + bw // 2
  rect(bx, by, bw, 6, 2)
  local dz = math.floor(params:get("deadzone") / 100 * bw / 2 + 0.5)
  rect(mid - dz, by - 1, 2 * dz + 1, 8, 5)
  local v = math.floor(g / 100 * bw / 2 + 0.5)
  if v > 0 then rect(mid, by + 1, v, 4, 13) elseif v < 0 then rect(mid + v, by + 1, -v, 4, 13) end
  -- ghost ticks: every track's effective level
  for _, t in ipairs(D.tracks) do
    rect(bx + math.floor(t:density() * (bw - 1) + 0.5), by + 9, 1, 4, t:p("mute") == 1 and 3 or 10)
  end
  txt(bx, by + 15, "-100", 4)
  txt_r(bx + bw, by + 15, "+100", 4)
end

local function overlay_confirm(c)
  local x, y = box(112, 36)
  txt(x + 4, y + 4, c.lines[1], 15)
  if c.lines[2] then txt(x + 4, y + 12, c.lines[2], 7) end
  rect(x + 4, y + 25, 44, 8, 4)
  txt(x + 7, y + 26, "K2 NO", 12)
  rect(x + 64, y + 25, 44, 8, 15)
  txt(x + 67, y + 26, "K3 YES", 0)
end

local function boot_screen()
  big(64, 8, "LAGOM", 15, "c", 4)
  for i = 0, 39 do px(44 + i, 30, i % 2 == 1 and 3 or 8) end
  txt_c(64, 37, "PRESS SEND ALL", 10)
  txt_c(64, 44, "ON THE MIDIMIX", 5)
  txt_c(64, 56, VERSION, 2)
end

-- public: draw / input -------------------------------------------------------------

local DRAW = {page_main, page_track, page_harmony, page_clock, page_scenes}

function UI.redraw()
  table.move(ZERO, 1, 128 * 64, 1, FB)
  if now() < boot_until and not D.Mix.synced then
    boot_screen()
  else
    boot_until = 0
    DRAW[UI.page]()
    local c = D.Confirm.queue[1]
    if c then overlay_confirm(c)
    elseif now() < saved_until then overlay_saved()
    elseif now() < global_until then overlay_global()
    end
  end
  screen.poke(0, 0, 128, 64, string.char(table.unpack(FB)))
  screen.update()
end

local function rows_of(page)
  if page == 2 then return track_rows() end
  if page == 3 then return HARMONY_ROWS end
  if page == 4 then return clock_rows() end
end

function UI.enc(n, d)
  boot_until = 0
  if n == 1 then
    UI.page = util.clamp(UI.page + d, 1, #PAGES)
  elseif UI.page == 1 then
    if n == 2 then UI.sel = util.clamp(UI.sel + d, 1, K.NUM_TRACKS)
    elseif n == 3 then params:delta("t" .. UI.sel .. "_slot", d) end
  elseif UI.page == 5 then
    if n == 2 or n == 3 then UI.sel_scene = util.clamp(UI.sel_scene + d, 1, 8) end
  else
    local rows = rows_of(UI.page)
    if n == 2 then
      UI.sel_param[UI.page] = util.clamp(UI.sel_param[UI.page] + d, 1, #rows)
    elseif n == 3 then
      local id = rows[UI.sel_param[UI.page]]
      local p = params:lookup_param(id)
      if p.t == params.tTRIGGER then
        if d > 0 then params:set(id, 1) end
      else
        params:delta(id, d)
      end
    end
  end
end

-- returns true if the key was used by the page
function UI.key(n, z)
  if z == 0 then return false end
  if boot_until > 0 then boot_until = 0 end
  if UI.page == 5 then
    local k = UI.sel_scene
    if n == 3 then
      params:set("scene_recall_" .. k, 1)
      return true
    elseif n == 2 then
      if D.S.scenes[k] then
        D.Confirm.ask({"OVERWRITE SCENE " .. k .. "?"}, function() params:set("scene_store_" .. k, 1) end)
      else
        params:set("scene_store_" .. k, 1)
      end
      return true
    end
  elseif n == 2 and UI.page ~= 1 then
    UI.page = 1
    return true
  end
  return false
end

return UI
