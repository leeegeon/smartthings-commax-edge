-- Unit Tests for Stream Parser (Fragmentation, Concatenation, Noise Recovery, 2KB Chunk & Overflow Handling)

local Parser = require("protocol.parser")
local fixtures = require("fixtures")
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

  print("=== Running Stream Parser Tests ===")

  -- Case 1: Standard Stream from Field Trace (12 valid frames fed sequentially)
  local parser1 = Parser.new()
  local parsed_count = 0
  for _, frame in ipairs(fixtures.FIELD_TRACE) do
    local extracted = parser1:feed(frame)
    parsed_count = parsed_count + #extracted
  end
  assert_eq(parsed_count, #fixtures.FIELD_TRACE, "Field trace frame count")
  assert_eq(parser1:has_synchronized(), true, "Parser synchronized after valid frames")
  assert_eq(parser1:get_stats().desync_byte_count, 0, "No desync bytes in clean stream")

  -- Case 2: Concatenated Packets in a single TCP chunk (2 frames: 82... and 02...)
  local parser2 = Parser.new()
  local extracted2 = parser2:feed(fixtures.CONCATENATED_PACKET)
  assert_eq(#extracted2, 2, "Concatenated packet extracted 2 frames")
  assert_eq(command.to_hex_string(extracted2[1]), "82 00 02 23 21 00 00 C8", "First concatenated frame match")
  assert_eq(command.to_hex_string(extracted2[2]), "02 03 00 00 00 00 00 05", "Second concatenated frame match")

  -- Case 3: Fragmented Packets (8-byte frame split across 3 chunks: 3 bytes, 3 bytes, 2 bytes)
  local parser3 = Parser.new()
  local target_frame = fixtures.FIELD_TRACE[1] -- 30 02 00 00 00 00 00 32
  local f1 = parser3:feed(target_frame:sub(1, 3))
  assert_eq(#f1, 0, "Chunk 1 (3 bytes) should yield 0 frames")
  local f2 = parser3:feed(target_frame:sub(4, 6))
  assert_eq(#f2, 0, "Chunk 2 (3 bytes) should yield 0 frames")
  local f3 = parser3:feed(target_frame:sub(7, 8))
  assert_eq(#f3, 1, "Chunk 3 (2 bytes) should complete the 8-byte frame")
  assert_eq(f3[1], target_frame, "Extracted fragmented frame matches original")

  -- Case 4: Garbage Bytes & Desync Recovery (30 08... + FF + 30 02...)
  local parser4 = Parser.new()
  local extracted4 = parser4:feed(fixtures.GARBAGE_INJECTION)
  assert_eq(#extracted4, 2, "Should parse 2 valid frames around FF garbage")
  assert_eq(command.to_hex_string(extracted4[1]), "30 08 00 00 00 00 00 38", "Frame before garbage")
  assert_eq(command.to_hex_string(extracted4[2]), "30 02 00 00 00 00 00 32", "Frame after garbage")
  assert_eq(parser4:get_stats().desync_byte_count, 1, "Desync count should record 1 dropped garbage byte")

  -- Case 5: 2KB Chunk with 256 valid frames: Zero frame loss
  local parser5 = Parser.new()
  local valid_frame = fixtures.FIELD_TRACE[1] -- 8 bytes
  local chunk_2kb = string.rep(valid_frame, 256) -- exactly 2048 bytes (256 frames)
  local extracted5 = parser5:feed(chunk_2kb)
  assert_eq(#extracted5, 256, "Extracted all 256 frames from 2KB chunk without loss")
  assert_eq(parser5:has_synchronized(), true, "Parser synchronized")
  assert_eq(parser5:get_stats().buffer_overflow_count, 0, "No overflow on 2KB valid frame chunk")
  assert_eq(#parser5.buffer, 0, "Buffer empty after full extraction")

  -- Case 6: Overflow handling (>4096 bytes) preserves last 512 bytes and retains synchronized
  local parser6 = Parser.new({ max_buffer_size = 4096, overflow_keep_bytes = 512 })
  -- Sync parser first with 1 valid frame
  parser6:feed(valid_frame)
  assert_eq(parser6:has_synchronized(), true, "Parser initially synchronized")

  -- Feed 5000 bytes of non-whitelisted noise (0xEE)
  local noise_5k = string.rep(string.char(0xEE), 5000)
  local f6 = parser6:feed(noise_5k)
  assert_eq(#f6, 0, "Noise yielded 0 valid frames")
  assert_eq(parser6:get_stats().buffer_overflow_count, 1, "Buffer overflow count incremented")
  assert_eq(#parser6.buffer, 512, "Buffer truncated to exactly 512 tail bytes")
  assert_eq(parser6:has_synchronized(), true, "Synchronized state preserved despite overflow")

  -- Case 7: Has Next Header Pending in Buffer
  local parser7 = Parser.new()
  -- Feed full 8-byte frame + 2 bytes of next frame starting with 0x30
  local frame_plus_partial = fixtures.FIELD_TRACE[1] .. string.char(0x30, 0x05)
  local extracted7 = parser7:feed(frame_plus_partial)
  assert_eq(#extracted7, 1, "Extracted 1 complete frame")
  assert_eq(parser7:has_next_header_pending(), true, "Buffer has pending next header (0x30)")

  -- Complete the 2nd frame (remaining 6 bytes: 00 00 00 00 00 35)
  local rest_of_frame = string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x35)
  local extracted7_2 = parser7:feed(rest_of_frame)
  assert_eq(#extracted7_2, 1, "Extracted 2nd complete frame")
  assert_eq(parser7:has_next_header_pending(), false, "Buffer is now empty; has_next_header_pending is false")

  print(string.format("Stream Parser Tests Passed: %d / %d\n", passed, total))
  return passed, total
end

return { run = run_tests }
