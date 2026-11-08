
IP: 192.168.0.132
PORT: 8899

# AGENTS.md — SmartThings Commax Wallpad Light Edge Driver (via Elfin-EW11)

## 1. Project Overview

Develop a custom Samsung SmartThings Edge Driver for controlling household lights (Channels 1–6) connected to a Commax RS485 wallpad bus, interfaced over Wi-Fi via an Elfin-EW11 serial-to-Ethernet/Wi-Fi adapter.

### Primary Objective

Create a robust, responsive, and bidirectional SmartThings lighting integration. The driver must accurately reflect physical wallpad/wall-switch state changes and allow SmartThings to reliably actuate lights by safely injecting commands into verified idle bus slots.

The intended architecture is:

```
SmartThings App / Automation
       │
       ▼
SmartThings Hub (Edge Driver: Lua / cosock)
       │  (TCP Socket, Single Connection, port 8899)
       ▼
Elfin-EW11 (Serial-to-WiFi Bridge)
       │  (RS485 Half-Duplex, 9600-8-N-1)
       ▼
Commax RS485 Bus
  ├── Commax Wallpad (Bus Master, continuous polling)
  ├── Wall Switches / Relays (Light 1 to 6)
  └── Other Wallpad sub-devices (Thermostat, Gas, etc. — ignored)
```

### Verified Hardware & Project Status (Field-Tested)

- **EW11 Configuration & Reliability:**
  - Parameters: 9600 baud, 8 data bits, 1 stop bit, parity none, protocol none, TCP Server mode, default port 8899, route UART.
  - Gap Time is configured low (few ms to ~10ms range) based on packet boundaries.
  - RS485 wiring issues have been fully resolved.
  - Bidirectional communication verified: Wallpad queries and device responses are continuously captured, and injected command frames reliably elicit ACK (`B1`) on the first attempt when sent in the designated timing slot.
- **Connection Rule:** The EW11 serial buffer/session cannot handle multiple concurrent TCP clients reliably. The driver must maintain exactly **one** persistent TCP connection. (External test scripts/terminals must disconnect before the driver connects).
- **Target Appliances:** Lights 1 to 6 only. (Lights 7 to 10 are polled by the wallpad but are physically uninstalled/unresponsive).
- **Protocol:** Commax fixed 8-byte frame protocol with a 1-byte checksum. Master-polled round-robin cycle is ~3 to 4 seconds.

---

## 2. Design Priorities

Follow these priorities in order:

1. **Bus Safety & Non-Interference:** The wallpad is the RS485 bus master. The driver must **never** collide with wallpad packets. Commands must only be transmitted during the verified idle timing window (immediately after receiving a `79` query frame).
2. **Passive Sniffing Over Active Polling:** Never transmit status query packets (`30 NN`). The wallpad already cycles through all devices continuously. The driver must observe existing bus traffic to synchronize states.
3. **Strict Stream Parsing & Self-Healing:** TCP packet boundaries do not guarantee RS485 frame boundaries. The stream parser must handle packet splitting, packet concatenation, and garbage bytes using a sliding-window header whitelist and checksum validation.
4. **Reliable State Tracking with ACK:** Control commands are queued per light. Transitions must be confirmed via ACK (`B1`) or timeout-based retries (up to 5 attempts), with physical truth ultimately grounded by regular state broadcast frames (`B0`).
5. **Clean SmartThings Device UX:** Expose lights as individual SmartThings switch devices (e.g., using a Bridge Parent + Child Light Devices architecture) so each light can be placed in its respective room in the SmartThings app.
6. **Hardware-Independent Testability:** Pure-logic components (checksum, parser, packet builder, state machine) must be fully testable offline without hardware using recorded raw packet fixtures.

---

## 3. Target SmartThings User Interface & Device Model

### 3.1 Device Architecture

SmartThings users expect to assign each physical light to a different room (e.g., Living Room, Kitchen, Bedroom 1). Therefore, the recommended architecture is:

- **Parent Device (Bridge / Gateway):**
  - Represents the EW11 bridge connection.
  - Profile exposes: Connection status (`connected` / `disconnected`), driver settings (EW11 IP address, port), and a discovery/sync trigger.
- **Child Devices (Lights 1 to 6):**
  - Created dynamically or upon driver initialization for channels 1 through 6.
  - Standard SmartThings `switch` capability (`on` / `off`).
  - Labeled clearly: `Light 1` through `Light 6` (user can rename them to "Living Room Light", etc.).

### 3.2 State Reporting Conventions

