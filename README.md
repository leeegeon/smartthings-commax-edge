# SmartThings Commax Wallpad Light Edge Driver (via Elfin-EW11)

Samsung SmartThings Edge Driver for bidirectional control and real-time state synchronization of household lights (Channels 1–6) connected to a Commax RS485 wallpad bus via an Elfin-EW11 Wi-Fi serial bridge.

---

## 1. Architecture Overview

```text
SmartThings App / Automations
       │
       ▼
SmartThings Hub (Edge Driver: Lua 5.3 / cosock)
       │  (Single Persistent TCP Client, Port 8899)
       ▼
Elfin-EW11 (Serial-to-WiFi Bridge)
       │  (RS485 Half-Duplex, 9600-8-N-1)
       ▼
Commax RS485 Bus
  ├── Commax Wallpad (Master, round-robin polling every 3~4s)
  ├── Wall Switches / Relays (Light 1 to 6)
  └── Other Wallpad sub-devices (Thermostat, Gas, etc. — safely ignored)
```

### Core Features

- **Bus Safety & Collision-Free:** Strictly passive sniffing for status; control frames (`31 NN SS`) are **only injected inside the ~90ms idle window following `79` query frames**.
- **Bidirectional Real-Time Sync:** Wall switches toggled physically report via `B0` status broadcast, immediately updating the SmartThings app.
- **Single Persistent Connection:** Connects directly to the EW11 TCP server with auto-reconnection and buffer flushing.
- **Optimistic UI with Physical Grounding:** Tapping switch in SmartThings app provides instant visual feedback while physical confirmation proceeds via ACK (`B1`) or rollback on failure.
- **Bridge + Child Device UX:** Parent Bridge device manages the TCP connection and settings; Channels 1–6 appear as individual Child Light switches that can be renamed and assigned to separate rooms in the SmartThings app.

---

## 2. Elfin-EW11 Configuration

Configure the Elfin-EW11 web administration panel (`http://<EW11-IP>/`) with the following verified parameters:

### Serial Port Settings
- **Protocol:** `None`
- **Baud Rate:** `9600`
- **Data Bit:** `8`
- **Stop Bit:** `1`
- **Parity:** `None`
- **Flow Control:** `None`
- **Buffer Size:** `1024`
- **Gap Time:** `10 ms` (10ms 안팎으로 반드시 낮게 설정: Gap Time이 길어지면 EW11 내부 패킷화 대기 지연으로 슬롯 위상이 밀려 전송 타이밍이 어긋날 수 있음)

### Communication Settings
- **Protocol:** `TCP Server`
- **Port:** `8899` (Default, configurable in driver preferences)
- **Route:** `UART`
- **Max TCP Clients:** `1` *(EW11 serial buffer cannot handle multiple concurrent TCP clients reliably)*

### Physical Wiring (RS485 Half-Duplex)
- **EW11 A+** $\rightarrow$ **Commax Wallpad RS485 A (TRX+)**
- **EW11 B-** $\rightarrow$ **Commax Wallpad RS485 B (TRX-)**
- **EW11 GND** $\rightarrow$ **Bus GND / Power GND**
- **EW11 VCC** $\rightarrow$ **DC 9V–36V** (can tap wallpad internal power if rated)

---

## 3. Protocol Specification

### Frame Format (Fixed 8 Bytes)
```text
[ Byte 0 ] [ Byte 1 ] [ Byte 2 ] [ Byte 3 ] [ Byte 4 ] [ Byte 5 ] [ Byte 6 ] [ Byte 7 ]
  Header     Param 1    Param 2    0x00       0x00       0x00       0x00      Checksum
```
- **Checksum Formula:** `Checksum = (sum(Byte 0 .. Byte 6)) & 0xFF`

