-- Unit Tests for Checksum and Command Builder

local checksum = require("protocol.checksum")
local command = require("protocol.command")

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

  print("=== Running Checksum & Command Builder Tests ===")

  -- Test 1: Checksum verification for 31 05 01 (Turn Light 5 ON) -> 0x37
  local cmd_5_on = command.build_control_frame(5, 1)
  assert_eq(cmd_5_on:byte(1), 0x31, "Header byte should be 0x31")
  assert_eq(cmd_5_on:byte(2), 0x05, "Channel byte should be 0x05")
  assert_eq(cmd_5_on:byte(3), 0x01, "State byte should be 0x01")
  assert_eq(cmd_5_on:byte(8), 0x37, "Checksum byte should be 0x37")
  assert_eq(checksum.verify(cmd_5_on), true, "Frame verify should be true")

  -- Test 2: Checksum verification for 31 05 00 (Turn Light 5 OFF) -> 0x36
  local cmd_5_off = command.build_control_frame(5, 0)
  assert_eq(cmd_5_off:byte(8), 0x36, "Checksum byte should be 0x36")
  assert_eq(checksum.verify(cmd_5_off), true, "Frame verify should be true")

  -- Test 3: Checksum calculation for channels 1..6
  for ch = 1, 6 do
    local on_frame = command.build_control_frame(ch, "on")
    local off_frame = command.build_control_frame(ch, "off")
    assert_eq(checksum.verify(on_frame), true, string.format("Light %d ON valid", ch))
    assert_eq(checksum.verify(off_frame), true, string.format("Light %d OFF valid", ch))
  end

  -- Test 4: Invalid frame length or corrupted checksum
  assert_eq(checksum.verify("1234567"), false, "7-byte frame must fail verification")
  assert_eq(checksum.verify("123456789"), false, "9-byte frame must fail verification")
  local corrupted = cmd_5_on:sub(1, 7) .. string.char(0x00)
  assert_eq(checksum.verify(corrupted), false, "Corrupted checksum must fail verification")

  -- Test 5: Hex string conversion helpers
  local hex_str = command.to_hex_string(cmd_5_on)
  assert_eq(hex_str, "31 05 01 00 00 00 00 37", "Hex string representation")
  local back_to_bin = command.from_hex_string(hex_str)
  assert_eq(back_to_bin, cmd_5_on, "From hex string conversion")

  print(string.format("Checksum Tests Passed: %d / %d\n", passed, total))
  return passed, total
end

return { run = run_tests }

