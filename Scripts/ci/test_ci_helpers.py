"""只运行临时文件、假控制套接字和回环 HTTP 服务，不启动应用或修改系统设置。"""
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile
import time
import threading
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
CI = ROOT / 'Scripts/ci'

def status_response(value):
    return json.dumps({'jsonrpc': '2.0', 'id': 1, 'result': value}).encode() + b'\n'


class StatusServer:
    """临时套接字替身；记录请求，覆盖延迟监听、分段回应和断连。"""
    def __init__(self, path, respond, delay=0):
        self.path = path
        self.respond = respond
        self.delay = delay
        self.requests = []
        self.errors = []
        self.stopped = threading.Event()
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def serve(self):
        try:
            if self.stopped.wait(self.delay):
                return
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(self.path))
                server.listen()
                server.settimeout(0.1)
                self.ready.set()
                while not self.stopped.is_set():
                    try:
                        connection, _ = server.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connection.settimeout(3)
                        request = bytearray()
                        while b'\n' not in request:
                            chunk = connection.recv(4096)
                            if not chunk:
                                break
                            request.extend(chunk)
                        self.requests.append(json.loads(request))
                        try:
                            self.respond(connection, len(self.requests))
                        except (BrokenPipeError, ConnectionResetError):
                            pass
        except Exception as error:
            self.errors.append(error)
            self.ready.set()

    def __enter__(self):
        self.thread.start()
        if not self.delay and not self.ready.wait(3):
            raise AssertionError('fixture socket did not start')
        if self.errors:
            raise AssertionError(f'fixture socket failed: {self.errors}')
        return self

    def __exit__(self, *_):
        self.stopped.set()
        self.thread.join(timeout=4)
        if self.thread.is_alive() or self.errors:
            raise AssertionError(f'fixture socket failed: {self.errors}')


