"""Items API v2: GET /items pages its results (100 per page) with next_page_token."""
import base64, json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

ITEMS = [{"id": f"item-{i:05d}", "value": i * 7 % 1000} for i in range(2431)]
PAGE = 100

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path != "/items":
            self.send_error(404); return
        token = parse_qs(url.query).get("page_token", [None])[0]
        start = int(base64.urlsafe_b64decode(token).decode()) if token else 0
        body = {"items": ITEMS[start:start + PAGE]}
        if start + PAGE < len(ITEMS):
            body["next_page_token"] = base64.urlsafe_b64encode(str(start + PAGE).encode()).decode()
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
