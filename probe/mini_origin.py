import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port=int(sys.argv[1]) if len(sys.argv)>1 else 18991
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body=b"obs-ok"
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
