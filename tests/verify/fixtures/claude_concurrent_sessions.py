#!/usr/bin/env python3
"""Continuous independent streams and delayed initialization, without real tools."""

import json
import os
import re
import sys
import threading
import time

import claude_long_tasks as wire


observe = wire.observe
wire.observe = lambda kind, **values: observe(kind, wall_at=time.time(), **values)
LABEL = {
    "11111111": "ALPHA",
    "22222222": "BETA",
    "33333333": "GAMMA",
}[wire.SESSION[:8]]
CANCEL = threading.Event()
WORKER = None
PENDING = None


def finish(value, error=False):
    wire.assistant(value)
    wire.result(value, error=error)
    wire.observe("terminal", label=LABEL, error=error)


def stream():
    pieces = []
    for index in range(1, 901):
        if CANCEL.is_set():
            finish("".join(pieces) + f"{LABEL}_STOPPED", error=True)
            return
        piece = f"{LABEL}_{index:04d} "
        pieces.append(piece)
        wire.event({
            "type": "content_block_delta", "index": 0,
            "delta": {"type": "text_delta", "text": piece},
        })
        wire.observe("chunk", label=LABEL, sequence=index)
        CANCEL.wait(0.1)
    finish("".join(pieces) + f"{LABEL}_FINISHED")


def user(request):
    global WORKER, PENDING
    if WORKER is not None and WORKER.is_alive():
        raise RuntimeError("Concurrent prompts reached the same CLI queue")
    if PENDING is not None:
        raise RuntimeError("New prompt arrived before approval settled")
    content = request["message"]["content"]
    if isinstance(content, list):
        content = "".join(part.get("text", "") for part in content)
    marker = re.search(r"AUI_(STREAM|QUICK|APPROVAL)", content)
    if marker is None:
        raise ValueError("Unexpected synthetic prompt")
    wire.persist("user", content)
    wire.observe("prompt", label=LABEL, marker=marker[0])
    CANCEL.clear()
    if marker[1] == "STREAM":
        WORKER = threading.Thread(target=stream, daemon=True)
        WORKER.start()
    elif marker[1] == "QUICK":
        wire.event({
            "type": "content_block_delta", "index": 0,
            "delta": {"type": "text_delta", "text": f"{LABEL}_QUICK_DONE"},
        })
        finish(f"{LABEL}_QUICK_DONE")
    else:
        tool_id = wire.tool(f"permission-{time.monotonic_ns()}", name="Bash")
        PENDING = (f"permission-{time.monotonic_ns()}", tool_id)
        wire.emit({
            "type": "control_request", "request_id": PENDING[0],
            "request": {
                "subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": tool_id,
                "input": {"command": "echo synthetic-only"},
                "title": "Independent-session approval",
                "description": "The fixture executes no shell commands.",
            },
        })
        wire.observe("approval", label=LABEL)


def control(request):
    subtype = request["request"]["subtype"]
    response = {}
    if subtype == "initialize":
        wire.observe("initialize_started", label=LABEL)
        if LABEL == "BETA":
            signal = wire.ROOT / "beta-initializing.json"
            temporary = signal.with_suffix(".tmp")
            temporary.write_text(json.dumps({"pid": os.getpid()}))
            temporary.replace(signal)
            time.sleep(3)
        response = {"commands": [], "models": [], "output_styles": []}
        wire.observe("initialize_finished", label=LABEL)
    elif subtype == "get_context_usage":
        response = {"tokens": 100, "context_window": 200000}
    elif subtype == "interrupt":
        CANCEL.set()
        wire.observe("interrupt", label=LABEL)
    wire.emit({
        "type": "control_response",
        "response": {
            "subtype": "success", "request_id": request["request_id"],
            "response": response,
        },
    })


def permission(request):
    global PENDING
    response = request["response"]
    if PENDING is None or response["request_id"] != PENDING[0]:
        raise RuntimeError("Unknown permission response")
    allowed = response["response"]["behavior"] == "allow"
    wire.tool_result(PENDING[1], "APPROVAL_RESULT" if allowed else "Denied")
    PENDING = None
    finish(f"{LABEL}_APPROVAL_DONE", error=not allowed)


def main():
    if "--version" in sys.argv:
        print("2.1.0 (local concurrency fixture)")
        return
    for line in sys.stdin:
        request = json.loads(line)
        if request["type"] == "control_request":
            control(request)
        elif request["type"] == "control_response":
            permission(request)
        elif request["type"] == "user":
            user(request)
        else:
            raise ValueError("Unexpected protocol frame")


if __name__ == "__main__":
    try:
        main()
    finally:
        CANCEL.set()
        if WORKER is not None:
            WORKER.join(timeout=1)
