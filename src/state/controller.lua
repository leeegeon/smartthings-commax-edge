-- Commax RS485 State Machine and Slot-Synchronized Command Controller
-- Enforces bus safety: only transmits during verified safe idle slots,
-- handles per-channel command queue, stale trigger prevention, ACK matching,
-- retry logic (0.15s interval), latency metrics, rolling slot interval stats,
-- chunk size distributions, optional jitter guard, and state de-duplication.

local config = require("config")
local command = require("protocol.command")

local Controller = {}
Controller.__index = Controller

--- Create a new Controller instance
-- @param options table Optional configurations
-- @return table Controller instance
function Controller.new(options)
  options = options or {}
  local self = setmetatable({}, Controller)

  -- Known confirmed states: [channel] = 0 (OFF) or 1 (ON)
  self.known_states = {}

  -- Pending command queue: [channel] = { target_state = 0|1, retry_count = 0, sent_time = ts, queued_time = ts, first_sent_time = ts, trigger_name = str }
  self.pending_commands = {}

  -- Configurable options with fallback to config module
  self.enable_jitter_guard = (options.enable_jitter_guard ~= nil) and options.enable_jitter_guard or config.ENABLE_JITTER_GUARD
  self.expected_79_interval = options.expected_79_interval or config.EXPECTED_79_INTERVAL_SEC or 0.100
  self.jitter_tolerance = options.jitter_tolerance or config.JITTER_TOLERANCE_SEC or 0.040
  self.stats_log_interval = options.stats_log_interval or config.SLOT_STATS_LOG_INTERVAL_SEC or 60
  self.log_fn = options.log_fn or function(lvl, msg) end

  -- Parse and validate pattern-based EXTRA_SLOT_TRIGGERS
  self.extra_trigger_patterns = {}
  local raw_triggers = options.extra_slot_triggers or config.EXTRA_SLOT_TRIGGERS or {}

  -- Support both array of patterns and map format
  for k, v in pairs(raw_triggers) do
    local entry = nil
    if type(v) == "table" and v.header then
      entry = v
    elseif type(k) == "number" and type(v) == "boolean" and v == true then
      entry = { header = k }
    elseif type(v) == "number" then
      entry = { header = v }
    end

    if entry then
      local hdr = entry.header
      if hdr == config.HEADERS.STATUS_QUERY then -- 0x30
        -- 0x30 MUST specify byte2 range strictly within 0x07..0x0A
        local b2_min = entry.byte2_min
        local b2_max = entry.byte2_max
        if not (b2_min and b2_max and b2_min >= 0x07 and b2_max <= 0x0A and b2_min <= b2_max) then
          self.log_fn("error", string.format(
            "Invalid EXTRA_SLOT_TRIGGER pattern for 0x30: byte2 range must be strictly within 0x07..0x0A (got %s..%s). Ignoring entry.",
            tostring(b2_min), tostring(b2_max)))
        else
          local pat_name = string.format("30[%02X-%02X]", b2_min, b2_max)
          table.insert(self.extra_trigger_patterns, {
            header = 0x30,
            byte2_min = b2_min,
            byte2_max = b2_max,
            name = pat_name,
          })
        end
      else
        local pat_name = entry.name or string.format("%02X", hdr)
        table.insert(self.extra_trigger_patterns, {
          header = hdr,
          byte2_min = entry.byte2_min,
          byte2_max = entry.byte2_max,
          name = pat_name,
        })
      end
    end
  end

  -- Diagnostics & metrics
  self.commands_sent = 0
  self.acks_received = 0
  self.commands_failed = 0
  self.jitter_skips = 0
  self.merged_79_count = 0
  self.trigger_stats = {} -- [name] = { candidates = 0, sent = 0, ack = 0 }

  -- Timing & rolling interval statistics
  self.last_frame_header = nil
  self.last_79_time = nil
  self.slot_intervals = {} -- rolling window of up to 100 entries
  self.last_stats_log_time = nil

  -- Chunk size distribution bins
  self.chunk_bins = {
    b1 = 0,        -- 1 byte
    b2_7 = 0,      -- 2..7 bytes
    b8 = 0,        -- 8 bytes (nominal single frame)
    b9_16 = 0,     -- 9..16 bytes (nominal double frame)
    b17_plus = 0,  -- 17+ bytes
  }

  return self
