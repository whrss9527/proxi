"""只运行临时文件、假 CLI 和回环 HTTP 服务，不启动应用或修改系统设置。"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
CI = ROOT / 'Scripts/ci'

class HelperTests(unittest.TestCase):
    def shell(self, body):
        return subprocess.run(['bash', '-c', f'source {shlex.quote(str(CI / "common.sh"))}; ' + body], capture_output=True, text=True)

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

    def test_status_reader_rejects_hang_malformed_and_nonzero(self):
        with tempfile.TemporaryDirectory() as tmp:
            cli = Path(tmp) / 'fake-cli'
            for body, valid in [('print(\'{"version":"1.2.3"}\')', True), ('print("not JSON")', False), ('raise SystemExit(1)', False), ('import time; time.sleep(30)', False)]:
                cli.write_text('#!/usr/bin/env python3\n' + body + '\n')
                cli.chmod(0o755)
                start = time.monotonic()
                result = subprocess.run(['python3', str(CI / 'read-status.py'), str(cli)], capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid, result.stderr)
                self.assertLess(time.monotonic() - start, 4)
                if valid:
                    self.assertEqual(json.loads(result.stdout)['version'], '1.2.3')

    def test_panel_wait_does_not_accept_an_existing_settings_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            counter = folder / 'calls'
            cli = folder / 'fake-cli'
            cli.write_text('#!/usr/bin/env python3\nimport json\nfrom pathlib import Path\np=Path(' + repr(str(counter)) + ')\nn=int(p.read_text())+1 if p.exists() else 1\np.write_text(str(n))\nprint(json.dumps({"interface":{"visibleWindows":1,"panelVisible":n>=3}}))\n')
            cli.chmod(0o755)
            # open 和进程检查只替换成测试函数；不会调用系统应用或启动 GUI。
            body = 'open() { return 0; }; pgrep() { return 0; }; export RUNNER_TEMP=' + shlex.quote(tmp) + '; show_panel ' + shlex.quote(str(cli))
            result = self.shell(body)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreaterEqual(int(counter.read_text()), 3)

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