- **Bidirectional Feedback:** When a wall switch or wallpad button is toggled physically, the bus emits a `B0` (or `31`+`B1`+`B0`) response. The driver must immediately emit a SmartThings `switch.switch.on()` or `switch.switch.off()` event to the corresponding child device.
- **De-duplication:** If the parsed state matches the current known device state, suppress redundant SmartThings events to avoid unnecessary hub load.
- **Optimistic UI vs. ACK Confirmation:**
  - When the user taps a switch in SmartThings, enqueue the command.
  - Do **not** permanently update the UI state immediately if communication could fail. The switch state should transition upon receiving the device's ACK (`B1 SS NN`).
  - If all retries fail, revert/refresh the switch state to match physical truth.

---

## 4. Hardware & Transport Layer (Elfin-EW11)

### 4.1 Connection Settings

- **Transport:** TCP Client (using SmartThings Edge Lua `cosock.socket.tcp`).
- **Target Host:** Configurable via Driver Settings (default IP, default port `8899`).
- **Connection Lifecycle:**
  - Maintain a single persistent connection.
  - Non-blocking socket polling using `cosock`.
  - On socket disconnect/error: Log error, close socket cleanly, wait for backoff interval (e.g., 5 seconds), and attempt reconnection.
  - **Crucial:** Clear the stream parsing buffer completely upon socket reconnect to avoid stale data offset.

---

## 5. Commax RS485 Protocol & State Machine

### 5.1 Frame Structure

Every valid packet is exactly **8 bytes**:

```
[ Byte 0 ] [ Byte 1 ] [ Byte 2 ] [ Byte 3 ] [ Byte 4 ] [ Byte 5 ] [ Byte 6 ] [ Byte 7 ]
  Header     Param 1    Param 2    0x00       0x00       0x00       0x00      Checksum
```

- **Checksum Algorithm:**
  ```lua
  checksum = (sum(byte[0 .. 6])) & 0xFF
  ```
  A frame is valid if and only if:
  1. Length is 8 bytes.
  2. Byte 0 is in the known header whitelist.
  3. Calculated checksum matches `Byte 7`.

### 5.2 Header Whitelist

The stream parser recognizes the following headers for frame synchronization:
- Lighting frames: `30`, `31`, `B0`, `B1`
- Other bus device frames (must be parsed and safely ignored without error):
  `10`, `90`, `0F`, `8F`, `02`, `82`, `77`, `F7`, `76`, `F6`, `79`, `20`, `A0`, `7F` (`7F` is a time broadcast frame)

### 5.3 Frame Definitions

Notation:
- `NN` = Light number (`0x01` to `0x06`)
- `SS` = State (`0x01` = ON, `0x00` = OFF)
- `CS` = Checksum byte

| Frame Type | Direction | Hex Format | Description / Example |
| :--- | :--- | :--- | :--- |
| **Status Query** | Wallpad → Device | `30 NN 00 00 00 00 00 CS` | Wallpad querying Light NN (`30 05 00 00 00 00 00 35`) |
| **Status Response** | Device → Wallpad | `B0 SS NN 00 00 00 00 CS` | Light NN reporting state (`B0 01 05 00 00 00 00 B6` = Light 5 ON) |
| **Control Command** | Driver/Wallpad → Dev | `31 NN SS 00 00 00 00 CS` | Turn Light NN to SS (`31 05 01 00 00 00 00 37` = Turn 5 ON) |
| **Control ACK** | Device → Driver/WP | `B1 SS NN 00 00 00 00 CS` | Light NN confirming SS (`B1 01 05 00 00 00 00 B7` = 5 is now ON) |

*Note on Wallpad Operation Sequence:* When a user toggles the physical wallpad:
`31 NN SS ...` → `B1 SS NN ...` → (shortly after) `30 NN ...` → `B0 SS NN ...`.

### 5.4 Bus Timing & Transmission Window (Critical)

- **Standard Polling Delays:**
  - Wallpad Query (`30`) → Device Response (`B0`): ~40–50 ms.
  - Device Response (`B0`) → Next Wallpad Query: ~50 ms.
- **The Safe Idle Window (`79` Query Series):**
  - The wallpad periodically sends a series of twelve `79` queries (`79 01 01` through `79 06 02`) once per 3–4s cycle.
  - **No device responds to `79` queries.**
  - The interval between consecutive `79` queries is ~100 ms.
  - An 8-byte frame takes ~8 ms at 9600 baud.
  - Therefore, **the ~90 ms window immediately following a complete `79` frame is idle bus time.**
- **Transmission Rules:**
  1. **Trigger:** Send queued commands directly inside the receive callback of a valid `79` frame. Do not use deferred timers.
  2. **Rate Limit:** Send at most **one** control frame per `79` slot.
  3. **Idempotency:** Commands are absolute values (ON or OFF), never toggles. Repeating a command is completely safe.
  4. If transmission misses the slot, the wallpad may collide; in that case, the relay ignores the corrupted packet (no ACK, no light change, no hardware harm).

