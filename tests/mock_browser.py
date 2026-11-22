#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Synthetic HTTP browser fixture; binds only an owned 127.0.0.1 listener."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import threading
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=0)
parser.add_argument('--info', type=Path, required=True)
parser.add_argument('--events', type=Path)
args = parser.parse_args()
state = {'recover': False}
events_lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urlsplit(self.path).path
        if args.events:
            with events_lock:
                with args.events.open('a') as output:
                    output.write(json.dumps({'event': 'request', 'path': path}) + '\n')
        if path == '/auth':
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="Synthetic fixture"')
            self.end_headers()
            return
        if path == '/arm':
            state['recover'] = True
        if path == '/recover' and not state['recover']:
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        name = {'/one': 'One', '/two': 'Two', '/popup': 'Popup', '/popup-message': 'Message', '/recover': 'Recovered'}.get(path, 'Ready')
        html = '''<!doctype html><meta charset="utf-8"><title>Fixture %s</title>
<style>body{margin:0;background:#164e57;color:white;font:16px system-ui}input,button,select,a{margin:8px;font:16px system-ui}#tick{position:fixed;bottom:8px}</style>
<input id="input" aria-label="Synthetic input"><button id="echo" onclick="document.getElementById('output').textContent=document.getElementById('input').value">Echo</button>
<select id="choice" onchange="window.choice=this.value"><option value="one">One</option><option value="two">Two</option></select>
<a id="popup" href="/popup" target="_blank">New tab</a><button id="openerPopup" onclick="window.fixtureChild=window.open('/popup-message','fixture-child')">Message popup</button><output id="output"></output><span id="tick"></span>
<script>window.cardToken=String(Math.random());window.tick=0;window.choice='one';window.popupMessages=[];addEventListener('message',event=>{if(event.origin===location.origin)window.popupMessages.push(event.data)});if(location.pathname==='/popup-message'&&window.opener)window.opener.postMessage('owned-popup-ready',location.origin);document.cookie='lanternFixture=shared; SameSite=Lax; path=/';setInterval(()=>{window.tick++;document.getElementById('tick').textContent=window.tick;if(new URLSearchParams(location.search).has('animate'))document.body.style.backgroundColor=window.tick%%20<10?'#164e57':'#ee3344'},100)</script>''' % name
        body = html.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

try:
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
except PermissionError:
    raise SystemExit(77)
args.info.parent.mkdir(parents=True, exist_ok=True)
args.info.write_text(json.dumps({'host': '127.0.0.1', 'port': server.server_port,
                                 'url': 'http://127.0.0.1:' + str(server.server_port)}))
try:
    server.serve_forever()
finally:
    server.server_close()
