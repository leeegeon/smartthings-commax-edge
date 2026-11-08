-- Configuration and constants for Commax RS485 Light Driver
local config = {
  DEFAULT_IP = "192.168.0.132",
  DEFAULT_PORT = 8899,

  -- Target lighting channels
  MIN_LIGHT_CHANNEL = 1,
  MAX_LIGHT_CHANNEL = 6,

  -- Protocol frame settings
  FRAME_LENGTH = 8,
  MAX_BUFFER_SIZE = 4096,          -- Upper safety boundary for raw stream buffer
  OVERFLOW_KEEP_BYTES = 512,       -- Keep tail bytes if buffer exceeds MAX_BUFFER_SIZE

  -- Known Frame Headers (Whitelist)
  HEADERS = {
    -- Lighting Frames
    STATUS_QUERY = 0x30, -- Wallpad -> Light query
    CONTROL_CMD  = 0x31, -- Wallpad/Driver -> Light control
    STATUS_RESP  = 0xB0, -- Light -> Wallpad status report
    CONTROL_ACK  = 0xB1, -- Light -> Wallpad/Driver control ACK

    -- Other Bus Devices (Whitelisted for safe parsing and dropping)
    OTHER_10     = 0x10,
    OTHER_90     = 0x90,
    OTHER_0F     = 0x0F,
    OTHER_8F     = 0x8F,
    OTHER_02     = 0x02,
    OTHER_82     = 0x82,
    OTHER_77     = 0x77,
    OTHER_F7     = 0xF7,
    OTHER_76     = 0x76,
    OTHER_F6     = 0xF6,
    IDLE_QUERY   = 0x79, -- Safe idle window trigger
    OTHER_20     = 0x20,
    OTHER_A0     = 0xA0,
    TIME_SYNC    = 0x7F, -- Time broadcast
  },

  -- Fast lookup set for header whitelist
  HEADER_SET = {
    [0x30] = true, [0x31] = true, [0xB0] = true, [0xB1] = true,
    [0x10] = true, [0x90] = true, [0x0F] = true, [0x8F] = true,
    [0x02] = true, [0x82] = true, [0x77] = true, [0xF7] = true,
    [0x76] = true, [0xF6] = true, [0x79] = true, [0x20] = true,
    [0xA0] = true, [0x7F] = true,
  },

  -- State machine & Retry limits
  MAX_RETRIES = 5,
  -- 0.15s interval: At 100ms slot spacing, retries occur every 2nd slot (~200ms apart).
  -- 5 attempts take ~0.8s, which can complete within the ~1.2s '79' burst only if the first attempt
  -- occurs early in the burst; otherwise, remaining retries wait safely for the next cycle's '79' burst.
  RETRY_INTERVAL_SEC = 0.15,
  MAX_TRIGGER_AGE_SEC = 0.04,      -- 40ms: driver processing latency guard (does not measure EW11/network delay)
  SLOW_LOG_THRESHOLD_SEC = 0.3,    -- 300ms threshold for logging slow frame dispatch
  DEBUG_FRAME_LOG = false,         -- If false, suppress string formatting and debug logs on normal frames
  RECONNECT_INTERVAL_SEC = 5,

  -- Jitter Guard & Timing Metrics
  ENABLE_JITTER_GUARD = false,     -- Optional jitter guard for consecutive 79 frames
  EXPECTED_79_INTERVAL_SEC = 0.100, -- Nominal ~100ms slot interval
  JITTER_TOLERANCE_SEC = 0.040,    -- 40ms tolerance; interval > 140ms skips slot transmission
  SLOT_STATS_LOG_INTERVAL_SEC = 60, -- Period for reporting rolling slot stats & chunk sizes

  -- Transport settings
  SOCKET_RECEIVE_TIMEOUT = 0.2,    -- 200ms: responsive timeout for receive(1) to check loop termination
  MAX_CONSECUTIVE_ERRORS = 10,     -- Reconnect if on_data throws > 10 consecutive exceptions

  -- Optional extra slot triggers (pattern-based)
  -- Each pattern entry:
  --   { header = 0x7F }
  --   { header = 0x30, byte2_min = 0x07, byte2_max = 0x0A }
  -- Note: header = 0x30 MUST have byte2 range strictly within 0x07..0x0A (0x01..0x06 have B0 responses).
  EXTRA_SLOT_TRIGGERS = {},
}

return config
