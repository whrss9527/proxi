#!/usr/bin/env python3
"""本地假发布：记录实际完成的请求，断言包名时不依赖应用的下载日志。"""
import argparse
import functools
import http.server
import json
import threading
import socketserver
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--directory', required=True)
parser.add_argument('--requests', required=True)
parser.add_argument('--port-file')
args = parser.parse_args()
lock = threading.Lock()

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_response(self, code, message=None):
        self.response_status = code
        super().send_response(code, message)

    def do_GET(self):
        super().do_GET()
        with lock, open(args.requests, 'a') as stream:
            stream.write(json.dumps({'method': 'GET', 'path': self.path, 'status': self.response_status}) + '\n')

class Server(http.server.ThreadingHTTPServer):
    # 跳过 HTTPServer 的反向 DNS，专用本地服务不需要主机名查询。
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = '127.0.0.1'
        self.server_port = self.server_address[1]

server = Server(('127.0.0.1', args.port), functools.partial(Handler, directory=args.directory))
if args.port_file:
    Path(args.port_file).write_text(str(server.server_port))
server.serve_forever()
