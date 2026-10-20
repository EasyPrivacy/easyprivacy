#!/usr/bin/env python3
"""Exercise the real terminal wizard and TLS server in an isolated directory."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import pty
import select
import socket
import ssl
import subprocess
import tempfile
import termios
import time


def configure(binary, directory, port, prefix=()):
    master, slave = pty.openpty()
    process = subprocess.Popen(
        [*prefix, str(binary), "setup", "--state-dir", str(directory)],
        stdin=slave, stdout=slave, stderr=slave, close_fds=True,
    )
    os.close(slave)
    transcript = bytearray()

    def expect(marker, response=None, password=False):
        deadline = time.monotonic() + 15
        while marker.encode() not in transcript:
            if time.monotonic() > deadline:
                raise RuntimeError(f"Wizard did not reach {marker!r}")
            if select.select([master], [], [], 0.1)[0]:
                transcript.extend(os.read(master, 4096))
        if password:
            while termios.tcgetattr(master)[3] & termios.ECHO:
                if time.monotonic() > deadline:
                    raise RuntimeError("Password input remained visible")
                time.sleep(0.01)
        if response is not None:
            os.write(master, response.encode() + b"\n")

    try:
        expect("Core name [My EasyPrivacy Core]: ", "Smoke Core")
        expect("Listening port [7444]: ", str(port))
        expect("Username: ", "owner")
        expect("Password (at least 15 characters, hidden): ", "a testing passphrase only", True)
        expect("Confirm password (hidden): ", "a testing passphrase only", True)
        expect("Setup complete.")
        if process.wait(timeout=15) != 0:
            raise RuntimeError("Wizard failed")
        if b"a testing passphrase only" in transcript:
            raise RuntimeError("Wizard echoed the password")
    finally:
        os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait()
    print("PASS: interactive setup completed with hidden password entry.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] / "dist/easyprivacy-node-linux-amd64")
    parser.add_argument("--dart", help="Optional Windows Dart executable accessible through WSL")
    parser.add_argument("--client-host", help="Address the Dart process uses to reach the test server")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="easyprivacy-smoke-") as temp:
        directory = Path(temp)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        configure(args.binary, directory, port)
        state = json.loads((directory / "core.json").read_text())
        cert = ssl.PEM_cert_to_DER_cert(state["certificate_pem"])
        fingerprint = "SHA256:" + hashlib.sha256(cert).hexdigest().upper()
        context = ssl.create_default_context(cadata=state["certificate_pem"])
        # The self-signed leaf is the exact independently verified trust anchor.
        context.check_hostname = False
        process = subprocess.Popen([str(args.binary), "serve", "--state-dir", str(directory)], stdout=subprocess.DEVNULL)
        try:
            for attempt in range(60):
                try:
                    connection = socket.create_connection(("127.0.0.1", port), timeout=0.3)
                    connection.close()
                    break
                except OSError:
                    if process.poll() is not None:
                        raise RuntimeError("Core exited before listening")
                    time.sleep(0.1)
            else:
                raise RuntimeError("Core did not start listening")

            def request(method, path, body=None, token=None):
                conn = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=5)
                headers = {"Content-Type": "application/json"}
                if token:
                    headers["Authorization"] = "Bearer " + token
                conn.request(method, path, json.dumps(body) if body is not None else None, headers)
                response = conn.getresponse()
                result = response.status, json.loads(response.read())
                conn.close()
                return result

            assert request("GET", "/api/v1/status")[0] == 401
            assert request("POST", "/api/v1/login", {"username": "owner", "password": "wrong"})[0] == 401
            code, data = request("POST", "/api/v1/login", {"username": "owner", "password": "a testing passphrase only"})
            assert code == 200
            token = data["access_token"]
            assert request("GET", "/api/v1/status", token=token)[1]["core_name"] == "Smoke Core"
            assert request("POST", "/api/v1/logout", token=token)[0] == 200
            assert request("GET", "/api/v1/status", token=token)[0] == 401
            print("PASS: real core process rejects unauthenticated/wrong-password access and revokes sign-out.")

            if args.dart:
                app = Path(__file__).resolve().parents[2] / "app"
                script = subprocess.check_output(["wslpath", "-w", str(app / "tool/connection_smoke.dart")], text=True).strip()
                host = args.client_host
                if not host:
                    host = subprocess.check_output(["hostname", "-I"], text=True).split()[0] if args.dart.lower().endswith(".exe") else "127.0.0.1"
                subprocess.run([args.dart, "run", script, f"{host}:{port}", fingerprint], cwd=app, check=True)
        finally:
            process.terminate()
            process.wait(timeout=10)


if __name__ == "__main__":
    main()
