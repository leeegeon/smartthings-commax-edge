"""
Offline Verification Runner in Python
Mirrors pure-logic checksum, frame builder, sliding-window parser (extract-first, 2KB lossless,
4KB tail-preserve), low-latency select drain, stale-trigger prevention, 0.15s retry interval,
slot timing rolling stats, chunk size distribution, jitter guard, pattern-based triggers,
target-state ACK matching with mismatch UI event suppression, and fast exit.
"""

# Config & Constants
MIN_LIGHT_CHANNEL = 1
MAX_LIGHT_CHANNEL = 6
FRAME_LENGTH = 8
MAX_BUFFER_SIZE = 4096
OVERFLOW_KEEP_BYTES = 512
MAX_RETRIES = 5
RETRY_INTERVAL_SEC = 0.15
MAX_TRIGGER_AGE_SEC = 0.04
EXPECTED_79_INTERVAL_SEC = 0.100
JITTER_TOLERANCE_SEC = 0.040

HEADERS = {
    "STATUS_QUERY": 0x30,
    "CONTROL_CMD": 0x31,
    "STATUS_RESP": 0xB0,
    "CONTROL_ACK": 0xB1,
    "IDLE_QUERY": 0x79,
    "TIME_SYNC": 0x7F,
}

HEADER_SET = {
    0x30, 0x31, 0xB0, 0xB1,
    0x10, 0x90, 0x0F, 0x8F,
    0x02, 0x82, 0x77, 0xF7,
    0x76, 0xF6, 0x79, 0x20,
    0xA0, 0x7F
}

def calculate_checksum(data: bytes) -> int:
    return sum(data[:7]) & 0xFF

def verify_checksum(frame: bytes) -> bool:
    if len(frame) != 8:
        return False
    return calculate_checksum(frame[:7]) == frame[7]

def build_control_frame(channel: int, state: int) -> bytes:
    assert MIN_LIGHT_CHANNEL <= channel <= MAX_LIGHT_CHANNEL, f"Invalid channel {channel}"
    state_byte = 1 if state in (1, True, "on", "ON") else 0
    payload = bytearray([HEADERS["CONTROL_CMD"], channel, state_byte, 0, 0, 0, 0])
    cs = calculate_checksum(payload)
    payload.append(cs)
    return bytes(payload)

class StreamParser:
    def __init__(self, max_buffer_size=MAX_BUFFER_SIZE, overflow_keep_bytes=OVERFLOW_KEEP_BYTES):
        self.buffer = bytearray()
        self.max_buffer_size = max_buffer_size
        self.overflow_keep_bytes = overflow_keep_bytes
        self.synchronized = False
        self.valid_frame_count = 0
        self.desync_byte_count = 0
        self.overflow_count = 0

    def reset(self):
        self.buffer.clear()
        self.synchronized = False

    def has_next_header_pending(self) -> bool:
        return len(self.buffer) > 0 and self.buffer[0] in HEADER_SET

    def feed(self, chunk: bytes):
        if not chunk:
            return []

        # Abnormally large chunk safety guard (>4096 bytes)
        if len(chunk) > self.max_buffer_size:
            self.overflow_count += 1
            self.buffer = bytearray(chunk[-self.overflow_keep_bytes:])
            return []

        self.buffer.extend(chunk)

        valid_frames = []
        # 1. Extract valid frames FIRST
        while len(self.buffer) >= FRAME_LENGTH:
            header = self.buffer[0]
            if header not in HEADER_SET:
                self.buffer.pop(0)
                self.desync_byte_count += 1
            else:
                candidate = bytes(self.buffer[:FRAME_LENGTH])
                if verify_checksum(candidate):
                    self.synchronized = True
                    self.valid_frame_count += 1
                    valid_frames.append(candidate)
                    del self.buffer[:FRAME_LENGTH]
                else:
                    self.buffer.pop(0)
                    self.desync_byte_count += 1

        # 2. Safety check for accumulated leftover buffer
        if len(self.buffer) > self.max_buffer_size:
            self.overflow_count += 1
            self.buffer = bytearray(self.buffer[-self.overflow_keep_bytes:])

        return valid_frames

