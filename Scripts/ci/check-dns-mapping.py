#!/usr/bin/env python3
"""用两个本机 DNS 服务验证实际内核的精确、子域名与默认解析去向。"""
import contextlib
import json
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


class DNSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        query, transport = self.request
        # 测试只发送一个标准 A 问题，保留问题原文，不处理其他 DNS 请求。
        end = 12
        while end < len(query) and query[end]:
            end += query[end] + 1
        end += 5
        if len(query) < end or query[end - 4:end] != b"\x00\x01\x00\x01":
            return
        header = query[:2] + struct.pack("!5H", 0x8180, 1, 1, 0, 0)
        answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 0, 4) + socket.inet_aton(self.server.answer)
        transport.sendto(header + query[12:end] + answer, self.client_address)


@contextlib.contextmanager
def nameserver(answer):
    with socketserver.UDPServer(("127.0.0.1", 0), DNSHandler) as server:
        server.answer = answer
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield "127.0.0.1:" + str(server.server_address[1])
        finally:
            server.shutdown()
            thread.join(timeout=2)


def controller(config):
    values = {}
    for line in config.read_text().splitlines():
        for key in ["external-controller", "secret"]:
            if line.startswith(key + ": "):
                values[key] = json.loads(line.split(": ", 1)[1])
    return values


def main():
    binary, config = sys.argv[1], Path(sys.argv[2])
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with nameserver("203.0.113.11") as default, nameserver("203.0.113.22") as mapped, tempfile.TemporaryDirectory() as temporary:
        document = Path(temporary) / "dns.json"
        document.write_text(json.dumps({"proxi": 1, "dns": {
            "enabled": True, "nameservers": [default], "fallback": [],
            "policies": {"exact.proxi.test": [mapped], "+.suffix.proxi.test": [mapped], "*.single.proxi.test": [mapped]},
        }}))
        subprocess.run([binary, "import", str(document)], check=True, timeout=30)
        try:
            # 导入返回后内核异步重载；等待实际解析得到目标结果，有截止时间。
            cases = {
                "exact.proxi.test": "203.0.113.22",
                "child.exact.proxi.test": "203.0.113.11",
                "suffix.proxi.test": "203.0.113.22",
                "a.b.suffix.proxi.test": "203.0.113.22",
                "a.single.proxi.test": "203.0.113.22",
                "single.proxi.test": "203.0.113.11",
                "a.b.single.proxi.test": "203.0.113.11",
                "unmapped.proxi.test": "203.0.113.11",
            }
            deadline = time.monotonic() + 30
            last = ""
            while time.monotonic() < deadline:
                try:
                    values = controller(config)
                    for domain, expected in cases.items():
                        url = "http://" + values["external-controller"] + "/dns/query?" + urllib.parse.urlencode({"name": domain, "type": "A"})
                        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + values["secret"]})
                        with opener.open(request, timeout=2) as response:
                            result = json.load(response)
                        actual = [item.get("data") for item in result.get("Answer", []) if item.get("type") == 1]
                        if actual != [expected]:
                            raise ValueError(domain + ": " + repr(actual) + ", expected " + expected)
                    print("DNS 映射实际解析通过：精确域名、所有子域名、一级子域名和默认解析共 8 项")
                    return
                except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
                    last = str(error)
                    time.sleep(0.5)
            raise RuntimeError("DNS 映射未按预期解析：" + last)
        finally:
            subprocess.run([binary, "undo"], check=True, timeout=30)


if __name__ == "__main__":
    main()
