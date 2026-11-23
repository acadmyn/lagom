-- screen: pages (main / track / harmony / clock / scenes), overlays, flashes.
-- E1 page, E2 select, E3 change, K2 back (to main), K3 play/stop or confirm.
local K = include("lib/const")

local UI = {
  page = 1,
  sel = 1,              -- selected track (main page E2, shown on the track page)
  sel_param = {1, 1, 1, 1},   -- per page: selected param row
  sel_scene = 1,
  layout_dirty = true,  -- tracks were enabled/disabled: recompute main page rows
}

local D                 -- deps: tracks, C, H, Cd, Mix, Learn, Confirm, S, Seq, Track
local VERSION = "V0.7"
local PAGES = {"MAIN", "TRACK", "HARMONY", "CLOCK", "SCENES"}
local GLYPH = {"M", "C", "D", "P"}

local msg, msg_until = nil, 0             -- header message
local saved_title, saved_sub, saved_until = nil, nil, 0
local global_until = 0
local POPUP_TIME = 1          -- seconds a fader/knob pop-up stays up
local PICKUP_TIME = 1.5       -- longer while a knob has not picked up
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

-- stretch: step s of len spread over `span` px -> start x offset and width
-- (minus a 1 px gap when there is room), so short sequences fill the view
local function step_span(s, len, span)
  local x0 = (s - 1) * span // len
  local x1 = s * span // len
  local w = x1 - x0
  if w >= 2 then w = w - 1 end
  return x0, w
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

function UI.message(s, secs) msg, msg_until = s, now() + (secs or 1) end

-- a device came or went: tell if any track (or the controller) uses it
local function ports_changed(changed)
  for _, p in ipairs(changed) do
    local used = p == D.Mix.port()
    for _, t in ipairs(D.tracks) do used = used or t:p("port") == p end
    if used then
      UI.message("P" .. p .. " " .. midi.vports[p].name .. (D.Out.up[p] and " ON" or " OFF"), 2)
    end
  end
end

-- the track's port has no device
local function port_down(t) return not D.Out.up[t:p("port")] end

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
local lane_ord, lane_sh, lane_ins = {}, {}, {}

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
  if ty == 3 then
    for l = 1, lanes do
      lane_ord[l], lane_sh[l], lane_ins[l] = t:drum_lane(l, len, dens)
      if not lane_ins[l] then lane_ins[l] = false end
    end
  end
  for s = 1, len do
    local lit, h, mask = false, 0.5, 0
    if ty == 3 then
      -- drums: height = lowest lane that plays (kick at the bottom)
      for l = lanes, 1, -1 do
        local ins = lane_ins[l]
        if (not ins or ins[s]) and lane_ord[l][s] <= lane_sh[l] then
          lit, h, mask = true, (l - 1) / 7, mask | (1 << l)
        end
      end
    elseif ty == 4 then
      -- poly: height = pitch of the lowest-numbered voice that plays
      h = steps1[s].p
      for l = lanes, 1, -1 do
        local ls = math.floor(t:lane_density(dens, l, lanes) * len + 0.5)
        if t.lanes[l].order[s] <= ls then
          lit, h, mask = true, t.lanes[l].steps[s].p, mask | (1 << l)
        end
      end
    else
      lit = order1[s] <= shown
      h = ty == 1 and steps1[s].p or 0.5
    end
    local o = out[s]
    o.h, o.lit, o.motif, o.mask = h, lit, order1[s] <= motif, mask
  end
  return out, len, dens, lanes
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

