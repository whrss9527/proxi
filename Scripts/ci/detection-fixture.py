#!/usr/bin/env python3
"""独立回环 HTTP 代理替身；绝不向外转发请求。"""
import http.server
import sys
from pathlib import Path

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"fixture ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
