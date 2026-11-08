-- SmartThings Edge Driver for Commax RS485 Wallpad Light via Elfin-EW11
-- Driver lifecycle, capability handlers, child device management, and bridge networking.

local capabilities = require("st.capabilities")
local Driver = require("st.driver")
local log = require("log")
local cosock = require("cosock")

local config = require("config")
local Parser = require("protocol.parser")
local Controller = require("state.controller")
local TcpClient = require("transport.tcp_client")
local command = require("protocol.command")

--- Robust helper: find parent device
local function find_parent_device(driver, device)
  if driver.bridge_device then
    return driver.bridge_device
  end
  if device and device.get_parent_device then
    local p = device:get_parent_device()
    if p then return p end
  end
  if device and device.parent_device_id then
    for _, dev in ipairs(driver:get_devices()) do
      if dev.id == device.parent_device_id then
        return dev
      end
    end
  end
  for _, dev in ipairs(driver:get_devices()) do
    if dev.parent_assigned_child_key == nil then
      return dev
    end
  end
  return nil
end

--- Robust helper: find child device by parent_assigned_child_key
local function find_child_device(driver, parent_device, child_key)
  if parent_device and parent_device.get_child_by_parent_assigned_key then
    local child = parent_device:get_child_by_parent_assigned_key(child_key)
    if child then return child end
  end
  for _, dev in ipairs(driver:get_devices()) do
    if dev.parent_assigned_child_key == child_key then
      return dev
    end
  end
  return nil
end

--- Extract light channel number from child device
local function get_channel_from_device(device)
  local key = device.parent_assigned_child_key
  if key then
    local ch = key:match("light_(%d+)")
    if ch then return tonumber(ch) end
  end
  if device.label then
    local ch = device.label:match("Light%s+(%d+)")
    if ch then return tonumber(ch) end
  end
  return nil
end

--- Create child devices for Light 1 through Light 6 if they don't already exist
local function create_child_devices(driver, parent_device)
  for ch = config.MIN_LIGHT_CHANNEL, config.MAX_LIGHT_CHANNEL do
    local child_key = string.format("light_%d", ch)
    local child = find_child_device(driver, parent_device, child_key)
    if not child then
      log.info(string.format("Creating child device for Light %d (key: %s)...", ch, child_key))
      local create_device_msg = {
        type = "EDGE_CHILD",
        label = string.format("Light %d", ch),
        profile = "commax-light-child",
        parent_device_id = parent_device.id,
        parent_assigned_child_key = child_key,
        vendor_provided_label = string.format("Light %d", ch),
      }
      local ok, err = driver:try_create_device(create_device_msg)
      if not ok then
        log.error(string.format("Failed to create child device for Light %d: %s", ch, tostring(err)))
      else
        log.info(string.format("Child device creation requested for Light %d", ch))
      end
    else
      log.debug(string.format("Child device for Light %d already exists.", ch))
    end
  end
end

--- Handler: Driver Discovery
local function discovery_handler(driver, opts, should_continue)
  log.info("Starting Commax EW11 Bridge discovery...")
  -- Check if parent bridge already exists
  local device_list = driver:get_devices()
  for _, dev in ipairs(device_list) do
    if dev.parent_assigned_child_key == nil then
      log.info("Commax EW11 Bridge already exists. Skipping duplicate bridge creation.")
      return
    end
  end

  -- Create Parent Bridge Device
  local metadata = {
    type = "LAN",
    device_network_id = "commax_ew11_bridge_01",
    label = "Commax EW11 Bridge",
    profile = "commax-ew11-bridge",
    manufacturer = "Commax",
    model = "EW11-RS485",
    vendor_provided_label = "Commax EW11 Bridge",
  }
  local ok, err = driver:try_create_device(metadata)
  if not ok then
    log.error("Failed to create bridge device: " .. tostring(err))
  else
    log.info("Bridge device creation requested successfully.")
  end
end

--- Handler: Device Added
local function device_added(driver, device)
  log.info(string.format("Device added: %s (ID: %s, Child Key: %s)",
    device.label, device.id, tostring(device.parent_assigned_child_key)))

  if device.parent_assigned_child_key == nil then
    -- Parent Bridge device added: cache and create child light devices
    driver.bridge_device = device
    create_child_devices(driver, device)
  else
    -- Child light device added: initialize default state to off
    device:emit_event(capabilities.switch.switch.off())
  end
