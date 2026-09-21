#!/usr/bin/env python3
"""Local-only lifecycle peer. It never executes tools or contacts a provider."""

import datetime
import json
import os
from pathlib import Path
import re
import sys
import threading
import time
import uuid


ROOT = Path(os.environ["AUI_LONG_TASK_ROOT"]).resolve()
CONFIG = Path(os.environ["CLAUDE_CONFIG_DIR"]).resolve()
WAIT_SECONDS = float(os.environ.get("AUI_LONG_TASK_SECONDS", "125"))
if ROOT != Path(os.environ["HOME"]).resolve() or CONFIG.parent != ROOT:
    raise ValueError("The lifecycle peer requires an isolated fixture HOME")
if not 1 <= WAIT_SECONDS <= 150:
    raise ValueError("Invalid bounded lifecycle workload")

SESSION = None
if "--resume" in sys.argv:
    SESSION = sys.argv[sys.argv.index("--resume") + 1]
SESSION = str(uuid.UUID(SESSION)) if SESSION else str(uuid.uuid4())
TRANSCRIPT = CONFIG / "projects" / re.sub(r"[^a-zA-Z0-9]", "-", str(ROOT))
TRANSCRIPT.mkdir(parents=True, exist_ok=True)
TRANSCRIPT = TRANSCRIPT / f"{SESSION}.jsonl"
LOCK = threading.RLock()
STOP = threading.Event()
WORKERS = []
PENDING = None
TURN = 0
STOP_REQUESTS = 0
PARENT = None
if TRANSCRIPT.exists():
    for line in TRANSCRIPT.read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        if not record.get("isSidechain"):
            PARENT = record["uuid"]


def emit(value):
    with LOCK:
        sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def observe(kind, **values):
    value = dict(kind=kind, session=SESSION, pid=os.getpid(), at=time.monotonic(), **values)
    with LOCK, (ROOT / "peer-events.jsonl").open("a", encoding="utf-8") as output:
        output.write(json.dumps(value, separators=(",", ":")) + "\n")


def tool_key(value):
    return value if value.startswith(SESSION) else f"{SESSION}-{value}"


def persist(role, content, sidechain=False, compact_summary=False):
    global PARENT
    with LOCK:
        record = {
            "type": role,
            "uuid": str(uuid.uuid4()),
            "parentUuid": PARENT,
            "sessionId": SESSION,
            "cwd": str(ROOT),
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "message": {"role": role, "content": content},
        }
        if sidechain:
            record["isSidechain"] = True
        else:
            PARENT = record["uuid"]
        if compact_summary:
            record["isCompactSummary"] = True
            record["isVisibleInTranscriptOnly"] = True
        with TRANSCRIPT.open("a", encoding="utf-8") as output:
            output.write(json.dumps(record, separators=(",", ":")) + "\n")
            output.flush()
        return record


def event(value, parent=None):
    emit({
        "type": "stream_event", "session_id": SESSION, "uuid": str(uuid.uuid4()),
        "parent_tool_use_id": tool_key(parent) if parent else None, "event": value,
    })


def assistant(value, parent=None):
    content = [{"type": "text", "text": value}]
    record = persist("assistant", content, sidechain=parent is not None)
    emit({
        "type": "assistant", "session_id": SESSION, "uuid": record["uuid"],
        "parent_tool_use_id": tool_key(parent) if parent else None,
        "message": {"role": "assistant", "model": "local-lifecycle-peer", "content": content},
    })


def tool(tool_id, name="Agent", parent=None):
    tool_id = tool_key(tool_id)
    block = {"type": "tool_use", "id": tool_id, "name": name, "input": {"command": "echo synthetic"}}
    record = persist("assistant", [block], sidechain=parent is not None)
    emit({
        "type": "assistant", "session_id": SESSION, "uuid": record["uuid"],
        "parent_tool_use_id": tool_key(parent) if parent else None,
        "message": {"role": "assistant", "model": "local-lifecycle-peer", "content": [block]},
    })
    return tool_id


def tool_result(tool_id, value):
    content = [{"type": "tool_result", "tool_use_id": tool_key(tool_id), "content": value}]
    record = persist("user", content)
    emit({"type": "user", "session_id": SESSION, "uuid": record["uuid"],
          "message": {"role": "user", "content": content}})


def result(value="", error=False):
    emit({
        "type": "result",
        "subtype": "error_during_execution" if error else "success",
        "session_id": SESSION, "is_error": error, "num_turns": 1,
        "duration_ms": 1, "duration_api_ms": 1, "total_cost_usd": 0,
        "usage": {"input_tokens": 1, "output_tokens": 1},
        "stop_reason": "end_turn", "result": value,
        "errors": ["Synthetic upstream failure"] if error else [],
    })


