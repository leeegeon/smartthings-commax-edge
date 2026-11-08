-- Elfin-EW11 TCP Client for SmartThings Edge Driver
-- Manages persistent single-session TCP connection via cosock,
-- low-latency receive loop (receive(1) + select-based non-blocking drain),
-- exception resilience with xpcall, automatic reconnection, and buffer flush triggers.

local config = require("config")

local TcpClient = {}
TcpClient.__index = TcpClient

--- Create a new TCP Client
-- @param options table Configuration (ip, port, on_data, on_connect, on_disconnect, log, reconnect_delay)
-- @return table TcpClient instance
function TcpClient.new(options)
  options = options or {}
  local self = setmetatable({}, TcpClient)

  self.ip = options.ip or config.DEFAULT_IP
  self.port = tonumber(options.port) or config.DEFAULT_PORT
  self.on_data = options.on_data or function(chunk, chunk_time) end
  self.on_connect = options.on_connect or function() end
  self.on_disconnect = options.on_disconnect or function() end
  self.log = options.log or function(lvl, msg) end

  self.sock = nil
  self.is_running = false
  self.is_connected = false
  self.reconnect_delay = options.reconnect_delay or config.RECONNECT_INTERVAL_SEC
  self.consecutive_errors = 0

  return self
end

--- Update target IP and Port
-- @param ip string
-- @param port number
function TcpClient:update_target(ip, port)
  local changed = (self.ip ~= ip) or (self.port ~= port)
  self.ip = ip or self.ip
  self.port = tonumber(port) or self.port
  if changed and self.is_connected then
    self.log("info", string.format("TCP target updated to %s:%d. Reconnecting...", self.ip, self.port))
    self:disconnect()
  end
end

--- Start persistent TCP connection and receive loop
function TcpClient:start()
  if self.is_running then return end
  self.is_running = true

  local ok, cosock = pcall(require, "cosock")
  if not ok then
    self.log("error", "cosock module not found. Cannot start background receive loop.")
    return
  end

  cosock.spawn(function()
    while self.is_running do
      -- Exception guard: protect the supervisor loop from dying on unhandled runtime errors
      local loop_ok, loop_err = pcall(function()
        local connect_ok = self:_connect(cosock)
        if connect_ok then
          self:_receive_loop(cosock)
        end
      end)

      if not loop_ok then
        self.log("error", "Exception in TCP supervisor loop: " .. tostring(loop_err))
      end

      if self.is_running then
        self.log("warn", string.format("Disconnected from EW11 (%s:%d). Reconnecting in %d seconds...",
          self.ip, self.port, self.reconnect_delay))
        self:_cleanup()
        local socket = cosock.socket or require("socket")
        socket.sleep(self.reconnect_delay)
      end
    end
    self:_cleanup()
  end, "commax_ew11_tcp_loop")
end

--- Internal connection helper
function TcpClient:_connect(cosock)
  self:_cleanup()
  self.consecutive_errors = 0

  self.log("info", string.format("Connecting to EW11 at %s:%d...", self.ip, self.port))
  local sock, err = cosock.socket.tcp()
  if not sock then
    self.log("error", "Failed to create TCP socket: " .. tostring(err))
    return false
  end

  sock:settimeout(5.0) -- 5 second connection timeout
  local ok, conn_err = sock:connect(self.ip, self.port)
  if not ok and conn_err ~= "already connected" then
    self.log("error", string.format("Failed to connect to EW11 (%s:%d): %s", self.ip, self.port, tostring(conn_err)))
    pcall(function() sock:close() end)
    return false
  end

  -- Enable TCP_NODELAY to disable Nagle's algorithm for low-latency frame transmission
  pcall(function() sock:setoption("tcp-nodelay", true) end)

  -- Initial timeout configuration
  sock:settimeout(config.SOCKET_RECEIVE_TIMEOUT or 0.2)
  self.sock = sock
  self.is_connected = true
  self.log("info", string.format("Successfully connected to EW11 (%s:%d)", self.ip, self.port))

  if self.on_connect then
    self.on_connect()
  end
  return true
end

