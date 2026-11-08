-- Commax RS485 Stream Parser with Sliding Window Frame Synchronization
-- Handles TCP fragmentation, concatenation, noise/garbage bytes, and desync recovery.
-- Priority: Extracts valid frames first without loss for up to 2KB+ chunks.
-- Abnormally large chunks (>4096B) retain the last 512 bytes without losing synchronization.

local checksum = require("protocol.checksum")
local config = require("config")

local Parser = {}
Parser.__index = Parser

--- Create a new Stream Parser instance
-- @param options table Optional configurations (max_buffer_size, overflow_keep_bytes, header_set)
-- @return table Parser instance
function Parser.new(options)
  options = options or {}
  local self = setmetatable({}, Parser)
  self.buffer = ""
  self.max_buffer_size = options.max_buffer_size or config.MAX_BUFFER_SIZE or 4096
  self.overflow_keep_bytes = options.overflow_keep_bytes or config.OVERFLOW_KEEP_BYTES or 512
  self.header_set = options.header_set or config.HEADER_SET

  -- Sync and diagnostic metrics
  self.synchronized = false
  self.valid_frame_count = 0
  self.desync_byte_count = 0
  self.buffer_overflow_count = 0

  return self
end

--- Clear buffer and reset sync state (e.g., on socket disconnect or reconnect)
function Parser:reset()
  self.buffer = ""
  self.synchronized = false
end

--- Check if the parser has achieved synchronization since last reset
-- @return boolean
function Parser:has_synchronized()
  return self.synchronized
end

--- Check if the remaining buffer after feed has bytes beginning with a whitelisted header
-- Indicates that a subsequent frame has already started arriving on the bus
-- @return boolean
function Parser:has_next_header_pending()
  if #self.buffer > 0 then
    local b1 = self.buffer:byte(1)
    if self.header_set[b1] then
      return true
    end
  end
  return false
end

--- Get current internal buffer content (for inspection/testing)
-- @return string
function Parser:get_buffer()
  return self.buffer
end

--- Get parsing statistics
-- @return table
function Parser:get_stats()
  return {
    synchronized = self.synchronized,
    valid_frame_count = self.valid_frame_count,
    desync_byte_count = self.desync_byte_count,
    buffer_overflow_count = self.buffer_overflow_count,
    buffer_length = #self.buffer,
  }
end

--- Feed incoming TCP data stream and extract all valid 8-byte frames
-- @param chunk string Raw binary data from socket
-- @return table Array of valid 8-byte frame strings
function Parser:feed(chunk)
  if not chunk or #chunk == 0 then
    return {}
  end

  -- Abnormally large chunk safety guard (>4096 bytes):
  -- Truncate to the last `overflow_keep_bytes` (512 bytes) and increment overflow counter.
  -- Crucially: do NOT reset self.synchronized!
  if #chunk > self.max_buffer_size then
    self.buffer_overflow_count = self.buffer_overflow_count + 1
    self.buffer = chunk:sub(-self.overflow_keep_bytes)
    return {}
  end

  self.buffer = self.buffer .. chunk

  local valid_frames = {}

  -- Frame extraction loop using sliding window: SALVAGE ALL VALID FRAMES FIRST
  while #self.buffer >= config.FRAME_LENGTH do
    local header_byte = self.buffer:byte(1)

    -- Check if byte 1 is in known header whitelist
    if not self.header_set[header_byte] then
      -- Drop 1 byte and advance sliding window
      self.buffer = self.buffer:sub(2)
      self.desync_byte_count = self.desync_byte_count + 1
    else
      -- Potential header found: inspect 8-byte candidate frame
      local candidate = self.buffer:sub(1, config.FRAME_LENGTH)

      if checksum.verify(candidate) then
        -- Valid frame verified!
        self.synchronized = true
        self.valid_frame_count = self.valid_frame_count + 1
        table.insert(valid_frames, candidate)

        -- Advance buffer past the full 8-byte frame
        self.buffer = self.buffer:sub(config.FRAME_LENGTH + 1)
      else
        -- Checksum mismatch: false header match or corrupted packet
        -- Drop 1 byte and continue sliding window
        self.buffer = self.buffer:sub(2)
        self.desync_byte_count = self.desync_byte_count + 1
      end
    end
  end

  -- Safety check for accumulated leftover buffer
  if #self.buffer > self.max_buffer_size then
    self.buffer_overflow_count = self.buffer_overflow_count + 1
    self.buffer = self.buffer:sub(-self.overflow_keep_bytes)
  end

  return valid_frames
end

return Parser
