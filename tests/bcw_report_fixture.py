"""Upstream-shaped scan/check report fixture for the real shell orchestration tests."""
import json
from pathlib import Path
import sys

label,kind,input_file,domain,path,take,output,scenario=sys.argv[1:]
if kind=='scan':
    args=['--payload=tls_client_hello --lua-desync=tcpseg:pos=0,1:repeats=20',
          '--payload=tls_client_hello --lua-desync=multisplit:pos=1',
          '--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5']
    if scenario=='two': args=args[:2]
    entries=[dict(protocol='HTTPS/TLS1.3',args=a,coverage=1) for a in args]
    entries+=entries[:1]  # Deliberate exact duplicate, not a fourth candidate.
else:
    entries=json.loads(Path(input_file).read_text())['strategies']
    # check's --take 1 is per protocol; these inputs are family-limited.
    seen=set();chosen=[]
    for row in entries:
        if row['protocol'] in seen: continue
        seen.add(row['protocol']);chosen.append(row)
    entries=chosen
    for row in entries:
        row.update(working=True,passes_ok=3,passes_total=3,observed='Bytes',admits=['Good','Mirage'])
        if scenario=='partial': row['passes_ok']=2
outcome='not_blocked' if scenario=='baseline' else 'found'
data=dict(schema=1,outcome=outcome,inconclusive=scenario=='baseline',domain=domain,
    control=dict(observed='NoConnect',admits=['Dead']),
    run=dict(embedded=True,dns='doh',qnum=52000,nft_table='yta_bcw_42_fixture',process_group=99,
             mark_base='0x20000000',desync_mark='0x10000000',bcw_version='0.12.1',
             workers=16 if kind=='scan' else 1,profiles_per_instance=64 if kind=='scan' else 1),
    strategies=entries)
Path(output).write_text(json.dumps(data))
