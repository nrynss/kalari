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
    state = {'bootstrapped': False, 'forwarded': False, 'error': None, 'requests': [], 'requests_omitted': 0}
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
                    with lock:
                        record = {'active': True, 'completed': False, 'bytes': 0, 'saw_done': False,
                                  'finish_reason': None, 'error': None, 'http_status': None,
                                  'oversized_line': False}
                        if len(state['requests']) < 8:
                            state['requests'].append(record)
                        else:
                            state['requests_omitted'] += 1
                    headers = {k: v for k, v in self.headers.items() if k.lower() not in ('host', 'content-length', 'connection')}
                    headers = {k: v for k, v in headers.items() if k.lower() != 'accept-encoding'}
                    headers['Accept-Encoding'] = 'identity'
                    request = urllib.request.Request(upstream + self.path.removeprefix('/v1'), data=body, headers=headers, method='POST')
                    try:
                        try:
                            response = urllib.request.urlopen(request, timeout=120)
                        except urllib.error.HTTPError as e:
                            response = e
                        pending = b''
                        with response:
                            record['http_status'] = response.status
                            self.send_response(response.status)
                            self.send_header('Content-Type', response.headers.get('Content-Type', 'application/json'))
                            if response.headers.get('Content-Encoding'):
                                self.send_header('Content-Encoding', response.headers['Content-Encoding'])
                            self.end_headers()
                            while chunk := response.read1(4096):
                                record['bytes'] += len(chunk)
                                pending += chunk
                                lines = pending.split(b'\n')
                                pending = lines.pop()
                                if len(pending) > 16384:
                                    pending = b''
                                    record['oversized_line'] = True
                                for line in lines:
                                    if not line.startswith(b'data:'): continue
                                    data = line[5:].strip()
                                    if data == b'[DONE]':
                                        record['saw_done'] = True
                                    else:
                                        try:
                                            event = json.loads(data)
                                            for choice in event.get('choices', []):
                                                reason = choice.get('finish_reason')
                                                if reason is not None:
                                                    record['finish_reason'] = reason if reason in ('stop', 'length', 'tool_calls', 'content_filter') else 'other'
                                        except (ValueError, TypeError, AttributeError):
                                            pass
                                self.wfile.write(chunk)
                                self.wfile.flush()
                        record['completed'] = True
                    except (BrokenPipeError, ConnectionResetError):
                        record['error'] = 'client_disconnected'
                    except TimeoutError:
                        record['error'] = 'upstream_timeout'
                    except Exception:
                        record['error'] = 'stream_error'
                    finally:
                        record['active'] = False
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