def task(task_id, kind="started", tool_id=None, status=None):
    value = {
        "type": "system", "subtype": f"task_{kind}", "session_id": SESSION,
        "uuid": str(uuid.uuid4()), "task_id": task_id,
        "description": task_id, "task_type": "local_agent",
    }
    if tool_id:
        value["tool_use_id"] = tool_key(tool_id)
    if status:
        value.update(status=status, summary=f"{task_id}: {status}", output_file="")
    emit(value)
    observe(f"task_{kind}", task_id=task_id, status=status)


def worker(callback):
    thread = threading.Thread(target=callback, daemon=True)
    WORKERS.append(thread)
    thread.start()


def permission(background, sidecar=True):
    global PENDING
    tool_id = "background-approval-tool" if background else "foreground-approval-tool"
    task_id = "background-approval-agent" if background else "foreground-approval-agent"
    tool_id = tool(tool_id, name="Bash", parent="approval-agent-call" if background else None)
    PENDING = {
        "request_id": f"permission-{TURN}", "tool_id": tool_id,
        "task_id": task_id, "background": background, "started": time.monotonic(),
    }
    if sidecar:
        task("sidecar", tool_id="sidecar-call")
    emit({
        "type": "control_request", "request_id": PENDING["request_id"],
        "request": {
            "subtype": "can_use_tool", "tool_name": "Bash",
            "tool_use_id": tool_id, "agent_id": task_id,
            "input": {"command": "echo synthetic"},
            "title": "Long background approval" if background else "Long foreground approval",
            "description": "Synthetic lifecycle check; no command is executed.",
        },
    })
    observe("permission_opened", background=background)


def long_background():
    assistant("BACKGROUND_LONG_STARTED")
    started = time.monotonic()
    observe("background_opened")
    if STOP.wait(WAIT_SECONDS):
        result("Background interrupted", error=True)
        return
    assistant("BACKGROUND_COMPLETED_125S")
    task("background-long", "notification", status="completed")
    result("BACKGROUND_COMPLETED_125S")
    observe("background_completed", seconds=time.monotonic() - started)


def child_only():
    if STOP.wait(1):
        return
    event({"type": "content_block_delta", "index": 0,
           "delta": {"type": "text_delta", "text": "CHILD_PRIVATE_TEXT"}}, parent="parented-call")
    assistant("CHILD_PRIVATE_TEXT", parent="parented-call")
    if not STOP.wait(1):
        task("parented-child", "notification", status="completed")


def user(request):
    global TURN
    content = request["message"]["content"]
    if isinstance(content, list):
        content = "".join(part.get("text", "") for part in content)
    if content not in (
        "LONG_BACKGROUND", "LONG_APPROVAL", "IDLE_APPROVAL", "HISTORY_APPROVAL", "PARENTED_ONLY",
        "ERROR_RECOVERY", "EXIT_RECOVERY", "NORMAL", "AFTER_BACKGROUND", "/compact",
    ):
        raise ValueError("Unexpected synthetic lifecycle prompt")
    TURN += 1
    persist("user", content)
    observe("user", command=content)
    if content == "LONG_BACKGROUND":
        tool("background-call")
        task("background-long", tool_id="background-call")
        tool_result("background-call", "Synthetic background agent started")
        assistant("BACKGROUND_ARMED")
        result("BACKGROUND_ARMED")
        worker(long_background)
    elif content in ("LONG_APPROVAL", "IDLE_APPROVAL", "HISTORY_APPROVAL"):
        background = content != "LONG_APPROVAL"
        task_id = "background-approval-agent" if background else "foreground-approval-agent"
        tool("approval-agent-call")
        task(task_id, tool_id="approval-agent-call")
        tool_result("approval-agent-call", "Synthetic approval agent started")
        if background:
            assistant("BACKGROUND_APPROVAL_ARMED")
            result("BACKGROUND_APPROVAL_ARMED")

            def open_later():
                release = ROOT / f"release-permission-{SESSION}"
                deadline = time.monotonic() + 150
                while not STOP.is_set() and not release.exists():
                    if time.monotonic() >= deadline:
                        result("Approval fixture was not released", error=True)
                        return
                    STOP.wait(0.05)
                if not STOP.is_set():
                    permission(True, sidecar=content != "HISTORY_APPROVAL")
            worker(open_later)
        else:
            permission(False)
    elif content == "PARENTED_ONLY":
        tool("parented-call")
        task("parented-child", tool_id="parented-call")
        tool_result("parented-call", "Synthetic child started")
        assistant("PARENTED_TASK_ARMED")
        result("PARENTED_TASK_ARMED")
        worker(child_only)
    elif content == "ERROR_RECOVERY":
        result(error=True)

        def persist_later():
            if not STOP.wait(3):
                persist("assistant", [{"type": "text", "text": "RECOVERED_AFTER_ERROR"}])
                observe("late_error_reply")
        worker(persist_later)
    elif content == "EXIT_RECOVERY":
        event({"type": "content_block_delta", "index": 0,
               "delta": {"type": "text_delta", "text": "BEFORE_EOF"}})
        persist("assistant", [{"type": "text", "text": "RECOVERED_AFTER_EXIT"}])
        observe("exit_without_result")
        sys.stdout.flush()
        os._exit(0)
    elif content in ("NORMAL", "AFTER_BACKGROUND"):
        value = "NORMAL_DONE" if content == "NORMAL" else "AFTER_BACKGROUND_DONE"
        assistant(value)
        result(value)
    elif content == "/compact":
        observe("compact_started")
        emit({"type": "system", "subtype": "status", "status": "compacting",
              "session_id": SESSION})

        def compact():
            if STOP.wait(1):
                return
            persist("user", "SYNTHETIC_COMPACT_SUMMARY", compact_summary=True)
            emit({"type": "system", "subtype": "compact_boundary", "session_id": SESSION,
                  "compact_metadata": {"trigger": "manual", "pre_tokens": 1234}})
            result("SYNTHETIC_COMPACT_SUMMARY")
            observe("compact_completed")
        worker(compact)


