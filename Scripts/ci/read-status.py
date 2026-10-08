#!/usr/bin/env python3
"""有界读取已有控制套接字；绝不经 CLI 启动或重新打开应用。"""
import json
import os
from pathlib import Path
import socket
import sys
import time

TIMEOUT = 2
MAX_RESPONSE = 1 << 20


def socket_path(binary):
    support = Path.home() / "Library/Application Support/Proxi"
    name = Path(binary).name
    if name == "ProxiEngine":
        support = Path(os.environ.get("PROXI_ENGINE_DIR") or support / "engine")
    elif name != "Proxi":
        raise ValueError(f"unsupported status target: {name}")
    return support / "control.sock"


def read_status(path):
    deadline = time.monotonic() + TIMEOUT

    def remaining():
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise TimeoutError("status request timed out")
        return seconds

    request = {"jsonrpc": "2.0", "id": 1, "method": "get_status", "params": {}, "client": "cli"}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(remaining())
        connection.connect(str(path))
        connection.settimeout(remaining())
        connection.sendall(json.dumps(request).encode() + b"\n")
        response = bytearray()
        while b"\n" not in response:
            connection.settimeout(remaining())
            chunk = connection.recv(65536)
            if not chunk:
                raise ValueError("control socket disconnected before a complete response")
            response.extend(chunk)
            if len(response) > MAX_RESPONSE:
                raise ValueError("status response exceeds size limit")
    message = json.loads(response.split(b"\n", 1)[0])
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0" or type(message.get("id")) is not int or message["id"] != 1:
        raise ValueError("invalid status response envelope")
    if "error" in message:
        raise ValueError("control socket returned an error")
    value = message.get("result")
    if not isinstance(value, dict):
        raise ValueError("status result must be an object")
    return value


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("expected the Proxi or ProxiEngine binary path")
        print(json.dumps(read_status(socket_path(sys.argv[1])), ensure_ascii=False))
    except (OSError, ValueError) as error:
        print(f"status read failed: {error}", file=sys.stderr)
        sys.exit(1)

