-- Main Test Runner for Offline Verification

-- Configure package.path to resolve src/ modules
package.path = package.path .. ";./src/?.lua;./src/?/init.lua;./tests/?.lua"

local test_checksum = require("test_checksum")
local test_parser = require("test_parser")
local test_tcp_client = require("test_tcp_client")
local test_state_machine = require("test_state_machine")
local test_optimistic_ui = require("test_optimistic_ui")

print("==================================================")
print("  COMMAX RS485 LIGHT DRIVER - OFFLINE TEST SUITE  ")
print("==================================================")

local p1, t1 = test_checksum.run()
local p2, t2 = test_parser.run()
local p3, t3 = test_tcp_client.run()
local p4, t4 = test_state_machine.run()
local p5, t5 = test_optimistic_ui.run()

local grand_passed = p1 + p2 + p3 + p4 + p5
local grand_total = t1 + t2 + t3 + t4 + t5

print("==================================================")
print(string.format("  OVERALL RESULTS: %d / %d TESTS PASSED", grand_passed, grand_total))
print("==================================================")

if grand_passed == grand_total then
  print("SUCCESS: All tests passed!")
  os.exit(0)
else
  print("FAILURE: Some tests failed!")
  os.exit(1)
end
