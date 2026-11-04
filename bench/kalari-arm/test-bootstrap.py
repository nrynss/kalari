#!/usr/bin/env python3
"""Verify the local bootstrap cannot forward before all tools appear."""
import http.server
import json
import threading
import time
import urllib.error
import urllib.request
import bootstrap_proxy

calls = []
class Upstream(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        calls.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(200); self.end_headers(); self.wfile.write(b'first\n'); self.wfile.flush(); time.sleep(2); self.wfile.write(b'second\n'); self.wfile.flush()

upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
threading.Thread(target=upstream.serve_forever, daemon=True).start()
proxy, state = bootstrap_proxy.start(f'http://127.0.0.1:{upstream.server_port}/v1', '/fixture/README.md')
url = f'http://127.0.0.1:{proxy.server_port}/v1/chat/completions'
def post(names):
    data = json.dumps({'tools': [{'function': {'name': n}} for n in names]}).encode()
    return urllib.request.urlopen(urllib.request.Request(url, data=data, method='POST'), timeout=5).read()

try:
    assert b'kalari-bootstrap-read' in post(['read'])
    assert not calls
    try: post(['read'])
    except urllib.error.HTTPError as e: assert e.code == 503
    else: raise AssertionError('missing tools reached upstream')
    assert not calls
    data = json.dumps({'tools': [{'function': {'name': n}} for n in sorted(bootstrap_proxy.REQUIRED)]}).encode()
    start = time.monotonic()
    with urllib.request.urlopen(urllib.request.Request(url, data=data, method='POST'), timeout=5) as response:
        assert response.readline() == b'first\n' and time.monotonic() - start < 1.5
        assert response.readline() == b'second\n' and time.monotonic() - start >= 1.5
    assert len(calls) == 1 and state['forwarded']
finally:
    proxy.shutdown(); upstream.shutdown()
