"""Auth CONNECT broker for probe. Listens on 127.0.0.1, validates Basic auth, serves canned API."""
import sys, socket, threading, base64, os
listen_port=int(sys.argv[sys.argv.index("--port")+1])
user=sys.argv[sys.argv.index("--user")+1]
pw_env=sys.argv[sys.argv.index("--pwenv")+1]
allowed=sys.argv[sys.argv.index("--allow")+1]  # e.g. 203.0.113.10:18080
trace=sys.argv[sys.argv.index("--trace")+1]
password=os.environ.get(pw_env, "")
if not password:
    print("broker: missing password env", flush=True); sys.exit(2)
expected="Basic "+base64.b64encode(f"{user}:{password}".encode()).decode()
srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", listen_port)); srv.listen(20)
actual=srv.getsockname()[1]
print(f"broker listening on {actual} allow={allowed} user={user}", flush=True)
def handle(c):
    try:
        # read headers
        data=b""
        while b"\r\n\r\n" not in data:
            chunk=c.recv(4096)
            if not chunk: return
            data+=chunk
            if len(data)>16384: return
        head=data.decode("iso-8859-1")
        lines=head.split("\r\n")
        req=lines[0]
        hdrs={}
        for l in lines[1:]:
            if not l: break
            if ":" in l:
                k,v=l.split(":",1); hdrs[k.strip().lower()]=v.strip()
        # expect CONNECT host:port
        if not req.startswith("CONNECT "):
            c.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return
        dest=req.split()[1]
        auth=hdrs.get("proxy-authorization","")
        if auth!=expected:
            c.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"probe\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return
        if dest!=allowed:
            c.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return
        c.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        # now read inner HTTP request
        inner=b""
        while b"\r\n\r\n" not in inner:
            chunk=c.recv(4096)
            if not chunk: break
            inner+=chunk
            if len(inner)>16384: break
        try: txt=inner.decode("iso-8859-1")
        except: txt=""
        first=txt.split("\r\n")[0] if txt else ""
        # append trace event
        with open(trace,"a") as f:
            f.write(first+"\n")
        body=b'{"ok":true}'
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "+str(len(body)).encode()+b"\r\nConnection: close\r\n\r\n"+body)
    except Exception as e:
        print(f"broker-err:{e}", flush=True)
    finally:
        try: c.close()
        except: pass
while True:
    cc,_=srv.accept()
    threading.Thread(target=handle, args=(cc,), daemon=True).start()
