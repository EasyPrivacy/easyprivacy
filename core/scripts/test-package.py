#!/usr/bin/env python3
"""Install/upgrade/remove a development .deb inside a disposable Ubuntu chroot.

Run as root in a Linux test environment, with a Canonical-signed/hash-verified
Ubuntu Base archive. Does not install the package into the host system.
"""
import argparse
from contextlib import contextmanager, ExitStack
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import ssl
import subprocess
import sys
import tempfile
import time

from smoke import configure


def run(command, **kwargs):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{command[:3]} failed:\n{result.stdout[-6000:]}")
    return result.stdout


@contextmanager
def kernel_views(root):
    """Provide systemd's kernel views inside our private mount namespace."""
    mounted = []
    try:
        for name in ('proc', 'sys'):
            target = root / name
            target.mkdir(exist_ok=True)
            run(['mount', '--bind', '/' + name, str(target)])
            mounted.append(target)
            run(['mount', '-o', 'remount,bind,ro,nosuid,nodev,noexec', str(target)])
        yield
    finally:
        for target in reversed(mounted):
            # Detach before TemporaryDirectory can traverse a kernel filesystem.
            run(['umount', '--lazy', str(target)])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--previous-package", type=Path)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("run inside the local Linux test environment as root")
    if os.stat('/proc/self/ns/mnt').st_ino == os.stat('/proc/1/ns/mnt').st_ino:
        os.execvp('unshare', ['unshare', '--mount', '--propagation', 'private',
                             sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])
    run(['mount', '--make-rprivate', '/'])
    # Recheck the cached image against the signed manifest verified at download.
    manifest = args.base.parent / "SHA256SUMS"
    expected = next(line.split()[0] for line in manifest.read_text().splitlines()
                    if line.split()[-1].lstrip("*") == args.base.name)
    assert hashlib.sha256(args.base.read_bytes()).hexdigest() == expected

    with tempfile.TemporaryDirectory(prefix="easyprivacy-package-test-") as temp, ExitStack() as mounts:
        root = Path(temp) / "root"
        root.mkdir()
        run(["tar", "--numeric-owner", "-xpf", str(args.base), "-C", str(root)])
        assert 'VERSION_ID="24.04"' in (root / "etc/os-release").read_text()
        for name, minor in [("null", 3), ("zero", 5), ("random", 8), ("urandom", 9)]:
            path = root / "dev" / name
            if not path.exists():
                os.mknod(path, stat.S_IFCHR | 0o666, os.makedev(1, minor))
            os.chmod(path, 0o666)
        resolv = root / "etc/resolv.conf"
        if resolv.is_symlink():
            resolv.unlink()
        resolv.write_text(Path("/etc/resolv.conf").read_text())
        mounts.enter_context(kernel_views(root))
        # Never let a dependency's maintainer scripts start a host-facing service.
        policy = root / "usr/sbin/policy-rc.d"
        policy.write_text("#!/bin/sh\nexit 101\n")
        policy.chmod(0o755)
        shutil.copyfile(args.package, root / "tmp/easyprivacy.deb")
        if args.previous_package:
            shutil.copyfile(args.previous_package,root / "tmp/previous.deb")
        environment = dict(os.environ, DEBIAN_FRONTEND="noninteractive", LC_ALL="C")

        def inside(*command):
            return run(["chroot", str(root), *command], env=environment)

        inside("apt-get", "update", "-qq")
        inside("apt-get", "install", "-y", "/tmp/previous.deb" if args.previous_package else "/tmp/easyprivacy.deb")
        assert inside("dpkg-query", "-W", "-f=${Status}", "easyprivacy-node") == "install ok installed"
        assert (root / "usr/bin/easyprivacy-node").exists()
        assert os.path.lexists(root / "etc/systemd/system/multi-user.target.wants/easyprivacy-node.service")
        assert not (root / "var/lib/easyprivacy-node/core.json").exists()
        account = inside("getent", "passwd", "easyprivacy-node").strip().split(":")
        uid, gid = int(account[2]), int(account[3])
        assert uid > 0 and gid > 0 and account[6] == "/usr/sbin/nologin"
        inside("systemd-analyze", "verify", "/usr/lib/systemd/system/easyprivacy-node.service")
        print("PASS: clean Ubuntu 24.04.4 package installation, service account and systemd unit validation.", flush=True)

        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        configure(Path("/usr/bin/easyprivacy-node"), Path("/var/lib/easyprivacy-fixture"), port,
                  prefix=["chroot", str(root)])
        state_dir = root / "var/lib/easyprivacy-node"
        state_dir.mkdir(mode=0o700,exist_ok=True)
        (root / "var/lib/easyprivacy-fixture/core.json").rename(state_dir / "core.json")
        (root / "var/lib/easyprivacy-fixture").rmdir()
        state_file = state_dir / "core.json"
        os.chown(state_dir, 0, gid)
        os.chmod(state_dir, 0o750)
        os.chown(state_file, 0, gid)
        os.chmod(state_file, 0o640)
        original = hashlib.sha256(state_file.read_bytes()).hexdigest()
        if args.previous_package:
            inside('apt-get','install','-y','/tmp/easyprivacy.deb')
            assert hashlib.sha256(state_file.read_bytes()).hexdigest()==original
            inside('systemd-analyze','verify','/usr/lib/systemd/system/easyprivacy-node.service')
            print('PASS: legacy package upgrades to device pairing without changing core identity or account credentials.',flush=True)

        runtime=state_dir/'runtime'
        inside('systemd-analyze','verify','/usr/lib/systemd/system/easyprivacy-vpn.service')
        inside('systemd-analyze','verify','/usr/lib/systemd/system/easyprivacy-service.service')
        assert not os.path.lexists(root/'etc/systemd/system/multi-user.target.wants/easyprivacy-service.service')
        vpn_dir=root/'var/lib/easyprivacy-vpn'
        assert stat.S_IMODE(vpn_dir.stat().st_mode)==0o700 and vpn_dir.stat().st_uid==0
        assert not os.path.lexists(root/'etc/systemd/system/multi-user.target.wants/easyprivacy-vpn.service')
        assert stat.S_IMODE(runtime.stat().st_mode)==0o700 and runtime.stat().st_uid==uid

        def service_identity():
            os.chroot(root)
            os.chdir("/")
            os.setgroups([])
            os.setgid(gid)
            os.setuid(uid)

        identity = run(["/usr/bin/easyprivacy-node", "identity"], preexec_fn=service_identity)
        assert "Core fingerprint: SHA256:" in identity
        print("PASS: unprivileged service account can read the protected core state.", flush=True)

        # Exercise the actual compiled core under its installed unprivileged
        # identity. The chroot has no init system, so create its private /run
        # directory as systemd's RuntimeDirectory directive would.
        admin=root/'run/easyprivacy-node';admin.mkdir(mode=0o700);os.chown(admin,uid,gid)
        fixture_key=bytes(range(32))
        device_id=hashlib.sha256(fixture_key).hexdigest()
        import base64
        database=runtime/'devices.json'
        database.write_text(json.dumps({'schema':1,'devices':[{
            'id':device_id,'name':'Package fixture','public_key':base64.b64encode(fixture_key).decode(),
            'created_at':'2026-10-17T00:00:00Z','revoked':False}]}))
        database.chmod(0o600);os.chown(database,uid,gid)
        context=ssl.create_default_context(cadata=json.loads(state_file.read_text())['certificate_pem']);context.check_hostname=False
        process=subprocess.Popen(['/usr/bin/easyprivacy-node','serve'],preexec_fn=service_identity,
                                 stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True)
        try:
            for _ in range(100):
                if process.poll() is not None:raise RuntimeError('Installed service exited: '+process.stderr.read())
                try:
                    connection=http.client.HTTPSConnection('127.0.0.1',port,context=context,timeout=.3)
                    connection.request('GET','/healthz');response=connection.getresponse();response.read();connection.close()
                    if response.status==200:break
                except OSError:time.sleep(.1)
            else:raise RuntimeError('Installed service readiness timed out')
            assert 'Pairing code: ' in inside('/usr/bin/easyprivacy-node','pair')
            assert 'Package fixture' in inside('/usr/bin/easyprivacy-node','devices')
            inside('/usr/bin/easyprivacy-node','revoke',device_id)
            assert json.loads(database.read_text())['devices'][0]['revoked'] is True
        finally:
            process.terminate();process.wait(timeout=10);process.stderr.close()
        devices_original=hashlib.sha256(database.read_bytes()).hexdigest()
        print('PASS: compiled installed core serves TLS, exposes its protected admin socket, and durably revokes devices as the unprivileged service account.',flush=True)

        # The network helper reads a different UID's private authorization store.
        # Root with only NET_ADMIN/CHOWN cannot traverse its mode-0700 directory.
        unit=(root/'usr/lib/systemd/system/easyprivacy-vpn.service').read_text()
        caps=next(line.split('=',1)[1].split() for line in unit.splitlines()
                  if line.startswith('CapabilityBoundingSet='))
        def read_with_capabilities(selected):
            bounding='-all'+''.join(',+'+c.removeprefix('CAP_').lower() for c in selected)
            return subprocess.run(['chroot',str(root),'setpriv','--bounding-set='+bounding,
                                   'cat','/var/lib/easyprivacy-node/runtime/devices.json'],
                                  env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        denied=read_with_capabilities([c for c in caps if c!='CAP_DAC_READ_SEARCH'])
        assert denied.returncode!=0 and 'Permission denied' in denied.stderr
        allowed=read_with_capabilities(caps)
        assert allowed.returncode==0,allowed.stderr
        assert json.loads(allowed.stdout)==json.loads(database.read_text())
        print('PASS: declared VPN helper capabilities read private device authorizations; the negative control is denied.',flush=True)

        absent = inside("/usr/bin/easyprivacy-node", "firewall")
        assert "UFW is not installed" in absent
        inside("apt-get", "install", "-y", "ufw")
        inactive = inside("/usr/bin/easyprivacy-node", "firewall")
        assert "UFW is inactive; left unchanged" in inactive
        dry_run = inside("ufw", "--dry-run", "allow", f"{port}/tcp")
        assert f"-p tcp --dport {port} -j ACCEPT" in dry_run
        assert "ENABLED=no" in (root / "etc/ufw/ufw.conf").read_text()
        print("PASS: real Ubuntu UFW remains inactive; dry-run validates the selected TCP rule without applying it.", flush=True)

        # A chroot shares the host's network namespace. Substitute UFW for active
        # CLI checks so no test can alter the host's firewall or SSH access.
        ufw = root / "usr/sbin/ufw"
        ufw.rename(ufw.with_name("ufw-real"))
        ufw.write_text(f'''#!/bin/sh
set -eu
[ "$LC_ALL" = C ] || exit 4
printf '%s\\n' "$*" >> /tmp/ufw-fixture.log
case "$*" in
    status) printf 'Status: active\\n' ;;
    'allow {port}/tcp') printf 'Rules updated (or existing rule retained)\\n' ;;
    *) exit 5 ;;
esac
''')
        ufw.chmod(0o755)
        for _ in range(2):
            applied = inside("/usr/bin/easyprivacy-node", "firewall")
            assert f"UFW allow rule applied for TCP {port}" in applied
            assert f"provider firewall, allow inbound TCP {port}" in applied
        log = root / "tmp/ufw-fixture.log"
        assert log.read_text().splitlines() == ["status", f"allow {port}/tcp"] * 2
        assert hashlib.sha256(state_file.read_bytes()).hexdigest() == original
        print("PASS: installed firewall command uses the saved port, fixes the locale, and preserves credentials on repeated runs (UFW fixture).", flush=True)

        # Synthetic operator configuration: package changes must preserve its
        # traffic key, endpoint, subnet, legacy peers and private permissions.
        vpn_config = vpn_dir / 'vpn.json'
        vpn_config.write_text(json.dumps({'schema': 1, 'name': 'Package fixture',
            'endpoint': 'example.test:51821', 'port': 51821, 'subnet': '10.87.0.0/24',
            'uplink': 'eth0', 'dns': ['1.1.1.1'],
            'private_key': base64.b64encode(bytes(range(1, 33))).decode()}))
        vpn_config.chmod(0o600)
        vpn_peers = vpn_dir / 'peers.json'
        vpn_peers.write_text('[]\n')
        vpn_peers.chmod(0o600)
        vpn_original = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in (vpn_config, vpn_peers)}

        def assert_vpn_preserved():
            for name, digest in vpn_original.items():
                path = vpn_dir / name
                assert hashlib.sha256(path.read_bytes()).hexdigest() == digest
                assert stat.S_IMODE(path.stat().st_mode) == 0o600

        staging = Path(temp) / "upgrade"
        run(["dpkg-deb", "--raw-extract", str(args.package), str(staging)])
        control = staging / "DEBIAN/control"
        lines = control.read_text().splitlines()
        control.write_text("\n".join(line + "+test1" if line.startswith("Version:") else line for line in lines) + "\n")
        run(["dpkg-deb", "--root-owner-group", "--build", str(staging), str(root / "tmp/upgrade.deb")])
        inside("dpkg", "--install", "/tmp/upgrade.deb")
        assert_vpn_preserved()
        assert os.path.lexists(root/'etc/systemd/system/multi-user.target.wants/easyprivacy-vpn.service')
        assert hashlib.sha256(state_file.read_bytes()).hexdigest() == original
        assert hashlib.sha256(database.read_bytes()).hexdigest()==devices_original
        assert log.read_text().splitlines() == ["status", f"allow {port}/tcp"] * 2
        inside("dpkg", "--remove", "easyprivacy-node")
        assert_vpn_preserved()
        assert not (root / "usr/bin/easyprivacy-node").exists()
        assert hashlib.sha256(state_file.read_bytes()).hexdigest() == original
        inside("dpkg", "--install", "/tmp/easyprivacy.deb")
        assert_vpn_preserved()
        assert hashlib.sha256(state_file.read_bytes()).hexdigest() == original
        inside("dpkg", "--purge", "easyprivacy-node")
        assert_vpn_preserved()
        assert hashlib.sha256(state_file.read_bytes()).hexdigest() == original
        assert hashlib.sha256(database.read_bytes()).hexdigest()==devices_original
        assert not os.path.lexists(root / "etc/systemd/system/multi-user.target.wants/easyprivacy-node.service")
        print("PASS: upgrade, remove, reinstall and purge preserve the existing core identity and credentials.", flush=True)
        print("PASS: VPN traffic key, endpoint, subnet, legacy peers and private permissions survive package changes.", flush=True)
    print("Package test root removed; the host installation was not changed.", flush=True)


if __name__ == "__main__":
    main()
