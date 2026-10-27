"""sha256sum fixture for shell transaction tests on Git for Windows."""
import hashlib
from pathlib import Path
import sys

if sys.argv[1] == '-c':
    for line in Path(sys.argv[2]).read_text().splitlines():
        digest, path = line.split(None, 1)
        if hashlib.sha256(Path(path.strip()).read_bytes()).hexdigest() != digest:
            sys.exit(1)
else:
    for path in sys.argv[1:]:
        print(hashlib.sha256(Path(path).read_bytes()).hexdigest(), ' ', path, sep='')