### 5.5 Command Queue & ACK State Machine

- **Per-Light Pending Queue:**
  - Each light channel (1–6) has at most 1 pending state (`target_state`, `retry_count`, `sent_timestamp`).
  - If a new SmartThings command arrives while a pending command exists for the same light, the newer command **replaces** the pending command (resets retry count).
- **Execution Flow:**
  1. ST command received → Update pending state for Light `NN`.
  2. Parser detects a complete `79` frame:
     - Check if any Light (1..6) has a pending command.
     - If yes, take the first pending command and immediately transmit `31 NN SS 00 00 00 00 CS`.
     - Record `sent_timestamp` and increment `retry_count`.
  3. Response matching:
     - If matching ACK `B1 SS NN` received: Clear pending command for Light `NN`, emit ST event `switch = on/off`, log round-trip latency.
     - If no ACK is received within ~150 ms (or by the time the next `79` slot arrives): Keep pending and retry on the next `79` slot.
  4. Retry Limit:
     - Maximum **5 attempts**.
     - If all 5 attempts fail: Log a warning, discard pending command. Do not fake state; physical truth will be corrected when the next `B0` cycle arrives.
- **Safety Interlock:**
  - Never transmit anything if the stream parser has not yet achieved synchronization (i.e., at least one valid checksummed frame has been parsed since connection).
  - The driver must **only ever transmit `31 NN SS` frames**. All other frame types are strictly prohibited from transmission.

---

## 6. Stream Parser Requirements

1. **Sliding Window Accumulator:**
   - Append raw bytes from TCP `receive()` to an internal buffer string.
2. **Frame Extraction Loop:**
   - While `buffer_length >= 8`:
     - Inspect byte 1 (potential header).
     - If byte 1 is NOT in the header whitelist:
       - Drop 1 byte from the front (`buffer = buffer:sub(2)`).
       - Increment `desync_byte_count` statistic.
       - Continue loop.
     - If byte 1 IS in the whitelist:
       - Extract candidate frame: `candidate = buffer:sub(1, 8)`.
       - Calculate checksum of `candidate[1..7]`.
       - If `checksum == candidate[8]`:
         - Valid frame found!
         - Remove 8 bytes from buffer (`buffer = buffer:sub(9)`).
         - Dispatch valid frame to handler.
       - If checksum does NOT match:
         - False header or corrupt packet.
         - Drop 1 byte from front (`buffer = buffer:sub(2)`).
         - Continue loop.
3. **Buffer Safety:**
   - If buffer exceeds max size (e.g., 256 bytes) without finding a valid frame, flush buffer to prevent memory leakage during line noise.
   - Flush buffer immediately on socket disconnect or reconnect.

---

## 7. What NOT To Do

- **DO NOT implement non-light devices:** Do not parse or transmit packets for thermostats, gas valves, ventilation, outlets, or batch-off (일괄소등).
- **DO NOT transmit polling queries (`30 NN`):** Never inject polling frames. Passive listening is sufficient.
- **DO NOT invent or guess protocol frames:** Only use the verified 8-byte frames specified herein.
- **DO NOT open multiple TCP connections:** Maintain strictly one client session.
- **DO NOT transmit outside of `79` slots:** Never transmit randomly or immediately upon receiving an ST command. Always wait for the `79` safe idle window.
- **DO NOT use optimistic state overrides without rollback:** Physical wall switches change the lights; physical bus frames (`B0` and `B1`) are the only source of truth.

---

## 8. Test Strategy (Hardware-Independent Verification)

The driver codebase must include unit tests runnable on any PC (using standard Lua or mock scripts) without SmartThings hardware or EW11:

### Test Suite Components

1. **Checksum & Frame Builder Unit Tests:**
   - Verify calculation of checksums for ON/OFF commands for channels 1–6.
   - Example: `31 05 01 00 00 00 00` must produce `0x37`.
   - Example: `31 05 00 00 00 00 00` must produce `0x36`.
2. **Stream Parser Unit Tests (Using Fixtures):**
   - **Case 1 (Standard stream):** Feeds valid consecutive frames.
   - **Case 2 (Concatenated packets):** Single TCP chunk containing 2+ frames:
     `82 00 02 23 21 00 00 C8 02 03 00 00 00 00 00 05`
   - **Case 3 (Fragmented packets):** Feed 8-byte frame in 3 separate calls (e.g., 3 bytes, 3 bytes, 2 bytes).
   - **Case 4 (Garbage bytes & Desync Recovery):**
     `30 08 00 00 00 00 00 38 FF 30 02 00 00 00 00 00 32` (Must drop `FF` and successfully parse both frames).
