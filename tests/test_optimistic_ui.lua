-- Unit Tests for Optimistic UI, ACK Confirmation, and Rollback on Failure

local Controller = require("state.controller")
local fixtures = require("fixtures")

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

  print("=== Running Optimistic UI & Rollback Tests ===")

  -- Mock SmartThings child device
  local function create_mock_child_device(label)
    return {
      label = label,
      emitted_events = {},
      emit_event = function(self, evt)
        table.insert(self.emitted_events, evt)
      end
    }
  end

  local sim_time = 500.0
  local function get_time() return sim_time end

  -- Test 1: Optimistic UI emission on command and confirmation on ACK
  do
    local ctrl = Controller.new()
    local child5 = create_mock_child_device("Light 5")

    -- Initial state: known state is 0 (OFF)
    assert_eq(ctrl:get_known_state(5), 0, "Initial physical state is 0")

    -- Step 1: User sends ON command
    -- Optimistic UI: Immediately queues command and emits ON event
    ctrl:queue_command(5, 1, sim_time)
    child5:emit_event({ capability = "switch", value = "on" })

    assert_eq(#child5.emitted_events, 1, "Optimistic event emitted immediately")
    assert_eq(child5.emitted_events[1].value, "on", "Optimistic event value is 'on'")
    -- Physical state in controller must NOT change yet!
    assert_eq(ctrl:get_known_state(5), 0, "Controller known_state remains 0 until confirmed by bus")

    -- Step 2: 79 slot transmits command
    local transmitted = {}
    ctrl:handle_frame(fixtures.IDLE_79_FRAME, true, function(b) table.insert(transmitted, b) end, function() end, nil, get_time)
    assert_eq(#transmitted, 1, "Command transmitted in 79 slot")

    -- Step 3: Device responds with ACK B1 01 05
    local ack_b1 = string.char(0xB1, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0xB7)
    ctrl:handle_frame(ack_b1, true, function() end, function(ch, st, is_ack)
      child5:emit_event({ capability = "switch", value = (st == 1) and "on" or "off", is_ack = is_ack })
    end, nil, get_time)

    assert_eq(ctrl:get_known_state(5), 1, "Physical state confirmed as 1 (ON)")
    assert_eq(#child5.emitted_events, 2, "Confirmation event emitted upon ACK")
    assert_eq(child5.emitted_events[2].value, "on", "Confirmed state is 'on'")
    assert_eq(child5.emitted_events[2].is_ack, true, "Confirmed event marked as ACK source")
  end

  -- Test 2: Optimistic UI emission with 5 retries failing -> Rollback to physical state
  do
    local ctrl = Controller.new()
    local child2 = create_mock_child_device("Light 2")

    -- Set initial physical confirmed state to 0 (OFF)
    assert_eq(ctrl:get_known_state(2), 0, "Initial physical state is 0 (OFF)")

    -- User turns ON
    ctrl:queue_command(2, 1, sim_time)
    child2:emit_event({ capability = "switch", value = "on" })
    assert_eq(#child2.emitted_events, 1, "Optimistic ON emitted")

    local retry_tx = {}
    local function mock_tx(b) table.insert(retry_tx, b) end
    local function on_failed(ch, last_known)
      child2:emit_event({ capability = "switch", value = (last_known == 1) and "on" or "off", is_rollback = true })
    end

    -- 5 attempts without ACK
    for i = 1, 5 do
      ctrl:handle_frame(fixtures.IDLE_79_FRAME, true, mock_tx, function() end, on_failed, get_time, nil, {
        chunk_time = sim_time, is_latest = true, has_next_header_pending = false,
      })
      sim_time = sim_time + 0.25 -- advance past retry_interval (0.2s)
    end
    assert_eq(#retry_tx, 5, "5 attempts sent")

    -- 6th slot -> aborts and triggers rollback
    ctrl:handle_frame(fixtures.IDLE_79_FRAME, true, mock_tx, function() end, on_failed, get_time, nil, {
      chunk_time = sim_time, is_latest = true, has_next_header_pending = false,
    })
    assert_eq(#child2.emitted_events, 2, "Rollback event emitted after failure")
    assert_eq(child2.emitted_events[2].value, "off", "Rolled back to confirmed physical truth ('off')")
    assert_eq(child2.emitted_events[2].is_rollback, true, "Event is marked as rollback")
  end

  print(string.format("Optimistic UI Tests Passed: %d / %d\n", passed, total))
  return passed, total
end

return { run = run_tests }

