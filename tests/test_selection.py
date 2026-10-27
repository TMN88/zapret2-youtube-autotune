import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def block(strategy, target='www.youtube.com', attempts=5, fail=None):
    lines = [f'- curl_test_https_tls13 ipv4 {target} : nfqws2 {strategy}']
    for n in range(1, attempts + 1):
        lines.append(f'[attempt {n}] ' + ('curl: (28) timeout' if n == fail else 'AVAILABLE'))
    lines.append('UNAVAILABLE code=28' if fail else '!!!!! AVAILABLE !!!!!')
    return '\n'.join(lines) + '\n'


class SelectionTests(unittest.TestCase):
    def run_rank(self, log, candidates='safe\n', targets='www.youtube.com\n', repeats=5):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            for name, body in [('log', log), ('candidates', candidates), ('targets', targets)]:
                (p / name).write_text(body, encoding='utf-8')
            return subprocess.run(['awk', '-v', f'targets={(p / "targets").as_posix()}', '-v', f'repeats={repeats}',
                                   '-v', 'protocol=curl_test_https_tls13', '-f', str(ROOT / 'src/select.awk'),
                                   str(p / 'candidates'), str(p / 'log')], text=True, capture_output=True)

    def test_accepts_all_repeats(self):
        r = self.run_rank(block('safe'))
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'safe'))

    def test_rejects_one_failed_attempt_even_if_four_pass(self):
        self.assertEqual(self.run_rank(block('safe', fail=2)).returncode, 2)

    def test_rejects_incomplete_run(self):
        self.assertEqual(self.run_rank(block('safe', attempts=4)).returncode, 2)

    def test_rejects_log_injection_unknown_candidate(self):
        self.assertEqual(self.run_rank(block('safe; touch /tmp/injection')).returncode, 2)

    def test_requires_every_target(self):
        self.assertEqual(self.run_rank(block('safe'), targets='www.youtube.com\ni.ytimg.com\n').returncode, 2)

    def test_no_union_of_different_strategies(self):
        r = self.run_rank(block('one') + block('two', 'i.ytimg.com'), 'one\ntwo\n', 'www.youtube.com\ni.ytimg.com\n')
        self.assertEqual(r.returncode, 2)

    def test_rejects_duplicated_trial_blocks(self):
        self.assertEqual(self.run_rank(block('safe', fail=2) + block('safe')).returncode, 2)

    def test_prefers_no_fake_when_both_reliable(self):
        simple = '--lua-desync=multidisorder:pos=1,midsld'
        fake = '--lua-desync=fake:blob=x --lua-desync=multidisorder:pos=1,midsld'
        r = self.run_rank(block(fake) + block(simple), simple + '\n' + fake + '\n')
        self.assertEqual(r.stdout.strip(), simple)


class BuildAndShellTests(unittest.TestCase):
    def test_build_is_reproducible(self):
        before = (ROOT / 'install.sh').read_bytes()
        subprocess.run([sys.executable, str(ROOT / 'scripts/build.py')], check=True, capture_output=True)
        self.assertEqual(before, (ROOT / 'install.sh').read_bytes())

    def test_shell_syntax_and_help(self):
        subprocess.run(['sh', '-n', str(ROOT / 'install.sh')], check=True)
        result = subprocess.run(['sh', str(ROOT / 'install.sh'), '--help'], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('--rollback', result.stdout)

    def test_list_expansion_preserves_other_services(self):
        env = dict(os.environ, YTA_LIBRARY_ONLY='1')
        command = '. "$1"; expanded_lists russia_inside meta telegram custom youtube'
        r = subprocess.run(['sh', '-c', command, 'test', str(ROOT / 'install.sh')], env=env, text=True, capture_output=True, check=True)
        items = r.stdout.split()
        self.assertNotIn('youtube', items)
        self.assertNotIn('russia_inside', items)
        self.assertEqual(items.count('meta'), 1)
        self.assertIn('telegram', items)
        self.assertIn('custom', items)

    def test_candidates_are_unique_and_no_shell_metacharacters(self):
        for path in (ROOT / 'data').glob('*candidates*.txt'):
            self.assertTrue(path.is_file())
        for name in ['tcp.txt', 'quic.txt']:
            lines = (ROOT / 'data' / name).read_text().splitlines()
            self.assertEqual(len(lines), len(set(lines)))
            for line in lines:
                for forbidden in [';', '$', '`', '|', '>', '<', '\\']:
                    self.assertNotIn(forbidden, line)


if __name__ == '__main__':
    unittest.main()
