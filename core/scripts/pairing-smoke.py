#!/usr/bin/env python3
"""Actual Windows Dart/native PAKE to Linux core, restart and MITM checks.

Uses only private temporary core state. Codes travel through child stdin, never
process arguments or log output. No real VPS or installed device is modified.
"""
import argparse
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from smoke import configure

def unused_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0))
        return s.getsockname()[1]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--dart',required=True)
    args=parser.parse_args()
    core=Path(__file__).resolve().parents[1]
    binary=core/'dist/easyprivacy-node-linux-amd64'
    app=core.parent/'apps'/'core'
    host=subprocess.check_output(['hostname','-I'],text=True).split()[0]
    with tempfile.TemporaryDirectory(prefix='easyprivacy-pairing-smoke-') as temp:
        directory=Path(temp)/'core'; directory.mkdir(mode=0o700)
        proxy_directory=Path(temp)/'proxy';proxy_directory.mkdir(mode=0o700)
        port,proxy_port=unused_port(),unused_port()
        configure(binary,directory,port)
        configure(binary,proxy_directory,proxy_port)
        state=json.loads((directory/'core.json').read_text())
        context=ssl.create_default_context(cadata=state['certificate_pem']);context.check_hostname=False
        process=None
        def start():
            proc=subprocess.Popen([str(binary),'serve','--state-dir',str(directory)],stdout=subprocess.DEVNULL)
            for _ in range(100):
                if proc.poll() is not None:raise RuntimeError('Core failed to start')
                try:
                    conn=http.client.HTTPSConnection('127.0.0.1',port,context=context,timeout=.3)
                    conn.request('GET','/healthz');response=conn.getresponse();response.read();conn.close()
                    if response.status==200:return proc
                except OSError:time.sleep(.1)
            proc.terminate();proc.wait(timeout=5);raise RuntimeError('Core readiness timed out')
        def code():
            text=subprocess.check_output([str(binary),'pair','--state-dir',str(directory)],text=True)
            match=re.search(r'Pairing code: ([0-9]{4}) ([0-9]{4})',text)
            if not match:raise RuntimeError('No pairing code returned')
            return ''.join(match.groups())

        proxy_state=json.loads((proxy_directory/'core.json').read_text())
        certificate=proxy_directory/'cert.pem';key=proxy_directory/'key.pem'
        certificate.write_text(proxy_state['certificate_pem']);key.write_text(proxy_state['private_key_pem']);key.chmod(0o600)
        proxy_pin='SHA256:'+hashlib.sha256(ssl.PEM_cert_to_DER_cert(proxy_state['certificate_pem'])).hexdigest().upper()
        class Relay(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_POST(self):
                if self.headers.get('Transfer-Encoding','').lower()=='chunked':
                    chunks=[];total=0
                    while True:
                        length=int(self.rfile.readline(128).split(b';',1)[0].strip(),16)
                        if length==0:
                            while self.rfile.readline(4096).strip():pass
                            break
                        total+=length
                        if total>4096:self.send_error(400);return
                        chunks.append(self.rfile.read(length))
                        if self.rfile.read(2)!=b'\r\n':self.send_error(400);return
                    body=b''.join(chunks)
                else:
                    length=int(self.headers.get('Content-Length','0'))
                    if length>4096:self.send_error(400);return
                    body=self.rfile.read(length)
                if self.path not in ('/api/v1/pairing/start','/api/v1/pairing/finish'):
                    self.server.auth_requests+=1;self.send_error(500);return
                connection=http.client.HTTPSConnection('127.0.0.1',port,context=context,timeout=5)
                connection.request('POST',self.path,body,{'Content-Type':'application/json'})
                response=connection.getresponse();raw=response.read();status=response.status;connection.close()
                if self.path.endswith('/start') and self.server.tamper:
                    self.server.tamper=False
                    value=json.loads(raw);value['core_fingerprint']=proxy_pin;raw=json.dumps(value).encode()
                self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
        relay=http.server.ThreadingHTTPServer(('0.0.0.0',proxy_port),Relay)
        relay.auth_requests=0;relay.tamper=True
        proxy_tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);proxy_tls.minimum_version=ssl.TLSVersion.TLSv1_3;proxy_tls.load_cert_chain(certificate,key)
        relay.socket=proxy_tls.wrap_socket(relay.socket,server_side=True)
        thread=threading.Thread(target=relay.serve_forever,daemon=True);thread.start()
        dart=None
        try:
            process=start()
            native=subprocess.check_output(['wslpath','-w',str(app/'native/windows/easyprivacy_pairing.dll')],text=True).strip()
            script=subprocess.check_output(['wslpath','-w',str(app/'tool/pairing_smoke.dart')],text=True).strip()
            # WSL only passes additional environment variables to Windows
            # processes when they are explicitly listed in WSLENV.
            shared_env=os.environ.get('WSLENV','')
            shared_env=':'.join(filter(None,[shared_env,'EASYPRIVACY_PAIRING_LIBRARY']))
            dart=subprocess.Popen([args.dart,'run',script],cwd=app,env=dict(os.environ,EASYPRIVACY_PAIRING_LIBRARY=native,WSLENV=shared_env),
                                  stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
            dart.stdin.write(json.dumps({'address':f'{host}:{port}','code':code()})+'\n');dart.stdin.flush()
            restarted=False
            for line in dart.stdout:
                if line.strip()=='READY_TO_RESTART':
                    process.terminate();process.wait(timeout=10);process=start();restarted=True
                    dart.stdin.write(json.dumps({'address':f'{host}:{proxy_port}','code':code()})+'\n');dart.stdin.flush()
                else:print(line.rstrip(),flush=True)
            if dart.wait(timeout=10)!=0 or not restarted:raise RuntimeError('Dart pairing smoke failed')
            assert relay.auth_requests==0,'Authentication data reached the untrusted TLS relay'
            assert len(json.loads((directory/'runtime/devices.json').read_text())['devices'])==2
            devices=subprocess.check_output([str(binary),'devices','--state-dir',str(directory)],text=True)
            assert devices.count('revoked')==2
            print('PASS: local admin socket, durable device records, and core-issued pairing codes; all temporary identities revoked.',flush=True)
        finally:
            if dart is not None and dart.poll() is None:dart.kill();dart.wait(timeout=10)
            if process is not None:process.terminate();process.wait(timeout=10)
            relay.shutdown();relay.server_close();thread.join(timeout=5)

if __name__=='__main__':main()
