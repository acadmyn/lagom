-- drum lane note learn: arm a lane, the next incoming note-on (from any
-- port except the controller) becomes that lane's note
local L = {
  track = nil,       -- armed track, or nil
  lane = nil,        -- armed lane
  last = nil,        -- lane to stop after (learn all), or nil for one lane
  done_msg = nil,    -- "T1 L2 = F2" shown briefly after a learn
  done_until = 0,
}

local MU = require "musicutil"
local TIMEOUT = 15
local deadline = 0

function L.arm(track, lane, last)
  L.track, L.lane, L.last = track, lane, last
  deadline = util.time() + TIMEOUT
end

function L.cancel() L.track, L.lane, L.last = nil, nil, nil end

function L.active()
  if L.track and util.time() > deadline then L.cancel() end
  return L.track ~= nil
end

function L.prompt()
  return "LEARN T" .. L.track .. " LANE " .. L.lane .. ": PLAY A NOTE"
end

-- returns true if the message was consumed
function L.midi_in(data)
  if not L.active() then return false end
  local msg = midi.to_msg(data)
  if msg.type ~= "note_on" then return false end
  local id = "t" .. L.track .. "_lane" .. L.lane .. "_note"
  params:set(id, msg.note)
  L.done_msg = "T" .. L.track .. " LANE " .. L.lane .. " = " .. MU.note_num_to_name(msg.note, true)
  L.done_until = util.time() + 1.5
  if L.last and L.lane < L.last then
    L.arm(L.track, L.lane + 1, L.last)
  else
    L.cancel()
  end
  return true
end

return L