end

--- Handler: Device Initialization
local function device_init(driver, device)
  log.info(string.format("Device init: %s (ID: %s)", device.label, device.id))

  if device.parent_assigned_child_key == nil then
    -- Parent Bridge Device
    driver.bridge_device = device

    if driver.tcp_client then
      log.info("TCP Client already running for Bridge device.")
      return
    end

    local ip = device.preferences and device.preferences.ew11Ip or config.DEFAULT_IP
    local port = device.preferences and device.preferences.ew11Port or config.DEFAULT_PORT

    -- Instantiate parser and controller for the bridge
    local parser = Parser.new()
    local controller = Controller.new()

    -- Helper to send raw frames over TCP
    local function tx_raw(bytes)
      if driver.tcp_client then
        driver.tcp_client:send(bytes)
      end
    end

    -- Callback when light state changes (confirmed ACK or physical B0)
    local function on_light_state_change(channel, state_val, is_ack)
      local child_key = string.format("light_%d", channel)
      local child = find_child_device(driver, driver.bridge_device or device, child_key)
      if child then
        local evt = (state_val == 1) and capabilities.switch.switch.on() or capabilities.switch.switch.off()
        log.info(string.format("Emitting SmartThings event: %s -> %s (Source: %s)",
          child.label, (state_val == 1) and "ON" or "OFF", is_ack and "ACK" or "Physical"))
        child:emit_event(evt)
      else
        log.warn(string.format("Child device for key %s not found to emit state event.", child_key))
      end
    end

    -- Callback when a command fails after all 5 retries (revert UI to physical state)
    local function on_command_failed(channel, last_known_state)
      local child_key = string.format("light_%d", channel)
      local child = find_child_device(driver, driver.bridge_device or device, child_key)
      if child then
        local evt = (last_known_state == 1) and capabilities.switch.switch.on() or capabilities.switch.switch.off()
        log.warn(string.format("Rolling back SmartThings UI for %s -> %s after max retries exceeded.",
          child.label, (last_known_state == 1) and "ON" or "OFF"))
        child:emit_event(evt)
      end
    end

    -- Setup TCP Client
    local tcp_client = TcpClient.new({
      ip = ip,
      port = port,
      on_data = function(chunk, chunk_time)
        chunk_time = chunk_time or cosock.socket.gettime()
        controller:record_chunk_size(#chunk)
        local valid_frames = parser:feed(chunk)
        local has_next_header = parser:has_next_header_pending()
        local total_frames = #valid_frames

        for i, frame in ipairs(valid_frames) do
          local is_latest = (i == total_frames)
          controller:handle_frame(
            frame,
            parser:has_synchronized(),
            tx_raw,
            on_light_state_change,
            on_command_failed,
            cosock.socket.gettime,
            function(lvl, msg)
              if lvl == "warn" then log.warn(msg)
              elseif lvl == "error" then log.error(msg)
              elseif lvl == "debug" then log.debug(msg)
              else log.info(msg) end
            end,
            {
              chunk_time = chunk_time,
              is_latest = is_latest,
              has_next_header_pending = has_next_header,
            }
          )
        end
      end,
      on_connect = function()
        log.info("Connected to EW11! Resetting parser stream buffer.")
        parser:reset()
        if device.online then device:online() end
      end,
      on_disconnect = function()
        log.warn("EW11 disconnected! Flushing parser stream buffer.")
        parser:reset()
        if device.offline then device:offline() end
      end,
      log = function(lvl, msg)
        if lvl == "warn" then log.warn(msg)
        elseif lvl == "error" then log.error(msg)
        else log.info(msg) end
      end
    })

    -- Store references on driver and device using set_field
    device:set_field("parser", parser, { persist = false })
    device:set_field("controller", controller, { persist = false })
    device:set_field("tcp_client", tcp_client, { persist = false })

    driver.parser = parser
    driver.controller = controller
    driver.tcp_client = tcp_client

    -- Start TCP client background loop
    tcp_client:start()

    -- Ensure child devices exist
    create_child_devices(driver, device)
  else
    -- Child device init: sync with last known state from parent controller if available
    local controller = driver.controller
    local ch = get_channel_from_device(device)
    if controller and ch then
      local st = controller:get_known_state(ch)
      local evt = (st == 1) and capabilities.switch.switch.on() or capabilities.switch.switch.off()
      device:emit_event(evt)
    else
      device:emit_event(capabilities.switch.switch.off())
    end
  end
end

--- Handler: Device Info Changed (Preferences updated)
local function device_info_changed(driver, device, event, args)
  log.info(string.format("Device info changed: %s", device.label))

  if device.parent_assigned_child_key == nil and driver.tcp_client then
    local new_ip = device.preferences and device.preferences.ew11Ip or config.DEFAULT_IP
    local new_port = device.preferences and device.preferences.ew11Port or config.DEFAULT_PORT
    driver.tcp_client:update_target(new_ip, new_port)
  end
end

--- Handler: Device Removed
local function device_removed(driver, device)
  log.info(string.format("Device removed: %s", device.label))
  if device.parent_assigned_child_key == nil and driver.tcp_client then
    driver.tcp_client:stop()
    driver.tcp_client = nil
    driver.controller = nil
    driver.parser = nil
    driver.bridge_device = nil
  end
end

--- Capability Handler: Switch On
local function handle_switch_on(driver, device, command_msg)
  local channel = get_channel_from_device(device)
  log.info(string.format("Received ST switch.on command for Light channel %s", tostring(channel)))
  if not channel then
    log.error("Could not determine light channel for device: " .. device.label)
    return
  end

  local controller = driver.controller
  if not controller then
    local parent = find_parent_device(driver, device)
    if parent then
      controller = parent:get_field("controller")
    end
  end

  if controller then
    local now = cosock.socket.gettime()
    controller:queue_command(channel, 1, now)
    -- P1: Optimistic UI update immediately on command reception for snappy app responsiveness
    device:emit_event(capabilities.switch.switch.on())
  else
    log.error("Bridge controller not accessible for device: " .. device.label)
  end
end

--- Capability Handler: Switch Off
local function handle_switch_off(driver, device, command_msg)
  local channel = get_channel_from_device(device)
  log.info(string.format("Received ST switch.off command for Light channel %s", tostring(channel)))
  if not channel then
    log.error("Could not determine light channel for device: " .. device.label)
    return
  end

  local controller = driver.controller
  if not controller then
    local parent = find_parent_device(driver, device)
    if parent then
      controller = parent:get_field("controller")
    end
  end

  if controller then
    local now = cosock.socket.gettime()
    controller:queue_command(channel, 0, now)
    -- P1: Optimistic UI update immediately on command reception for snappy app responsiveness
    device:emit_event(capabilities.switch.switch.off())
  else
    log.error("Bridge controller not accessible for device: " .. device.label)
  end
end

--- Capability Handler: Refresh
local function handle_refresh(driver, device, command_msg)
  log.info(string.format("Refresh requested for %s", device.label))
  local controller = driver.controller
  if not controller then
    local parent = find_parent_device(driver, device)
    if parent then
      controller = parent:get_field("controller")
    end
  end

  if not controller then return end

  -- If refresh is called on child switch device: emit current known state
  local channel = get_channel_from_device(device)
  if channel then
    local st = controller:get_known_state(channel)
    local evt = (st == 1) and capabilities.switch.switch.on() or capabilities.switch.switch.off()
    device:emit_event(evt)
    return
  end

  -- If refresh is called on parent bridge device: emit current known states to all child devices
  for ch = config.MIN_LIGHT_CHANNEL, config.MAX_LIGHT_CHANNEL do
    local child_key = string.format("light_%d", ch)
    local child = find_child_device(driver, device, child_key)
    if child then
      local st = controller:get_known_state(ch)
      local evt = (st == 1) and capabilities.switch.switch.on() or capabilities.switch.switch.off()
      child:emit_event(evt)
    end
  end
end

-- Initialize SmartThings Driver
local commax_driver = Driver("commax-ew11-light", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = device_info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handle_switch_off,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
})

-- Run driver
commax_driver:run()