--- Internal low-latency receive loop
-- Drain approach:
-- To avoid ambiguity over whether cosock's settimeout(0) returns partial data across different platform builds,
-- we use cosock.socket.select({sock}, nil, 0) to check whether bytes are actively queued in the OS buffer.
-- When readable, we fetch them with receive(1) until select reports the buffer empty.
-- This guarantees immediate, non-blocking delivery of multi-byte bursts without blocking delays.
function TcpClient:_receive_loop(cosock)
  local gettime = (cosock.socket and cosock.socket.gettime) or os.time
  local receive_timeout = config.SOCKET_RECEIVE_TIMEOUT or 0.2
  local max_errors = config.MAX_CONSECUTIVE_ERRORS or 10

  while self.is_running and self.is_connected do
    -- Reset receive timeout at the start of each iteration
    self.sock:settimeout(receive_timeout)

    local first_byte, err, partial = self.sock:receive(1)
    local b1 = first_byte or partial

    if b1 and #b1 > 0 then
      local chunk_time = gettime()
      local parts = { b1 }

      -- Check and drain any remaining bytes already buffered
      if cosock.socket and cosock.socket.select then
        while true do
          local readable, _, s_err = cosock.socket.select({ self.sock }, nil, 0)
          if not (readable and #readable > 0) then
            break
          end
          self.sock:settimeout(0)
          local next_b, r_err, r_partial = self.sock:receive(1)
          local more = next_b or r_partial
          if more and #more > 0 then
            table.insert(parts, more)
          else
            break
          end
        end
      else
        -- Fallback non-blocking drain for environments without select
        self.sock:settimeout(0)
        while true do
          local rest, r_err, r_partial = self.sock:receive(64)
          local more = rest or r_partial
          if more and #more > 0 then
            table.insert(parts, more)
          end
          if r_err then
            break
          end
        end
      end

      local full_chunk = table.concat(parts)
      if #full_chunk > 0 then
        -- Exception protection: protect receive loop from on_data crashes
        local data_ok, data_err = xpcall(function()
          self.on_data(full_chunk, chunk_time)
        end, debug.traceback)

        if not data_ok then
          self.consecutive_errors = self.consecutive_errors + 1
          self.log("error", string.format("Error in on_data handler (count: %d/%d): %s",
            self.consecutive_errors, max_errors, tostring(data_err)))

          if self.consecutive_errors >= max_errors then
            self.log("error", string.format("Exceeded %d consecutive on_data errors. Disconnecting to reset stream parser...", max_errors))
            self.is_connected = false
            break
          end
        else
          self.consecutive_errors = 0
        end
      end
    end

    if err then
      if err == "timeout" then
        -- Normal timeout when bus is quiet within 0.2s: continue loop to check is_running
      elseif err == "closed" or err == "Socket is closed" then
        self.log("warn", "EW11 closed the TCP connection.")
        self.is_connected = false
        break
      else
        self.log("warn", "TCP receive error: " .. tostring(err))
        self.is_connected = false
        break
      end
    end
  end
end

--- Send raw bytes to EW11
-- @param bytes string Binary string to transmit
-- @return boolean success, string? error
function TcpClient:send(bytes)
  if not self.is_connected or not self.sock then
    return false, "Socket not connected"
  end

  self.sock:settimeout(1.0)
  local sent, err = self.sock:send(bytes)
  -- Restore socket receive timeout
  self.sock:settimeout(config.SOCKET_RECEIVE_TIMEOUT or 0.2)

  if not sent then
    self.log("error", "Failed to send data to EW11: " .. tostring(err))
    self.is_connected = false
    return false, err
  end

  return true
end

--- Clean up socket
function TcpClient:_cleanup()
  if self.is_connected then
    self.is_connected = false
    if self.on_disconnect then
      self.on_disconnect()
    end
  end

  if self.sock then
    pcall(function()
      self.sock:shutdown()
      self.sock:close()
    end)
    self.sock = nil
  end
end

--- Disconnect and stop background loop
function TcpClient:stop()
  self.is_running = false
  self:_cleanup()
end

--- Disconnect socket to trigger reconnect
function TcpClient:disconnect()
  self:_cleanup()
end

return TcpClient