def decision(request):
    global PENDING
    response = request["response"]
    if PENDING is None or response["request_id"] != PENDING["request_id"]:
        raise ValueError("Unexpected synthetic approval response")
    pending = PENDING
    PENDING = None
    allowed = response["response"]["behavior"] == "allow"
    observe("permission_decided", background=pending["background"], allowed=allowed,
            seconds=time.monotonic() - pending["started"])
    content = [{
        "type": "tool_result", "tool_use_id": pending["tool_id"],
        "content": "APPROVED_RESULT" if allowed else "Denied", "is_error": not allowed,
    }]
    record = persist("user", content)
    emit({"type": "user", "session_id": SESSION, "uuid": record["uuid"],
          "message": {"role": "user", "content": content}})
    task(pending["task_id"], "notification", status="completed" if allowed else "stopped")
    value = "BACKGROUND_APPROVAL_COMPLETED" if pending["background"] else "APPROVAL_COMPLETED"
    if allowed:
        assistant(value)
    result(value if allowed else "Denied", error=not allowed)


def control(request):
    global STOP_REQUESTS
    subtype = request["request"]["subtype"]
    response = {}
    if subtype == "initialize":
        response = {"commands": [], "models": [], "output_styles": []}
    elif subtype == "get_context_usage":
        response = {"totalTokens": 1, "rawMaxTokens": 200000}
        if os.environ.get("AUI_LONG_TASK_MODE") == "controls":
            response = {
                "totalTokens": 1234, "rawMaxTokens": 200000,
                "categories": [
                    {"name": "Synthetic instructions", "tokens": 1000},
                    {"name": "Synthetic messages", "tokens": 234},
                ],
            }
    elif subtype == "set_model":
        model = request["request"]["model"]
        if model not in ("opus", "haiku", "sonnet"):
            raise ValueError("Unexpected synthetic model")
        observe("model_requested", model=model)
        if STOP.wait(0.65):
            return
        if model == "haiku":
            emit({"type": "control_response", "response": {
                "subtype": "error", "request_id": request["request_id"],
                "error": "Synthetic model rejection",
            }})
            observe("model_rejected", model=model)
            return
        observe("model_applied", model=model)
    elif subtype == "set_permission_mode":
        mode = request["request"]["mode"]
        if mode != "plan":
            raise ValueError("Unexpected synthetic permission mode")
        observe("permission_applied", mode=mode)
    elif subtype == "interrupt":
        observe("interrupt")
        STOP.set()
    elif subtype == "stop_task":
        if request["request"]["task_id"] != "sidecar":
            raise ValueError("This fixture only permits stopping its sidecar")
        STOP_REQUESTS += 1
        if STOP_REQUESTS == 1:
            emit({"type": "control_response", "response": {
                "subtype": "error", "request_id": request["request_id"],
                "error": "Synthetic Stop rejection; retry is safe.",
            }})
            observe("stop_rejected")
            return
        task("sidecar", "notification", status="stopped")
        observe("stop_confirmed")
    else:
        raise ValueError("Unexpected synthetic control request")
    emit({"type": "control_response", "response": {
        "subtype": "success", "request_id": request["request_id"], "response": response,
    }})


def main():
    if "--version" in sys.argv:
        print("2.1.0 (local lifecycle fixture)")
        return
    observe("connected")
    for line in sys.stdin:
        request = json.loads(line)
        if request["type"] == "control_request":
            control(request)
        elif request["type"] == "control_response":
            decision(request)
        elif request["type"] == "user":
            user(request)
        else:
            raise ValueError("Unexpected lifecycle frame")


if __name__ == "__main__":
    try:
        main()
    finally:
        STOP.set()
        for item in WORKERS:
            item.join(timeout=1)
