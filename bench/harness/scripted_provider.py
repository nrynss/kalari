#!/usr/bin/env python3
"""A loopback OpenAI-compatible provider with canned tool calls, for the rehearsal.

It is not a model and it has no network: it answers on 127.0.0.1 and returns a
fixed sequence of assistant messages. The sequence is chosen from the phase
marker in the latest user message:

  PHASE=payouts      write a canary by relative path, then stop
  PHASE=settlements  write a canary, write the correct consumer, run it, then stop

Title requests (no tools) get a title. The server writes its bound port to
--port-file so the shell can point OpenCode at it.
"""
import argparse
import http.server
import json
import os
import threading


class State:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.requests = 0
        self.actions = []
        self.consumer = open(args.consumer_source).read()
        self.trace = open(args.trace, "a")

    def choose(self, body):
        tools = {t.get("function", {}).get("name") for t in (body.get("tools") or [])}
        messages = body.get("messages") or []
        last_user = max((i for i, m in enumerate(messages) if m.get("role") == "user"), default=-1)
        text = ""
        if last_user >= 0:
            content = messages[last_user].get("content")
            text = content if isinstance(content, str) else json.dumps(content)
        phase = "settlements" if "PHASE=settlements" in text else (
            "payouts" if "PHASE=payouts" in text else ""
        )
        if not tools:
            return {"kind": "title", "text": "Scripted workspace resume"}
        if not phase:
            return {"kind": "text", "text": "scripted provider: no phase marker"}
        steps = sum(1 for m in messages[last_user + 1:] if m.get("role") == "tool")
        if "write" not in tools:
            return {"kind": "text", "text": "scripted provider: write tool missing"}
        if phase == "payouts":
            if steps == 0:
                return {
                    "kind": "call",
                    "name": "write",
                    "arguments": {
                        "path": "payouts-canary.txt",
                        "content": "payouts\n",
                    },
                }
            return {"kind": "text", "text": "payouts phase complete"}
        if "shell" not in tools:
            return {"kind": "text", "text": "scripted provider: shell tool missing"}
        if steps == 0:
            return {
                "kind": "call",
                "name": "write",
                "arguments": {
                    "path": "settlements-canary.txt",
                    "content": "settlements\n",
                },
            }
        if steps == 1:
            return {
                "kind": "call",
                "name": "write",
                "arguments": {
                    "path": "settlement_reconcile.py",
                    "content": self.consumer,
                },
            }
        if steps == 2:
            return {
                "kind": "call",
                "name": "shell",
                "arguments": {
                    "command": (
                        "python3 settlement_reconcile.py "
                        f"--base-url {self.args.api_base_url} --out settlements.jsonl"
                    ),
                    "description": "run the upgraded settlements consumer",
                },
            }
        return {"kind": "text", "text": "settlements phase complete"}

    def record(self, body, action):
        self.requests += 1
        self.actions.append(action["kind"])
        messages = body.get("messages") or []
        blob = json.dumps(messages, default=str)
        entry = {
            "request": self.requests,
            "path": body.get("path"),
            "model": body.get("model"),
            "stream": bool(body.get("stream")),
            "tools": sorted(t.get("function", {}).get("name") for t in (body.get("tools") or [])),
            "messages": len(messages),
            "payouts_context": "PHASE=payouts" in blob,
            "settlements_context": "PHASE=settlements" in blob,
            "action": action,
        }
        self.trace.write(json.dumps(entry) + "\n")
        self.trace.flush()


def sse_chunks(action, model):
    if action["kind"] == "title":
        yield {"choices": [{"index": 0, "delta": {"role": "assistant", "content": action["text"]},
                            "finish_reason": None}]}
        yield {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
        return
    if action["kind"] == "text":
        yield {"choices": [{"index": 0, "delta": {"role": "assistant", "content": action["text"]},
                            "finish_reason": None}]}
        yield {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
        return
    call = {
        "index": 0,
        "id": "scripted-call",
        "type": "function",
        "function": {
            "name": action["name"],
            "arguments": json.dumps(action["arguments"]),
        },
    }
    yield {"choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                        "finish_reason": None}]}
    yield {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}


def make_handler(state):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length)
            try:
                body = json.loads(raw)
            except ValueError:
                self.send_error(400, "invalid JSON")
                return
            body["path"] = self.path
            with state.lock:
                action = state.choose(body)
                state.record(body, action)
            if body.get("stream") is False:
                message = {"role": "assistant", "content": action.get("text", "")}
                if action["kind"] == "call":
                    message = {
                        "role": "assistant",
                        "content": None,
                        "tool_calls": [{
                            "id": "scripted-call",
                            "type": "function",
                            "function": {
                                "name": action["name"],
                                "arguments": json.dumps(action["arguments"]),
                            },
                        }],
                    }
                doc = {
                    "id": "scripted",
                    "object": "chat.completion",
                    "created": 1,
                    "model": body.get("model", "scripted"),
                    "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
                }
                data = json.dumps(doc).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            for chunk in sse_chunks(action, body.get("model", "scripted")):
                doc = {
                    "id": "scripted",
                    "object": "chat.completion.chunk",
                    "created": 1,
                    "model": body.get("model", "scripted"),
                    **chunk,
                }
                self.wfile.write(("data: " + json.dumps(doc) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--consumer-source", required=True)
    ap.add_argument("--api-base-url", required=True)
    args = ap.parse_args()
    state = State(args)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), make_handler(state))
    port = server.server_address[1]
    with open(args.port_file, "w") as f:
        f.write(str(port) + "\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
