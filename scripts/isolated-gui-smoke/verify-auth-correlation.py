import json,sys
from pathlib import Path
lines=[line.split() for line in Path(sys.argv[1]).read_text().splitlines()]
assert len(lines)==2, f"expected exactly two sessions; got {len(lines)}"
assert all(len(x)==4 and all(v.isdigit() for v in x[:3]) for x in lines)
types=sorted(x[3] for x in lines)
assert types==['diagnostic','interactive'], f"unexpected session types: {types}"
assert len({x[2] for x in lines})==2
observed=[json.loads(x) for x in Path(sys.argv[3]).read_text().splitlines()]
sockets={int(x['client_port']):int(x['ssh_pid']) for x in observed if 'client_port' in x and 'ssh_pid' in x}
assert all(int(x[2]) in sockets for x in lines), f"missing socket to client PID mapping: expected {[x[2] for x in lines]}, observed {sorted(sockets)}"
assert len({sockets[int(x[2])] for x in lines})==2, 'sessions do not map to distinct client processes'
Path(sys.argv[2]).write_text(json.dumps({'sessions':[{'server_pid':int(x[0]),'parent_pid':int(x[1]),'client_port':int(x[2]),'ssh_pid':sockets[int(x[2])],'type':x[3]} for x in lines], 'exact_probe_command_sha256_match':True},indent=2)+'\n')
print('DOUBLE_CLICK_SSH_CORRELATION=PASS')
