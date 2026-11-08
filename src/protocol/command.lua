-- Commax RS485 Command Frame Builder
-- The driver MUST ONLY EVER transmit 31 NN SS frames.

local checksum = require("protocol.checksum")
local config = require("config")

local command = {}

--- Convert binary string to uppercase hex string (e.g. "31 05 01 00 00 00 00 37")
-- @param str string Binary string
-- @return string Space-separated hex representation
function command.to_hex_string(str)
  if not str or #str == 0 then return "" end
  local hex_parts = {}
  for i = 1, #str do
    table.insert(hex_parts, string.format("%02X", str:byte(i)))
  end
  return table.concat(hex_parts, " ")
end

--- Convert hex string (e.g. "31 05 01 00 00 00 00 37" or "3105010000000037") to binary string
-- @param hex_str string Hex formatted string
-- @return string Binary string
function command.from_hex_string(hex_str)
  local clean = hex_str:gsub("%s+", "")
  return (clean:gsub("..", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end

--- Build an 8-byte control command frame: 31 NN SS 00 00 00 00 CS
-- @param channel integer Light channel number (1 to 6)
-- @param state integer|boolean|string State: 1/0, true/false, or "on"/"off"
-- @return string 8-byte binary frame
function command.build_control_frame(channel, state)
  channel = tonumber(channel)
  if not channel or channel < config.MIN_LIGHT_CHANNEL or channel > config.MAX_LIGHT_CHANNEL then
    error(string.format("Invalid light channel %s (allowed: %d..%d)", tostring(channel), config.MIN_LIGHT_CHANNEL, config.MAX_LIGHT_CHANNEL))
  end

  local state_byte = 0
  if state == 1 or state == true or state == "on" or state == "ON" then
    state_byte = 1
  elseif state == 0 or state == false or state == "off" or state == "OFF" then
    state_byte = 0
  else
    error("Invalid state value: " .. tostring(state))
  end

  local payload = {
    config.HEADERS.CONTROL_CMD, -- 0x31
    channel,                    -- NN
    state_byte,                 -- SS
    0x00,
    0x00,
    0x00,
    0x00
  }

  local cs = checksum.calculate(payload)
  payload[8] = cs

  return string.char(table.unpack(payload))
end

return command

