-- Unit Tests for Controller State Machine, Slot Interval Stats, Jitter Guard,
-- Pattern Triggers, 0.15s Retry Interval, ACK Mismatch Event Suppression & Fast Exit

local Controller = require("state.controller")
local fixtures = require("fixtures")
local command = require("protocol.command")
local config = require("config")

local function run_tests()
  local passed = 0
  local total = 0

  local function assert_eq(actual, expected, msg)
    total = total + 1
    if actual == expected then
      passed = passed + 1
    else
      error(string.format("FAILED: %s (expected %s, got %s)", msg or "", tostring(expected), tostring(actual)))
    end
  end

  print("=== Running State Machine & Controller Tests ===")

  local sim_time = 100.0
  local function get_time() return sim_time end

  -- Test 1: Command queuing and safety interlock before sync
  local ctrl = Controller.new()
  ctrl:queue_command(5, 1, sim_time) -- Turn Light 5 ON

  local transmitted = {}
  local function mock_tx(bytes) table.insert(transmitted, bytes) end

  local state_events = {}
  local function mock_event(ch, st, is_ack) table.insert(state_events, { channel = ch, state = st, is_ack = is_ack }) end

  local failed_events = {}
  local function mock_failed(ch, last_st) table.insert(failed_events, { channel = ch, last_state = last_st }) end

  -- SAFETY INTERLOCK: 79 frame received BUT is_synced = false -> must NOT transmit
  ctrl:handle_frame(fixtures.IDLE_79_FRAME, false, mock_tx, mock_event, mock_failed, get_time)
  assert_eq(#transmitted, 0, "No transmission before parser synchronization")

  -- Now is_synced = true: receive non-79 frame -> should NOT transmit
  local query_2 = fixtures.FIELD_TRACE[1]
  ctrl:handle_frame(query_2, true, mock_tx, mock_event, mock_failed, get_time)
  assert_eq(#transmitted, 0, "No transmission outside slot trigger")

  -- Receive 79 frame with is_synced = true -> should transmit 31 05 01... immediately
  ctrl:handle_frame(fixtures.IDLE_79_FRAME, true, mock_tx, mock_event, mock_failed, get_time, nil, {
    chunk_time = sim_time,
    is_latest = true,
    has_next_header_pending = false,
  })
  assert_eq(#transmitted, 1, "Transmitted 1 frame in 79 slot")
  assert_eq(command.to_hex_string(transmitted[1]), "31 05 01 00 00 00 00 37", "Transmitted command frame format")

  -- Test 2: Stale Trigger Prevention
  -- (a) Not latest frame in chunk
  ctrl:queue_command(5, 1, sim_time)
  ctrl:handle_frame(fixtures.IDLE_79_FRAME, true, mock_tx, mock_event, mock_failed, get_time, nil, {
    chunk_time = sim_time,
    is_latest = false, -- not latest!
    has_next_header_pending = false,
  })
  assert_eq(#transmitted, 1, "Should NOT transmit if not the latest frame in chunk")

  -- (b) Chunk is stale (trigger age > MAX_TRIGGER_AGE_SEC)
  ctrl:handle_frame(fixtures.IDLE_79_FRAME, true, mock_tx, mock_event, mock_failed, get_time, nil, {
    chunk_time = sim_time - 0.06, -- 60ms old (> 40ms)
    is_latest = true,
    has_next_header_pending = false,
  })
  assert_eq(#transmitted, 1, "Should NOT transmit if trigger age exceeds 40ms threshold")

  -- (c) Remaining buffer has next frame starting
  ctrl:handle_frame(fixtures.IDLE_79_FRAME, true, mock_tx, mock_event, mock_failed, get_time, nil, {
    chunk_time = sim_time,
    is_latest = true,
    has_next_header_pending = true, -- next frame already arriving!
  })
  assert_eq(#transmitted, 1, "Should NOT transmit if subsequent frame already starting in buffer")

  -- Test 3: Retry interval (0.15s): retries every 2nd slot (~200ms)
  local ctrl_retry = Controller.new()
  sim_time = 200.0
  ctrl_retry:queue_command(3, 1, sim_time) -- Turn Light 3 ON

  local retry_tx = {}
  local function mock_retry_tx(b) table.insert(retry_tx, b) end

  -- 1st attempt at t=200.0
  ctrl_retry:handle_frame(fixtures.IDLE_79_FRAME, true, mock_retry_tx, mock_event, mock_failed, get_time, nil, {
    chunk_time = sim_time, is_latest = true, has_next_header_pending = false,
  })
  assert_eq(#retry_tx, 1, "Attempt 1 sent at t=200.0")

  -- 100ms later (t=200.10): inside retry_interval (0.15s) -> suppressed
  sim_time = 200.10
  ctrl_retry:handle_frame(fixtures.IDLE_79_FRAME, true, mock_retry_tx, mock_event, mock_failed, get_time, nil, {
    chunk_time = sim_time, is_latest = true, has_next_header_pending = false,
  })
  assert_eq(#retry_tx, 1, "Suppressed within 0.15s interval at t=200.10")

  -- 200ms after attempt 1 (t=200.20): 0.15s interval elapsed -> attempt 2 sent!
  sim_time = 200.20
  ctrl_retry:handle_frame(fixtures.IDLE_79_FRAME, true, mock_retry_tx, mock_event, mock_failed, get_time, nil, {
    chunk_time = sim_time, is_latest = true, has_next_header_pending = false,
  })
  assert_eq(#retry_tx, 2, "Attempt 2 sent at t=200.20")

  -- Complete attempts 3, 4, 5
  sim_time = 200.40
  ctrl_retry:handle_frame(fixtures.IDLE_79_FRAME, true, mock_retry_tx, mock_event, mock_failed, get_time, nil, { chunk_time = sim_time, is_latest = true, has_next_header_pending = false })
  sim_time = 200.60
  ctrl_retry:handle_frame(fixtures.IDLE_79_FRAME, true, mock_retry_tx, mock_event, mock_failed, get_time, nil, { chunk_time = sim_time, is_latest = true, has_next_header_pending = false })
  sim_time = 200.80
  ctrl_retry:handle_frame(fixtures.IDLE_79_FRAME, true, mock_retry_tx, mock_event, mock_failed, get_time, nil, { chunk_time = sim_time, is_latest = true, has_next_header_pending = false })
  assert_eq(#retry_tx, 5, "5 attempts sent in ~0.8s")

  -- 6th attempt (t=201.00): max retries (5) exceeded -> abort and trigger rollback
  sim_time = 201.00
  ctrl_retry:handle_frame(fixtures.IDLE_79_FRAME, true, mock_retry_tx, mock_event, mock_failed, get_time, nil, { chunk_time = sim_time, is_latest = true, has_next_header_pending = false })
  assert_eq(#retry_tx, 5, "No further transmission after 5 failed attempts")
  assert_eq(ctrl_retry:get_pending(3), nil, "Pending command cleared after abort")
  assert_eq(#failed_events, 1, "Rollback event triggered")
  assert_eq(failed_events[1].channel, 3, "Rollback channel 3")
  assert_eq(failed_events[1].last_state, 0, "Reverted to last known state 0")

  -- Test 4: Slot Interval Statistics (normal 0.1s, delayed 0.18s, merged 0.005s)
  do
    local ctrl_stats = Controller.new()
    local t = 500.0
    local f79 = fixtures.IDLE_79_FRAME

    -- First 79: baseline
    ctrl_stats:handle_frame(f79, true, mock_tx, mock_event, mock_failed, function() return t end)

    -- Consecutive 79 at +0.100s
    t = t + 0.100
    ctrl_stats:handle_frame(f79, true, mock_tx, mock_event, mock_failed, function() return t end)

    -- Consecutive 79 at +0.100s
    t = t + 0.100
    ctrl_stats:handle_frame(f79, true, mock_tx, mock_event, mock_failed, function() return t end)

    -- Consecutive 79 at +0.180s (delayed)
    t = t + 0.180
    ctrl_stats:handle_frame(f79, true, mock_tx, mock_event, mock_failed, function() return t end)

    -- Consecutive 79 at +0.005s (merged frame < 20ms)
    t = t + 0.005
    ctrl_stats:handle_frame(f79, true, mock_tx, mock_event, mock_failed, function() return t end)

    local st = ctrl_stats:get_slot_interval_stats()
    assert_eq(st.count, 3, "3 non-merged interval samples recorded (0.1, 0.1, 0.18)")
    assert_eq(st.merged_count, 1, "1 merged sample (<20ms) recorded")
    local expected_avg = (0.100 + 0.100 + 0.180) / 3
    assert_eq(math.abs(st.avg - expected_avg) < 0.001, true, "Average interval calculation correct")
    assert_eq(math.abs(st.max - 0.180) < 0.001, true, "Max interval is 0.180s")
    assert_eq(math.abs(st.p95 - 0.180) < 0.001, true, "p95 interval is 0.180s")
  end

  -- Test 5: Jitter Guard (Option)
  do
    -- Jitter Guard ENABLED
    local ctrl_jg = Controller.new({ enable_jitter_guard = true })
    local t = 600.0
    local f79 = fixtures.IDLE_79_FRAME
    local jg_tx = {}

    ctrl_jg:queue_command(1, 1, t)

    -- First 79 (prior frame was nil, not 79): guard must NOT apply to first 79!
    ctrl_jg:handle_frame(f79, true, function(b) table.insert(jg_tx, b) end, mock_event, mock_failed, function() return t end, nil, {
      chunk_time = t, is_latest = true, has_next_header_pending = false,
    })
    assert_eq(#jg_tx, 1, "First 79 in burst is transmitted (guard does not skip first 79)")

    -- Next consecutive 79 arrived at +0.150s (> 0.100 + 0.040 = 0.140s)
    t = t + 0.200 -- advance time past retry_interval too
    ctrl_jg:queue_command(2, 1, t)
    -- Fake previous 79 timestamp to be 0.150s before t
    ctrl_jg.last_79_time = t - 0.150
    ctrl_jg.last_frame_header = config.HEADERS.IDLE_QUERY

    ctrl_jg:handle_frame(f79, true, function(b) table.insert(jg_tx, b) end, mock_event, mock_failed, function() return t end, nil, {
      chunk_time = t, is_latest = true, has_next_header_pending = false,
    })
    assert_eq(#jg_tx, 1, "Consecutive 79 with 0.150s interval skipped due to jitter guard")
    assert_eq(ctrl_jg.jitter_skips, 1, "jitter_skips counter incremented")

    -- Next consecutive 79 arrived at normal +0.100s -> transmission allowed!
    t = t + 0.200
    ctrl_jg.last_79_time = t - 0.100
    ctrl_jg.last_frame_header = config.HEADERS.IDLE_QUERY

    ctrl_jg:handle_frame(f79, true, function(b) table.insert(jg_tx, b) end, mock_event, mock_failed, function() return t end, nil, {
      chunk_time = t, is_latest = true, has_next_header_pending = false,
    })
    assert_eq(#jg_tx, 2, "Normal interval (0.100s) allowed through jitter guard")

    -- Jitter Guard DISABLED (default): interval > 0.140s does NOT skip
    local ctrl_no_jg = Controller.new({ enable_jitter_guard = false })
    local no_jg_tx = {}
    t = 700.0
    ctrl_no_jg:queue_command(1, 1, t)
    ctrl_no_jg.last_79_time = t - 0.150
    ctrl_no_jg.last_frame_header = config.HEADERS.IDLE_QUERY

    ctrl_no_jg:handle_frame(f79, true, function(b) table.insert(no_jg_tx, b) end, mock_event, mock_failed, function() return t end, nil, {
      chunk_time = t, is_latest = true, has_next_header_pending = false,
    })
    assert_eq(#no_jg_tx, 1, "With jitter guard off, 0.150s interval is transmitted normally")
  end

  -- Test 6: Pattern-Based EXTRA_SLOT_TRIGGERS
  do
    -- Valid patterns: 0x7F and 0x30 with byte2 in 0x07..0x0A
    local error_logged = false
    local ctrl_pat = Controller.new({
      extra_slot_triggers = {
        { header = 0x7F },
        { header = 0x30, byte2_min = 0x07, byte2_max = 0x0A },
        { header = 0x30 }, -- INVALID: missing byte2 range -> MUST be rejected!
      },
      log_fn = function(lvl, msg)
        if lvl == "error" and msg:match("Invalid EXTRA_SLOT_TRIGGER") then
          error_logged = true
        end
      end
    })
    assert_eq(error_logged, true, "Invalid 0x30 pattern without byte2 range logged error and rejected")
    assert_eq(#ctrl_pat.extra_trigger_patterns, 2, "Only 2 valid patterns registered")

    local t = 800.0
    local pat_tx = {}

    -- 30 07 00... (byte2 = 0x07): SHOULD TRIGGER
    local f_30_07 = string.char(0x30, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x37)
    ctrl_pat:queue_command(1, 1, t)
    ctrl_pat:handle_frame(f_30_07, true, function(b) table.insert(pat_tx, b) end, mock_event, mock_failed, function() return t end, nil, {
      chunk_time = t, is_latest = true, has_next_header_pending = false,
    })
    assert_eq(#pat_tx, 1, "30 07 triggers transmission")

    -- 30 0A 00... (byte2 = 0x0A): SHOULD TRIGGER
    t = t + 0.20
    local f_30_0A = string.char(0x30, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3A)
    ctrl_pat:queue_command(2, 1, t)
    ctrl_pat:handle_frame(f_30_0A, true, function(b) table.insert(pat_tx, b) end, mock_event, mock_failed, function() return t end, nil, {
      chunk_time = t, is_latest = true, has_next_header_pending = false,
    })
    assert_eq(#pat_tx, 2, "30 0A triggers transmission")

    -- 30 05 00... (byte2 = 0x05, light channel with B0 response): MUST NOT TRIGGER!
    t = t + 0.20
    local f_30_05 = fixtures.FIELD_TRACE[5] -- 30 05 00 00 00 00 00 35
    ctrl_pat:queue_command(3, 1, t)
    ctrl_pat:handle_frame(f_30_05, true, function(b) table.insert(pat_tx, b) end, mock_event, mock_failed, function() return t end, nil, {
      chunk_time = t, is_latest = true, has_next_header_pending = false,
    })
    assert_eq(#pat_tx, 2, "30 05 (Light 5 query) is NOT a slot trigger")

    -- 7F (time sync): SHOULD TRIGGER
    t = t + 0.20
    local f_7F = string.char(0x7F, 0x11, 0x08, 0x00, 0x00, 0x00, 0x00, 0x98)
    ctrl_pat:handle_frame(f_7F, true, function(b) table.insert(pat_tx, b) end, mock_event, mock_failed, function() return t end, nil, {
      chunk_time = t, is_latest = true, has_next_header_pending = false,
    })
    assert_eq(#pat_tx, 3, "7F triggers transmission")
  end

  -- Test 7: ACK Target State Matching & Mismatch Event Suppression
  do
    local ctrl_ack = Controller.new()
    local t = 900.0
    ctrl_ack:queue_command(4, 1, t) -- Target state = 1 (ON)

    local ack_events = {}
    local function on_st(ch, st, is_ack) table.insert(ack_events, { ch = ch, st = st, is_ack = is_ack }) end

    -- Transmit attempt 1
    ctrl_ack:handle_frame(fixtures.IDLE_79_FRAME, true, mock_tx, on_st, mock_failed, function() return t end, nil, {
      chunk_time = t, is_latest = true, has_next_header_pending = false,
    })

    -- Receive mismatched ACK: B1 00 04 (State = 0 OFF, while target was 1 ON)
    local ack_mismatch = string.char(0xB1, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0xB5)
    ctrl_ack:handle_frame(ack_mismatch, true, mock_tx, on_st, mock_failed, function() return t end)
    assert_eq(ctrl_ack:get_pending(4) ~= nil, true, "Pending command must NOT be cleared on state mismatch")
    assert_eq(ctrl_ack:get_known_state(4), 0, "Known state updated to physical truth 0")
    assert_eq(#ack_events, 0, "UI event SUPPRESSED on ACK mismatch while pending command exists")

    -- Now receive matching ACK: B1 01 04 (State = 1 ON)
    local ack_match = string.char(0xB1, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00, 0xB6)
    ctrl_ack:handle_frame(ack_match, true, mock_tx, on_st, mock_failed, function() return t end)
    assert_eq(ctrl_ack:get_pending(4), nil, "Pending command cleared on matching target state")
    assert_eq(ctrl_ack:get_known_state(4), 1, "Known state updated to 1")
    assert_eq(#ack_events, 1, "UI event EMITTED when ACK matches target state")
    assert_eq(ack_events[1].st, 1, "Emitted event state is 1")

    -- Receive ACK for channel with NO pending command: should emit event normally
    local ack_no_pending = string.char(0xB1, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0xB3)
    ctrl_ack:handle_frame(ack_no_pending, true, mock_tx, on_st, mock_failed, function() return t end)
    assert_eq(#ack_events, 2, "ACK without pending command emits UI event normally")
  end

  -- Test 8: Fast Exit and Logging Overhead Reduction
  do
    local ctrl_fast = Controller.new()
    local log_calls = 0
    local function counting_log(lvl, msg) log_calls = log_calls + 1 end

    -- Slot trigger received with EMPTY pending queue
    ctrl_fast:handle_frame(fixtures.IDLE_79_FRAME, true, mock_tx, mock_event, mock_failed, get_time, counting_log, {
      chunk_time = sim_time, is_latest = true, has_next_header_pending = false,
    })

    assert_eq(log_calls, 0, "Fast exit: zero log calls when pending queue is empty")
    local t_stats = ctrl_fast:get_trigger_stats()
    assert_eq(t_stats["79"].candidates, 1, "Trigger candidate count still tracked on fast exit")
  end

  print(string.format("State Machine Tests Passed: %d / %d\n", passed, total))
  return passed, total
end

return { run = run_tests }
