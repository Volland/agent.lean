#!/usr/bin/env python3
"""A scripted OpenAI-compatible endpoint for driver tests.

Request 1 must carry the user's prompt and gets two tool calls (`add`, `lookup`); request 2 must
carry both tool results and gets the final answer. Every request must carry
`Authorization: Bearer test-key`, injected by the driver from its credential store.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {"n": 0}


def reply(message):
    return {"id": "mock", "object": "chat.completion", "choices": [{"index": 0, "message": message,
            "finish_reason": "tool_calls" if message.get("tool_calls") else "stop"}],
            "usage": {"total_tokens": 42}}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))))
        if self.headers.get("authorization") != "Bearer test-key":
            return self.send(401, {"error": {"message": "missing or wrong credential"}})
        STATE["n"] += 1
        msgs = req["messages"]
        if STATE["n"] == 1:
            return self.send(200, reply({"role": "assistant", "content": None, "tool_calls": [
                {"id": "c1", "type": "function", "function": {"name": "add", "arguments": "{\"a\":2,\"b\":3}"}},
                {"id": "c2", "type": "function", "function": {"name": "lookup", "arguments": "{\"key\":\"region\"}"}}]}))
        tools = {m["tool_call_id"]: m["content"] for m in msgs if m["role"] == "tool"}
        if tools.get("c1") != "5" or tools.get("c2") != "\"value-of-region\"":
            return self.send(400, {"error": {"message": f"unexpected tool results {tools}"}})
        return self.send(200, reply({"role": "assistant", "content": "2+3=5 and region is value-of-region."}))


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 18080), H).serve_forever()
