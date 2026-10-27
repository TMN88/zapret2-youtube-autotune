import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
A = '--payload=tls_client_hello --lua-desync=multisplit:pos=1'
B = '--payload=tls_client_hello --lua-desync=multidisorder:pos=1,midsld'
C = '--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5'


def block(strategy, target='www.youtube.com', attempts=3, fail=None, proto='tls13'):
    lines = [f'- curl_test_https_{proto} ipv4 {target} : nfqws2 {strategy}']
    for n in range(1, attempts + 1):
        lines.append(f'[attempt {n}] ' + ('curl: (28) timeout' if n == fail else 'AVAILABLE'))
    lines.append('UNAVAILABLE code=28' if fail else '!!!!! AVAILABLE !!!!!')
    return '\n'.join(lines) + '\n'


class SelectionTests(unittest.TestCase):
    def rank(self, log, candidates=A+'\n', targets='www.youtube.com\n', discover=0):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            for name, body in [('log', log), ('candidates', candidates), ('targets', targets)]:
                (p/name).write_text(body, encoding='utf-8')
            return subprocess.run(['awk', '-v', f'targets={(p/"targets").as_posix()}',
                '-v', 'repeats=3', '-v', 'protocol=curl_test_https_tls13', '-v', f'discover={discover}',
                '-f', (ROOT/'src/select.awk').as_posix(), (p/'candidates').as_posix(),
                (p/'log').as_posix()], text=True, capture_output=True)

    def test_all_three_alternatives_in_native_order(self):
        r = self.rank(block(A)+block(B)+block(C), A+'\n'+B+'\n'+C+'\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines(), [A, B, C])

    def test_discovery_works_with_empty_allowlist(self):
        r = self.rank(block(B), candidates='', discover=1)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, B))

    def test_rejects_one_failed_attempt(self):
        self.assertEqual(self.rank(block(A, fail=2)).returncode, 2)

    def test_rejects_incomplete_or_duplicated_blocks(self):
        for log in [block(A, attempts=2), block(A, fail=2)+block(A), block(A)+block(A)]:
            self.assertEqual(self.rank(log).returncode, 2)

    def test_requires_every_target_and_same_strategy(self):
        targets='www.youtube.com\ni.ytimg.com\n'
        self.assertEqual(self.rank(block(A), targets=targets).returncode, 2)
        self.assertEqual(self.rank(block(A)+block(B, 'i.ytimg.com'), A+'\n'+B+'\n', targets).returncode, 2)
        self.assertEqual(self.rank(block(A)+block(A, 'i.ytimg.com'), targets=targets).returncode, 0)

    def test_rejects_injection_and_process_control_options(self):
        for args in [A+'; touch /tmp/injection', A+' $(id)', A+' `id`', A+' --lua-init=evil',
                     A+' --new', A+' --hostlist=/tmp/other', A+"'", A+' --qnum=1']:
            self.assertEqual(self.rank(block(args), candidates='', discover=1).returncode, 2, args)

    def test_baseline_summary_and_other_protocol_do_not_count(self):
        for log in ['- checking without DPI bypass\n[attempt 1] AVAILABLE\n!!!!! AVAILABLE !!!!!\n',
                    f'curl_test_https_tls13 ipv4 www.youtube.com : nfqws2 {A}\n!!!!! AVAILABLE !!!!!\n',
                    block(A, proto='tls12')]:
            self.assertEqual(self.rank(log).returncode, 2)

    def test_empty_first_tls_intersection_is_empty(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            (p/'empty').write_text('')
            (p/'ok').write_text(A+'\n')
            r=subprocess.run(['awk', 'FILENAME==ARGV[1] {ok[$0]=1; next} $0 in ok',
                (p/'empty').as_posix(), (p/'ok').as_posix()], capture_output=True, text=True)
            self.assertEqual(r.stdout, '')


class BuildTests(unittest.TestCase):
    def test_build_and_posix_shell(self):
        before=(ROOT/'install.sh').read_bytes()
        subprocess.run([sys.executable, str(ROOT/'scripts/build.py')], check=True, capture_output=True)
        self.assertEqual(before, (ROOT/'install.sh').read_bytes())
        subprocess.run(['sh','-n', str(ROOT/'install.sh')], check=True)
        r=subprocess.run(['sh', str(ROOT/'install.sh'), '--help'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertIn('--rollback', r.stdout)


if __name__ == '__main__':
    unittest.main()
