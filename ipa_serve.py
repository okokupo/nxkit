#!/usr/bin/env python3
"""极简 Range HTTP 文件服务：仅绑 127.0.0.1，供 cloudflared 隧道回源。密令路径不匹配一律 404。"""
import os, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = sys.argv[1]
ROOT = sys.argv[2]
FNAME = sys.argv[3]
PORT = int(sys.argv[4])
PATH = os.path.join(ROOT, FNAME)
SIZE = os.path.getsize(PATH)

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/' + TOKEN + '/' + FNAME:
            self.send_error(404); return
        m = re.match(r'bytes=(\d*)-(\d*)$', self.headers.get('Range', '') or '')
        start, end = 0, SIZE - 1
        if m:
            if m.group(1): start = int(m.group(1))
            if m.group(2): end = int(m.group(2))
            end = min(end, SIZE - 1)
            if start > end or start >= SIZE:
                self.send_response(416); self.send_header('Content-Range', f'bytes */{SIZE}'); self.end_headers(); return
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{SIZE}')
        else:
            self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', f'attachment; filename="{FNAME}"')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        self.end_headers()
        with open(PATH, 'rb') as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(1 << 20, remaining))
                if not chunk: break
                try: self.wfile.write(chunk)
                except BrokenPipeError: return
                remaining -= len(chunk)
    do_HEAD = do_GET  # 发头不写体
    def do_HEAD(self):
        if self.path != '/' + TOKEN + '/' + FNAME:
            self.send_error(404); return
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(SIZE))
        self.end_headers()
    def log_message(self, fmt, *args):
        print(f'[ipa-serve] {self.address_string()} {fmt % args}', flush=True)

print(f'[ipa-serve] 127.0.0.1:{PORT}  token-path=/'+TOKEN+'/'+FNAME+f'  size={SIZE}', flush=True)
ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
