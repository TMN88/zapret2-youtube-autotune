"""Exercise the real shell preparation functions with a stateful UCI fixture."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = 'geoblock block porn news anime hdrezka tiktok meta twitter discord'.split()

# Re-index anonymous sections on every call, as UCI does after delete.
UCI = r'''
import json, os, sys
from pathlib import Path
p = Path(os.environ['UCI_STATE'])
state = json.loads(p.read_text())
a = [x for x in sys.argv[1:] if x != '-q']
cmd, key = a[0], a[1]
def sections(package):
    counts = {}
    for section in state[package]:
        kind = section['type']
        index = counts.get(kind, 0)
        counts[kind] = index + 1
        yield section.get('name') or f'@{kind}[{index}]', section
if cmd == 'show':
    for name, section in sections(key):
        print(f'{key}.{name}={section["type"]}')
    sys.exit(0)
package, name, *option = key.split('.', 2)
value = None
if cmd in ('set', 'add_list'):
    option[0], value = option[0].split('=', 1)
section = next(s for n, s in sections(package) if n == name)
options = section.setdefault('options', {})
if cmd == 'get':
    result = options.get(option[0]) if option else section['type']
    if result is None: sys.exit(1)
    print(' '.join(result) if isinstance(result, list) else result)
elif cmd == 'delete':
    if option:
        if option[0] not in options: sys.exit(1)
        del options[option[0]]
    else: state[package].remove(section)
elif cmd == 'set': options[option[0]] = value
elif cmd == 'add_list': options.setdefault(option[0], []).append(value)
else: raise ValueError(cmd)
p.write_text(json.dumps(state))
'''


class PreparationTests(unittest.TestCase):
    def shell(self, command):
        return subprocess.run(['sh', '-c', '. "$1"; ' + command, 'test',
                               (ROOT / 'install.sh').as_posix()],
                              env=dict(os.environ, YTA_LIBRARY_ONLY='1'),
                              text=True, capture_output=True)

    def test_low_ram_stops_before_download(self):
        r = self.shell('awk() { echo 8080; }; curl() { echo no-http3; }; check_memory')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('8080', r.stdout)

    def test_http3_download_needs_more_headroom_than_tcp(self):
        base = 'awk() { echo 60000; }; curl() { echo no-http3; }; '
        self.assertNotEqual(self.shell(base + 'check_memory').returncode, 0)
        self.assertEqual(self.shell(base + 'QUIC=0; check_memory').returncode, 0)

    def test_cleanup_removes_downloads_but_retains_other_files(self):
        r = self.shell('d=/tmp/zapret2-youtube-autotune-$$; mkdir "$d"; '
                       'trap \'rm -f "$d/curl.tar" "$d/keep"; rmdir "$d"\' EXIT; '
                       'touch "$d/curl.tar" "$d/keep"; remove_run_downloads "$d"; '
                       '[ ! -e "$d/curl.tar" ] && [ -f "$d/keep" ]; '
                       '! remove_run_downloads /tmp/unrelated')
        self.assertEqual(r.returncode, 0, r.stderr)

    def run_preparation(self, state, command):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            fixture, data = d / 'uci.py', d / 'state.json'
            fixture.write_text(UCI, encoding='utf-8')
            data.write_text(json.dumps(state), encoding='utf-8')
            env = dict(os.environ, YTA_LIBRARY_ONLY='1', UCI_STATE=str(data),
                       UCI_FIXTURE=fixture.as_posix(), PYTHON_BIN=Path(sys.executable).as_posix())
            shell = '. "$1"; uci() { "$PYTHON_BIN" "$UCI_FIXTURE" "$@"; }; ' + command
            result = subprocess.run(['sh', '-c', shell, 'test', (ROOT / 'install.sh').as_posix()],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(data.read_text())

    def test_removes_named_and_reindexed_anonymous_strategies(self):
        main = {'name': 'main', 'type': 'zapret2', 'options': {'custom_scripts': '1', 'flowoffload': 'donttouch'}}
        hostlist = {'name': 'old_hosts', 'type': 'list', 'options': {'path': '/etc/old.txt'}}
        state = {'zapret2': [main, {'type': 'strategy'}, {'name': 'user', 'type': 'strategy'},
                             {'type': 'strategy'}, hostlist]}
        out = self.run_preparation(state, 'clear_zapret_strategies; clear_zapret_strategies')
        self.assertEqual(out['zapret2'], [dict(main, options={**main['options'], 'enabled': '0', 'custom_scripts': '0'}), hostlist])

    def test_expands_all_affected_sections_and_keeps_custom_settings(self):
        def section(name, lists):
            return {'name': name, 'type': 'section', 'options': {'community_lists': lists,
                    'interface': 'awg1', 'user_domain_list': ['example.org'], 'connection_type': 'vpn'}}
        state = {'podkop': [section('main', ['russia_inside', 'telegram', 'meta']),
                            section('extra', ['youtube', 'cloudflare']), section('xbox', ['google_play'])]}
        out = self.run_preparation(state, 'prepare_community_lists; prepare_community_lists')
        self.assertEqual(out['podkop'][0]['options']['community_lists'], COMPONENTS + ['telegram'])
        self.assertEqual(out['podkop'][1]['options']['community_lists'], ['cloudflare'])
        self.assertEqual(out['podkop'][2], state['podkop'][2])
        for before, after in zip(state['podkop'], out['podkop']):
            for key in ('interface', 'user_domain_list', 'connection_type'):
                self.assertEqual(after['options'][key], before['options'][key])

    def test_youtube_only_section_can_become_empty(self):
        state = {'podkop': [{'type': 'section', 'options': {'community_lists': ['youtube']}}]}
        out = self.run_preparation(state, 'prepare_community_lists')
        self.assertNotIn('community_lists', out['podkop'][0]['options'])

    def test_backup_and_stop_precede_strategy_removal(self):
        core = (ROOT / 'src/core.sh').read_text(encoding='utf-8')
        main = core[core.index('main() {'):]
        self.assertLess(main.index('    backup\n'), main.index('    prepare_podkop\n'))
        prepare = core[core.index('prepare_podkop() {'):core.index('\nscan() {')]
        self.assertLess(prepare.index('/etc/init.d/zapret2 stop'), prepare.index('    clear_zapret_strategies'))


if __name__ == '__main__':
    unittest.main()