3. **State Machine & Slot Transmission Tests:**
   - Feed mock socket with `79` frames.
   - Verify pending command transmits immediately on `79`.
   - Verify `B1` ACK clears pending state and confirms status.
   - Verify 5-attempt retry logic when ACK is dropped.
   - Verify new command supersedes previous pending command for the same channel.

### Real-World Field Fixture (For Parser Test)

```text
30 02 00 00 00 00 00 32
B0 00 02 00 00 00 00 B2
31 05 01 00 00 00 00 37
B1 01 05 00 00 00 00 B7
30 05 00 00 00 00 00 35
B0 01 05 00 00 00 00 B6
30 03 00 00 00 00 00 33
B0 00 03 00 00 00 00 B3
31 05 00 00 00 00 00 36
B1 00 05 00 00 00 00 B6
30 05 00 00 00 00 00 35
B0 00 05 00 00 00 00 B5
```

---

## 9. Development Workflow & File Structure

### Proposed Project Directory Structure

```
smartthings-ew11-commax-light/
├── AGENTS.md                          # This document
├── config.yaml                        # Driver metadata (packageKey, name, permissions: lan)
├── profiles/
│   ├── commax-ew11-bridge.yaml        # Parent device profile (connection status, preferences)
│   └── commax-light-child.yaml        # Child switch device profile (switch capability)
├── src/
│   ├── init.lua                       # Driver lifecycle, device handlers, discovery
│   ├── config.lua                     # Constants, channel ranges (1..6), retry limits
│   ├── protocol/
│   │   ├── checksum.lua               # Checksum calculator and validator
│   │   ├── parser.lua                 # Stream buffer accumulator, sliding-window parser
│   │   └── command.lua                # Frame generator (31 NN SS)
│   ├── transport/
│   │   └── tcp_client.lua             # cosock TCP socket manager, reconnect loop
│   └── state/
│       └── controller.lua             # Command queue, 79 slot sender, ACK matching, retry logic
└── tests/
    ├── test_checksum.lua
    ├── test_parser.lua
    ├── test_state_machine.lua
    └── fixtures.lua
```

### Phased Execution Steps

1. **Phase 1: Project Setup & Offline Unit Tests**
   - Initialize project structure.
   - Implement `checksum.lua`, `command.lua`, and `parser.lua`.
   - Run offline test suites with fixture data to prove 100% parser resilience against noise and fragmentation.
2. **Phase 2: State Machine & Timing Logic**
   - Implement `controller.lua` (queue, 79 detection, ACK timeout, max 5 retries).
   - Test using simulated packet streams.
3. **Phase 3: SmartThings Edge Driver Integration**
   - Implement `tcp_client.lua` using `cosock`.
   - Create device profiles (`commax-ew11-bridge` and `commax-light-child`).
   - Wire capability handlers (`switch.on`, `switch.off`) to the controller queue.
   - Auto-create or provide manual discovery for Child Lights 1–6.
4. **Phase 4: Hardware Verification & Logging**
   - Deploy to SmartThings Hub.
   - Connect to EW11 over LAN.
   - Monitor live logs (`smartthings edge:drivers:logcat`).

---

## 10. Hardware Verification Checklist (Definition of Done)

- [ ] **Connection:** Driver connects to EW11 over TCP and sustains single-session connection without dropouts.
- [ ] **Reconnection:** Disconnecting/rebooting EW11 results in clean automatic reconnection and buffer flush.
- [ ] **Physical-to-ST Sync:** Toggling Light 1 through 6 on physical wall switches updates SmartThings app status within one polling cycle (~3s).
- [ ] **ST-to-Physical Actuation:** Turning Light 1 through 6 ON/OFF from SmartThings switches physical lights reliably on the first attempt in `79` slot.
- [ ] **No False Triggers:** Non-light frames (`10`, `77`, `02`, `7F`, etc.) are cleanly parsed and ignored without log errors.
- [ ] **Collision-Free:** Injected frames never collide with wallpad commands; wallpad continues normal operation with zero lag or lockup.
- [ ] **Retries & Logging:** If an ACK is artificially dropped, driver retries up to 5 times on subsequent `79` slots before safely aborting.
- [ ] **Documentation:** `README.md` documents EW11 DIP/web settings and installation steps.

---

## 11. Instructions for Future AI Coding Sessions

1. **Read this file first.** Never modify core protocol constants or timing assumptions without explicit user confirmation.
2. **Prioritize safety:** Do not write speculative transmission logic for other appliances.
3. **Keep pure logic decoupled:** Always keep protocol parsing and frame generation pure Lua so they can be tested without SmartThings SDK dependencies.
4. **Check the facts:** If an error occurs, distinguish between network errors (TCP/EW11), parsing errors (frame alignment/checksum), and protocol rejections (missing ACK).

