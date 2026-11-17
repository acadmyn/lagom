-- shared constants
local K = {}

K.PPQN = 48          -- internal ticks per quarter note
K.NUM_TRACKS = 8
K.MAX_STEPS = 32
K.MAX_RANGE = 48      -- semitones above base note (4 octaves)

-- clock divisions: label + ticks per step at 48 ppqn
K.DIV_NAMES = {"1/32", "1/16T", "1/16", "1/8T", "1/8", "1/4T", "1/4", "1/2", "1/1", "2bar"}
K.DIV_SHORT = {"/32", "/16T", "/16", "/8T", "/8", "/4T", "/4", "/2", "/1", "2B"}
K.DIV_TICKS = {6, 8, 12, 16, 24, 32, 48, 96, 192, 384}
K.DIV_DEFAULT = 3    -- 1/16

return K
