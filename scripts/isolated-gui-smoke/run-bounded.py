import subprocess
import sys

if len(sys.argv) < 3:
    raise SystemExit('timeout and command required')
try:
    seconds = float(sys.argv[1])
    if not 0 < seconds <= 180:
        raise ValueError()
    result = subprocess.run(sys.argv[2:], timeout=seconds, check=False)
except ValueError:
    raise SystemExit('invalid timeout')
except subprocess.TimeoutExpired:
    print('GUI_PROBE_TIMEOUT=YES', file=sys.stderr, flush=True)
    raise SystemExit(124)
raise SystemExit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
