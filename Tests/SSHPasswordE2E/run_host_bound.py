"""Synthetic two-hop OpenSSH/AskPass credential-boundary regression."""

import json
import os
import re
import shlex
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import paramiko


ASKPASS = Path(sys.argv[1])
PROXY_HELPER = Path(sys.argv[2])
REPOSITORY = Path(sys.argv[3])
DESTINATION_PASSWORD = "synthetic-destination"
JUMP_PASSWORD = "synthetic-jump"


class Server(paramiko.ServerInterface):
    def __init__(self, role, method, prompt="Password: "):
        self.role = role
        self.method = method
        self.prompt = prompt
        self.received_role = None
        self.received_roles = []
        self.interactive_responses = 0
        self.shell_ready = threading.Event()

    def get_allowed_auths(self, username):
        return "keyboard-interactive" if self.method == "repeat" else self.method

    def check_auth_none(self, username):
        return paramiko.AUTH_SUCCESSFUL if self.method == "none" else paramiko.AUTH_FAILED

    def check_auth_password(self, username, password):
        return self._check(password)

    def check_auth_interactive(self, username, submethods):
        query = paramiko.InteractiveQuery("", "")
        query.add_prompt(self.prompt, echo=False)
        return query

    def check_auth_interactive_response(self, responses):
        result = self._check(responses[0] if len(responses) == 1 else "")
        self.interactive_responses += 1
        if self.method == "repeat" and result == paramiko.AUTH_SUCCESSFUL and self.interactive_responses == 1:
            query = paramiko.InteractiveQuery("", "")
            query.add_prompt("Password for the other host: ", echo=False)
            return query
        return result

    def _check(self, password):
        self.received_role = (
            "jump" if password == JUMP_PASSWORD else
            "destination" if password == DESTINATION_PASSWORD else
            "manual" if password == "synthetic-correct" else "other"
        )
        self.received_roles.append(self.received_role)
        return (
            paramiko.AUTH_SUCCESSFUL
            if self.received_role in ("jump", "destination", "manual")
            else paramiko.AUTH_FAILED
        )

    def check_channel_direct_tcpip_request(self, channel_id, origin, destination):
        return paramiko.OPEN_SUCCEEDED if self.role == "jump" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, *args):
        return True

    def check_channel_shell_request(self, channel):
        self.shell_ready.set()
        return True


def listener():
    value = socket.socket()
    value.bind(("127.0.0.1", 0))
    value.listen(1)
    value.settimeout(20)
    return value


def serve_destination(listening, server, key):
    client, _ = listening.accept()
    transport = paramiko.Transport(client)
    transport.add_server_key(key)
    try:
        transport.start_server(server=server)
        channel = transport.accept(10)
        if channel:
            server.shell_ready.wait(5)
            channel.send_exit_status(0)
            channel.close()
    finally:
        transport.close()
        listening.close()


def serve_jump(listening, server, key, destination_port):
    client, _ = listening.accept()
    transport = paramiko.Transport(client)
    transport.add_server_key(key)
    try:
        transport.start_server(server=server)
        channel = transport.accept(10)
        if channel:
            destination = socket.create_connection(("127.0.0.1", destination_port), timeout=10)
            try:
                while True:
                    readable, _, _ = select.select([channel, destination], [], [], 10)
                    if not readable:
                        break
                    for source in readable:
                        data = source.recv(32768)
                        if not data:
                            return
                        (destination if source is channel else channel).sendall(data)
            finally:
                destination.close()
                channel.close()
    finally:
        transport.close()
        listening.close()


