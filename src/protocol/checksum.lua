-- Commax RS485 Frame Checksum Calculator and Validator
-- Formula: Checksum = (sum(byte[0 .. 6])) & 0xFF (Bytes 1..7 in Lua 1-based indexing)
-- Byte 7 (Lua index 8) is the Checksum byte.

local checksum = {}

--- Calculate checksum for 7 bytes
-- @param data string|table Either a binary string (at least 7 bytes) or a table of numbers (indices 1..7)
-- @return integer Checksum byte (0x00 - 0xFF)
function checksum.calculate(data)
  local sum = 0
  if type(data) == "string" then
    local len = math.min(#data, 7)
    for i = 1, len do
      sum = sum + data:byte(i)
    end
  elseif type(data) == "table" then
    local len = math.min(#data, 7)
    for i = 1, len do
      sum = sum + (data[i] or 0)
    end
  else
    error("Invalid data type for checksum calculation: " .. type(data))
  end
  return sum & 0xFF
end

--- Verify if an 8-byte frame has a valid checksum
-- @param frame string|table 8-byte binary string or table of 8 numbers
-- @return boolean true if frame is valid 8 bytes and checksum matches, false otherwise
function checksum.verify(frame)
  if type(frame) == "string" then
    if #frame ~= 8 then
      return false
    end
    local expected = checksum.calculate(frame)
    local actual = frame:byte(8)
    return expected == actual
  elseif type(frame) == "table" then
    if #frame ~= 8 then
      return false
    end
    local expected = checksum.calculate(frame)
    local actual = frame[8]
    return expected == actual
  end
  return false
end

return checksum