end

--- Record size of an incoming TCP read chunk for drain diagnostics
-- @param size number Length in bytes of the chunk
function Controller:record_chunk_size(size)
  if type(size) ~= "number" or size <= 0 then return end
  if size == 1 then
    self.chunk_bins.b1 = self.chunk_bins.b1 + 1
  elseif size >= 2 and size <= 7 then
    self.chunk_bins.b2_7 = self.chunk_bins.b2_7 + 1
  elseif size == 8 then
    self.chunk_bins.b8 = self.chunk_bins.b8 + 1
  elseif size >= 9 and size <= 16 then
    self.chunk_bins.b9_16 = self.chunk_bins.b9_16 + 1
  else
    self.chunk_bins.b17_plus = self.chunk_bins.b17_plus + 1
  end
end

--- Queue a command for a light channel (replaces any previous pending command for this channel)
-- @param channel integer Light channel (1 to 6)
-- @param target_state integer|boolean|string Target state (1/0, true/false, "on"/"off")
-- @param queued_time number? Optional timestamp of when command was queued
function Controller:queue_command(channel, target_state, queued_time)
  channel = tonumber(channel)
  if not channel or channel < config.MIN_LIGHT_CHANNEL or channel > config.MAX_LIGHT_CHANNEL then
    return false, "Invalid channel"
  end

  local state_val = 0
  if target_state == 1 or target_state == true or target_state == "on" or target_state == "ON" then
    state_val = 1
  end

  -- Record or replace pending command (resets retry count to 0)
  self.pending_commands[channel] = {
    target_state = state_val,
    retry_count = 0,
    queued_time = queued_time or os.time(),
    first_sent_time = nil,
    sent_time = nil,
    trigger_name = nil,
  }

  return true
end

--- Clear pending command for a channel
-- @param channel integer
function Controller:clear_pending(channel)
  self.pending_commands[channel] = nil
end

--- Get pending command for a channel
-- @param channel integer
-- @return table|nil
function Controller:get_pending(channel)
  return self.pending_commands[channel]
end

--- Get last confirmed state for a channel
-- @param channel integer
-- @return integer 0 (OFF) or 1 (ON), defaults to 0 if not yet received
function Controller:get_known_state(channel)
  return self.known_states[channel] or 0
end

--- Get statistics for trigger headers
-- @return table
function Controller:get_trigger_stats()
  return self.trigger_stats
end

--- Get rolling slot interval statistics
-- @return table { count, avg, p50, p95, max, merged_count, jitter_skips }
function Controller:get_slot_interval_stats()
  local n = #self.slot_intervals
  if n == 0 then
    return {
      count = 0,
      avg = 0,
      p50 = 0,
      p95 = 0,
      max = 0,
      merged_count = self.merged_79_count,
      jitter_skips = self.jitter_skips,
    }
  end

  local sorted = {}
  local sum = 0
  for _, v in ipairs(self.slot_intervals) do
    table.insert(sorted, v)
    sum = sum + v
  end
  table.sort(sorted)

  local avg = sum / n
  local p50 = sorted[math.max(1, math.ceil(n * 0.50))]
  local p95 = sorted[math.max(1, math.ceil(n * 0.95))]
  local max = sorted[n]

  return {
    count = n,
    avg = avg,
    p50 = p50,
    p95 = p95,
    max = max,
    merged_count = self.merged_79_count,
    jitter_skips = self.jitter_skips,
  }
end

--- Internal helper: check if frame matches any slot trigger
-- @param frame string 8-byte frame
-- @return boolean is_trigger, string trigger_name
function Controller:_match_slot_trigger(frame)
  local header = frame:byte(1)
  if header == config.HEADERS.IDLE_QUERY then
    return true, "79"
  end

  for _, pat in ipairs(self.extra_trigger_patterns) do
    if pat.header == header then
      if pat.byte2_min and pat.byte2_max then
        local b2 = frame:byte(2)
        if b2 >= pat.byte2_min and b2 <= pat.byte2_max then
          return true, pat.name
        end
      else
        return true, pat.name
      end
    end
  end

  return false, nil
end

