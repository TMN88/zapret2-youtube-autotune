"""Addressed tests for family quotas, cache, optional QUIC and failover decisions."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import test_preparation as support

ROOT=Path(__file__).resolve().parents[1]
TCP='--payload=tls_client_hello --lua-desync=tcpseg:pos=0,1:ip_id=rnd:repeats=1'
MULTI='--payload=tls_client_hello --lua-desync=multisplit:pos=1'
FAKE='--payload=tls_client_hello --lua-desync=multisplit:pos=10:seqovl=1'


class RuntimeTests(unittest.TestCase):
    shell=support.TransactionTests.shell

    def test_distinct_family_classification(self):
        r=self.shell(f"strategy_family '{TCP}'; strategy_family '{MULTI}'; strategy_family '{FAKE}'; "
            "strategy_family '--lua-desync=fake:blob=fake_default_tls --lua-desync=multisplit:pos=1'")
        self.assertEqual(r.stdout.splitlines(),['tcpseg','multi','fake','fake'])

    def test_cache_reuse_and_invalidation(self):
        for variant,expected in [('valid',0),('old',1),('wan',1),('tampered',1)]:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as d:
                p=Path(d)
                (p/'strategy-1.txt').write_text(TCP+'\n')
                (p/'strategy-2.txt').write_text(MULTI+'\n')
                (p/'cache-time').write_text('1' if variant=='old' else '199990')
                (p/'cache-context').write_text('other' if variant=='wan' else 'context')
                command=(f'OWN="{p.as_posix()}"; RUN="$OWN"; date() {{ echo 200000; }}; '
                    'cache_context() { echo context; }; '
                    'sha256sum "$OWN/strategy-1.txt" "$OWN/strategy-2.txt" > "$OWN/cache.sha256"; ')
                if variant=='tampered': command+='printf evil >> "$OWN/strategy-1.txt"; '
                r=self.shell(command+'cache_load')
                self.assertEqual(r.returncode,expected,r.stderr)

    def test_health_classifies_dns_rate_limit_server_error_and_block(self):
        for response,rc,expected in [('200 20000',0,0),('200 2',0,1),('429 10',0,2),
                                      ('503 10',0,2),('403 10',0,2),('000 0',6,2),('000 0',28,1)]:
            with self.subTest(response=response,rc=rc):
                r=self.shell(f"curl() {{ printf '%s' '{response}'; return {rc}; }}; WAN_DEV=wan; health_probe www.youtube.com/ 10000")
                self.assertEqual(r.returncode,expected,r.stderr)

    def test_one_inconclusive_endpoint_blocks_failover(self):
        r=self.shell('health_probe() { case "$1" in www*) return 1;; *) return 2;; esac; }; health_round')
        self.assertEqual(r.returncode,2)

    def decision(self, count=0, health=1, wan=True, cooldown=False, edited=False):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            (p/'config').write_text('original')
            (p/'cache-context').write_text('context')
            (p/'active').write_text('1')
            (p/'count').write_text(str(count))
            (p/'last').write_text('2000' if cooldown else '0')
            command=(f'OWN="{p.as_posix()}"; CONFIG="$OWN/config"; LOCK="$OWN/lock"; '
                'FAIL_COUNT="$OWN/count"; LAST_SWITCH="$OWN/last"; MON_STATUS="$OWN/status"; '
                'sha256sum "$CONFIG" > "$OWN/active.sha256"; '
                'sha256sum "$CONFIG" > "$OWN/cache.sha256"; '
                'uci() { :; }; date() { echo 2001; }; cache_context() { echo context; }; '
                f'wan_ready() {{ return {0 if wan else 1}; }}; health_round() {{ return {health}; }}; '
                'backup() { echo confirmed-switch; exit 0; }; ')
            if edited: command+='printf edited >> "$CONFIG"; '
            r=self.shell(command+'monitor_once')
            return r, (p/'count').read_text().strip(), (p/'status').read_text() if (p/'status').exists() else ''

    def test_exactly_three_failures_before_switch(self):
        for previous in (0,1,2):
            r,count,_=self.decision(count=previous)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(count,str(previous+1))
            self.assertEqual('confirmed-switch' in r.stdout,previous==2)

    def test_healthy_uncertain_or_wan_down_resets_failure_streak(self):
        for opts in [{'health':0},{'health':2},{'wan':False}]:
            r,count,_=self.decision(count=2,**opts)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(count,'0')
            self.assertNotIn('confirmed-switch',r.stdout)

    def test_cooldown_and_manual_edit_never_switch(self):
        for opts in [{'cooldown':True},{'edited':True}]:
            r,_,status=self.decision(count=2,**opts)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertNotIn('confirmed-switch',r.stdout)
            if opts.get('edited'): self.assertIn('suspended_config_changed',status)

    def test_optional_quic_never_scans_when_unsupported_off_or_direct_ok(self):
        for kind in ('unsupported','off','direct'):
            setup={'unsupported':'curl() { echo curl-no-http3; };',
                   'off':'QUIC_MODE=off;',
                   'direct':"curl() { echo 'Features: HTTP3'; }; quic_probe() { return 0; };"}[kind]
            r=self.shell(setup+' scan() { echo forbidden-scan; exit 99; }; configure_quic; echo "$QUIC_STATUS"')
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertNotIn('forbidden-scan',r.stdout)
            self.assertIn({'unsupported':'unsupported_curl','off':'disabled','direct':'direct_ok'}[kind],r.stdout)

    def test_runtime_service_uses_local_procd_and_bounded_polling(self):
        source=(ROOT/'src/runtime.sh').read_text(encoding='utf-8')
        self.assertIn('procd_set_param respawn 3600 5 5',source)
        self.assertIn('sleep 60',source)
        self.assertIn('-ge 900',source)
        self.assertNotIn('crontab',source)

    def test_colored_result_counts_and_reserve_warning(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            (p/'strategy-1.txt').write_text(TCP+'\n')
            (p/'strategy-2.txt').write_text(MULTI+'\n')
            r=self.shell(f'OWN="{p.as_posix()}"; QUIC_STATUS=unsupported_curl; print_results 2')
            self.assertEqual(r.returncode,0,r.stderr)
            for text in ['\x1b[','Подтверждено TCP/TLS: 2','Применено TCP/TLS: 1 | Резервных: 1',
                         'Третье семейство не подтверждено','QUIC: не применена','Failover: включён']:
                self.assertIn(text,r.stdout)

    def test_quic_is_separate_and_survives_tcp_switch(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            state={'main':{'type':'zapret2','options':{}}}
            (p/'uci.json').write_text(json.dumps(state))
            r=self.shell(f'export YTA_UCI_STATE="{p.as_posix()}/uci.json"; '
                f'uci() {{ "$YTA_PYTHON" "{(ROOT/"tests/uci_fixture.py").as_posix()}" "$@"; }}; '
                f'LAYOUT=uci; BACKUP="{p.as_posix()}"; '
                'QUIC_ARGS="--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=2"; '
                f"stage_profile 1 '{TCP}'; stage_profile 2 '{MULTI}'")
            self.assertEqual(r.returncode,0,r.stderr)
            out=json.loads((p/'uci.json').read_text())
            self.assertEqual(out['yta_1']['options']['enabled'],'0')
            self.assertEqual(out['yta_2']['options']['enabled'],'1')
            self.assertEqual(out['yta_quic']['options']['enabled'],'1')
            self.assertEqual(out['yta_quic']['options']['protocol'],['udp'])
            self.assertEqual(out['main']['options']['nfqws_ports_udp'],'443')

    def test_switch_confirms_reserves_and_restores_when_all_fail(self):
        for scenario,expected in [('healthy',2),('false_positive',3),('all_fail',1)]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as d:
                p=Path(d)
                source=(ROOT/'install.sh').read_text(encoding='utf-8').replace('/etc/init.d/zapret2','test_service')
                (p/'control.sh').write_text(source,encoding='utf-8')
                for name,text in [('config','original'),('cache-context','context'),('active','1'),
                                  ('count','2'),('last','0'),('strategy-2.txt',MULTI),('strategy-3.txt',FAKE)]:
                    (p/name).write_text(text)
                health={'healthy':'[ "$health_calls" -ne 1 ]',
                        'false_positive':'[ "$health_calls" -ne 1 ] && [ "$health_calls" -ne 3 ]',
                        'all_fail':'return 1'}[scenario]
                command=(f'. "{p.as_posix()}/control.sh"; OWN="{p.as_posix()}"; CONFIG="$OWN/config"; '
                    'LAYOUT=shell; MODE=monitor; LOCK="$OWN/lock"; FAIL_COUNT="$OWN/count"; '
                    'LAST_SWITCH="$OWN/last"; MON_STATUS="$OWN/status"; '
                    'sha256sum "$CONFIG" > "$OWN/active.sha256"; sha256sum "$CONFIG" > "$OWN/cache.sha256"; '
                    'uci() { :; }; date() { echo 2001; }; cache_context() { echo context; }; '
                    'wan_ready() { return 0; }; sleep() { :; }; '
                    'test_service() { printf "%s\\n" "$*" >> "$OWN/service.calls"; }; '
                    'stage_profile() { printf "%s\\n" "$1" >> "$OWN/trials"; }; '
                    f'health_calls=0; health_round() {{ health_calls=$((health_calls+1)); {health}; }}; '
                    'backup() { BACKUP="$OWN/backup"; RUN="$OWN/run"; mkdir "$BACKUP" "$RUN"; '
                    'cp "$CONFIG" "$BACKUP/original-config"; sha256sum "$CONFIG" > "$BACKUP/config.sha256"; '
                    '''printf 'printf restored > "%s/restored"\\n' "$OWN" > "$BACKUP/rollback.sh"; }; monitor_once''')
                r=self.shell(command)
                self.assertEqual(r.returncode,1 if scenario=='all_fail' else 0,r.stderr)
                self.assertEqual((p/'active').read_text().strip(),str(expected))
                self.assertEqual((p/'trials').read_text().splitlines(),['2'] if scenario=='healthy' else ['2','3'])
                self.assertEqual((p/'restored').exists(),scenario=='all_fail')


if __name__=='__main__': unittest.main()