class HelperTests(unittest.TestCase):
    def shell(self, body, env=None):
        return subprocess.run(['bash', '-c', f'source {shlex.quote(str(CI / "common.sh"))}; ' + body], capture_output=True, text=True, cwd=ROOT, env=env, timeout=15)

    def test_detection_fixture_has_no_dns_dependency(self):
        with tempfile.TemporaryDirectory() as tmp:
            port_file = Path(tmp) / 'port'
            # 替换反向 DNS；服务若误调用它就立即失败，不能靠延长等待掩盖。
            launcher = "import socket,runpy,sys; socket.getfqdn=lambda *_: (_ for _ in ()).throw(RuntimeError('unexpected DNS')); sys.argv=['fixture',sys.argv[1]]; runpy.run_path(sys.argv[2] if len(sys.argv)>2 else 'Scripts/ci/detection-fixture.py',run_name='__main__')"
            server = subprocess.Popen(['python3', '-c', launcher, str(port_file)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 4
                while not port_file.exists() and server.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(port_file.exists(), 'fixture did not bind without DNS')
                with urllib.request.urlopen(f'http://127.0.0.1:{port_file.read_text()}/health', timeout=2) as response:
                    self.assertEqual(response.read(), b'fixture ok')
            finally:
                server.terminate()
                server.communicate(timeout=3)

    def test_wait_retries_and_fails_on_timeout(self):
        with tempfile.TemporaryDirectory() as tmp:
            flag = shlex.quote(str(Path(tmp) / 'ready'))
            ready = self.shell(f'(sleep 0.4; touch {flag}) & wait_for 3 fixture test -f {flag}')
            self.assertEqual(ready.returncode, 0, ready.stderr)
        start = time.monotonic()
        failed = self.shell('wait_for 1 never-ready false')
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('等待超时', failed.stderr)
        self.assertLess(time.monotonic() - start, 3)

    def test_continuous_observation_detects_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            flag = shlex.quote(str(Path(tmp) / 'still-off'))
            result = self.shell(f'touch {flag}; (sleep 0.4; rm {flag}) & assert_for 2 invariant test -f {flag}')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('条件失效', result.stderr)

    def test_update_waits_for_download_and_stops_sending_after_progress(self):
        # 用 shell 函数替代 open，不接触真实应用或 Launch Services。
        result = self.shell('''set -e
calls=0
fixture_requested() {
    [[ $1 == 8766 && $2 == /ProxySwitch-macos-arm64.zip ]] || return 99
    ((calls >= 3))
}
open() {
    [[ $# == 3 && $1 == -a && $2 == "/fake/Old App.app" && $3 == proxyswitch://update ]] || return 99
    calls=$((calls + 1))
    ((calls >= 2))
}
wait_for 3 download app_update_requested "/fake/Old App.app" proxyswitch://update 8766 /ProxySwitch-macos-arm64.zip
app_update_requested "/fake/Old App.app" proxyswitch://update 8766 /ProxySwitch-macos-arm64.zip
[[ $calls == 3 ]]
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepting_update_url_does_not_count_as_download_readiness(self):
        result = self.shell('open() { return 0; }; fixture_requested() { return 1; }; wait_for 0 download app_update_requested /fake/App.app proxyswitch://update 8766 /app.zip')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('等待超时', result.stderr)

    def test_fixture_readiness_requires_successful_get_not_health_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'fixture-requests-8766.jsonl'
            records = [{'method': 'HEAD', 'path': '/latest.json', 'status': 200},
                       {'method': 'GET', 'path': '/latest.json', 'status': 404}]
            log.write_text(''.join(json.dumps(item) + '\n' for item in records))
            self.assertNotEqual(self.shell('fixture_requested 8766 /latest.json', env={**os.environ, 'RUNNER_TEMP': tmp}).returncode, 0)
            records.append({'method': 'GET', 'path': '/latest.json', 'status': 200})
            log.write_text(''.join(json.dumps(item) + '\n' for item in records))
            self.assertEqual(self.shell('fixture_requested 8766 /latest.json', env={**os.environ, 'RUNNER_TEMP': tmp}).returncode, 0)

    def status_env(self, tmp):
        return {**os.environ, 'HOME': tmp, 'RUNNER_TEMP': tmp, 'PROXI_ENGINE_DIR': ''}

    def status_path(self, tmp, engine=False):
        support = Path(tmp) / 'Library/Application Support/Proxi'
        return (support / 'engine' if engine else support) / 'control.sock'

    def read_status(self, tmp, binary='Proxi', env=None):
        return subprocess.run(['python3', str(CI / 'read-status.py'), binary],
                              capture_output=True, text=True, timeout=4,
                              env=env or self.status_env(tmp))

    def test_status_reader_never_executes_cli_when_socket_not_ready(self):
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='proxi-ci-') as tmp:
            cli = Path(tmp) / 'Proxi'
            marker = Path(tmp) / 'launched'
            cli.write_text('#!/bin/sh\ntouch ' + shlex.quote(str(marker)) + '\n')
            cli.chmod(0o755)
            path = self.status_path(tmp)
            path.parent.mkdir(parents=True)
            # 缺失和遗留但未监听的套接字，都应立即失败且不启动 CLI。
            for stale in [False, True]:
                if stale:
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                        connection.bind(str(path))
                result = self.read_status(tmp, str(cli))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn('status read failed', result.stderr)
                self.assertFalse(marker.exists())

    def test_status_polling_waits_for_socket_without_opening_windows(self):
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='proxi-ci-') as tmp:
            value = {'interface': {'visibleWindows': 0}}
            with StatusServer(self.status_path(tmp), lambda c, n: c.sendall(status_response(value)), delay=0.4) as server:
                result = self.shell("wait_json /not-an-executable/Proxi '.interface.visibleWindows == 0' 3", env=self.status_env(tmp))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(server.requests, [{'jsonrpc': '2.0', 'id': 1, 'method': 'get_status', 'params': {}, 'client': 'cli'}])
            self.assertEqual(json.loads((Path(tmp) / 'status-last.json').read_text()), value)

    def test_status_reader_decodes_fragmented_response(self):
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='proxi-ci-') as tmp:
            def respond(connection, _):
                data = status_response({'version': '1.2.3'})
                connection.sendall(data[:15])
                time.sleep(0.05)
                connection.sendall(data[15:])
            with StatusServer(self.status_path(tmp), respond):
                result = self.read_status(tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {'version': '1.2.3'})

    def test_status_reader_selects_main_and_engine_sockets(self):
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='proxi-ci-') as tmp:
            for binary, path, env in [
                ('Proxi', self.status_path(tmp), self.status_env(tmp)),
                ('ProxiEngine', self.status_path(tmp, engine=True), self.status_env(tmp)),
                ('ProxiEngine', Path(tmp) / 'override/control.sock', {**self.status_env(tmp), 'PROXI_ENGINE_DIR': str(Path(tmp) / 'override')}),
            ]:
                with self.subTest(binary=binary, path=path), StatusServer(path, lambda c, n: c.sendall(status_response({'target': binary}))):
                    result = self.read_status(tmp, binary, env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {'target': binary})
            self.assertNotEqual(self.read_status(tmp, 'unsupported').returncode, 0)

    def test_status_reader_rejects_invalid_rpc_and_disconnects(self):
        responses = [b'', b'{"jsonrpc":', b'not JSON\n', b'\xff\n', b'[]\n',
                     b'{}\n', b'{"jsonrpc":"2.0","id":2,"result":{}}\n',
                     b'{"jsonrpc":"2.0","id":true,"result":{}}\n',
                     b'{"jsonrpc":"2.0","id":1,"error":{"code":-32001}}\n',
                     b'{"jsonrpc":"2.0","id":1,"result":[]}\n',
                     b'x' * ((1 << 20) + 1)]
        for response in responses:
            with self.subTest(response=response[:80]), tempfile.TemporaryDirectory(dir='/tmp', prefix='proxi-ci-') as tmp:
                with StatusServer(self.status_path(tmp), lambda c, n: c.sendall(response)):
                    result = self.read_status(tmp)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn('status read failed', result.stderr)
                self.assertNotIn('Traceback', result.stderr)

    def test_status_reader_bounds_stalled_and_trickling_responses(self):
        def stall(connection, _):
            time.sleep(2.2)
        def trickle(connection, _):
            for _ in range(20):
                connection.sendall(b' ')
                time.sleep(0.2)
        for respond in [stall, trickle]:
            with self.subTest(respond=respond.__name__), tempfile.TemporaryDirectory(dir='/tmp', prefix='proxi-ci-') as tmp:
                with StatusServer(self.status_path(tmp), respond):
                    start = time.monotonic()
                    result = self.read_status(tmp)
                    elapsed = time.monotonic() - start
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('timed out', result.stderr)
                self.assertLess(elapsed, 3.5)

    def test_panel_wait_does_not_accept_an_existing_settings_window(self):
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='proxi-ci-') as tmp:
            def respond(connection, count):
                connection.sendall(status_response({'interface': {'visibleWindows': 1, 'panelVisible': count >= 3}}))
            with StatusServer(self.status_path(tmp), respond) as server:
                # open 只替换成测试函数；不会调用系统应用或启动 GUI。
                result = self.shell('open() { return 0; }; show_panel Proxi', env=self.status_env(tmp))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreaterEqual(len(server.requests), 3)

    def test_status_timeout_reports_last_snapshot_and_retains_no_window_assertion(self):
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='proxi-ci-') as tmp:
            value = {'interface': {'visibleWindows': 1}}
            with StatusServer(self.status_path(tmp), lambda c, n: c.sendall(status_response(value))):
                result = self.shell("wait_json Proxi '.interface.visibleWindows == 0' 1", env=self.status_env(tmp))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('等待超时', result.stderr)
            self.assertIn('"visibleWindows": 1', result.stderr)
            self.assertEqual(json.loads((Path(tmp) / 'status-last.json').read_text()), value)

    def test_status_timeout_reports_read_error_without_stale_snapshot(self):
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='proxi-ci-') as tmp:
            snapshot = Path(tmp) / 'status-last.json'
            snapshot.write_text('{"stale":true}')
            result = self.shell("wait_json Proxi 'has(\"proxy\")' 1", env=self.status_env(tmp))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('未收到有效状态', result.stderr)
            self.assertIn('status read failed', result.stderr)
            self.assertFalse(snapshot.exists())
            self.assertIn('status read failed', (Path(tmp) / 'status-read.log').read_text())

    def test_gui_artifacts_include_polling_snapshot_and_errors(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        uploads = [block for block in workflow.split('- uses: actions/upload-artifact@v4')
                   if '${{ runner.temp }}/*-status.json' in block]
        self.assertEqual(len(uploads), 6)
        for block in uploads:
            self.assertIn('${{ runner.temp }}/status-last.json', block)
            self.assertIn('${{ runner.temp }}/*.log', block)

    def test_result_gate_rejects_skipped_cancelled_and_missing(self):
        names = ['scripts', 'build', 'smoke', 'migration', 'update', 'rename', 'signing', 'extension']
        results = {name: {'result': 'success'} for name in names}
        def run(value):
            return subprocess.run(['python3', str(CI / 'check-results.py')], env={**os.environ, 'CI_NEEDS': json.dumps(value)}, capture_output=True)
        self.assertEqual(run(results).returncode, 0)
        for state in ['failure', 'cancelled', 'skipped']:
            bad = {**results, 'extension': {'result': state}}
            self.assertNotEqual(run(bad).returncode, 0)
        del results['extension']
        self.assertNotEqual(run(results).returncode, 0)

    def test_fixture_records_served_assets_and_http_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'app.zip').write_bytes(b'reviewed-fixture')
            port_file = folder / 'port'
            requests = folder / 'requests.jsonl'
            server = subprocess.Popen(['python3', str(CI / 'fixture-server.py'), '--port', '0', '--directory', tmp, '--requests', str(requests), '--port-file', str(port_file)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not port_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                port = int(port_file.read_text())
                with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}/app.zip', method='HEAD')) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.read(), b'')
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/app.zip') as response:
                    self.assertEqual(response.read(), b'reviewed-fixture')
                with self.assertRaises(urllib.error.HTTPError):
                    urllib.request.urlopen(f'http://127.0.0.1:{port}/missing.zip')
                while (not requests.exists() or len(requests.read_text().splitlines()) < 2) and time.monotonic() < deadline:
                    time.sleep(0.05)
                records = [json.loads(line) for line in requests.read_text().splitlines()]
                self.assertEqual([(r['path'], r['status']) for r in records], [('/app.zip', 200), ('/missing.zip', 404)])
            finally:
                server.terminate()
                server.wait(timeout=5)

if __name__ == '__main__':
    unittest.main()
