# -*- coding: utf-8 -*-
"""Loopback-only fixtures for real URLSession streaming; never calls an AI provider."""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

requests = []
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path != "/requests":
            self.send_error(404)
            return
        with lock:
            body = json.dumps(requests, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            with lock:
                requests.append({"body": body, "authorized": self.headers.get("Authorization") == "Bearer test-secret",
                                 "hasAuthorization": bool(self.headers.get("Authorization"))})
            route = self.path.split("/")[1]
            if route == "denied":
                self.send_error(401)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json" if route == "json" else "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            if route == "json":
                self.wfile.write(json.dumps({"choices": [{"message": {"content": "兼容服务的完整回复"}, "finish_reason": "stop"}]}).encode())
                return

            def event(obj):
                data = ("data: " + json.dumps(obj, ensure_ascii=False) + "\r\n\r\n").encode()
                # Split inside Chinese UTF-8 code points and across SSE line boundaries.
                for start in range(0, len(data), 7):
                    self.wfile.write(data[start:start + 7])
                    self.wfile.flush()
                time.sleep(1.4 if route == "ui" else 0.14)

            self.wfile.write(b": heartbeat\r\n\r\n")
            event({"choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]})
            if route == "empty":
                self.wfile.write(b"data: [DONE]\r\n\r\n")
                return
            chunks = ["## 记录事实\n", "已专注 25 分钟。\n", "样本较少，以下仅是初步观察。"]
            if len(body.get("messages", [])) >= 4:
                chunks = ["## 后续分析\n", "针对你的问题：" + body["messages"][-1]["content"] + "\n", "建议下一轮先明确可验证的完成标准。"]
            for index, chunk in enumerate(chunks):
                event({"choices": [{"index": 0, "delta": {"content": chunk}, "finish_reason": None}]})
                if index == 0:
                    if route == "broken":
                        return
                    if route in ("slow", "quittest"):
                        time.sleep(8 if route == "quittest" else 4)
                    if route == "error":
                        event({"error": {"message": "mock failure"}})
                        return
            if route == "length":
                event({"choices": [{"index": 0, "delta": {}, "finish_reason": "length"}]})
            else:
                event({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
                self.wfile.write(b"data: [DONE]\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
