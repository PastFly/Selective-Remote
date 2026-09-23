"""Exercise the release SSH proxy through two real OpenSSH servers and a PTY session."""

import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(tempfile.mkdtemp(prefix="sr-real-sshd-"))
USER = os.environ["USER"]
PROXY = sys.argv[1]


def run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, **kwargs)


def port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    result = sock.getsockname()[1]
    sock.close()
    return result


def key(name):
    path = ROOT / name
    result = run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(path)])
    assert result.returncode == 0, result.stderr
    return path


client_key = key("client")
agent_socket = ROOT / "agent.sock"
agent = subprocess.Popen(["/usr/bin/ssh-agent", "-D", "-a", str(agent_socket)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(100):
    if agent_socket.exists():
        break
    time.sleep(0.05)
agent_env = dict(os.environ, SSH_AUTH_SOCK=str(agent_socket))
assert run(["/usr/bin/ssh-add", str(client_key)], env=agent_env).returncode == 0
host_keys = [key("jump-host"), key("destination-host")]
(ROOT / "authorized_keys").write_text(client_key.with_suffix(".pub").read_text())
ports = [port(), port()]
known_hosts = ROOT / "known_hosts"
known_hosts.write_text("".join(
    f"[127.0.0.1]:{p} ssh-ed25519 {k.with_suffix('.pub').read_text().split()[1]}\n"
    for p, k in zip(ports, host_keys)
))

servers = []
try:
    for role, p, hostkey in zip(("jump", "destination"), ports, host_keys):
        config = ROOT / f"{role}.conf"
        config.write_text("\n".join([
            f"Port {p}", "ListenAddress 127.0.0.1", f"HostKey {hostkey}",
            f"AuthorizedKeysFile {ROOT / 'authorized_keys'}", "StrictModes no",
            "PubkeyAuthentication yes", "PasswordAuthentication no", "KbdInteractiveAuthentication no",
            "UsePAM no", "AllowTcpForwarding yes", "PermitTTY yes", "LogLevel ERROR",
            f"PidFile {ROOT / (role + '.pid')}", "",
        ]))
        output = open(ROOT / f"{role}.log", "w")
        server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=output, stderr=output)
        servers.append((server, output))
        for _ in range(100):
            if server.poll() is not None:
                raise RuntimeError(f"{role} sshd exited: {(ROOT / (role + '.log')).read_text()}")
            try:
                with socket.create_connection(("127.0.0.1", p), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError(f"{role} sshd did not listen")

    base = ["/usr/bin/ssh", "-p", str(ports[1]), "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={known_hosts}", "-o", "BatchMode=yes",
            "-o", "PreferredAuthentications=publickey", "-o", "IdentitiesOnly=yes",
            "-i", str(client_key), "-S", "none", "-o", "ControlMaster=no", "-tt"]
    command = "read line; printf 'session=%s\\n' \"$line\""
    destination = ["-l", USER, "127.0.0.1", command]
    direct = run(base + destination, input="transport-ok\n", timeout=15, env=agent_env)
    assert direct.returncode == 0 and "session=transport-ok" in direct.stdout

    jump_config = ROOT / "ssh_config"
    jump_config.write_text("\n".join([
        "Host synthetic-jump", "  HostName 127.0.0.1", f"  Port {ports[0]}",
        f"  User {USER}", f"  UserKnownHostsFile {known_hosts}",
        "  StrictHostKeyChecking yes", f"  IdentityFile {client_key}",
        "  IdentitiesOnly yes", "",
    ]))
    main_style = run(base + ["-F", str(jump_config), "-J", "synthetic-jump"] + destination,
                     input="transport-ok\n", timeout=15, env=agent_env)
    assert main_style.returncode == 0 and "session=transport-ok" in main_style.stdout

    child_base = ["/usr/bin/ssh", "-p", str(ports[0]), "-o", "StrictHostKeyChecking=yes",
                  "-o", f"UserKnownHostsFile={known_hosts}", "-o", "NumberOfPasswordPrompts=1"]
    words = child_base + ["-o", "ProxyJump=none", "-o", "ProxyCommand=none",
                          "-o", "ClearAllForwardings=yes", "-W", "%h:%p",
                          "-l", USER, "127.0.0.1"]
    manual_proxy = " ".join(words)
    baseline = run(base + ["-o", "ProxyCommand=" + manual_proxy] + destination,
                   input="transport-ok\n", timeout=15, env=agent_env)
    assert baseline.returncode == 0 and "session=transport-ok" in baseline.stdout

    identity = "jump|synthetic-profile|" + USER + "@127.0.0.1:" + str(ports[0])
    proxy_command = " ".join([
        "'" + PROXY + "'", "jump", "'127.0.0.1'", str(ports[0]), "%h", "%p",
        "'" + USER + "'", "\"${SELECTIVEREMOTE_JUMP_SECRET_FILE:-}\"", "'" + identity + "'",
        "'yes'", "'" + str(known_hosts) + "'",
    ])
    env = dict(agent_env, SELECTIVEREMOTE_JUMP_TARGET_IDENTITY=identity)
    managed = run(base + ["-o", "ProxyCommand=" + proxy_command] + destination,
                  input="transport-ok\n", timeout=15, env=env)
    assert managed.returncode == 0 and "session=transport-ok" in managed.stdout, (
        f"managed transport failed: exit={managed.returncode}, "
        f"session={'session=transport-ok' in managed.stdout}, "
        f"helper_signal={-managed.returncode if managed.returncode < 0 else 'none'}"
    )
    print("direct, main-style -J, OpenSSH -W, managed jump, destination PTY session: PASS")
finally:
    agent.terminate()
    agent.wait(timeout=3)
    for server, output in servers:
        server.terminate()
        try:
            server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server.kill()
        output.close()
    shutil.rmtree(ROOT)
