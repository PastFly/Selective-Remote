import json
import socket
import time

for attempt in range(30):
    try:
        with socket.create_connection(('127.0.0.1', 52223), timeout=1) as conn:
            conn.settimeout(5)
            conn.sendall(b'TEST-ONLY-CODEX-FORWARD-REQUEST')
            data = conn.recv(1024)
            if data != b'TEST-ONLY-CODEX-FORWARD-RESPONSE':
                raise SystemExit('forward response mismatch')
            print(json.dumps({'test_id': 'SSH_LOCAL_FORWARD', 'status': 'PASS'}))
            break
    except (ConnectionRefusedError, TimeoutError, socket.timeout):
        if attempt == 29:
            raise SystemExit('synthetic local forward unavailable')
        time.sleep(1)