class StateController:
    def __init__(self, extra_slot_triggers=None, enable_jitter_guard=False):
        self.known_states = {}
        self.pending_commands = {}
        self.commands_sent = 0
        self.acks_received = 0
        self.commands_failed = 0
        self.jitter_skips = 0
        self.merged_79_count = 0
        self.enable_jitter_guard = enable_jitter_guard

        # Extra pattern validation
        self.extra_patterns = []
        for v in (extra_slot_triggers or []):
            if isinstance(v, dict) and "header" in v:
                hdr = v["header"]
                if hdr == HEADERS["STATUS_QUERY"]:
                    b_min, b_max = v.get("byte2_min"), v.get("byte2_max")
                    if b_min and b_max and 0x07 <= b_min <= 0x0A and 0x07 <= b_max <= 0x0A and b_min <= b_max:
                        self.extra_patterns.append({
                            "header": 0x30,
                            "b_min": b_min,
                            "b_max": b_max,
                            "name": f"30[{b_min:02X}-{b_max:02X}]"
                        })
                    else:
                        # Invalid 0x30 range: rejected!
                        pass
                else:
                    self.extra_patterns.append({
                        "header": hdr,
                        "b_min": v.get("byte2_min"),
                        "b_max": v.get("byte2_max"),
                        "name": v.get("name", f"{hdr:02X}")
                    })
            elif isinstance(v, int):
                if v != HEADERS["STATUS_QUERY"]:
                    self.extra_patterns.append({
                        "header": v,
                        "b_min": None,
                        "b_max": None,
                        "name": f"{v:02X}"
                    })

        self.trigger_stats = {}
        self.last_frame_header = None
        self.last_79_time = None
        self.slot_intervals = []
        self.chunk_bins = {"1B": 0, "2-7B": 0, "8B": 0, "9-16B": 0, "17+B": 0}

    def record_chunk_size(self, size: int):
        if size == 1:
            self.chunk_bins["1B"] += 1
        elif 2 <= size <= 7:
            self.chunk_bins["2-7B"] += 1
        elif size == 8:
            self.chunk_bins["8B"] += 1
        elif 9 <= size <= 16:
            self.chunk_bins["9-16B"] += 1
        elif size >= 17:
            self.chunk_bins["17+B"] += 1

    def queue_command(self, channel: int, target_state: int, queued_time: float = 0.0):
        self.pending_commands[channel] = {
            "target_state": 1 if target_state in (1, True, "on") else 0,
            "retry_count": 0,
            "queued_time": queued_time,
            "first_sent_time": None,
            "sent_time": None,
            "trigger_name": None,
        }

    def match_slot_trigger(self, frame: bytes):
        header = frame[0]
        if header == HEADERS["IDLE_QUERY"]:
            return True, "79"
        for pat in self.extra_patterns:
            if pat["header"] == header:
                if pat["b_min"] is not None and pat["b_max"] is not None:
                    b2 = frame[1]
                    if pat["b_min"] <= b2 <= pat["b_max"]:
                        return True, pat["name"]
                else:
                    return True, pat["name"]
        return False, None

    def get_slot_stats(self):
        if not self.slot_intervals:
            return {"count": 0, "avg": 0, "p50": 0, "p95": 0, "max": 0, "merged": self.merged_79_count}
        s = sorted(self.slot_intervals)
        n = len(s)
        import math
        p50 = s[max(0, math.ceil(n * 0.5) - 1)]
        p95 = s[max(0, math.ceil(n * 0.95) - 1)]
        return {
            "count": n,
            "avg": sum(s) / n,
            "p50": p50,
            "p95": p95,
            "max": s[-1],
            "merged": self.merged_79_count,
            "jitter_skips": self.jitter_skips,
        }

    def handle_frame(self, frame: bytes, is_synced: bool, tx_fn, on_state_change, on_command_failed=None, current_time=0.0, ctx=None):
        header = frame[0]
        ctx = ctx or {}
        chunk_time = ctx.get("chunk_time", current_time)
        is_latest = ctx.get("is_latest", True)
        has_next_header_pending = ctx.get("has_next_header_pending", False)

        if "chunk_size" in ctx:
            self.record_chunk_size(ctx["chunk_size"])

        interval_from_last_79 = None
        is_consecutive_79 = False
        if header == HEADERS["IDLE_QUERY"]:
            if self.last_frame_header == HEADERS["IDLE_QUERY"] and self.last_79_time is not None:
                interval_from_last_79 = current_time - self.last_79_time
                is_consecutive_79 = True
                if interval_from_last_79 < 0.020:
                    self.merged_79_count += 1
                else:
                    self.slot_intervals.append(interval_from_last_79)
                    if len(self.slot_intervals) > 100:
                        self.slot_intervals.pop(0)
            self.last_79_time = current_time

        is_slot_trigger, trigger_name = self.match_slot_trigger(frame)

        if is_slot_trigger:
            if trigger_name not in self.trigger_stats:
                self.trigger_stats[trigger_name] = {"candidates": 0, "sent": 0, "ack": 0}
            self.trigger_stats[trigger_name]["candidates"] += 1

            # Fast Exit if pending is empty
            if not self.pending_commands:
                self.last_frame_header = header
                return

            if not is_synced:
                self.last_frame_header = header
                return

            # Jitter guard check
            if self.enable_jitter_guard and is_consecutive_79 and interval_from_last_79 is not None:
                limit = EXPECTED_79_INTERVAL_SEC + JITTER_TOLERANCE_SEC
                if interval_from_last_79 > limit:
                    self.jitter_skips += 1
                    self.last_frame_header = header
                    return

            # Stale trigger checks
            if not is_latest or (current_time - chunk_time) > MAX_TRIGGER_AGE_SEC or has_next_header_pending:
                self.last_frame_header = header
                return

            for ch in range(MIN_LIGHT_CHANNEL, MAX_LIGHT_CHANNEL + 1):
                if ch in self.pending_commands:
                    pending = self.pending_commands[ch]
                    if pending["sent_time"] is not None and (current_time - pending["sent_time"]) < RETRY_INTERVAL_SEC:
                        continue

                    if pending["retry_count"] >= MAX_RETRIES:
                        del self.pending_commands[ch]
                        self.commands_failed += 1
                        if on_command_failed:
                            on_command_failed(ch, self.known_states.get(ch, 0))
                    else:
                        if pending["retry_count"] == 0:
                            pending["first_sent_time"] = current_time
                        cmd = build_control_frame(ch, pending["target_state"])
                        pending["retry_count"] += 1
                        pending["sent_time"] = current_time
                        pending["trigger_name"] = trigger_name
                        self.commands_sent += 1
                        self.trigger_stats[trigger_name]["sent"] += 1
                        tx_fn(cmd)
                        break

        elif header == HEADERS["CONTROL_ACK"]:
            state_val, ch = frame[1], frame[2]
            if MIN_LIGHT_CHANNEL <= ch <= MAX_LIGHT_CHANNEL:
                pending = self.pending_commands.get(ch)
                if pending and pending["target_state"] == state_val:
                    if pending["trigger_name"] in self.trigger_stats:
                        self.trigger_stats[pending["trigger_name"]]["ack"] += 1
                    del self.pending_commands[ch]
                    self.acks_received += 1
                    self.known_states[ch] = state_val
                    on_state_change(ch, state_val, True)
                elif pending:
                    # Mismatch: update state but suppress UI event
                    self.known_states[ch] = state_val
                else:
                    # No pending: emit event
                    self.known_states[ch] = state_val
                    on_state_change(ch, state_val, True)

        elif header == HEADERS["STATUS_RESP"]:
            state_val, ch = frame[1], frame[2]
            if MIN_LIGHT_CHANNEL <= ch <= MAX_LIGHT_CHANNEL:
                if ch in self.pending_commands and self.pending_commands[ch]["target_state"] == state_val:
                    del self.pending_commands[ch]
                if self.known_states.get(ch) != state_val:
                    self.known_states[ch] = state_val
                    on_state_change(ch, state_val, False)

        self.last_frame_header = header

