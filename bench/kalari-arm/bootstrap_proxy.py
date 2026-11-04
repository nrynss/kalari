"""Gate the first real inference request on OpenCode's MCP tool discovery."""
import http.server
import json
import threading
import time
import urllib.error
import urllib.request

REQUIRED = {f'kalari_{name}' for name in
            ('what_changed', 'blast_radius', 'recall_lessons', 'run_in_sandbox', 'record_lesson')}


def start(upstream, read_path):
    state = {'bootstrapped': False, 'forwarded': False, 'error': None}
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                body = self.rfile.read(int(self.headers['Content-Length']))
                req = json.loads(body)
                names = {t.get('function', {}).get('name') for t in req.get('tools', [])}
                with lock:
                    if not names:
                        action = 'auxiliary'
                    elif not state['bootstrapped']:
                        state['bootstrapped'] = True
                        action = 'bootstrap'
                    elif not REQUIRED.issubset(names):
                        state['error'] = 'Kalari tools missing after bootstrap'
                        action = 'reject'
                    else:
                        state['forwarded'] = True
                        action = 'forward'
                if action == 'reject':
                    self.send_error(503, 'Kalari tools missing after bootstrap')
                    return
                if action == 'forward':
                    headers = {k: v for k, v in self.headers.items() if k.lower() not in ('host', 'content-length', 'connection')}
                    request = urllib.request.Request(upstream + self.path.removeprefix('/v1'), data=body, headers=headers, method='POST')
                    try:
                        response = urllib.request.urlopen(request, timeout=120)
                    except urllib.error.HTTPError as e:
                        response = e
                    with response:
                        self.send_response(response.status)
                        self.send_header('Content-Type', response.headers.get('Content-Type', 'application/json'))
                        self.end_headers()
                        while chunk := response.read1(4096):
                            self.wfile.write(chunk)
                            self.wfile.flush()
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                def chunk(delta, finish=None):
                    doc = {'id': 'kalari-bootstrap', 'object': 'chat.completion.chunk', 'created': 1,
                           'model': 'bootstrap', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
                    self.wfile.write(('data: ' + json.dumps(doc) + '\n\n').encode())
                if action == 'bootstrap':
                    time.sleep(2)
                    chunk({'tool_calls': [{'index': 0, 'id': 'kalari-bootstrap-read', 'type': 'function',
                           'function': {'name': 'read', 'arguments': json.dumps({'path': str(read_path)})}}]})
                    chunk({}, 'tool_calls')
                else:
                    chunk({'content': 'Kalari session'})
                    chunk({}, 'stop')
                self.wfile.write(b'data: [DONE]\n\n')
            except Exception:
                state['error'] = 'bootstrap proxy error'
                try: self.send_error(502, 'bootstrap proxy error')
                except Exception: pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, state
