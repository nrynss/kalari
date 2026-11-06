"""Broker: CONNECT auth, then forward inner HTTP to Unix socket obs."""
import sys, socket, threading, base64, os
port=int(sys.argv[sys.argv.index("--port")+1]); user=sys.argv[sys.argv.index("--user")+1]
pwenv=sys.argv[sys.argv.index("--pwenv")+1]; allowed=sys.argv[sys.argv.index("--allow")+1]
sock_path=sys.argv[sys.argv.index("--sock")+1]
pw=os.environ.get(pwenv,"")
if not pw: print("missing pw"); sys.exit(2)
exp="Basic "+base64.b64encode(f"{user}:{pw}".encode()).decode()
srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1",port)); srv.listen(20)
print(f"broker-unix listening on {port} -> {sock_path}", flush=True)
def handle(c):
    try:
        data=b""
        while b"\r\n\r\n" not in data:
            ch=c.recv(4096)
            if not ch: return
            data+=ch
        head=data.decode("iso-8859-1")
        lines=head.split("\r\n"); req=lines[0]; hdrs={}
        for l in lines[1:]:
            if not l: break
            if ":" in l:
                k,v=l.split(":",1); hdrs[k.strip().lower()]=v.strip()
        if not req.startswith("CONNECT "):
            c.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return
        dest=req.split()[1]
        if hdrs.get("proxy-authorization","")!=exp:
            c.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"probe\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return
        if dest!=allowed:
            c.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return
        c.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        inner=b""
        while b"\r\n\r\n" not in inner:
            ch=c.recv(4096)
            if not ch: break
            inner+=ch
        # forward inner to unix obs
        u=socket.socket(socket.AF_UNIX); u.settimeout(5); u.connect(sock_path)
        u.sendall(inner if inner else b"GET /empty HTTP/1.0\r\n\r\n")
        resp=b""
        while True:
            ch=u.recv(4096)
            if not ch: break
            resp+=ch
        u.close()
        c.sendall(resp if resp else b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
    except Exception as e:
        print(f"err:{e}", flush=True)
    finally:
        try: c.close()
        except: pass
while True:
    cc,_=srv.accept()
    threading.Thread(target=handle, args=(cc,), daemon=True).start()