def main():
    print("==================================================")
    print("  COMMAX PROTOCOL VERIFICATION RUNNER (PYTHON)    ")
    print("==================================================")
    
    # 1. Checksum Tests
    cmd_5_on = build_control_frame(5, 1)
    assert cmd_5_on.hex().upper() == "3105010000000037", f"Failed: {cmd_5_on.hex()}"
    assert verify_checksum(cmd_5_on)
    print("✔ Checksum & Command generation verified")

    # 2. Field Trace Stream Tests
    field_trace = bytes.fromhex(
        "3002000000000032"
        "B0000200000000B2"
        "3105010000000037"
        "B1010500000000B7"
        "3005000000000035"
        "B0010500000000B6"
        "3003000000000033"
        "B0000300000000B3"
        "3105000000000036"
        "B1000500000000B6"
        "3005000000000035"
        "B0000500000000B5"
    )
    parser = StreamParser()
    extracted = parser.feed(field_trace)
    assert len(extracted) == 12, f"Expected 12 frames, got {len(extracted)}"
    assert parser.synchronized
    print("✔ Field trace stream parsing (12 frames) verified")

    # 3. Concatenated Packet Test
    concat = bytes.fromhex("82000223210000C80203000000000005")
    p2 = StreamParser()
    frames2 = p2.feed(concat)
    assert len(frames2) == 2
    print("✔ Concatenated packet parsing verified")

    # 4. Fragmented Packet Test & has_next_header_pending
    p3 = StreamParser()
    f1 = p3.feed(field_trace[:3])
    f2 = p3.feed(field_trace[3:6])
    f3 = p3.feed(field_trace[6:8])
    assert len(f1) == 0 and len(f2) == 0 and len(f3) == 1
    assert not p3.has_next_header_pending()
    p3.feed(bytes.fromhex("3005"))
    assert p3.has_next_header_pending()
    print("✔ Fragmented packet reassembly & pending header check verified")

    # 5. Garbage Injection Recovery
    p4 = StreamParser()
    garbage_stream = bytes.fromhex("3008000000000038") + b"\xFF" + bytes.fromhex("3002000000000032")
    frames4 = p4.feed(garbage_stream)
    assert len(frames4) == 2
    assert p4.desync_byte_count == 1
    print("✔ Garbage injection and desync recovery verified")

    # 6. Parser 2KB Lossless Chunk & 4KB Overflow Tail-Preservation
    p_large = StreamParser(max_buffer_size=4096, overflow_keep_bytes=512)
    single_valid = field_trace[:8]
    chunk_2kb = single_valid * 256 # exactly 2048 bytes (256 frames)
    ext_2kb = p_large.feed(chunk_2kb)
    assert len(ext_2kb) == 256, f"Expected 256 frames, got {len(ext_2kb)}"
    assert p_large.synchronized
    assert p_large.overflow_count == 0
    assert len(p_large.buffer) == 0

    # Feed 5000 bytes noise
    noise_5k = b"\xEE" * 5000
    ext_noise = p_large.feed(noise_5k)
    assert len(ext_noise) == 0
    assert p_large.overflow_count == 1
    assert len(p_large.buffer) == 512, f"Expected 512 tail bytes, got {len(p_large.buffer)}"
    assert p_large.synchronized, "Synchronized must be preserved on overflow"
    print("✔ 2KB lossless chunk & 4KB overflow tail preservation verified")

    # 7. Stale Trigger Prevention
    ctrl = StateController()
    ctrl.queue_command(5, 1, queued_time=1.0)
    tx_list = []
    idle_79 = bytes.fromhex("790101000000007B")
    
    # Not latest in chunk
    ctrl.handle_frame(idle_79, True, tx_list.append, lambda *args: None, current_time=1.0, ctx={"chunk_time": 1.0, "is_latest": False})
    assert len(tx_list) == 0, "Must not transmit if not latest"

    # Stale chunk (> 40ms)
    ctrl.handle_frame(idle_79, True, tx_list.append, lambda *args: None, current_time=1.05, ctx={"chunk_time": 1.0, "is_latest": True})
    assert len(tx_list) == 0, "Must not transmit if chunk is stale (age 50ms > 40ms)"

    # Pending next header
    ctrl.handle_frame(idle_79, True, tx_list.append, lambda *args: None, current_time=1.0, ctx={"chunk_time": 1.0, "is_latest": True, "has_next_header_pending": True})
    assert len(tx_list) == 0, "Must not transmit if next header pending"

    # Fresh & valid
    ctrl.handle_frame(idle_79, True, tx_list.append, lambda *args: None, current_time=1.01, ctx={"chunk_time": 1.0, "is_latest": True, "has_next_header_pending": False})
    assert len(tx_list) == 1
    assert tx_list[0].hex().upper() == "3105010000000037"
    print("✔ Stale trigger prevention (3 conditions) verified")

    # 8. Retry Interval (0.15s) & 5 Retries Abort
    ctrl_retry = StateController()
    ctrl_retry.queue_command(3, 1, queued_time=10.0)
    tx_retry = []
    failed_reverts = []
    t = 10.0
    
    # Attempt 1
    ctrl_retry.handle_frame(idle_79, True, tx_retry.append, lambda *args: None, current_time=t)
    assert len(tx_retry) == 1
    
    # Suppressed at t=10.10 (< 0.15s)
    ctrl_retry.handle_frame(idle_79, True, tx_retry.append, lambda *args: None, current_time=t + 0.10)
    assert len(tx_retry) == 1

    # Attempt 2 at t=10.20 (>= 0.15s)
    ctrl_retry.handle_frame(idle_79, True, tx_retry.append, lambda *args: None, current_time=t + 0.20)
    assert len(tx_retry) == 2

    # Attempts 3, 4, 5 at +0.40, +0.60, +0.80
    for dt in [0.40, 0.60, 0.80]:
        ctrl_retry.handle_frame(idle_79, True, tx_retry.append, lambda *args: None, current_time=t + dt)
    assert len(tx_retry) == 5

    # 6th attempt aborts & rolls back
    ctrl_retry.handle_frame(idle_79, True, tx_retry.append, lambda *args: None,
                            on_command_failed=lambda ch, st: failed_reverts.append((ch, st)),
                            current_time=t + 1.00)
    assert len(tx_retry) == 5
    assert 3 not in ctrl_retry.pending_commands
    assert ctrl_retry.commands_failed == 1
    assert len(failed_reverts) == 1 and failed_reverts[0] == (3, 0)
    print("✔ 0.15s retry interval & 5-attempt retry limit verified")

    # 9. Slot Timing Stats & Chunk Distribution
    ctrl_st = StateController()
    cur = 100.0
    # First 79
    ctrl_st.handle_frame(idle_79, True, lambda *args: None, lambda *args: None, current_time=cur, ctx={"chunk_size": 8})
    # Consecutive 79s
    ctrl_st.handle_frame(idle_79, True, lambda *args: None, lambda *args: None, current_time=cur + 0.100, ctx={"chunk_size": 8})
    ctrl_st.handle_frame(idle_79, True, lambda *args: None, lambda *args: None, current_time=cur + 0.200, ctx={"chunk_size": 16})
    ctrl_st.handle_frame(idle_79, True, lambda *args: None, lambda *args: None, current_time=cur + 0.380, ctx={"chunk_size": 1})
    ctrl_st.handle_frame(idle_79, True, lambda *args: None, lambda *args: None, current_time=cur + 0.385, ctx={"chunk_size": 24}) # merged (0.005s)
    
    st_res = ctrl_st.get_slot_stats()
    assert st_res["count"] == 3, f"Expected 3 non-merged intervals, got {st_res['count']}"
    assert st_res["merged"] == 1
    assert abs(st_res["avg"] - ((0.100 + 0.100 + 0.180) / 3)) < 0.001
    assert abs(st_res["max"] - 0.180) < 0.001
    assert ctrl_st.chunk_bins["8B"] == 2
    assert ctrl_st.chunk_bins["9-16B"] == 1
    assert ctrl_st.chunk_bins["1B"] == 1
    assert ctrl_st.chunk_bins["17+B"] == 1
    print("✔ Slot timing stats & chunk distribution verified")

    # 10. Jitter Guard
    ctrl_jg = StateController(enable_jitter_guard=True)
    t = 200.0
    ctrl_jg.queue_command(1, 1, queued_time=t)
    tx_jg = []
    # First 79 (prior frame was None) -> NOT skipped by guard
    ctrl_jg.handle_frame(idle_79, True, tx_jg.append, lambda *args: None, current_time=t)
    assert len(tx_jg) == 1, "First 79 in burst must not be skipped"

    # Consecutive 79 with interval 0.150s (> 0.140s) -> SKIPPED
    t = t + 0.20
    ctrl_jg.queue_command(2, 1, queued_time=t)
    ctrl_jg.last_79_time = t - 0.150
    ctrl_jg.last_frame_header = HEADERS["IDLE_QUERY"]
    ctrl_jg.handle_frame(idle_79, True, tx_jg.append, lambda *args: None, current_time=t)
    assert len(tx_jg) == 1, "Interval 0.150s must be skipped by jitter guard"
    assert ctrl_jg.jitter_skips == 1

    # Consecutive 79 with normal interval 0.100s -> TRANSMITTED
    t = t + 0.20
    ctrl_jg.last_79_time = t - 0.100
    ctrl_jg.last_frame_header = HEADERS["IDLE_QUERY"]
    ctrl_jg.handle_frame(idle_79, True, tx_jg.append, lambda *args: None, current_time=t)
    assert len(tx_jg) == 2, "Normal interval must be transmitted"
    print("✔ Jitter guard on/off & first-79 exemption verified")

    # 11. Pattern-based Extra Triggers
    ctrl_pat = StateController(extra_slot_triggers=[
        {"header": 0x7F},
        {"header": 0x30, "byte2_min": 0x07, "byte2_max": 0x0A},
        {"header": 0x30}, # Invalid without range: rejected
    ])
    assert len(ctrl_pat.extra_patterns) == 2, f"Expected 2 valid patterns, got {len(ctrl_pat.extra_patterns)}"
    tx_pat = []
    t = 300.0

    # 30 07: match
    f_30_07 = bytes.fromhex("3007000000000037")
    ctrl_pat.queue_command(1, 1, queued_time=t)
    ctrl_pat.handle_frame(f_30_07, True, tx_pat.append, lambda *args: None, current_time=t)
    assert len(tx_pat) == 1

    # 30 05: light query -> MUST NOT MATCH
    t += 0.20
    f_30_05 = bytes.fromhex("3005000000000035")
    ctrl_pat.queue_command(2, 1, queued_time=t)
    ctrl_pat.handle_frame(f_30_05, True, tx_pat.append, lambda *args: None, current_time=t)
    assert len(tx_pat) == 1, "Light query 30 05 must not trigger"

    # 7F: match
    t += 0.20
    f_7F = bytes.fromhex("7F01010000000081")
    ctrl_pat.handle_frame(f_7F, True, tx_pat.append, lambda *args: None, current_time=t)
    assert len(tx_pat) == 2
    print("✔ Pattern-based EXTRA_SLOT_TRIGGERS validation & matching verified")

    # 12. ACK Mismatch Event Suppression
    ctrl_ack = StateController()
    ctrl_ack.queue_command(2, 1, queued_time=400.0) # Target ON
    tx_ack = []
    ctrl_ack.handle_frame(idle_79, True, tx_ack.append, lambda *args: None, current_time=400.0)
    assert len(tx_ack) == 1
    
    # Mismatched ACK: B1 00 02 (OFF) while pending ON
    ack_off = bytes.fromhex("B1000200000000B3")
    ack_events = []
    ctrl_ack.handle_frame(ack_off, True, tx_ack.append, lambda ch, st, ack: ack_events.append((ch, st, ack)), current_time=400.1)
    assert 2 in ctrl_ack.pending_commands, "Mismatch ACK must not clear pending command"
    assert ctrl_ack.known_states[2] == 0, "Known state updated to actual status"
    assert len(ack_events) == 0, "UI event must be SUPPRESSED on ACK mismatch while pending exists"

    # Matching ACK: B1 01 02 (ON)
    ack_on = bytes.fromhex("B1010200000000B4")
    ctrl_ack.handle_frame(ack_on, True, tx_ack.append, lambda ch, st, ack: ack_events.append((ch, st, ack)), current_time=400.2)
    assert 2 not in ctrl_ack.pending_commands, "Matching ACK clears pending command"
    assert ctrl_ack.known_states[2] == 1
    assert len(ack_events) == 1 and ack_events[0] == (2, 1, True), "UI event emitted on matching ACK"

    # ACK when NO pending command exists: UI event emitted
    ctrl_ack.handle_frame(ack_off, True, tx_ack.append, lambda ch, st, ack: ack_events.append((ch, st, ack)), current_time=400.3)
    assert len(ack_events) == 2 and ack_events[1] == (2, 0, True), "UI event emitted when no pending command"
    print("✔ ACK target-state matching & mismatch UI suppression verified")

    # 13. Fast Exit when queue empty
    ctrl_fast = StateController()
    ctrl_fast.handle_frame(idle_79, True, tx_list.append, lambda *args: None, current_time=500.0)
    assert ctrl_fast.trigger_stats["79"]["candidates"] == 1
    assert ctrl_fast.trigger_stats["79"]["sent"] == 0
    print("✔ Fast exit on empty queue verified")

    print("==================================================")
    print("  ALL OFFLINE PROTOCOL VERIFICATIONS PASSED!      ")
    print("==================================================")

if __name__ == "__main__":
    main()
