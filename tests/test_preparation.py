"""Exercise actual transaction functions with inert local service/UCI fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import sys
import json

ROOT=Path(__file__).resolve().parents[1]
SAFE='--payload=tls_client_hello --lua-desync=multisplit:pos=1'


class TransactionTests(unittest.TestCase):
    def shell(self, command):
        # Git for Windows supplies sh/awk, but not always sha256sum.
        shim = ('sha256sum() { "$YTA_PYTHON" "$YTA_HASH" "$@"; }; '
                'mkdir() { for arg in "$@"; do [ "$arg" = -p ] || '
                '''"$YTA_PYTHON" -c 'import os,sys; os.makedirs(sys.argv[1],exist_ok=True)' "$arg"; done; }; ''')
        if os.name == 'nt':
            shim += 'chmod() { :; }; '
        return subprocess.run(['sh','-c','. "$1"; '+shim+command,'test',(ROOT/'install.sh').as_posix()],
            env=dict(os.environ,YTA_LIBRARY_ONLY='1',YTA_PYTHON=Path(sys.executable).as_posix(),
                     YTA_HASH=(ROOT/'tests/hash_fixture.py').as_posix()),
            capture_output=True, text=True, encoding='utf-8')

    def test_banner_lists_all_manual_requirements_with_color(self):
        r=self.shell('banner')
        self.assertEqual(r.returncode, 0)
        for word in ['\x1b[', 'ОСТАНОВЛЕНА', 'podcop', 'forcop', 'forkozz', 'steer', 'FakeIP']:
            self.assertIn(word, r.stdout)

    def test_preparation_does_not_modify_other_bypasses(self):
        core=(ROOT/'src/core.sh').read_text(encoding='utf-8')
        self.assertNotIn('uci commit podkop',core)
        self.assertNotIn('opkg install',core)
        self.assertNotIn('apk add',core)
        self.assertNotIn('killall',core)

    def test_shell_profile_is_standalone_and_original_is_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            (p/'original-config').write_text('NFQWS2_OPT="old\nargs"\nNFQWS2_ENABLE=0\n')
            r=self.shell(f'LAYOUT=shell; BACKUP="{p.as_posix()}"; RUN="$BACKUP"; '
                'CONFIG="$BACKUP/config"; OWN=/etc/zapret2-youtube-autotune; '
                f"stage_profile 1 '{SAFE}'; "
                '. "$CONFIG"; printf "%s\\n" "$NFQWS2_ENABLE" "$DISABLE_CUSTOM" "$NFQWS2_OPT"')
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('1\n1\n--filter-tcp=443',r.stdout)
            self.assertIn(SAFE,r.stdout)
            self.assertIn('old', (p/'original-config').read_text())

    def test_uci_reserved_names_are_checked_before_writing_owner(self):
        r=self.shell('uci() { printf "%s\\n" "$*"; }; disable_strategies() { echo disable-all; }; '
            'OWN=/tmp/nonexistent-yta-fixture; guard_reserved_sections')
        # Fixture get must fail to indicate no pre-existing reserved names.
        self.assertNotEqual(r.returncode,0)
        self.assertIn('уже существует',r.stderr)

    def test_concurrent_config_edit_fails_without_overwrite(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d); (p/'config').write_text('new external config')
            r=self.shell(f'BACKUP="{p.as_posix()}"; LAYOUT=shell; '
                'printf "bad  %s/config\\n" "$BACKUP" > "$BACKUP/config.sha256"; assert_unchanged')
            self.assertNotEqual(r.returncode,0)
            self.assertTrue((p/'conflict').exists())
            self.assertEqual((p/'config').read_text(),'new external config')

    def test_three_uci_profiles_are_independent_and_one_is_enabled(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            state={'main':{'type':'zapret2','options':{}},
                   'user_strategy':{'type':'strategy','options':{'enabled':'1','script':'keep me'}}}
            (p/'uci.json').write_text(json.dumps(state))
            command=(f'export YTA_UCI_STATE="{p.as_posix()}/uci.json"; '
                f'uci() {{ "$YTA_PYTHON" "{(ROOT/"tests/uci_fixture.py").as_posix()}" "$@"; }}; '
                f'LAYOUT=uci; BACKUP="{p.as_posix()}"; OWN=/etc/zapret2-youtube-autotune; '
                f"stage_profile 1 '{SAFE}'; stage_profile 2 '{SAFE.replace('pos=1','pos=2')}'; "
                f"stage_profile 3 '{SAFE.replace('pos=1','pos=3')}'; "
                'disable_strategies; uci set zapret2.yta_1.enabled=1')
            r=self.shell(command)
            self.assertEqual(r.returncode,0,r.stderr)
            out=json.loads((p/'uci.json').read_text())
            self.assertEqual([k for k,v in out.items() if v['type']=='strategy' and v['options']['enabled']=='1'], ['yta_1'])
            self.assertEqual(len({out[f'yta_{n}']['options']['script'] for n in (1,2,3)}),3)
            self.assertEqual(out['user_strategy']['options']['script'],'keep me')

    def test_actual_generated_rollback_restores_original_and_stays_stopped(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d); base=p/'base'; base.mkdir()
            own=p/'own'; own.mkdir()
            (own/'strategy-3.txt').write_text('new strategy')
            original='NFQWS2_ENABLE=0\nNFQWS2_OPT="original"\n'
            (p/'original-config').write_text(original)
            (base/'config').write_text('changed')
            for name,value in [('config-path',(base/'config').as_posix()),('base-path',base.as_posix()),
                               ('layout','shell'),('was-enabled','0')]:
                (p/name).write_text(value+'\n')
            service=p/'service.sh'
            service.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{p.as_posix()}/service.log"\n')
            core=(ROOT/'src/core.sh').read_text(encoding='utf-8')
            script=core.split("<<'ROLLBACK'\n",1)[1].split('\nROLLBACK',1)[0]
            script=script.replace('[ "$(id -u)" = 0 ] || exit 1', ':')
            script=script.replace('/etc/init.d/zapret2',f'sh "{service.as_posix()}"')
            script=script.replace('/etc/init.d/youtube-failover',(p/'monitor-service.sh').as_posix())
            script=script.replace('/etc/zapret2-youtube-autotune',own.as_posix())
            (p/'rollback.sh').write_text(script,encoding='utf-8')
            for _ in range(2):
                r=subprocess.run(['sh',(p/'rollback.sh').as_posix()],capture_output=True,text=True,encoding='utf-8')
                self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual((base/'config').read_text(),original)
            self.assertFalse((own/'strategy-3.txt').exists())
            self.assertEqual((p/'service.log').read_text().splitlines(),['stop','disable','stop','disable'])

    def test_cleanup_restores_and_propagates_failure(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            (p/'rollback.sh').write_text(f'#!/bin/sh\nprintf restored > "{p.as_posix()}/restored"\n')
            r=self.shell(f'BACKUP="{p.as_posix()}"; CHANGED=1; trap cleanup EXIT; exit 7')
            self.assertEqual(r.returncode,7,r.stderr)
            self.assertTrue((p/'restored').exists())
            self.assertTrue((p/'finished').exists())

    def test_cleanup_does_not_rollback_over_conflict(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d); (p/'conflict').touch()
            (p/'rollback.sh').write_text(f'printf bad > "{p.as_posix()}/overwritten"\n')
            r=self.shell(f'BACKUP="{p.as_posix()}"; CHANGED=1; trap cleanup EXIT; exit 9')
            self.assertEqual(r.returncode,9)
            self.assertFalse((p/'overwritten').exists())


if __name__=='__main__':
    unittest.main()