def case(name, jump_method, destination_method, jump_prompt="Password: ", destination_prompt="Password: ", kind="terminal", saved_jump=True, saved_destination=True, wrong_jump=False, wrong_destination=False, cancel=False, expect_failure=False, unmanaged_jump=False):
    with tempfile.TemporaryDirectory(prefix="sr-host-bound-") as directory:
        root = Path(directory)
        destination_listener = listener()
        jump_listener = listener()
        destination_port = destination_listener.getsockname()[1]
        jump_port = jump_listener.getsockname()[1]
        forward_listener = listener()
        forward_port = forward_listener.getsockname()[1]
        forward_listener.close()
        destination = Server("destination", destination_method, destination_prompt)
        jump = Server("jump", jump_method, jump_prompt)
        destination_key = paramiko.RSAKey.generate(2048)
        jump_key = paramiko.RSAKey.generate(2048)
        known_hosts = root / "known_hosts"
        known_hosts.write_text(
            f"[127.0.0.1]:{destination_port} {destination_key.get_name()} {destination_key.get_base64()}\n"
            f"[127.0.0.1]:{jump_port} {jump_key.get_name()} {jump_key.get_base64()}\n"
        )
        destination_secret = root / "destination-secret"
        jump_secret = root / "jump-secret"
        if saved_destination:
            destination_secret.write_text("synthetic-wrong" if wrong_destination else DESTINATION_PASSWORD)
            destination_secret.chmod(0o600)
        if saved_jump:
            jump_secret.write_text("synthetic-wrong" if wrong_jump else JUMP_PASSWORD)
            jump_secret.chmod(0o600)
        count_file = root / "askpass-count"
        count_file.write_text("")

        destination_thread = threading.Thread(
            target=serve_destination,
            args=(destination_listener, destination, destination_key),
            daemon=True,
        )
        jump_thread = threading.Thread(
            target=serve_jump,
            args=(jump_listener, jump, jump_key, destination_port),
            daemon=True,
        )
        arguments_file = root / "arguments.json"
        export_environment = dict(
            os.environ,
            SR_TEST_SSH_ARGUMENTS_FILE=str(arguments_file),
            SR_TEST_SSH_PORT=str(destination_port),
            SR_TEST_JUMP_PORT=str(jump_port),
            SR_TEST_SSH_ARGUMENT_KIND=kind,
            SR_TEST_FORWARD_PORT=str(forward_port),
        )
        exported = subprocess.run(
            ["swift", "test", "--filter", "exportTerminalPasswordArgumentsForSyntheticEndpoint"],
            cwd=REPOSITORY,
            env=export_environment,
            capture_output=True,
            text=True,
            timeout=120,
        )
        assert exported.returncode == 0 and arguments_file.exists(), f"{name}: production argument export failed"
        arguments = json.loads(arguments_file.read_text())
        proxy_index = next(i for i, value in enumerate(arguments) if value.startswith("ProxyCommand="))
        proxy = arguments[proxy_index]
        proxy = re.sub(r"'[^']*/SelectiveRemoteSSHProxy'", shlex.quote(str(PROXY_HELPER)), proxy)
        assert str(PROXY_HELPER) in proxy and proxy.endswith("''"), f"{name}: jump process unavailable"
        arguments[proxy_index] = proxy[:-2] + shlex.quote(str(known_hosts))
        if unmanaged_jump:
            arguments[proxy_index] = (
                "ProxyCommand=/usr/bin/ssh "
                f"-p {jump_port} -o NumberOfPasswordPrompts=1 "
                f"-o StrictHostKeyChecking=yes -o UserKnownHostsFile={known_hosts} "
                "-W %h:%p synthetic@127.0.0.1"
            )
        arguments[-1:-1] = ["-o", f"UserKnownHostsFile={known_hosts}"]
        if kind == "sftp":
            arguments = [
                "ControlPersist=no" if value == "ControlPersist=600" else
                "ControlMaster=no" if value == "ControlMaster=yes" else value
                for value in arguments
            ]
        destination_identity = f"destination|11111111-1111-4111-8111-111111111111|synthetic@127.0.0.1:{destination_port}"
        jump_identity = f"jump|22222222-2222-4222-8222-222222222222|synthetic@127.0.0.1:{jump_port}"
        destination_state = root / "destination-state"
        jump_state = root / "jump-state"
        for state in (destination_state, jump_state):
            state.write_text("0,0")
            state.chmod(0o600)
        environment = dict(os.environ)
        environment.update(
            DISPLAY=":0",
            SSH_ASKPASS=str(ASKPASS),
            SSH_ASKPASS_REQUIRE="force",
            SELECTIVEREMOTE_ASKPASS_TARGET_IDENTITY=destination_identity,
            SELECTIVEREMOTE_ASKPASS_OWNER_PID=str(os.getpid()),
            SELECTIVEREMOTE_JUMP_TARGET_IDENTITY=jump_identity,
            SELECTIVEREMOTE_TERMINAL_PASSWORD_STATE_FILE=str(destination_state),
            SELECTIVEREMOTE_JUMP_PASSWORD_STATE_FILE=str(jump_state),
            SR_TEST_ASKPASS_COUNT_FILE=str(count_file),
        )
        if saved_destination:
            environment["SELECTIVEREMOTE_ASKPASS_SECRET_FILE"] = str(destination_secret)
            environment["SELECTIVEREMOTE_ASKPASS_CREDENTIAL_IDENTITY"] = destination_identity
        if saved_jump:
            environment["SELECTIVEREMOTE_JUMP_SECRET_FILE"] = str(jump_secret)
            environment["SELECTIVEREMOTE_JUMP_CREDENTIAL_IDENTITY"] = jump_identity
        if cancel:
            environment["SR_TEST_ASKPASS_RESPONSES"] = "cancel"
        elif unmanaged_jump:
            environment["SR_TEST_ASKPASS_RESPONSES"] = "correct"
        elif not saved_jump or not saved_destination:
            environment["SR_TEST_ASKPASS_RESPONSES"] = "correct"
        elif wrong_jump or wrong_destination:
            environment["SR_TEST_ASKPASS_RESPONSES"] = "wrong"
        destination_thread.start()
        jump_thread.start()
        if kind == "terminal":
            result = subprocess.run(
                ["/usr/bin/ssh", *arguments],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                env=environment,
                timeout=20,
                start_new_session=True,
            )
            if cancel or expect_failure:
                assert result.returncode != 0, f"{name}: rejected authentication unexpectedly succeeded"
            else:
                assert result.returncode == 0, f"{name}: connection failed ({result.returncode})"
        else:
            process = subprocess.Popen(
                ["/usr/bin/ssh", *arguments],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                env=environment,
                start_new_session=True,
            )
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline and destination.received_role is None and process.poll() is None:
                time.sleep(0.05)
            process.terminate()
            _, error = process.communicate(timeout=5)
            assert destination.received_role is not None, f"{name}: destination authentication failed ({error[:200]!r})"
        jump_thread.join(2)
        destination_thread.join(2)
        assert "destination" not in jump.received_roles, f"{name}: jump received destination credential"
        assert "jump" not in destination.received_roles, f"{name}: destination received jump credential"
        if cancel:
            assert jump.received_role is None and destination.received_role is None, f"{name}: authentication continued after cancel"
            assert len(count_file.read_text()) == 1, f"{name}: AskPass was invoked again after cancel"
            print(f"{name}: cancelled askpass=1 jump_identity=none destination_identity=none")
            return
        if expect_failure:
            assert len(count_file.read_text()) <= 3, f"{name}: unbounded AskPass attempts"
            print(f"{name}: rejected askpass={len(count_file.read_text())} cross_host_identity=none")
            return
        assert jump.received_role in (None, "jump", "manual"), f"{name}: unexpected jump credential"
        assert destination.received_role in (None, "destination", "manual"), f"{name}: unexpected destination credential"
        print(f"{name}: jump_identity={jump.received_role or 'none'} destination_identity={destination.received_role or 'none'}")


