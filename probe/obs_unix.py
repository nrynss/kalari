"""Private observed API on Unix socket. No TCP. Appends to trace, returns JSON.

Only a complete request block is observed: an empty or incomplete
connection closes with no trace write and no 200. Oversize blocks are
refused with 400 and also write nothing. The socket file is created with
mode 600; the runner places it in a private per-run directory.
"""
import sys, os, socket, threading

READ_TIMEOUT = 10.0
HEADER_CAP = 16384

sock_path = sys.argv[sys.argv.index("--sock") + 1]
trace = sys.argv[sys.argv.index("--trace") + 1]
if os.path.exists(sock_path):
    os.remove(sock_path)
srv = socket.socket(socket.AF_UNIX)
srv.bind(sock_path)
os.chmod(sock_path, 0o600)
srv.listen(20)
print(f"obs listening on {sock_path}", flush=True)


def handle(c):
    try:
        c.settimeout(READ_TIMEOUT)
        data = b""
        try:
            while b"\r\n\r\n" not in data:
                ch = c.recv(4096)
                if not ch:
                    return  # empty/incomplete: no observation, no reply
                data += ch
                if len(data) > HEADER_CAP:
                    try:
                        c.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    except Exception:
                        pass
                    return
        except (socket.timeout, TimeoutError):
            return  # expired: no observation, no reply
        txt = data.decode("iso-8859-1", errors="replace")
        first = txt.split("\r\n")[0] if txt else ""
        if len(first.split()) < 2:
            return  # not a request line: no observation, no 200
        with open(trace, "a") as f:
            f.write(first + "\n")
        body = b'{"ok":true,"via":"unix"}'
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
    except Exception:
        print("obs: transport error", flush=True)
    finally:
        try:
            c.close()
        except Exception:
            pass


while True:
    cc, _ = srv.accept()
    threading.Thread(target=handle, args=(cc,), daemon=True).start()
