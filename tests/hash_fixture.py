"""sha256sum fixture for shell transaction tests on Git for Windows."""
import hashlib
from pathlib import Path
import sys

if sys.argv[1] == '-c':
    data=sys.stdin.read() if sys.argv[2]=='-' else Path(sys.argv[2]).read_text()
    for line in data.splitlines():
        digest, path = line.split(None, 1)
        if hashlib.sha256(Path(path.strip()).read_bytes()).hexdigest() != digest:
            sys.exit(1)
else:
    if len(sys.argv)==1:
        print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()+'  -')
    for path in sys.argv[1:]:
        print(hashlib.sha256(Path(path).read_bytes()).hexdigest(), ' ', path, sep='')