def scope_case(name, target, credential, expect_saved):
    with tempfile.TemporaryDirectory(prefix="sr-askpass-scope-") as directory:
        path = Path(directory) / "secret"
        path.write_text(DESTINATION_PASSWORD)
        path.chmod(0o600)
        environment = dict(os.environ)
        environment.update(
            SELECTIVEREMOTE_ASKPASS_SECRET_FILE=str(path),
            SELECTIVEREMOTE_ASKPASS_OWNER_PID=str(os.getppid()),
            SR_TEST_ASKPASS_RESPONSES="wrong",
        )
        if target is not None:
            environment["SELECTIVEREMOTE_ASKPASS_TARGET_IDENTITY"] = target
        if credential is not None:
            environment["SELECTIVEREMOTE_ASKPASS_CREDENTIAL_IDENTITY"] = credential
        result = subprocess.run([str(ASKPASS), "Password: "], env=environment, capture_output=True, timeout=5)
        assert result.returncode == 0
        assert (result.stdout.strip() == DESTINATION_PASSWORD.encode()) == expect_saved, f"{name}: wrong credential scope"
        print(f"{name}: saved_identity={'allowed' if expect_saved else 'denied'}")


case("misleading_destination_prompt", "none", "keyboard-interactive", destination_prompt="Password for jump.example: ")
case("jump_password_destination_password", "password", "password")
case("jump_keyboard_interactive_destination_password", "keyboard-interactive", "password", jump_prompt="Password for destination.example: ")
case("jump_password_destination_keyboard_interactive", "password", "keyboard-interactive", destination_prompt="Password for jump.example: ")
case("jump_repeated_keyboard_interactive", "repeat", "password", jump_prompt="Password for destination.example: ")
case("destination_repeated_keyboard_interactive", "password", "repeat", destination_prompt="Password for jump.example: ")
case("sftp_through_jump", "password", "password", kind="sftp")
case("forwarding_through_jump", "password", "password", kind="forwarding")
if os.environ.get("SR_TEST_INCLUDE_CANCEL") == "1":
    case("jump_cancel", "password", "password", saved_jump=False, cancel=True)
    case("manual_jump", "password", "password", saved_jump=False)
    case("manual_destination", "password", "password", saved_destination=False)
    case("wrong_saved_jump", "password", "password", wrong_jump=True, expect_failure=True)
    case("wrong_saved_destination", "password", "password", wrong_destination=True, expect_failure=True)
    scope_case("missing_target", None, "destination|target", False)
    scope_case("mismatched_target", "jump|target", "destination|target", False)
    scope_case("ambiguous_target", "ambiguous", "ambiguous", False)
    scope_case("matching_target", "destination|target", "destination|target", True)
    case("unmanaged_jump_cannot_inherit_destination_secret", "password", "password", unmanaged_jump=True)
print("SSH_HOST_BOUND_SYNTHETIC_E2E=PASS")
