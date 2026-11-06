import sys, socket, threading
listen_port=int(sys.argv[1]) if len(sys.argv)>1 else 18990
target_port=int(sys.argv[2]) if len(sys.argv)>2 else 18991
def handle(c):
    try:
        data=c.recv(8192)
        if not data: c.close(); return
        txt=data.decode('iso-8859-1', errors='replace')
        print("PROXY-REQ:"+txt.split("\r\n")[0], flush=True)
        for line in txt.split("\r\n")[1:8]:
            if line.lower().startswith("proxy-") or line.lower().startswith("host"):
                print("PROXY-HDR:"+line, flush=True)
            if not line: break
        # Simple: forward GET http://... or / to target
        s=socket.create_connection(("127.0.0.1", target_port), timeout=5)
        # If absolute URI, convert to origin-form
        lines=txt.split("\r\n")
        # forward as GET / with Host
        s.sendall(b"GET / HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        resp=b""
        while True:
            chunk=s.recv(4096)
            if not chunk: break
            resp+=chunk
        s.close()
        # wrap as HTTP response via proxy = forward raw
        c.sendall(resp)
    except Exception as e:
        print(f"PROXY-ERR:{e}", flush=True)
    finally:
        try: c.close()
        except: pass
srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", listen_port)); srv.listen(20)
print(f"proxy listening on {listen_port} -> {target_port}", flush=True)
while True:
    c,_=srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
