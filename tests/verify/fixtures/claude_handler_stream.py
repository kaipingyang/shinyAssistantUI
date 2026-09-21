#!/usr/bin/env python3
"""Local approval/cancellation peer; tools and network calls are never executed."""

import json
import os
import sys
import threading

from claude_memory_stream import emit as emit_value


output_lock = threading.Lock()
cancelled = threading.Event()
session = f"handler-fixture-{os.getpid()}"
pending_permission = None
worker = None
turn = 0


def emit(value):
    with output_lock:
        emit_value(value)


def event(value):
    emit(
        {
            "type": "stream_event",
            "uuid": f"handler-event-{turn}",
            "session_id": session,
            "event": value,
        }
    )


def text(value):
    event(
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "text_delta", "text": value},
        }
    )


def result(value="", error=False):
    emit(
        {
            "type": "result",
            "subtype": "error_during_execution" if error else "success",
            "session_id": session,
            "is_error": error,
            "num_turns": 1,
            "duration_ms": 1,
            "duration_api_ms": 1,
            "total_cost_usd": 0,
            "usage": {"input_tokens": 1, "output_tokens": 1},
            "stop_reason": "end_turn",
            "result": value,
        }
    )


def stream_until_cancelled():
    for index in range(1, 2001):
        if cancelled.is_set():
            result("Interrupted", error=True)
            return
        text(f"RUNNING_{index:04d} ")
        cancelled.wait(0.03)
    result("CANCEL_WAS_NOT_RECEIVED", error=True)


def user_message(request):
    global pending_permission, worker, turn
    if worker is not None and worker.is_alive():
        raise RuntimeError("A foreground turn started before its predecessor settled")
    turn += 1
    content = request["message"]["content"]
    if isinstance(content, list):
        content = "".join(part.get("text", "") for part in content)
    if content == "APPROVAL":
        tool_id = f"approval-tool-{turn}"
        request_id = f"approval-request-{turn}"
        tool_input = {"command": "echo synthetic-fixture"}
        text("APPROVAL_WAITING ")
        event(
            {
                "type": "content_block_start",
                "index": 1,
                "content_block": {"type": "tool_use", "id": tool_id, "name": "Bash"},
            }
        )
        event(
            {
                "type": "content_block_delta",
                "index": 1,
                "delta": {
                    "type": "input_json_delta",
                    "partial_json": json.dumps(tool_input),
                },
            }
        )
        event({"type": "content_block_stop", "index": 1})
        pending_permission = (request_id, tool_id)
        emit(
            {
                "type": "control_request",
                "request_id": request_id,
                "request": {
                    "subtype": "can_use_tool",
                    "tool_name": "Bash",
                    "input": tool_input,
                    "tool_use_id": tool_id,
                    "title": "Synthetic approval",
                    "description": "No command is executed by this fixture.",
                },
            }
        )
    elif content == "CANCEL":
        cancelled.clear()
        worker = threading.Thread(target=stream_until_cancelled, daemon=True)
        worker.start()
    elif content == "NORMAL":
        text("NORMAL_DONE ")
        result("NORMAL_DONE ")
    else:
        raise ValueError("Unexpected synthetic prompt")


def control_response(request):
    global pending_permission
    response = request["response"]
    if pending_permission is None or response["request_id"] != pending_permission[0]:
        raise ValueError("Unexpected permission response")
    _, tool_id = pending_permission
    pending_permission = None
    decision = response["response"]
    allowed = decision["behavior"] == "allow"
    emit(
        {
            "type": "user",
            "session_id": session,
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": tool_id,
                        "content": "APPROVAL_RESULT_SENTINEL" if allowed else "Denied",
                        "is_error": not allowed,
                    }
                ],
            },
        }
    )
    if allowed:
        text("APPROVAL_DONE ")
        result("APPROVAL_WAITING APPROVAL_DONE ")
    else:
        result("Denied", error=True)


def main():
    if "--version" in sys.argv:
        print("2.1.0 (handler fixture, not Claude Code)")
        return
    for line in sys.stdin:
        request = json.loads(line)
        if request["type"] == "control_request":
            subtype = request["request"]["subtype"]
            response = {}
            if subtype == "initialize":
                response = {"commands": [], "models": [], "output_styles": []}
            elif subtype == "get_context_usage":
                response = {"tokens": 1, "context_window": 200000}
            elif subtype == "interrupt":
                cancelled.set()
            emit(
                {
                    "type": "control_response",
                    "response": {
                        "subtype": "success",
                        "request_id": request["request_id"],
                        "response": response,
                    },
                }
            )
        elif request["type"] == "control_response":
            control_response(request)
        elif request["type"] == "user":
            user_message(request)
        else:
            raise ValueError("Unexpected stream-json message")


if __name__ == "__main__":
    try:
        main()
    finally:
        cancelled.set()
        if worker is not None:
            worker.join(timeout=1)
