"""Real jq contract tests and mocked scanner/architecture/resource tests; no router access."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tarfile
import hashlib
import io
import unittest
import test_preparation as support

ROOT=Path(__file__).resolve().parents[1]
A='--payload=tls_client_hello --lua-desync=tcpseg:pos=0,1:repeats=20'
B='--payload=tls_client_hello --lua-desync=multisplit:pos=1'
C='--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5'
JQ=os.environ.get('YTA_TEST_JQ') or shutil.which('jq')

def report(mode='check',args=A,domain='www.youtube.com'):
    return dict(schema=1,outcome='found',domain=domain,inconclusive=False,control=dict(observed='NoConnect',admits=['Dead']),
        run=dict(embedded=True,dns='doh',qnum=52000,nft_table='yta_bcw_42_scan',process_group=99,
                 mark_base='0x20000000',desync_mark='0x10000000',bcw_version='0.12.1',
                 workers=16 if mode=='scan' else 1,profiles_per_instance=64 if mode=='scan' else 1),
        strategies=[dict(protocol='HTTPS/TLS1.3',args=args,working=True,passes_ok=3,passes_total=3,
                         observed='Bytes',admits=['Good','Mirage'])])


class JsonTests(unittest.TestCase):
    def parse(self,data,mode='causal',domain='www.youtube.com'):
        self.assertTrue(JQ,'A real jq executable is required for these tests')
        return subprocess.run([JQ,'-er','--arg','mode',mode,'--arg','domain',domain,
            '--arg','table','yta_bcw_42_scan','--argjson','pid','99','--argjson','qnum','52000',
            '--argjson','workers','16','--argjson','profiles','64','-f',str(ROOT/'src/bcw-report.jq')],
            input=json.dumps(data),capture_output=True,text=True,encoding='utf-8')

    def test_scan_and_three_complete_passes(self):
        self.assertEqual(self.parse(report('scan'),mode='scan').returncode,0)
        r=self.parse(report())
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stdout.strip(),'HTTPS/TLS1.3\t'+A)

    def test_rejects_partial_false_working_identity_and_future_schema(self):
        cases=[]
        for field,value in [('passes_ok',2),('passes_total',2),('working',False),
                             ('observed','Unobserved'),('admits',['Mirage'])]:
            d=report();d['strategies'][0][field]=value;cases.append(d)
        d=report();d['schema']=2;cases.append(d)
        d=report();del d['control'];cases.append(d)
        d=report();del d['inconclusive'];cases.append(d)
        for d in cases: self.assertNotEqual(self.parse(d).returncode,0)

    def test_rejects_wrong_kernel_namespace_and_unrelated_domain(self):
        for key,value in [('embedded',False),('qnum',200),('nft_table','fw4'),('dns','system'),
                          ('process_group',98),('workers',1024),('profiles_per_instance',1024)]:
            d=report();d['run'][key]=value
            self.assertNotEqual(self.parse(d).returncode,0,key)
        d=report();d['domain']='example.org'
        self.assertNotEqual(self.parse(d).returncode,0)

    def test_baseline_never_proves_main_strategy(self):
        d=report();d.update(outcome='not_blocked',inconclusive=True)
        self.assertNotEqual(self.parse(d).returncode,0)
        # An auxiliary host may work directly: its TLS reachability still has to pass 3/3.
        self.assertEqual(self.parse(d,mode='auxiliary').returncode,0)

    def test_broken_empty_or_unfinished_report_is_not_success(self):
        for outcome in ['broken','censored','nothing_works']:
            d=report();d['outcome']=outcome
            self.assertNotEqual(self.parse(d).returncode,0)
        d=report();d['strategies']=[]
        self.assertNotEqual(self.parse(d).returncode,0)


class AdapterTests(unittest.TestCase):
    shell=support.TransactionTests.shell

    def test_architectures_including_mt7621_endianness(self):
        for arch,byte,expected in [('aarch64_cortex-a53','1','arm64'),('mipsel_24kc','1','mipsel'),
            ('mips','1','mipsel'),('mips','2','mips'),('mips64','2','mips64'),('arm_cortex-a7','1','arm')]:
            r=self.shell(f'bcw_arch {arch} {byte}')
            self.assertEqual((r.returncode,r.stdout.strip()),(0,expected))
        self.assertNotEqual(self.shell('bcw_arch mips64el 1').returncode,0)
        self.assertNotEqual(self.shell('bcw_arch unknown 0').returncode,0)

    def test_adaptive_workers_and_memory_floor(self):
        for ram,workers,profiles in [(65536,8,16),(100000,16,64),(200000,32,128)]:
            r=self.shell(f'bcw_resources {ram}; echo "$BCW_WORKERS $BCW_PROFILES"')
            self.assertEqual(r.stdout.strip(),f'{workers} {profiles}')
        self.assertNotEqual(self.shell('bcw_resources 32000').returncode,0)
        self.assertEqual(self.shell('WORKERS_LIMIT=4; bcw_resources 200000; echo "$BCW_WORKERS"').stdout.strip(),'4')

    def test_exact_filter_mark_capability_and_real_dry_run(self):
        for help_text,expected in [('--filter-mark=<mark>',0),('--filter-mark-neg=<mark>',1),('--filter-l7=tls',1)]:
            with tempfile.TemporaryDirectory() as d:
                p=Path(d);(p/'nfq2').mkdir()
                binary=p/'nfq2/nfqws2'
                binary.write_text(f'#!/bin/sh\nif [ "$1" = --help ]; then echo "{help_text}"; exit 0; fi\nexit 0\n')
                if os.name!='nt': binary.chmod(0o700)
                r=self.shell(f'BASE="{p.as_posix()}"; RUN="$BASE"; bcw_capability')
                self.assertEqual(r.returncode,expected,r.stderr)

    def test_safe_argv_rejects_injection_and_preserves_distinct_families(self):
        data='\n'.join([A,B,C,A+';touch /tmp/x',A+' $(id)',A+' --lua-init=evil',A+' --new',
                        '--lua-desync=luaexec:code=bad'])+'\n'
        r=subprocess.run(['awk','-f',str(ROOT/'src/safe.awk')],input=data,capture_output=True,text=True)
        self.assertEqual(r.stdout.splitlines(),[A,B,C])

    def test_corrupt_download_never_runs_or_installs(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            r=self.shell(f'RUN="{p.as_posix()}"; OWN="$RUN/own"; BCW_TOOLS="$RUN/tools"; WAN_DEV=wan; '
                'bcw_arch() { echo arm64; }; command() { return 1; }; '
                'curl() { printf corrupt > "$RUN/bcw.tar.gz"; }; '
                'bcw_binary_ok() { echo executed > "$RUN/executed"; return 1; }; bcw_install')
            self.assertNotEqual(r.returncode,0)
            self.assertIn('SHA256',r.stderr)
            self.assertFalse((p/'executed').exists())
            self.assertFalse((p/'own').exists())
            self.assertFalse((p/'tools').exists())

    def test_verified_cached_binary_avoids_download(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'bin').mkdir()
            (p/'bin/owner').write_text('zapret2-youtube-autotune')
            binary=p/'bin/blockcheckw-v0.12.1-arm64';binary.write_text('trusted fixture')
            r=self.shell(f'OWN="{p.as_posix()}"; RUN="$OWN"; BCW_TOOLS="$OWN/bin"; command() {{ return 1; }}; '
                'bcw_arch() { echo arm64; }; bcw_binary_ok() { return 0; }; '
                'curl() { echo forbidden-download; exit 99; }; '
                'sha256sum "$OWN/bin/blockcheckw-v0.12.1-arm64" > "$OWN/bin/blockcheckw-v0.12.1-arm64.sha256"; '
                'bcw_install; echo "$BCW_BIN"')
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertNotIn('forbidden-download',r.stdout)
            self.assertIn('v0.12.1-arm64',r.stdout)

    def test_verified_archive_is_atomic_and_low_flash_is_rejected(self):
        for flash,success in [(10000,True),(1,False)]:
            with self.subTest(flash=flash),tempfile.TemporaryDirectory() as d:
                p=Path(d); archive=p/'fixture.tar.gz'
                with tarfile.open(archive,'w:gz') as tar:
                    content=b'cached binary fixture'
                    info=tarfile.TarInfo('blockcheckw');info.size=len(content)
                    tar.addfile(info,io.BytesIO(content))
                digest=hashlib.sha256(archive.read_bytes()).hexdigest()
                r=self.shell(f'RUN="{p.as_posix()}"; OWN="$RUN/own"; BCW_TOOLS="$RUN/tools"; WAN_DEV=wan; '
                    'bcw_arch() { echo arm64; }; command() { return 1; }; '
                    f'bcw_sha() {{ echo {digest}; }}; '
                    'curl() { cp "$RUN/fixture.tar.gz" "$RUN/bcw.tar.gz"; }; '
                    'bcw_binary_ok() { return 0; }; '
                    f'df() {{ echo "fs 20000 1000 {flash} 1% /usr"; }}; bcw_install')
                self.assertEqual(r.returncode,0 if success else 1,r.stderr)
                self.assertEqual((p/'tools/blockcheckw-v0.12.1-arm64').exists(),success)
                self.assertFalse((p/'tools/blockcheckw-v0.12.1-arm64.part').exists())

    def test_no_legacy_scanner_or_system_performance_tuning(self):
        src=''.join((ROOT/'src'/p).read_text(encoding='utf-8') for p in ['core.sh','runtime.sh','bcw.sh'])
        for forbidden in ['blockcheck2','Blockcheck2','killall','sysctl -w','rustc','cargo build','docker run']:
            self.assertNotIn(forbidden,src)
        self.assertIn('--embedded --no-conflict-cleanup',src)
        self.assertIn('--smoke-qnum-base',src)

    def test_deadline_never_creates_negative_remaining(self):
        r=self.shell('date() { echo 200; }; SCAN_DEADLINE=100; bcw_remaining')
        self.assertEqual(r.stdout.strip(),'0')

    def test_real_choose_pipeline_groups_checks_and_rejects_bad_evidence(self):
        for scenario,expected in [('three',3),('two',2),('partial',0),('baseline',0)]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as d:
                p=Path(d)
                command=(f'RUN="{p.as_posix()}"; BACKUP="$RUN"; REFRESH=1; write_assets; '
                    'bcw_prepare() { BCW_WORKERS=16; BCW_PROFILES=64; BCW_QNUM=52000; }; '
                    'bcw_run() { JOB_TABLE=yta_bcw_42_fixture; JOB_PID=99; JOB_REPORT="$RUN/report.json"; '
                    'printf "%s\\n" "$1" >> "$RUN/jobs"; '
                    f'"$YTA_PYTHON" "{(ROOT/"tests/bcw_report_fixture.py").as_posix()}" '
                    f'"$@" "$JOB_REPORT" {scenario}; }}; choose')
                r=self.shell(command)
                self.assertEqual(r.returncode,0 if expected else 1,r.stderr)
                if expected:
                    selected=(p/'selected').read_text().splitlines()
                    self.assertEqual(len(selected),expected)
                    self.assertEqual(len(set(selected)),expected)
                    jobs=(p/'jobs').read_text().splitlines()
                    self.assertEqual(jobs.count('scan'),1)
                    self.assertEqual(sum(x.startswith('check_') for x in jobs),expected)
                    self.assertEqual(sum(x.startswith('verify_') for x in jobs),expected*4)
                else:
                    self.assertNotIn('Blockcheck2',r.stdout+r.stderr)

    def test_scoped_cleanup_never_deletes_a_foreign_table(self):
        for table,deleted in [('fw4',False),('ours',True)]:
            with tempfile.TemporaryDirectory() as d:
                p=Path(d)
                command=f'BACKUP="{p.as_posix()}"; SCAN_PID=99999999; '
                command+='SCAN_TABLE="yta_bcw_$$_test"; ' if table=='ours' else 'SCAN_TABLE=fw4; '
                r=self.shell(command+'kill() { return 1; }; wait() { :; }; nft() { echo "$*"; }; stop_scan')
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertEqual('delete table' in r.stdout,deleted)

    def test_build_is_reproducible_and_posix_shell_parses(self):
        before=(ROOT/'install.sh').read_bytes()
        subprocess.run([sys.executable,str(ROOT/'scripts/build.py')],check=True,capture_output=True)
        self.assertEqual(before,(ROOT/'install.sh').read_bytes())
        subprocess.run(['sh','-n',str(ROOT/'install.sh')],check=True)


if __name__=='__main__': unittest.main()
