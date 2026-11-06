"""Private observed API on Unix socket. No TCP. Appends to trace, returns JSON."""
import sys, os, socket, threading
sock_path=sys.argv[sys.argv.index("--sock")+1]
trace=sys.argv[sys.argv.index("--trace")+1]
if os.path.exists(sock_path): os.remove(sock_path)
srv=socket.socket(socket.AF_UNIX); srv.bind(sock_path); os.chmod(sock_path, 0o600); srv.listen(20)
print(f"obs listening on {sock_path}", flush=True)
def handle(c):
    try:
        data=b""
        while b"\r\n\r\n" not in data:
            ch=c.recv(4096)
            if not ch: break
            data+=ch
        txt=data.decode("iso-8859-1", errors="replace")
        first=txt.split("\r\n")[0] if txt else ""
        with open(trace,"a") as f: f.write(first+"\n")
        body=b'{"ok":true,"via":"unix"}'
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "+str(len(body)).encode()+b"\r\nConnection: close\r\n\r\n"+body)
    finally:
        try: c.close()
        except: pass
while True:
    cc,_=srv.accept()
    threading.Thread(target=handle, args=(cc,), daemon=True).start()