### Supported Lighting Frames
| Frame Type | Header | Param 1 | Param 2 | Direction | Example |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **Status Query** | `0x30` | `NN` (Channel) | `0x00` | Wallpad $\rightarrow$ Device | `30 05 00 00 00 00 00 35` |
| **Status Response** | `0xB0` | `SS` (State) | `NN` (Channel) | Device $\rightarrow$ Wallpad | `B0 01 05 00 00 00 00 B6` (Ch 5 ON) |
| **Control Command** | `0x31` | `NN` (Channel) | `SS` (State) | Driver $\rightarrow$ Device | `31 05 01 00 00 00 00 37` (Turn 5 ON) |
| **Control ACK** | `0xB1` | `SS` (State) | `NN` (Channel) | Device $\rightarrow$ Driver | `B1 01 05 00 00 00 00 B7` (Ch 5 is ON) |

- `NN`: Channel `0x01` through `0x06`
- `SS`: State (`0x01` = ON, `0x00` = OFF)

---

## 4. Diagnostics & Live Log Metrics

드라이버는 버스 타이밍과 통신 품질을 실시간으로 추적하며, 60초마다 주기적 요약 로그를 출력합니다.

### 주기적 진단 로그 항목 (60초 주기 info)
1. **슬롯 간격 통계 (`Slot interval stats`):**
   - 최근 100개 연속 `79` 프레임 간격을 롤링 윈도우로 집계합니다.
   - `avg`: 평균 간격 (공칭 약 0.100s)
   - `p50`: 중앙값 (0.100s 부근이어야 정상)
   - `p95` & `max`: 95분위수 및 최대 간격 (0.140s 이하가 이상적)
   - `merged(<20ms)`: EW11 또는 Wi-Fi 버퍼링으로 인해 20ms 미만 간격으로 붙어서 수신된 프레임 수
   - `jitter_skips`: `ENABLE_JITTER_GUARD` 활성화 시 지연된 슬롯 전송을 건너뛴 횟수
2. **수신 청크 크기 분포 (`Read chunk distribution`):**
   - non-blocking drain이 정상 동작하는지 검증하는 지표입니다.
   - `1B`, `2-7B`, `8B`, `9-16B`, `17+B`
   - 대부분의 청크가 8바이트 또는 16바이트에 집중되어야 정상적인 프레임 단위 도착 상태입니다.
3. **명령 지연 계측 (`Latency Instrumentation`):**
   - `Command queued -> first send`: ST 앱 명령 수신부터 첫 슬롯 송신까지 대기 시간 (최대 약 2.5~3.7초 대기, 순환 주기)
   - `send -> ACK`: 송신 직후 기기 ACK 수신까지의 지연 (Gap Time 10ms 기준 통상 50~100ms 이내)
   - `first_sent -> ACK`: 첫 시도 송신부터 최종 ACK 확인까지의 총 소요 시간

---

## 5. Installation & Deployment

### Step 1: Package Driver
Using the official SmartThings CLI:
```powershell
smartthings edge:drivers:package .
```

### Step 2: Assign to Channel & Install to Hub
```powershell
# Create or select your driver channel
smartthings edge:channels:assign <DRIVER_ID> --channel <CHANNEL_ID>

# Install the driver onto your SmartThings Hub
smartthings edge:drivers:install <DRIVER_ID> --hub <HUB_ID> --channel <CHANNEL_ID>
```

### Step 3: Add Device in SmartThings App
1. Open the **SmartThings App**.
2. Tap **+ (Add Device)** $\rightarrow$ **Scan nearby devices**.
3. The **Commax EW11 Bridge** device will be discovered and created.
4. Child devices (**Light 1** through **Light 6**) will be created automatically under the bridge.
5. In the Bridge device settings, verify or update the **EW11 IP Address** (Default: `192.168.0.132`) and **EW11 TCP Port** (Default: `8899`).
6. Rename each light and assign it to its respective room.

### Step 4: Live Logging
Monitor driver execution and network frames in real time:
```powershell
smartthings edge:drivers:logcat --hub-address <HUB_IP>
```

---

## 6. Offline Unit Testing

Pure-logic components (checksum calculation, sliding-window stream parser, and state machine) can be tested offline without hardware:

```powershell
# Run verification with Python runner
python tests\run_tests.py
```
