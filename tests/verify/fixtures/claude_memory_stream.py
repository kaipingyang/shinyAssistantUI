#!/usr/bin/env python3
"""Deterministic, local-only stream-json peer for the real R SDK transport."""

import json
import math
import os
import sys
import threading
import time

OUTPUT_LOCK = threading.Lock()


def emit(value):
    with OUTPUT_LOCK:
        sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def chunk(index):
    return f"MEMORY_{index:06d}_{'x' * 48}\n"


def stream(count, interval, quiet_seconds=0):
    session = "memory-comparison-fixture"
    if quiet_seconds:
        time.sleep(quiet_seconds)

    def event(value):
        emit(
            {
                "type": "stream_event",
                "uuid": "memory-event",
                "session_id": session,
                "event": value,
            }
        )

    event(
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text", "text": ""},
        }
    )
    for index in range(1, count + 1):
        event(
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": chunk(index)},
            }
        )
        if interval:
            time.sleep(interval)
    event({"type": "content_block_stop", "index": 0})
    event({"type": "message_delta", "delta": {"stop_reason": "end_turn"}})
    text = "".join(chunk(index) for index in range(1, count + 1))
    emit(
        {
            "type": "assistant",
            "session_id": session,
            "uuid": "memory-assistant",
            "message": {
                "role": "assistant",
                "model": "fixture",
                "content": [{"type": "text", "text": text}],
            },
        }
    )
    emit(
        {
            "type": "result",
            "subtype": "success",
            "session_id": session,
            "is_error": False,
            "num_turns": 1,
            "duration_ms": 1,
            "duration_api_ms": 1,
            "total_cost_usd": 0,
            "usage": {"input_tokens": 1, "output_tokens": count},
            "stop_reason": "end_turn",
            "result": text,
        }
    )


def main():
    if "--version" in sys.argv:
        print("2.1.0 (memory fixture, not Claude Code)")
        return
    count = int(os.environ.get("AUI_MEMORY_EVENTS", "1200"))
    interval = float(os.environ.get("AUI_MEMORY_INTERVAL", "0.001"))
    quiet_seconds = float(os.environ.get("AUI_MEMORY_QUIET_SECONDS", "0"))
    usage_delay = float(os.environ.get("AUI_MEMORY_USAGE_DELAY_SECONDS", "0"))
    if (
        not 1 <= count <= 20000
        or not 0 <= interval <= 0.1
        or not 0 <= quiet_seconds <= 120
        or not (0 <= usage_delay <= 40 or usage_delay == math.inf)
    ):
        raise ValueError("Invalid bounded fixture workload")
    for line in sys.stdin:
        request = json.loads(line)
        if request["type"] == "control_request":
            subtype = request["request"]["subtype"]
            response = {}
            if subtype == "initialize":
                response = {"commands": [], "models": [], "output_styles": []}
            elif subtype == "get_context_usage":
                if math.isinf(usage_delay):
                    continue
                response = {"totalTokens": 1, "rawMaxTokens": 200000}
            value = {
                "type": "control_response",
                "response": {
                    "subtype": "success",
                    "request_id": request["request_id"],
                    "response": response,
                },
            }
            if subtype == "get_context_usage" and usage_delay:
                timer = threading.Timer(usage_delay, emit, args=(value,))
                timer.daemon = True
                timer.start()
            else:
                emit(value)
        elif request["type"] == "user":
            stream(count, interval, quiet_seconds)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
