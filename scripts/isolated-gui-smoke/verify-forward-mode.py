import json,socket,sys,time
kind=sys.argv[1]
assert kind in ('Remote','Dynamic')
for i in range(60):
 try:
  c=socket.create_connection(('127.0.0.1',52223),timeout=1);break
 except OSError:
  time.sleep(.5)
else: raise RuntimeError('forward listener unavailable')
c.settimeout(5)
if kind=='Dynamic':
 c.sendall(b'\x05\x01\x00'); assert c.recv(2)==b'\x05\x00'
 c.sendall(b'\x05\x01\x00\x01'+socket.inet_aton('127.0.0.1')+(52224).to_bytes(2,'big'))
 header=c.recv(4); assert len(header)==4 and header[:2]==b'\x05\x00',repr(header)
 lengths={1:4,4:16}; n=lengths.get(header[3]); assert n is not None
 buf=b''
 while len(buf)<n+2: buf+=c.recv(n+2-len(buf))
c.sendall(b'TEST-ONLY-CODEX-FORWARD-REQUEST')
assert c.recv(1024)==b'TEST-ONLY-CODEX-FORWARD-RESPONSE'
c.close()
print(json.dumps({'mode':kind,'synthetic_payload':'PASS'}))
