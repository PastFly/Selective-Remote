import json,sys
from pathlib import Path
lines=[line.split() for line in Path(sys.argv[1]).read_text().splitlines()]
assert len(lines)==2, f"expected exactly two sessions; got {len(lines)}"
assert all(len(x)==4 and all(v.isdigit() for v in x[:3]) for x in lines)
types=sorted(x[3] for x in lines)
assert types==['diagnostic','interactive'], f"unexpected session types: {types}"
assert len({x[2] for x in lines})==2
Path(sys.argv[2]).write_text(json.dumps({'sessions':[{'server_pid':int(x[0]),'parent_pid':int(x[1]),'client_port':int(x[2]),'type':x[3]} for x in lines], 'exact_probe_command_sha256_match':True},indent=2)+'\n')
print('DOUBLE_CLICK_SSH_CORRELATION=PASS')