--- Handle an incoming valid 8-byte frame
-- @param frame string 8-byte frame
-- @param is_synced boolean Whether stream parser has achieved valid synchronization
-- @param tx_fn function Callback to transmit raw frame bytes: tx_fn(bytes)
-- @param on_state_change function Callback when state changes: on_state_change(channel, state_val, is_ack)
-- @param on_command_failed function Callback when retries exhausted: on_command_failed(channel, last_known_state)
-- @param get_time_fn function Optional function returning current timestamp in seconds
-- @param log_fn function Optional logging function
-- @param ctx table? Optional context: { chunk_time = number, is_latest = boolean, has_next_header_pending = boolean, chunk_size = number }
function Controller:handle_frame(frame, is_synced, tx_fn, on_state_change, on_command_failed, get_time_fn, log_fn, ctx)
  if not frame or #frame ~= config.FRAME_LENGTH then return end

  local header = frame:byte(1)
  get_time_fn = get_time_fn or os.time
  log_fn = log_fn or function() end
  local now = get_time_fn()

  -- Context normalization
  ctx = ctx or {}
  local chunk_time = ctx.chunk_time or now
  local is_latest = (ctx.is_latest ~= false) -- defaults to true if not explicitly false
  local has_next_header_pending = (ctx.has_next_header_pending == true)

  if ctx.chunk_size then
    self:record_chunk_size(ctx.chunk_size)
  end

  -- Track consecutive 0x79 arrival interval (ONLY when immediate prior frame was also 0x79)
  local interval_from_last_79 = nil
  local is_consecutive_79 = false

  if header == config.HEADERS.IDLE_QUERY then
    if self.last_frame_header == config.HEADERS.IDLE_QUERY and self.last_79_time then
      interval_from_last_79 = now - self.last_79_time
      is_consecutive_79 = true

      if interval_from_last_79 < 0.020 then
        -- Frames merged into single TCP chunk/read (<20ms). Exclude from rolling window stats.
        self.merged_79_count = self.merged_79_count + 1
      else
        table.insert(self.slot_intervals, interval_from_last_79)
        if #self.slot_intervals > 100 then
          table.remove(self.slot_intervals, 1)
        end
      end
    end
    self.last_79_time = now
  end

  -- Periodic logging: 60-second summary of slot timing and chunk size distribution
  if not self.last_stats_log_time then
    self.last_stats_log_time = now
  elseif (now - self.last_stats_log_time) >= self.stats_log_interval then
    local stats = self:get_slot_interval_stats()
    log_fn("info", string.format(
      "Slot interval stats (window 100): samples=%d, avg=%.3fs, p50=%.3fs, p95=%.3fs, max=%.3fs, merged(<20ms)=%d, jitter_skips=%d",
      stats.count, stats.avg, stats.p50, stats.p95, stats.max, stats.merged_count, stats.jitter_skips))
    log_fn("info", string.format(
      "Read chunk distribution: 1B=%d, 2-7B=%d, 8B=%d, 9-16B=%d, 17+B=%d",
      self.chunk_bins.b1, self.chunk_bins.b2_7, self.chunk_bins.b8, self.chunk_bins.b9_16, self.chunk_bins.b17_plus))
    self.last_stats_log_time = now
  end

  -- Latency instrumentation: read -> handle_frame dispatch latency
  -- Note on limitation: trigger_age (now - chunk_time) measures only internal driver processing delay.
  -- It cannot detect EW11 UART Gap Time or Wi-Fi transport latency. Actual bus timing is monitored
  -- via rolling slot intervals and round-trip ACK latencies above.
  local dispatch_delay = now - chunk_time
  local slow_threshold = config.SLOW_LOG_THRESHOLD_SEC or 0.3
  if dispatch_delay > slow_threshold then
    log_fn("info", string.format("Slow frame dispatch: read->handle_frame took %.3fs (header: %02X, threshold: %.3fs)",
      dispatch_delay, header, slow_threshold))
  elseif config.DEBUG_FRAME_LOG then
    log_fn("debug", string.format("Frame dispatch latency: %.3fs (header: %02X)", dispatch_delay, header))
  end

  -- Determine if this frame matches a safe slot trigger (0x79 or extra pattern)
  local is_slot_trigger, trigger_name = self:_match_slot_trigger(frame)

  -- CASE 1: Slot Trigger frame received -> Verified Safe Idle Window
  if is_slot_trigger then
    -- Track trigger candidate occurrences regardless of queue state
    if not self.trigger_stats[trigger_name] then
      self.trigger_stats[trigger_name] = { candidates = 0, sent = 0, ack = 0 }
    end
    self.trigger_stats[trigger_name].candidates = self.trigger_stats[trigger_name].candidates + 1

    -- FAST EXIT: If no pending commands are waiting, exit immediately without string formatting or checks
    if next(self.pending_commands) == nil then
      self.last_frame_header = header
      return
    end

    -- SAFETY INTERLOCK: Never transmit if parser has not yet achieved synchronization
    if not is_synced then
      log_fn("debug", "Slot trigger received but stream not yet synchronized. Skipping transmission.")
      self.last_frame_header = header
      return
    end

    -- OPTIONAL JITTER GUARD:
    -- When enabled, if consecutive 79 frame arrival interval exceeds threshold (0.100s + 0.040s = 0.140s),
    -- Wi-Fi or EW11 jitter has truncated the safe idle window. Skip transmission to prevent bus collision.
    -- Crucial: Does NOT apply to the first 79 query (e.g. 79 01 01) because there is no prior consecutive 79 reference.
    if self.enable_jitter_guard and is_consecutive_79 and interval_from_last_79 then
      local jitter_limit = self.expected_79_interval + self.jitter_tolerance
      if interval_from_last_79 > jitter_limit then
        self.jitter_skips = self.jitter_skips + 1
        log_fn("info", string.format("Jitter guard triggered on %s: interval %.3fs > threshold %.3fs. Skipping slot.",
          trigger_name, interval_from_last_79, jitter_limit))
        self.last_frame_header = header
        return
      end
    end

    -- STALE TRIGGER & COLLISION PREVENTION:
    -- (a) Frame must be the latest extracted frame in the chunk
    -- (b) Chunk arrival must be fresh (age <= MAX_TRIGGER_AGE_SEC)
    -- (c) Parser buffer must not have the beginning of another whitelisted frame
    local trigger_age = now - chunk_time
    local max_age = config.MAX_TRIGGER_AGE_SEC or 0.04

    if not is_latest then
      log_fn("debug", string.format("Slot trigger (%s) skipped: not the latest frame in chunk.", trigger_name))
      self.last_frame_header = header
      return
    end

    if trigger_age > max_age then
      log_fn("debug", string.format("Slot trigger (%s) skipped: stale trigger (age: %.3fs > max: %.3fs).",
        trigger_name, trigger_age, max_age))
      self.last_frame_header = header
      return
    end

    if has_next_header_pending then
      log_fn("debug", string.format("Slot trigger (%s) skipped: subsequent frame already arriving in parser buffer.", trigger_name))
      self.last_frame_header = header
      return
    end

    local retry_interval = config.RETRY_INTERVAL_SEC or 0.15

    -- Check if any channel (1..6) has a pending command
    for ch = config.MIN_LIGHT_CHANNEL, config.MAX_LIGHT_CHANNEL do
      local pending = self.pending_commands[ch]
      if pending then
        -- Check retry interval: don't re-transmit if previous send was within retry_interval
        if pending.sent_time and (now - pending.sent_time) < retry_interval then
          log_fn("debug", string.format("Waiting for ACK for Light %d (%.3fs elapsed, interval %.3fs).",
            ch, (now - pending.sent_time), retry_interval))
        else
          -- Check retry limit (max 5 attempts)
          if pending.retry_count >= config.MAX_RETRIES then
            log_fn("warn", string.format("Command for Light %d exceeded max retries (%d). Aborting and reverting UI.",
              ch, config.MAX_RETRIES))
            self.pending_commands[ch] = nil
            self.commands_failed = self.commands_failed + 1

            -- Rollback/refresh UI to match last known physical truth
            if on_command_failed then
              local fallback_state = self.known_states[ch] or 0
              on_command_failed(ch, fallback_state)
            end
          else
            -- First send latency metric
            if pending.retry_count == 0 then
              pending.first_sent_time = now
              local queue_to_send = now - (pending.queued_time or now)
              log_fn("info", string.format("Command queued -> first send: %.3fs (Light %d)", queue_to_send, ch))
            end

            -- Transmit 31 NN SS frame immediately in the idle slot
            local cmd_frame = command.build_control_frame(ch, pending.target_state)
            pending.retry_count = pending.retry_count + 1
            pending.sent_time = now
            pending.trigger_name = trigger_name
            self.commands_sent = self.commands_sent + 1

            -- Track trigger statistics
            self.trigger_stats[trigger_name].sent = self.trigger_stats[trigger_name].sent + 1

            log_fn("info", string.format("Transmitting in slot %s: Light %d -> %s (attempt %d/%d): %s",
              trigger_name, ch, pending.target_state == 1 and "ON" or "OFF", pending.retry_count, config.MAX_RETRIES,
              command.to_hex_string(cmd_frame)))

            tx_fn(cmd_frame)

            -- CRITICAL RULE: Rate limit to at most ONE control frame per slot
            break
          end
        end
      end
    end

  -- CASE 2: 0xB1 Control ACK Frame (B1 SS NN 00 00 00 00 CS)
  elseif header == config.HEADERS.CONTROL_ACK then
    local state_val = frame:byte(2)
    local ch = frame:byte(3)

    if ch >= config.MIN_LIGHT_CHANNEL and ch <= config.MAX_LIGHT_CHANNEL then
      local pending = self.pending_commands[ch]

      -- ACK matching: only clear pending if target_state matches received ACK state
      if pending and pending.target_state == state_val then
        local send_to_ack = now - (pending.sent_time or now)
        local queue_to_ack = now - (pending.queued_time or pending.sent_time or now)
        local total_elapsed = now - (pending.first_sent_time or pending.sent_time or now)

        -- Track trigger ACK success
        if pending.trigger_name and self.trigger_stats[pending.trigger_name] then
          self.trigger_stats[pending.trigger_name].ack = self.trigger_stats[pending.trigger_name].ack + 1
        end

        log_fn("info", string.format(
          "ACK (B1) confirmed for Light %d = %s (send->ACK: %.3fs, first_sent->ACK: %.3fs, queue->ACK: %.3fs, attempt: %d)",
          ch, state_val == 1 and "ON" or "OFF", send_to_ack, total_elapsed, queue_to_ack, pending.retry_count))

        self.pending_commands[ch] = nil
        self.acks_received = self.acks_received + 1
        self.known_states[ch] = state_val

        if on_state_change then
          on_state_change(ch, state_val, true)
        end
      elseif pending then
        -- Mismatched ACK: Physical relay state does not match desired target state.
        -- Update internal known_state, but SUPPRESS UI event emission while pending command exists.
        -- Retain pending command for subsequent retry slots.
        log_fn("warn", string.format("ACK state mismatch for Light %d: expected %d, got %d. Retaining pending command (UI event suppressed).",
          ch, pending.target_state, state_val))
        self.known_states[ch] = state_val
      else
        -- No pending command exists for this channel: emit confirmed state change
        self.known_states[ch] = state_val
        if on_state_change then
          on_state_change(ch, state_val, true)
        end
      end
    end

  -- CASE 3: 0xB0 Status Response Frame (B0 SS NN 00 00 00 00 CS)
  elseif header == config.HEADERS.STATUS_RESP then
    local state_val = frame:byte(2)
    local ch = frame:byte(3)

    if ch >= config.MIN_LIGHT_CHANNEL and ch <= config.MAX_LIGHT_CHANNEL then
      -- If physical state matches pending command, clear pending
      local pending = self.pending_commands[ch]
      if pending and pending.target_state == state_val then
        self.pending_commands[ch] = nil
      end

      -- State de-duplication: only emit event if state changed
      if self.known_states[ch] ~= state_val then
        log_fn("info", string.format("Status (B0) physical change for Light %d = %s", ch, state_val == 1 and "ON" or "OFF"))
        self.known_states[ch] = state_val
        if on_state_change then
          on_state_change(ch, state_val, false)
        end
      end
    end

  -- Other frames (whitelisted bus frames): safely ignored
  end

  self.last_frame_header = header
end

return Controller
