"""Build a single wget-able POSIX shell installer; no runtime Python dependency."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parts = [root.joinpath('src/core.sh').read_text(encoding='utf-8'), '\n',
         root.joinpath('src/runtime.sh').read_text(encoding='utf-8'), '\n',
         root.joinpath('src/bcw.sh').read_text(encoding='utf-8'), '\nwrite_assets() {\n']
for source, target in [('src/safe.awk', 'safe.awk'), ('src/bcw-report.jq', 'bcw-report.jq')]:
    marker = 'YTA_' + target.upper().replace('.', '_').replace('-', '_')
    parts += [f'    cat > "$RUN/{target}" <<\'{marker}\'\n',
              root.joinpath(source).read_text(encoding='utf-8').rstrip() + '\n', marker + '\n']
parts += ['}\n\nif [ "${YTA_LIBRARY_ONLY:-0}" != 1 ]; then main "$@"; fi\n']
root.joinpath('install.sh').write_text(''.join(parts), encoding='utf-8', newline='\n')
print('Built install.sh')

