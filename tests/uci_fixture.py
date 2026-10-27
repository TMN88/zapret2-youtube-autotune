"""Small stateful UCI fixture: staging named strategies, no router access."""
import json
import os
from pathlib import Path
import sys

p=Path(os.environ['YTA_UCI_STATE'])
state=json.loads(p.read_text())
args=[x for x in sys.argv[1:] if x!='-q']
cmd,key=args[:2]
if cmd=='changes': sys.exit(0)
if cmd=='show':
    for name,section in state.items():
        print(f'zapret2.{name}={section["type"]}')
    sys.exit(0)
value=None
if cmd in ('set','add_list'):
    key,value=key.split('=',1)
_,name,*option=key.split('.',2)
if cmd=='get':
    if name not in state: sys.exit(1)
    s=state[name]
    result=s['options'].get(option[0]) if option else s['type']
    if result is None: sys.exit(1)
    print(' '.join(result) if isinstance(result,list) else result)
elif cmd=='set':
    if option: state[name]['options'][option[0]]=value
    else: state.setdefault(name,{'type':value,'options':{}})
elif cmd=='add_list': state[name]['options'].setdefault(option[0],[]).append(value)
elif cmd=='delete':
    if name not in state: sys.exit(1)
    if option: state[name]['options'].pop(option[0],None)
    else: del state[name]
else: raise ValueError(cmd)
p.write_text(json.dumps(state))