-- row height `rh` (7 = compact). content is rh - 1 tall, the motif line below.
-- rows of 10 px or more draw drum lanes and poly voices separately
local function draw_row(i, y, selected, rh)
  local t = D.tracks[i]
  local muted = t:p("mute") == 1
  local st, len, dens, lanes = strip(t)
  local ch = rh - 1
  local r = ch - 2
  local ty = t:p("type")
  local tall = rh >= 10 and (ty == 3 or ty == 4)
  local playing = D.C.playing and not muted

  if selected then
    rect(0, y, 4, 6, muted and 4 or 10)
    txt(0, y, i, 0)
  else
    txt(0, y, i, muted and 3 or 10)
  end
  if port_down(t) then
    txt(4, y, "!", 15)
  else
    txt(4, y, GLYPH[t:p("type")], muted and 2 or 6)
  end

  if track_flash[i] and now() < track_flash[i] then rect(9, y, 63, ch, 4) end
  local on_lvl, off_lvl = muted and 3 or 12, muted and 1 or 3
  for s = 1, len do
    local dx, w = step_span(s, len, 64)
    local x = 9 + dx
    local d = st[s]
    local head = playing and s == t.pos
    if tall then
      if head then rect(x, y, w, ch, 4) end
      if ty == 3 then
        -- one row per lane, lane 1 (kick) at the bottom
        local lh = math.max(1, ch // lanes - 1)
        for l = 1, lanes do
          local ly = y + ((lanes - l) * ch) // lanes
          local lit = d.mask & (1 << l) ~= 0
          if lit or not head then
            rect(x, ly, w, lh, lit and (head and 15 or on_lvl) or (muted and 0 or 1))
          end
        end
      else
        -- every voice that plays at its own pitch; voice 1 dim when none do
        if d.mask == 0 then
          rect(x, y + r - math.floor(d.h * r + 0.5), w, 1, off_lvl)
        else
          for l = 1, lanes do
            if d.mask & (1 << l) ~= 0 then
              local py = y + r - math.floor(t.lanes[l].steps[s].p * r + 0.5)
              rect(x, py, w, 1, head and 15 or on_lvl)
            end
          end
        end
      end
    else
      local py = y + r - math.floor(d.h * r + 0.5)
      if head then
        rect(x, y, w, ch, d.lit and 15 or 6)
        rect(x, py, w, 1, 0)
      else
        rect(x, py, w, 1, d.lit and on_lvl or off_lvl)
      end
    end
    if d.motif then rect(x, y + ch, w, 1, muted and 1 or 5) end
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

-- enabled tracks in order and their row height; rebuilt only when a track
-- is enabled or disabled
local shown_ids, row_h = {}, 7

local function enabled(i) return params:get("t" .. i .. "_enabled") == 1 end

-- nearest enabled track from i in direction dir (or i if none)
local function next_enabled(i, dir)
  local j = i + dir
  while j >= 1 and j <= K.NUM_TRACKS do
    if enabled(j) then return j end
    j = j + dir
  end
  return i
end

local function relayout()
  UI.layout_dirty = false
  shown_ids = {}
  for i = 1, K.NUM_TRACKS do
    if enabled(i) then shown_ids[#shown_ids + 1] = i end
  end
  row_h = math.max(7, 56 // math.max(1, #shown_ids))
  if #shown_ids > 0 and not enabled(UI.sel) then
    local j = next_enabled(UI.sel, 1)
    if j == UI.sel then j = next_enabled(UI.sel, -1) end
    UI.sel = j
  end
end

local function page_main()
  header_main()
  if #shown_ids == 0 then
    txt_c(62, 28, "NO TRACKS ENABLED", 10)
    txt_c(62, 36, "TURN ONE ON ON THE TRACK PAGE", 4)
  end
  for k, i in ipairs(shown_ids) do
    draw_row(i, 9 + (k - 1) * row_h, i == UI.sel, row_h)
  end
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
    if id == "track" then
      txt(2, ry, "TRACK", on and 15 or 5)
      txt(62, ry, "< " .. UI.sel .. " >", on and 15 or 9)
    elseif id == "shift" then
      txt(2, ry, "SHIFT", on and 15 or 5)
      txt(62, ry, "< E3 >", on and 15 or 9)
    elseif id == "move" then
      txt(2, ry, "MOVE SLOT", on and 15 or 5)
      txt(62, ry, "< " .. D.tracks[UI.sel].slot .. " >", on and 15 or 9)
    elseif id:match("^hchord") then
      local ci = tonumber(id:sub(7))
      txt(2, ry, "CHORD " .. ci, on and 15 or 5)
      txt(62, ry, D.H.chord_label(D.Cd.working[ci].d), on and 15 or 9)
    elseif id:match("^hlen") then
      local ci = tonumber(id:sub(5))
      local len = D.Cd.working[ci].len
      txt(2, ry, "CHORD " .. ci .. " LENGTH", on and 15 or 5)
      txt(62, ry, len .. (len == 1 and " BAR" or " BARS"), on and 15 or 9)
    else
      local p = params:lookup_param(id)
      txt(2, ry, string.upper(p.name), on and 15 or 5)
      local v = p.t == params.tBINARY and (params:get(id) == 1 and "ON" or "OFF")
                or string.upper(params:string(id))
      txt(62, ry, v, on and 15 or 9)
      if (id:match("_port$") or id == "lagom_clock_in") and not D.Out.up[params:get(id)] then
        txt(62 + width(v) + 4, ry, "OFF", 15)
      end
      if id:match("_copy_to$") then
        local t = D.tracks[UI.sel]
        local n = params:get(id)
        txt(78, ry, n == t.slot and "(SAME)" or (t.slots[n] and "K3 (FULL)" or "K3"), on and 10 or 4)
      end
    end
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
  local rows = {"track", pre .. "enabled"}
  for _, k in ipairs(TRACK_ROWS) do
    if params:visible(pre .. k) then rows[#rows + 1] = pre .. k end
  end
  if params:get(pre .. "type") == 3 then
    for l = 1, params:get(pre .. "voices") do
      local lp = pre .. "lane" .. l .. "_"
      rows[#rows + 1] = lp .. "note"
      rows[#rows + 1] = lp .. "mode"
      if params:get(lp .. "mode") == 2 then
        rows[#rows + 1] = lp .. "hits"
        rows[#rows + 1] = lp .. "rotate"
      else
        rows[#rows + 1] = lp .. "max"
      end
      rows[#rows + 1] = lp .. "from"
      rows[#rows + 1] = lp .. "to"
      rows[#rows + 1] = lp .. "role"
    end
  end
  rows[#rows + 1] = "shift"
  rows[#rows + 1] = "move"
  rows[#rows + 1] = pre .. "copy_to"
  rows[#rows + 1] = pre .. "clear"
  return rows
end

-- harmony page: two stops per chord (hchordN = degree, hlenN = length),
-- then params. rebuilt when the chord count changes; the selection follows
-- the item it was on
local HARMONY_PARAMS = {"harmony_slot", "chords", "progression", "reroll_progression",
                        "chord_rate", "root", "scale", "harmony_drift", "harmony_gravity"}
local h_rows, h_rows_n = {}, -1

local function harmony_rows()
  local n = #D.Cd.working
  if n == h_rows_n then return h_rows end
  local was = h_rows[UI.sel_param[3] or 1]
  h_rows = {}
  for i = 1, n do
    h_rows[#h_rows + 1] = "hchord" .. i
    h_rows[#h_rows + 1] = "hlen" .. i
  end
  for _, id in ipairs(HARMONY_PARAMS) do h_rows[#h_rows + 1] = id end
  h_rows_n = n
  if was then
    for k, id in ipairs(h_rows) do
      if id == was then UI.sel_param[3] = k; break end
    end
  end
  return h_rows
end

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
  header_page("T" .. i, enabled(i) and
    (string.upper(D.Track.TYPES[ty]) .. "  P" .. t:p("port") .. " CH" .. t:p("ch")) or "OFF")
  txt_r(121, 1, t:target_slot() .. (t:unsaved() and "*" or " "),
        (t.pending and blink()) and 2 or 11)

  local st, len, dens = strip(t)
  if track_flash[i] and now() < track_flash[i] then rect(0, 9, 97, 28, 3) end
  if ty == 3 then
    -- drums: one row per lane
    local lanes = t:num_lanes()
    for l = 1, lanes do
      local ly = 34 - l * 3
      local ord, sh, ins = t:drum_lane(l, len, dens)
      for s = 1, len do
        local dx, w = step_span(s, len, 96)
        local on = (not ins or ins[s]) and ord[s] <= sh
        rect(1 + dx, ly, w, 2, on and ((D.C.playing and s == t.pos) and 15 or 10) or 3)
      end
    end
  elseif ty == 4 then
    -- poly: a 2 px mark per voice at its pitch; hidden notes dim, voice 1
    -- brightest, the playing step brightest of all
    local lanes = t:num_lanes()
    for pass = 0, 1 do
      for l = lanes, 1, -1 do
        local ld = t:lane_density(dens, l, lanes)
        for s = 1, len do
          local on = t:is_audible(s, len, ld, l)
          if (pass == 1) == on then
            local dx, w = step_span(s, len, 96)
            local y = 32 - math.floor(t.lanes[l].steps[s].p * 22 + 0.5)
            local lv = 2
            if on then lv = (D.C.playing and s == t.pos) and 15 or math.max(5, 11 - l) end
            rect(1 + dx, y, w, 2, lv)
          end
        end
      end
    end
  else
    for s = 1, len do
      local dx, w = step_span(s, len, 96)
      local d = st[s]
      local h = math.floor(d.h * 22 + 0.5) + 2
      rect(1 + dx, 34 - h, w, h, d.lit and ((D.C.playing and s == t.pos) and 15 or 10) or 3)
    end
  end
  for s = 1, len do
    local dx, w = step_span(s, len, 96)
    if st[s].motif then rect(1 + dx, 36, w, 1, 8) end
  end
  if D.C.playing and t.pos >= 1 and t.pos <= len then
    local dx, w = step_span(t.pos, len, 96)
    rect(1 + dx, 37, w, 1, 15)
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
  txt_r(121, 1, Cd.target_slot() .. (Cd.unsaved() and "*" or " "),
        (Cd.pending_slot and blink()) and 2 or 11)

  -- progression boxes: width follows each chord's length (at least 12 px).
  -- dots under a box = its bars; the selected chord gets a bright frame
  local rows = harmony_rows()
  local sel = rows[UI.sel_param[3]] or ""
  local sel_i = tonumber(sel:match("^hchord(%d)") or sel:match("^hlen(%d)") or "")
  local sel_len = sel:match("^hlen") ~= nil
  local n = #Cd.working
  local total = 0
  for _, ch in ipairs(Cd.working) do total = total + ch.len end
  local avail = 124 - 2 * (n - 1)
  local minw = math.min(12, avail // n)
  local extra = avail - minw * n
  local bar = params:get("beats_per_bar") * K.PPQN
  local x, y = 1, 11
  for i, ch in ipairs(Cd.working) do
    local w = minw + math.floor(extra * ch.len / total)
    local label = H.chord_label(ch.d):match("^(%S+)")
    local a = Cd.anchor[i]
    local changed = not a or a.d ~= ch.d or a.len ~= ch.len
    if i == Cd.idx then
      local flash = now() < chord_flash_until
      rect(x, y, w, 13, flash and 8 or 15)
      txt_c(x + w / 2, y + 4, label, 0)
      -- progress through this chord's bars
      local frac = ((Cd.bars + (rel_ticks() % bar) / bar) / ch.len)
      rect(x, 26, math.floor(w * math.min(1, frac) + 0.5), 1, 10)
    else
      local pend = (Cd.pending_next and i == (Cd.idx % n) + 1) and blink()
      frame(x, y, w, 13, pend and 12 or 4)
      txt_c(x + w / 2, y + 4, label, changed and 15 or 7)
    end
    if i == sel_i and not sel_len then frame(x - 1, y - 1, w + 2, 15, 15) end
    local bw = math.max(1, w // ch.len)
    for b = 0, ch.len - 1 do
      rect(x + b * bw, 28, math.max(1, bw - 1), 1, (i == sel_i and sel_len) and 15 or 3)
    end
    x = x + w + 2
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

  param_list(3, rows, 56, 1)
  txt_r(121, 56, UI.sel_param[3] .. "/" .. #rows, 3)
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
  return sc.h == nil or sc.h == D.Cd.target_slot()
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
    if sc and sc.h then txt(x + 9, y + 3, "H" .. sc.h, sel and 12 or 6) end
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

-- track fader / knob: name, big value, a bar over the param's range. while a
-- knob has not picked up, the bar is dim, a blinking tick marks the knob and
-- an arrow says which way to turn it.
local function overlay_touch(T)
  local x, y = box(104, 40)
  txt(x + 4, y + 4, T.title, 8)
  big(x + 100, y + 3, T.value, 15, "r")
  local bx, bw, by = x + 6, 92, y + 19
  rect(bx, by, bw, 6, 2)
  local fw = math.floor(T.frac * bw + 0.5)
  if fw > 0 then rect(bx, by + 1, fw, 4, T.knob and 6 or 13) end
  if T.knob then
    local kx = bx + math.floor(T.knob_frac * (bw - 1) + 0.5)
    rect(kx, by - 2, 1, 10, blink(6) and 15 or 8)
    txt_c(64, by + 10, T.knob, 15)
  end
  txt(bx, by + 10, T.lo, 4)
  txt_r(bx + bw, by + 10, T.hi, 4)
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
  local changed = D.Out.poll()
  if changed then ports_changed(changed) end
  if UI.layout_dirty then relayout() end
  table.move(ZERO, 1, 128 * 64, 1, FB)
  if now() < boot_until and not D.Mix.synced then
    boot_screen()
  else
    boot_until = 0
    DRAW[UI.page]()
    local c = D.Confirm.queue[1]
    if c then overlay_confirm(c)
    elseif now() < saved_until then overlay_saved()
    else
      -- whichever of master fader / track control moved last
      local T = D.Mix.touch
      local t_until = T.at + (T.knob and PICKUP_TIME or POPUP_TIME)
      if now() < t_until and T.at >= global_until - 1 then overlay_touch(T)
      elseif now() < global_until then overlay_global()
      end
    end
  end
  screen.poke(0, 0, 128, 64, string.char(table.unpack(FB)))
  screen.update()
end

local function rows_of(page)
  if page == 2 then return track_rows() end
  if page == 3 then return harmony_rows() end
  if page == 4 then return clock_rows() end
end

function UI.enc(n, d)
  boot_until = 0
  if n == 1 then
    UI.page = util.clamp(UI.page + d, 1, #PAGES)
  elseif UI.page == 1 then
    if n == 2 then
      local dir = d > 0 and 1 or -1
      for _ = 1, math.abs(d) do UI.sel = next_enabled(UI.sel, dir) end
    elseif n == 3 then params:delta("t" .. UI.sel .. "_slot", d) end
  elseif UI.page == 5 then
    if n == 2 or n == 3 then UI.sel_scene = util.clamp(UI.sel_scene + d, 1, 8) end
  else
    local rows = rows_of(UI.page)
    if n == 2 then
      UI.sel_param[UI.page] = util.clamp(UI.sel_param[UI.page] + d, 1, #rows)
    elseif n == 3 then
      local id = rows[UI.sel_param[UI.page]]
      if id == "track" then
        UI.sel = util.clamp(UI.sel + d, 1, K.NUM_TRACKS)
        return
      elseif id == "shift" then
        params:set("t" .. UI.sel .. (d > 0 and "_shift_right" or "_shift_left"), 1)
        return
      elseif id == "move" then
        params:set("t" .. UI.sel .. (d > 0 and "_move_later" or "_move_earlier"), 1)
        return
      elseif id:match("^hchord") then
        local ci = tonumber(id:sub(7))
        D.Cd.set_degree(ci, D.Cd.working[ci].d + d)
        return
      elseif id:match("^hlen") then
        local ci = tonumber(id:sub(5))
        D.Cd.set_len(ci, D.Cd.working[ci].len + d)
        return
      end
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
  elseif n == 3 and UI.page == 2 then
    local rows = track_rows()
    local id = rows[UI.sel_param[2]]
    if id and id:match("_copy_to$") then
      params:set("t" .. UI.sel .. "_copy", 1)
      return true
    end
  elseif n == 2 and UI.page ~= 1 then
    UI.page = 1
    return true
  end
  return false
end

return UI
