"""Shared, isolated smart-HTTP fixture; repository data stays on Linux tmpfs."""
import base64
import http.server
import json
import os
import pathlib
import re
import shutil
import signal
import socket
import struct
import subprocess
import threading
import urllib.parse

ROOT = pathlib.Path('/dev/shm/orca-e2e-git')
ROOT.mkdir()
shutil.copytree('/opt/fixture/source.git', ROOT / 'source.git')
for index in range(4):
    repository = ROOT / f'w-{index}.git'
    subprocess.run(['git', 'init', '--bare', str(repository)], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(repository), 'config', 'http.receivepack', 'true'], check=True)
accepted, rejected = {}, {}
backend_failures = 0
lock = threading.Lock()


def host_gateway():
    with open('/proc/net/route', encoding='ascii') as routes:
        for line in routes.readlines()[1:]:
            fields = line.split()
            if fields[1] == '00000000':
                return socket.inet_ntoa(struct.pack('<I', int(fields[2], 16)))
    raise RuntimeError('default network gateway unavailable')


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=b'', headers=None):
        self.send_response(status)
        for key, value in (headers or {}).items():
            if key.lower() != 'content-length':
                self.send_header(key, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        limit = 8 * 1024 * 1024
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            chunks, size = [], 0
            while True:
                length = int(self.rfile.readline().split(b';')[0], 16)
                if length == 0:
                    while self.rfile.readline().strip():
                        pass
                    return b''.join(chunks)
                size += length
                if size > limit:
                    raise ValueError('body limit')
                chunks.append(self.rfile.read(length))
                if self.rfile.read(2) != b'\r\n':
                    raise ValueError('chunk boundary')
        length = int(self.headers.get('Content-Length', '0'))
        if length < 0 or length > limit:
            raise ValueError('body limit')
        return self.rfile.read(length)

    def handle_git(self):
        global backend_failures
        url = urllib.parse.urlsplit(self.path)
        if url.path == '/__metrics':
            with lock:
                result = {'accepted': dict(accepted), 'rejected': dict(rejected), 'backendFailures': backend_failures, 'hostGateway': host_gateway()}
            result['filesystem'] = subprocess.check_output(['stat', '-f', '-c', '%T', str(ROOT)], text=True).strip()
            result['refs'] = {
                f'w-{i}': subprocess.check_output(['git', '-C', str(ROOT / f'w-{i}.git'), 'for-each-ref', '--format=%(refname)', 'refs/heads'], text=True).splitlines()
                for i in range(4)
            }
            self.reply(200, json.dumps(result).encode(), {'Content-Type': 'application/json'})
            return
        match = re.fullmatch(r'/(source|w-[0-3])\.git/.*', url.path)
        if not match or '..' in url.path.split('/'):
            self.reply(404)
            return
        user = match[1]
        if user != 'source':
            provided = self.headers.get('Authorization')
            expected = 'Basic ' + base64.b64encode(f'{user}:dummy-{user}'.encode()).decode()
            with lock:
                if provided != expected:
                    key = user + (':invalid' if provided else ':missing')
                    rejected[key] = rejected.get(key, 0) + 1
                else:
                    accepted[user] = accepted.get(user, 0) + 1
            if provided != expected:
                self.reply(401, headers={'WWW-Authenticate': 'Basic realm="e2e"'})
                return
        try:
            body = self.body()
        except (ValueError, OverflowError):
            self.reply(400)
            return
        env = {
            **os.environ, 'GIT_PROJECT_ROOT': str(ROOT), 'GIT_HTTP_EXPORT_ALL': '1',
            'PATH_INFO': url.path, 'QUERY_STRING': url.query, 'REQUEST_METHOD': self.command,
            'CONTENT_TYPE': self.headers.get('Content-Type', ''),
            'HTTP_CONTENT_ENCODING': self.headers.get('Content-Encoding', ''),
            'HTTP_GIT_PROTOCOL': self.headers.get('Git-Protocol', ''),
            'CONTENT_LENGTH': str(len(body)), 'REMOTE_USER': user,
        }
        process = subprocess.Popen(['git', 'http-backend'], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            output, _ = process.communicate(body, timeout=5)
            if process.returncode:
                raise RuntimeError('backend exit')
            header, boundary, content = output.partition(b'\r\n\r\n')
            if not boundary:
                raise RuntimeError('backend framing')
            status, headers = 200, {}
            for line in header.decode().split('\r\n'):
                key, value = line.split(':', 1)
                if key.lower() == 'status':
                    status = int(value.strip().split()[0])
                else:
                    headers[key] = value.strip()
            self.reply(status, content, headers)
        except (subprocess.TimeoutExpired, RuntimeError):
            with lock:
                backend_failures += 1
            self.reply(500)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

    do_GET = handle_git
    do_POST = handle_git


http.server.ThreadingHTTPServer(('127.0.0.1', 18081), Handler).serve_forever()
