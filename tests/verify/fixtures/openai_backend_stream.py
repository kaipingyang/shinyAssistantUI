#!/usr/bin/env python3
"""Local-only OpenAI-compatible SSE peer for installed backend verification."""

import argparse
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "".join(
            item.get("text", "") for item in value if item.get("type") == "text"
        )
    return ""


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port, root):
        super().__init__(("127.0.0.1", port), FixtureHandler)
        self.root = root
        self.lock = threading.Lock()
        self.serial = 0

    def record(self, event, **fields):
        with self.lock:
            with (self.root / "model-events.jsonl").open("a", encoding="utf-8") as out:
                out.write(json.dumps({"event": event, "at": time.time(), **fields}) + "\n")


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def do_GET(self):
        value = {"ready": True}
        if self.path == "/v1/models":
            value = {"object": "list", "data": [{"id": "gpt-4.1", "object": "model"}]}
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 4 * 1024 * 1024:
            self.send_error(413)
            return
        request = json.loads(self.rfile.read(length))
        messages = request.get("messages", [])
        users = [i for i, message in enumerate(messages) if message.get("role") == "user"]
        if not users:
            self.send_error(400)
            return
        last_user = users[-1]
        prompt = text_content(messages[last_user].get("content"))
        marker_match = re.search(r"\bAUI_[A-Z_]+\b", prompt)
        marker = marker_match.group(0) if marker_match else "AUI_NORMAL"
        mode = next(
            (
                mode
                for mode in (
                    "SHIELD", "APPROVE", "DENY", "CANCEL", "FAST", "SLOW",
                    "QUIET", "LONG", "NORMAL"
                )
                if f"AUI_{mode}" in prompt
            ),
            "NORMAL",
        )
        tools = {
            tool.get("function", {}).get("name", "")
            for tool in request.get("tools", [])
        }
        results = [
            message
            for message in messages[last_user + 1 :]
            if message.get("role") == "tool"
        ]
        with self.server.lock:
            self.server.serial += 1
            serial = self.server.serial
        self.server.record(
            "request", serial=serial, mode=mode, chars=len(prompt), tool_results=len(results)
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        def emit(delta, finish=None):
            value = {
                "id": f"fixture-{serial}",
                "object": "chat.completion.chunk",
                "created": 1,
                "model": "gpt-4.1",
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }
            data = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
            self.wfile.write(f"data: {data}\n\n".encode("utf-8"))
            self.wfile.flush()

        try:
            emit({"role": "assistant"})
            if mode in ("APPROVE", "DENY") and not results:
                name = "Echo" if "Echo" in tools else "Write"
                if name not in tools:
                    raise RuntimeError("Expected fixture tool was not registered")
                arguments = {"value": "APPROVED_PROOF"}
                if name == "Write":
                    arguments = {
                        "file_path": str(self.server.root / f"proof-{mode.lower()}.txt"),
                        "content": "APPROVED_PROOF",
                    }
                emit(
                    {
                        "tool_calls": [
                            {
                                "index": 0,
                                "id": f"fixture-tool-{serial}",
                                "type": "function",
                                "function": {
                                    "name": name,
                                    "arguments": json.dumps(arguments),
                                },
                            }
                        ]
                    }
                )
                emit({}, "tool_calls")
            else:
                if mode == "QUIET":
                    time.sleep(2)
                if mode == "LONG" and "LONG_INPUT_SENTINEL" not in prompt:
                    raise RuntimeError("Fragmented long input lost its suffix")
                if results:
                    chunks = [f"AUI_{mode}_DONE"]
                    interval = 0
                elif mode == "SHIELD":
                    chunks = ["Answer FAKEID", "001"] + [" safe"] * 18
                    interval = 0.05
                elif mode == "CANCEL":
                    chunks = [f"AUI_RUNNING_{i:04d} " for i in range(1000)]
                    interval = 0.02
                elif mode in ("FAST", "SLOW"):
                    chunks = [f"{marker}_{i:02d} " for i in range(200)]
                    interval = 0.001 if mode == "FAST" else 0.1
                else:
                    chunks = [f"{marker}_{i:02d} " for i in range(20)]
                    interval = 0.05
                for index, chunk in enumerate(chunks):
                    if index == 0:
                        self.server.record("first", serial=serial, mode=mode)
                    emit({"content": chunk})
                    if interval:
                        time.sleep(interval)
                emit({}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.server.record("done", serial=serial, mode=mode)
        except (BrokenPipeError, ConnectionResetError):
            self.server.record("cancelled", serial=serial, mode=mode)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    if not args.root.is_dir():
        raise ValueError("Fixture root must already exist")
    FixtureServer(args.port, args.root.resolve()).serve_forever()
