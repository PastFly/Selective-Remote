"""Disposable SSH server exercising the production Terminal arguments and AskPass source."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

import paramiko


REPOSITORY = Path(sys.argv[1])
ASKPASS = Path(sys.argv[2])


class SyntheticServer(paramiko.ServerInterface):
    def __init__(self, mode):
        self.mode = mode
        self.password_attempts = 0
        self.interactive_attempts = 0
        self.shell_ready = threading.Event()

    def get_allowed_auths(self, username):
        if self.mode == "password":
            return "password"
        if self.mode == "interactive":
            return "keyboard-interactive"
        return "keyboard-interactive,password"

    def check_auth_password(self, username, password):
        self.password_attempts += 1
        if self.mode == "interactive-fallback":
            return paramiko.AUTH_FAILED
        return (
            paramiko.AUTH_SUCCESSFUL
            if password == "synthetic-correct" and self.mode != "reject"
            else paramiko.AUTH_FAILED
        )

    def check_auth_interactive(self, username, submethods):
        self.interactive_attempts += 1
        query = paramiko.InteractiveQuery("", "")
        query.add_prompt("Password: ", echo=False)
        return query

    def check_auth_interactive_response(self, responses):
        return (
            paramiko.AUTH_SUCCESSFUL
            if responses == ["synthetic-correct"]
            and self.mode in ("interactive", "interactive-fallback")
            else paramiko.AUTH_FAILED
        )

    def check_channel_request(self, kind, channel_id):
        return (
            paramiko.OPEN_SUCCEEDED
            if kind == "session"
            else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        )

    def check_channel_pty_request(self, *args):
        return True

    def check_channel_shell_request(self, channel):
        self.shell_ready.set()
        return True


def case(name, mode, saved=None, answer="correct", expected=(0, 1, 1, 0), sftp=False, jump_token=None):
    with tempfile.TemporaryDirectory(prefix="sr-ssh-auth-") as directory:
        root = Path(directory)
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(30)
        port = listener.getsockname()[1]
        server = SyntheticServer(mode)
        host_key = paramiko.RSAKey.generate(2048)

        def serve():
            try:
                client, _ = listener.accept()
                transport = paramiko.Transport(client)
                transport.add_server_key(host_key)
                transport.start_server(server=server)
                channel = transport.accept(5)
                if channel:
                    server.shell_ready.wait(3)
                    channel.send_exit_status(0)
                    channel.close()
                transport.close()
            finally:
                listener.close()

        thread = threading.Thread(target=serve, daemon=True)
        arguments_file = root / "arguments.json"
        environment = dict(
            os.environ,
            SR_TEST_SSH_ARGUMENTS_FILE=str(arguments_file),
            SR_TEST_SSH_PORT=str(port),
            SR_TEST_SSH_ARGUMENT_KIND="sftp" if sftp else "terminal",
        )
        export = subprocess.run(
            ["swift", "test", "--filter", "exportTerminalPasswordArgumentsForSyntheticEndpoint"],
            cwd=REPOSITORY,
            env=environment,
            capture_output=True,
            text=True,
            timeout=120,
        )
        assert export.returncode == 0 and arguments_file.exists(), f"{name}: argument export failed"
        arguments = json.loads(arguments_file.read_text())
        assert "NumberOfPasswordPrompts=1" in arguments
        if sftp:
            assert "PreferredAuthentications=keyboard-interactive,password" in arguments
            arguments = [
                f"ControlPath={root / 'control'}" if value.startswith("ControlPath=") else value
                for value in arguments
            ]
        else:
            assert "PreferredAuthentications=password,keyboard-interactive" in arguments
        arguments[-1:-1] = [
            "-o", f"UserKnownHostsFile={root / 'known_hosts'}",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=5",
        ]
        state_file = root / "attempt-state"
        if not sftp:
            state_file.write_text("0,0")
            state_file.chmod(0o600)
        count_file = root / "helper-count"
        count_file.write_text("")
        count_file.chmod(0o600)
        environment.update(
            DISPLAY=":0",
            SSH_ASKPASS=str(ASKPASS),
            SSH_ASKPASS_REQUIRE="force",
            SR_TEST_ASKPASS_COUNT_FILE=str(count_file),
            SR_TEST_ASKPASS_RESPONSES=answer,
        )
        if not sftp:
            environment["SELECTIVEREMOTE_TERMINAL_PASSWORD_STATE_FILE"] = str(state_file)
        if jump_token:
            environment["SELECTIVEREMOTE_JUMP_PROMPT_TOKENS"] = jump_token
        if saved is not None:
            secret_file = root / "prepared-secret"
            secret_file.write_text("synthetic-correct" if saved == "correct" else "synthetic-wrong")
            secret_file.chmod(0o600)
            environment["SELECTIVEREMOTE_ASKPASS_SECRET_FILE"] = str(secret_file)
        thread.start()
        result = subprocess.run(
            ["/usr/bin/ssh", *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=12,
            start_new_session=True,
        )
        thread.join(2)
        calls = len(count_file.read_text())
        saved_uses, visible_uses = (
            (0, 0) if sftp else tuple(map(int, state_file.read_text().split(",")))
        )
        actual = (result.returncode, calls, saved_uses, visible_uses)
        assert actual == expected, (
            f"{name}: expected {expected}, got {actual}; "
            f"ssh_error={result.stderr.decode(errors='replace')[:300]}"
        )
        print(
            f"{name}: exit={result.returncode} askpass={calls} "
            f"saved={saved_uses} visible={visible_uses} "
            f"password_auth={server.password_attempts} "
            f"interactive_auth={server.interactive_attempts}"
        )


case("password_unsaved_correct", "password", expected=(0, 1, 0, 1))
case("password_unsaved_cancel", "password", answer="cancel", expected=(-15, 1, 0, 1))
case("password_unsaved_wrong", "password", answer="wrong", expected=(255, 1, 0, 1))
case("password_saved_correct", "password", saved="correct", expected=(0, 1, 1, 0))
case("interactive_saved_correct", "interactive", saved="correct", expected=(0, 1, 1, 0))
case("mixed_saved_correct", "both", saved="correct", expected=(0, 1, 1, 0))
case("mixed_saved_reused", "interactive-fallback", saved="correct", expected=(0, 2, 2, 0))
case("password_saved_wrong", "password", saved="wrong", expected=(255, 1, 1, 0))
case("mixed_rejection_one_visible", "reject", answer="wrong", expected=(255, 2, 0, 1))
case("jump_prompt_does_not_use_destination_secret", "password", saved="correct", jump_token="127.0.0.1", expected=(0, 1, 0, 0))
case("sftp_master_cancel", "password", answer="cancel", expected=(255, 1, 0, 0), sftp=True)
case("sftp_master_wrong", "password", answer="wrong", expected=(255, 1, 0, 0), sftp=True)
print("SSH_PASSWORD_SYNTHETIC_E2E=PASS")
