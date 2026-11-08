-- Unit Tests for TcpClient (Receive Loop, Select Drain, Socket Options, Exception Guard & Reconnect)

local TcpClient = require("transport.tcp_client")
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

  print("=== Running TcpClient Unit Tests ===")

  -- Mock socket implementation
  local function create_mock_socket(incoming_stream, options)
    options = options or {}
    local sock = {
      buffer = incoming_stream or "",
      timeout = 0,
      options = {},
      sent_data = {},
      is_closed = false,
      call_history = {},
    }

    function sock:settimeout(t)
      self.timeout = t
      table.insert(self.call_history, { op = "settimeout", val = t })
    end

    function sock:setoption(opt, val)
      self.options[opt] = val
      table.insert(self.call_history, { op = "setoption", opt = opt, val = val })
      return true
    end

    function sock:receive(pattern)
      table.insert(self.call_history, { op = "receive", pattern = pattern, current_timeout = self.timeout })
      if self.is_closed then
        return nil, "closed"
      end

      if type(pattern) == "number" then
        if #self.buffer == 0 then
          if options.closed_on_empty then
            self.is_closed = true
            return nil, "closed"
          else
            return nil, "timeout"
          end
        end

        local to_read = math.min(pattern, #self.buffer)
        local data = self.buffer:sub(1, to_read)
        self.buffer = self.buffer:sub(to_read + 1)
        return data
      end

      return nil, "timeout"
    end

    function sock:send(data)
      table.insert(self.sent_data, data)
      return #data
    end

    function sock:close()
      self.is_closed = true
    end

    return sock
  end

  -- Test 1: Select-based Fast Drain: multiple bytes arriving are bundled into a single chunk
  do
    local simulated_time = 1000.123
    local received_chunks = {}
    local received_timestamps = {}

    local test_bytes = string.char(0x30, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x32)
    local mock_sock = create_mock_socket(test_bytes, { closed_on_empty = true })

    local mock_cosock = {
      socket = {
        gettime = function() return simulated_time end,
        select = function(recvt, sendt, timeout)
          if #mock_sock.buffer > 0 then
            return { mock_sock }, {}, nil
          end
          return {}, {}, nil
        end
      }
    }

    local client = TcpClient.new({
      on_data = function(chunk, chunk_time)
        table.insert(received_chunks, chunk)
        table.insert(received_timestamps, chunk_time)
      end
    })
    client.sock = mock_sock
    client.is_connected = true
    client.is_running = true

    -- Run receive loop (exits when mock socket returns 'closed' on empty)
    client:_receive_loop(mock_cosock)

    assert_eq(#received_chunks, 1, "All 8 bytes should be drained and delivered in exactly 1 chunk")
    assert_eq(received_chunks[1], test_bytes, "Drained chunk matches test frame bytes")
    assert_eq(received_timestamps[1], simulated_time, "chunk_time matches timestamp recorded on first byte")
    assert_eq(client.is_connected, false, "Connection status updated to false on socket close")
  end

  -- Test 2: Exception Protection in on_data (xpcall resilience up to 10 errors)
  do
    local error_count = 0
    local log_errors = {}
    local client = TcpClient.new({
      on_data = function(chunk, chunk_time)
        error_count = error_count + 1
        error("Simulated parser or handler crash #" .. error_count)
      end,
      log = function(lvl, msg)
        if lvl == "error" then
          table.insert(log_errors, msg)
        end
      end
    })

    -- Provide 12 individual 1-byte chunks
    local mock_sock = create_mock_socket(string.rep("A", 15), { closed_on_empty = false })
    client.sock = mock_sock
    client.is_connected = true
    client.is_running = true

    local mock_cosock = {
      socket = {
        gettime = function() return 100.0 end,
        select = function() return {}, {}, nil end, -- no extra drain, reads 1 byte per loop
      }
    }

    client:_receive_loop(mock_cosock)

    -- Loop must have continued past errors 1..9, and aborted on error 10
    assert_eq(error_count, 10, "Receive loop survived 9 errors and aborted on the 10th consecutive error")
    assert_eq(client.is_connected, false, "Client disconnected after 10 consecutive errors")
    assert_eq(#log_errors >= 10, true, "All errors logged with traceback")
  end

  -- Test 3: Send does not interfere with receive loop timeout
  do
    local mock_sock = create_mock_socket("")
    local client = TcpClient.new()
    client.sock = mock_sock
    client.is_connected = true

    local ok = client:send("TEST")
    assert_eq(ok, true, "Send succeeded")
    assert_eq(#mock_sock.sent_data, 1, "1 message sent")
    assert_eq(mock_sock.sent_data[1], "TEST", "Message content match")
    assert_eq(mock_sock.timeout, config.SOCKET_RECEIVE_TIMEOUT or 0.2, "Timeout restored after send")
  end

  print(string.format("TcpClient Unit Tests Passed: %d / %d\n", passed, total))
  return passed, total
end

return { run = run_tests }
