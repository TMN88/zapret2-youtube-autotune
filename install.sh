#!/bin/sh
# MIT. Uses the installed Blockcheck2; does not install/replace zapret2.
set -eu
VERSION=3.0.0
BASE=/opt/zapret2
OWN=/etc/zapret2-youtube-autotune
LOCK=/var/lock/zapret2-youtube-autotune.lock
WAN_NETWORK=wan
REPEATS=3
WANT=3
TIME_LIMIT=1800
MODE=autotune
BACKUP=
RUN=
SCAN_PID=
WATCH_PID=
CHANGED=0
SUCCESS=0
LOCK_HELD=0
MEDIA_FILE=
CACHED=0
QUIC_MODE=auto
QUIC_ARGS=
MONITOR=1
REFRESH=0
FAIL_COUNT=/tmp/yta-failover-count
LAST_SWITCH=/tmp/yta-last-switch
MON_STATUS=/tmp/yta-monitor.status

say() { printf '%s\n' "$*"; }
die() { printf '\033[1;91mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }
valid_name() { case "$1" in ''|*[!A-Za-z0-9_]*) return 1;; esac; }
banner() {
    printf '\033[1;97;41m ОБЯЗАТЕЛЬНАЯ РУЧНАЯ ПОДГОТОВКА ДО ЗАПУСКА \033[0m\n'
    printf '\033[1;93m%s\033[0m\n' \
      '1. zapret2 уже установлен; его служба ОСТАНОВЛЕНА.' \
      '2. YouTube отключён/исключён в podcop / forcop / forkozz / steer (Podkop / Forkop).' \
      '3. Другие обходы YouTube, VPN-перехват и FakeIP для YouTube отключены.' \
      'Скрипт не выполняет эту подготовку за вас. Проверяется только YouTube.'
}
help() {
    cat <<'HELP'
YouTube Autotune 3: OpenWrt 24.10/25.12, installed native Blockcheck2.
sh install.sh [--want 2|3] [--base /opt/zapret2] [--wan-network wan]
  --scan-seconds N        Discovery time limit per pass (default 1800).
  --media-url-file FILE   Optional fresh HTTPS googlevideo media URL from this WAN.
  --check                Read-only prerequisites, no network tests.
  --refresh              Ignore the 24-hour WAN/engine-scoped result cache.
  --no-quic              Skip optional QUIC discovery (default: auto if HTTP3 exists).
  --no-failover          Do not enable the local failover service.
  --status               Show the installed monitor status and active TCP strategy.
  --rollback BACKUP      Restore the original stopped service and configuration.
  --help | --version
Default: one verified alternative per TCP Segmentation / Multi / Fake-Seqovl family.
One active, up to two reserves; local procd failover. Optional verified QUIC only if needed.
TLS 1.2 + 1.3; no HTTP3 downloads, Podkop changes or package installation.
Supports Routerich/Manager UCI and official shell configuration; unknown layouts fail closed.
HELP
}

preflight() {
    [ "$(id -u)" = 0 ] || die 'Запустите от root.'
    [ -f /etc/openwrt_release ] || die 'Это не OpenWrt.'
    . /etc/openwrt_release
    case "$DISTRIB_RELEASE" in 24.10*|25.12*) ;; *) die 'Поддерживаются OpenWrt 24.10/25.12.';; esac
    available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    [ "${available_kb:-0}" -ge 32000 ] || die 'Для подбора недостаточно RAM (нужно 32 МБ MemAvailable).'
    for cmd in uci curl awk sed sort cmp sha256sum setsid nft ubus jsonfilter tar; do
        command -v "$cmd" >/dev/null || die "Нет $cmd. Установите недостающую зависимость вручную (opkg на 24 / apk на 25)."
    done
    case "$BASE" in /*) ;; *) die 'Нужен абсолютный --base.';; esac
    case "$BASE" in *[!A-Za-z0-9_./-]*) die 'Недопустимый --base.';; esac
    BASE=$(readlink -f "$BASE")
    [ -x "$BASE/blockcheck2.sh" ] && [ -x "$BASE/nfq2/nfqws2" ] || die 'Установите zapret2 и Blockcheck2 вручную.'
    [ -d "$BASE/blockcheck2.d/standard" ] && [ -f "$BASE/blockcheck2.d/custom/10-list.sh" ] || die 'Нет native standard/custom тестов Blockcheck2.'
    [ -x /etc/init.d/zapret2 ] || die 'Нет службы /etc/init.d/zapret2.'
    # procd status alone is insufficient on some packages.
    if /etc/init.d/zapret2 running >/dev/null 2>&1 || pidof nfqws2 >/dev/null 2>&1; then
        die 'Сначала вручную остановите zapret2 / nfqws2.'
    fi
    [ -z "$(uci changes zapret2)" ] || die 'Завершите несохранённые изменения zapret2 в LuCI/UCI.'
    if [ -f "$BASE/init.d/openwrt/uci2config" ]; then
        LAYOUT=uci
        [ "$(uci -q get zapret2.main)" = zapret2 ] || die 'Неизвестная UCI-схема: нет zapret2.main.'
        CONFIG=/etc/config/zapret2
    else
        LAYOUT=shell
        CONFIG="$BASE/config"
        [ -f "$CONFIG" ] && grep -q '^NFQWS2_OPT=' "$CONFIG" || die 'Неизвестная конфигурация zapret2.'
    fi
    WAN_DEV=$(ubus call "network.interface.$WAN_NETWORK" status | jsonfilter -e '@.l3_device')
    case "$WAN_DEV" in ''|*[!A-Za-z0-9_.:-]*) die 'Не удалось определить WAN device.';; esac
    if [ -e "$OWN" ]; then
        [ -f "$OWN/owner" ] && [ "$(cat "$OWN/owner")" = zapret2-youtube-autotune ] || die "Папка $OWN принадлежит другой программе."
    fi
    if [ "$LAYOUT" = uci ]; then guard_reserved_sections; fi
    say "YouTube Autotune $VERSION: OpenWrt $DISTRIB_RELEASE, $LAYOUT, WAN $WAN_DEV."
}

guard_reserved_sections() {
    for key in yta_1 yta_2 yta_3 yta_hosts yta_quic; do
        if uci -q get "zapret2.$key" >/dev/null && [ ! -f "$OWN/owner" ]; then die "UCI $key уже существует."; fi
    done
}

backup() {
    mkdir -p "$(dirname "$LOCK")"
    if [ "$LOCK_HELD" = 0 ]; then
        mkdir "$LOCK" 2>/dev/null || die "Есть активный/незавершённый запуск: $LOCK. Проверьте его backup перед повторным запуском."
    fi
    LOCK_HELD=1
    umask 077
    printf '%s\n' "$$" > "$LOCK/pid"
    BACKUP="/root/zapret2-youtube-backup-$(date +%Y%m%d-%H%M%S)-$$"
    RUN="/tmp/zapret2-youtube-autotune-$$"
    mkdir "$BACKUP" "$RUN"
    printf '%s\n' "$BACKUP" > "$LOCK/backup"
    printf '%s\n' "$CONFIG" > "$BACKUP/config-path"
    printf '%s\n' "$BASE" > "$BACKUP/base-path"
    printf '%s\n' "$LAYOUT" > "$BACKUP/layout"
    cp -p "$CONFIG" "$BACKUP/original-config"
    printf '0\n' > "$BACKUP/was-running"
    pidof nfqws2 >/dev/null 2>&1 && printf '1\n' > "$BACKUP/was-running" || true
    printf '0\n' > "$BACKUP/monitor-running"
    if [ -f /etc/init.d/youtube-failover ]; then
        cp -p /etc/init.d/youtube-failover "$BACKUP/monitor-service"
        printf '0\n' > "$BACKUP/monitor-enabled"
        /etc/init.d/youtube-failover enabled >/dev/null 2>&1 && printf '1\n' > "$BACKUP/monitor-enabled" || true
        /etc/init.d/youtube-failover running >/dev/null 2>&1 && printf '1\n' > "$BACKUP/monitor-running" || true
        if [ "$MODE" = autotune ]; then /etc/init.d/youtube-failover stop; fi
    fi
    # UCI services may regenerate BASE/config; preserve it separately, too.
    if [ -f "$BASE/config" ]; then cp -p "$BASE/config" "$BACKUP/base-config"; fi
    printf '0\n' > "$BACKUP/was-enabled"
    /etc/init.d/zapret2 enabled >/dev/null 2>&1 && printf '1\n' > "$BACKUP/was-enabled" || true
    [ ! -d "$OWN" ] || tar -czf "$BACKUP/owned.tar.gz" -C /etc zapret2-youtube-autotune
    sha256sum "$CONFIG" > "$BACKUP/config.sha256"
    cat > "$BACKUP/rollback.sh" <<'ROLLBACK'
#!/bin/sh
set -eu
b=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || exit 1
c=$(cat "$b/config-path"); base=$(cat "$b/base-path")
/etc/init.d/zapret2 stop >/dev/null 2>&1 || true
if [ ! -f "$b/from-monitor" ]; then
    [ ! -x /etc/init.d/youtube-failover ] || /etc/init.d/youtube-failover stop >/dev/null 2>&1 || true
fi
if [ "$(cat "$b/layout")" = uci ]; then uci -q revert zapret2 || true; fi
cp -p "$b/original-config" "$c"
if [ -f "$b/base-config" ]; then cp -p "$b/base-config" "$base/config"; fi
rm -f /etc/zapret2-youtube-autotune/youtube.txt /etc/zapret2-youtube-autotune/owner
for f in control.sh runtime.conf active active.sha256 cache-context cache-time cache.sha256 quic.txt; do
    rm -f "/etc/zapret2-youtube-autotune/$f"
done
for n in 1 2 3; do rm -f "/etc/zapret2-youtube-autotune/strategy-$n.txt"; done
if [ -f "$b/owned.tar.gz" ]; then
    tar -xzf "$b/owned.tar.gz" -C /etc
else
    # Only our fixed files; never recursive deletion of user-supplied paths.
    rm -f /etc/zapret2-youtube-autotune/youtube.txt /etc/zapret2-youtube-autotune/owner
    for n in 1 2 3; do rm -f "/etc/zapret2-youtube-autotune/strategy-$n.txt"; done
    rmdir /etc/zapret2-youtube-autotune 2>/dev/null || true
fi
if [ ! -f "$b/owned.tar.gz" ]; then
    for f in control.sh runtime.conf active active.sha256 cache-context cache-time cache.sha256 quic.txt; do
        rm -f "/etc/zapret2-youtube-autotune/$f"
    done
    rmdir /etc/zapret2-youtube-autotune 2>/dev/null || true
fi
if [ "$(cat "$b/was-enabled")" = 1 ]; then /etc/init.d/zapret2 enable; else /etc/init.d/zapret2 disable; fi
if [ -f "$b/was-running" ] && [ "$(cat "$b/was-running")" = 1 ]; then /etc/init.d/zapret2 start; fi
if [ -f "$b/monitor-service" ]; then
    cp -p "$b/monitor-service" /etc/init.d/youtube-failover
    if [ "$(cat "$b/monitor-enabled")" = 1 ]; then /etc/init.d/youtube-failover enable; else /etc/init.d/youtube-failover disable; fi
    if [ "$(cat "$b/monitor-running")" = 1 ]; then /etc/init.d/youtube-failover start; fi
else
    [ ! -x /etc/init.d/youtube-failover ] || /etc/init.d/youtube-failover disable
    rm -f /etc/init.d/youtube-failover
fi
printf 'Исходная конфигурация и состояние служб восстановлены.\n'
ROLLBACK
    chmod 700 "$BACKUP/rollback.sh"
    # Survives a killed parent. Never restores over a detected concurrent edit.
    cat > "$BACKUP/watchdog.sh" <<'WATCHDOG'
#!/bin/sh
b=$1; parent=$2
while kill -0 "$parent" 2>/dev/null; do
    [ ! -f "$b/finished" ] || exit 0
    sleep 5
done
if [ -f "$b/scan-pid" ]; then
    p=$(cat "$b/scan-pid")
    kill -s TERM -- "-$p" 2>/dev/null || true
    sleep 2
    kill -s KILL -- "-$p" 2>/dev/null || true
    nft delete table inet "blockcheck2-$p" 2>/dev/null || true
fi
if [ -f "$b/changed" ] && [ ! -f "$b/conflict" ] && [ ! -f "$b/finished" ]; then
    sh "$b/rollback.sh" > "$b/watchdog.log" 2>&1 || exit 1
fi
if [ ! -f "$b/changed" ] && [ ! -f "$b/finished" ] && [ -f "$b/monitor-service" ] && [ "$(cat "$b/monitor-running")" = 1 ]; then
    /etc/init.d/youtube-failover start >> "$b/watchdog.log" 2>&1 || exit 1
fi
if [ "$(cat /var/lock/zapret2-youtube-autotune.lock/pid 2>/dev/null)" = "$parent" ]; then
    rm -f /var/lock/zapret2-youtube-autotune.lock/pid /var/lock/zapret2-youtube-autotune.lock/backup
    rmdir /var/lock/zapret2-youtube-autotune.lock 2>/dev/null || true
fi
WATCHDOG
    setsid sh "$BACKUP/watchdog.sh" "$BACKUP" "$$" </dev/null > "$BACKUP/watchdog.log" 2>&1 &
    WATCH_PID=$!
    say "Backup и логи: $BACKUP"
    say "Ручной откат: sh $BACKUP/rollback.sh"
}

stop_scan() {
    [ -n "$SCAN_PID" ] || return 0
    kill -s TERM -- "-$SCAN_PID" 2>/dev/null || true
    n=0
    while kill -0 "$SCAN_PID" 2>/dev/null && [ "$n" -lt 5 ]; do sleep 1; n=$((n+1)); done
    kill -s KILL -- "-$SCAN_PID" 2>/dev/null || true
    wait "$SCAN_PID" 2>/dev/null || true
    # Only this invocation's table; no global blockcheck/nfqws sweep.
    nft delete table inet "blockcheck2-$SCAN_PID" 2>/dev/null || true
    SCAN_PID=
    rm -f "$BACKUP/scan-pid"
}
cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    stop_scan
    if [ "$SUCCESS" != 1 ] && [ "$CHANGED" = 1 ]; then
        if [ -f "$BACKUP/conflict" ]; then
            say "Параллельные изменения: автоматическая перезапись остановлена. Backup: $BACKUP" >&2
        else
          printf '\033[1;93mПодбор/переключение не завершено — выполняется откат.\033[0m\n' >&2
          if ! sh "$BACKUP/rollback.sh"; then
            say "Автовозврат не завершён: sh $BACKUP/rollback.sh" >&2
            exit 1
          fi
        fi
    fi
    if [ -d "$BACKUP" ]; then
        if [ "$SUCCESS" != 1 ] && [ "$CHANGED" = 0 ] && [ -f "$BACKUP/monitor-service" ] && [ "$(cat "$BACKUP/monitor-running")" = 1 ]; then /etc/init.d/youtube-failover start; fi
        : > "$BACKUP/finished"
    fi
    [ -z "$WATCH_PID" ] || kill "$WATCH_PID" 2>/dev/null || true
    if [ "$LOCK_HELD" = 1 ]; then rm -f "$LOCK/pid" "$LOCK/backup"; rmdir "$LOCK" 2>/dev/null || true; fi
    exit "$rc"
}

assert_unchanged() {
    if ! sha256sum -c "$BACKUP/config.sha256" >/dev/null || { [ "$LAYOUT" = uci ] && [ -n "$(uci changes zapret2)" ]; }; then
        : > "$BACKUP/conflict"
        die 'Конфигурация изменена другим процессом; остановка без её перезаписи.'
    fi
}

prepare_blockcheck() {
    # Private test tree; upstream code and binary versions remain matched.
    mkdir -p "$RUN/bc/blockcheck2.d/discover" "$RUN/bc/blockcheck2.d/verify"
    for d in common lua nfq2 mdig binaries; do
        [ ! -d "$BASE/$d" ] || ln -s "$BASE/$d" "$RUN/bc/$d"
    done
    cp "$BASE/blockcheck2.sh" "$RUN/bc/blockcheck2.sh"
    cp "$BASE/blockcheck2.d/standard/"* "$RUN/bc/blockcheck2.d/discover/"
    cp "$BASE/blockcheck2.d/custom/10-list.sh" "$RUN/bc/blockcheck2.d/verify/"
    : > "$RUN/bc/config"
    # Hook uses public pktws test API rather than rewriting the installed engine.
    # Name sorts before native scripts, so it is sourced before any trials.
    cat > "$RUN/bc/blockcheck2.d/discover/00-yta.sh" <<'HOOK'
pktws_curl_test_update()
{
    local yta_code family count
    case " $* " in
        *--payload=quic_initial*) family=quic; count=${YTA_QUIC:-0};;
        *seqovl=*|*--lua-desync=fake:*) family=fake; count=${YTA_FAKE:-0};;
        *--lua-desync=tcpseg:*) family=tcpseg; count=${YTA_TCPSEG:-0};;
        *--lua-desync=multisplit:*|*--lua-desync=multidisorder:*) family=multi; count=${YTA_MULTI:-0};;
        *) return 1;;
    esac
    [ "$count" -lt 3 ] || return 0
    pktws_curl_test "$@"; yta_code=$?
    if [ "$yta_code" = 0 ]; then
        shift; shift
        strategy="${strategy:-$*}"
        # Only successes are counted; the outer parser also checks all attempts.
        case "$family" in tcpseg) YTA_TCPSEG=$((count+1));; multi) YTA_MULTI=$((count+1));; fake) YTA_FAKE=$((count+1));; quic) YTA_QUIC=$((count+1));; esac
        if [ "${YTA_QUIC:-0}" -ge 3 ] || { [ "${YTA_TCPSEG:-0}" -ge 3 ] && [ "${YTA_MULTI:-0}" -ge 3 ] && [ "${YTA_FAKE:-0}" -ge 3 ]; }; then unprepare_all; exit 0; fi
    fi
    return "$yta_code"
}
HOOK
    export YTA_CURL="$(command -v curl)" YTA_WAN="$WAN_DEV"
    cat > "$RUN/curl-wrapper" <<'WRAPPER'
#!/bin/sh
exec "$YTA_CURL" --interface "$YTA_WAN" --noproxy '*' "$@"
WRAPPER
    chmod 700 "$RUN/curl-wrapper"
    printf '%s\n' www.youtube.com i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg youtubei.googleapis.com redirector.googlevideo.com > "$RUN/targets"
}

scan() {
    label=$1; test=$2; proto=$3; targets=$4
    log="$BACKUP/$label.log"
    say "Blockcheck2: $label (только YouTube, $REPEATS последовательных попытки)."
    # Start directly via setsid: recorded PID equals the engine's process group/table ID.
    env ZAPRET_BASE="$RUN/bc" ZAPRET_RW="$RUN/bc" ZAPRET_CONFIG="$RUN/bc/config" \
      NFQWS2="$BASE/nfq2/nfqws2" MDIG="$BASE/mdig/mdig" SIMULATE=0 SKIP_PKTWS=0 \
      CURL="$RUN/curl-wrapper" TEST="$test" DOMAINS="$(cat "$targets")" BATCH=1 IPVS=4 \
      SCANLEVEL=force PARALLEL=0 REPEATS="$REPEATS" FWTYPE=nftables \
      LIST_HTTPS_TLS13="$RUN/candidates" LIST_HTTPS_TLS12="$RUN/candidates" LIST_QUIC="$RUN/candidates" \
      ENABLE_HTTP=0 ENABLE_HTTPS_TLS12="$([ "$proto" = tls12 ] && echo 1 || echo 0)" \
      ENABLE_HTTPS_TLS13="$([ "$proto" = tls13 ] && echo 1 || echo 0)" ENABLE_HTTP3="$([ "$proto" = quic ] && echo 1 || echo 0)" \
      SECURE_DNS=1 SKIP_DNSCHECK=1 SKIP_IPBLOCK=1 DOH_SERVER=https://dns.google/dns-query \
      CURL_MAX_TIME=8 CURL_MAX_TIME_DOH=8 CURL_HTTPS_GET=1 PACE=300 \
      setsid sh "$RUN/bc/blockcheck2.sh" > "$log" 2>&1 &
    SCAN_PID=$!
    printf '%s\n' "$SCAN_PID" > "$BACKUP/scan-pid"
    seconds=0
    while kill -0 "$SCAN_PID" 2>/dev/null; do
        if [ "$seconds" -ge "$TIME_LIMIT" ]; then
            say "Лимит времени $label; используем только завершённые успешные тесты."
            stop_scan
            return 0
        fi
        sleep 2; seconds=$((seconds+2))
    done
    scan_rc=0; wait "$SCAN_PID" || scan_rc=$?
    stop_scan
    [ "$scan_rc" = 0 ] || die "Blockcheck2: код $scan_rc, см. $log"
}

select_log() {
    # One parser for discovered and allowlisted validation candidates.
    awk -v targets="$2" -v repeats="$REPEATS" -v protocol="$3" -v discover="$4" \
      -f "$RUN/select.awk" "$RUN/candidates" "$1"
}

choose() {
    if [ "$REFRESH" = 0 ] && cache_load; then CACHED=1; say 'Используются сохранённые результаты (тот же WAN/движок, не старше 24 часов).'; return; fi
    printf '%s\n' www.youtube.com > "$RUN/discovery-target"
    : > "$RUN/candidates"
    scan discover-tls13 discover tls13 "$RUN/discovery-target"
    select_log "$BACKUP/discover-tls13.log" "$RUN/discovery-target" curl_test_https_tls13 1 > "$RUN/pool" || true
    awk '!seen[$0]++' "$RUN/pool" > "$RUN/candidates"
    : > "$RUN/selected"
    if [ -s "$RUN/candidates" ]; then verify_candidates primary; fi
    # Fallback only when the verified pool is short; never re-test old candidates.
    if [ "$(family_count "$RUN/selected")" -lt "$WANT" ]; then
        cp "$RUN/candidates" "$RUN/tried"
        scan discover-tls12 discover tls12 "$RUN/discovery-target"
        select_log "$BACKUP/discover-tls12.log" "$RUN/discovery-target" curl_test_https_tls12 1 > "$RUN/extra" || true
        awk 'FILENAME==ARGV[1] {seen[$0]=1; next} !seen[$0]++' "$RUN/tried" "$RUN/extra" > "$RUN/candidates"
        if [ -s "$RUN/candidates" ]; then verify_candidates fallback; fi
    fi
    validated_count=$(family_count "$RUN/selected")
    if [ "$validated_count" -lt 2 ]; then
        printf '\033[1;91mПодтверждено TCP/TLS: %s из 3 | Применено: 0\033[0m\n' "$validated_count"
        die 'Меньше двух разных семейств прошли все цели и оба TLS. Конфигурация не менялась.'
    fi
}

verify_candidates() {
    batch=$1
    scan "verify-$batch-tls13" verify tls13 "$RUN/targets"
    select_log "$BACKUP/verify-$batch-tls13.log" "$RUN/targets" curl_test_https_tls13 0 > "$RUN/ok13" || true
    scan "verify-$batch-tls12" verify tls12 "$RUN/targets"
    select_log "$BACKUP/verify-$batch-tls12.log" "$RUN/targets" curl_test_https_tls12 0 > "$RUN/ok12" || true
    awk 'FILENAME==ARGV[1] {ok[$0]=1; next} $0 in ok' "$RUN/ok13" "$RUN/ok12" >> "$RUN/selected"
}

disable_strategies() {
    for section in $(uci show zapret2 | sed -n 's/^zapret2\.\([^=]*\)=strategy$/\1/p'); do
        uci set "zapret2.$section.enabled=0"
    done
}

stage_profile() {
    number=$1; args=$2
    if [ "$LAYOUT" = uci ]; then
        disable_strategies
        uci set zapret2.yta_hosts=list
        uci set "zapret2.yta_hosts.path=$OWN/youtube.txt"
        uci set "zapret2.yta_$number=strategy"
        uci set "zapret2.yta_$number.enabled=1"
        uci set "zapret2.yta_$number.port=443"
        uci -q delete "zapret2.yta_$number.protocol" || true
        uci add_list "zapret2.yta_$number.protocol=tcp"
        uci -q delete "zapret2.yta_$number.filter_l3" || true
        uci add_list "zapret2.yta_$number.filter_l3=ipv4"
        uci -q delete "zapret2.yta_$number.filter_l7" || true
        uci add_list "zapret2.yta_$number.filter_l7=tls"
        uci -q delete "zapret2.yta_$number.hostlist" || true
        uci add_list "zapret2.yta_$number.hostlist=yta_hosts"
        uci set "zapret2.yta_$number.script=$args"
        uci set zapret2.main.enabled=1
        uci set zapret2.main.custom_scripts=0
        uci set zapret2.main.nfqws_ports_tcp=443
        uci set zapret2.main.nfqws_ports_udp=
        uci set "zapret2.main.openwrt_wan4=$WAN_NETWORK"
        uci set zapret2.main.flowoffload=donttouch
        uci set zapret2.main.disable_ipv6=1
        stage_quic
        uci changes zapret2 > "$BACKUP/planned.changes"
    else
        cp -p "$BACKUP/original-config" "$RUN/config.new"
        # Appended assignments override older multiline assignments without corrupting them.
        cat >> "$RUN/config.new" <<EOF

# YouTube Autotune: one independently verified alternative
NFQWS2_ENABLE=1
NFQWS2_PORTS_TCP=443
NFQWS2_PORTS_UDP='${QUIC_ARGS:+443}'
NFQWS2_OPT='--filter-tcp=443 --filter-l7=tls --hostlist=$OWN/youtube.txt $args ${QUIC_ARGS:+--new --filter-udp=443 --filter-l7=quic --hostlist=$OWN/youtube.txt $QUIC_ARGS}'
DISABLE_CUSTOM=1
DISABLE_IPV6=1
MODE_FILTER=none
FLOWOFFLOAD=donttouch
OPENWRT_WAN4='$WAN_NETWORK'
EOF
        mv "$RUN/config.new" "$CONFIG"
        sha256sum "$CONFIG" > "$BACKUP/config.sha256"
    fi
}

probe() {
    p_target=$1; p_expected=$2; p_min=$3
    p_metrics=$(curl --interface "$WAN_DEV" --noproxy '*' -4 --http1.1 \
      --connect-timeout 5 --max-time 20 -sS -o /dev/null \
      -w '%{http_code} %{size_download}' "https://$p_target") || return 1
    [ -z "$BACKUP" ] || printf '%s %s\n' "$p_target" "$p_metrics" >> "$BACKUP/installed-verification.log"
    set -- $p_metrics
    case "$p_expected:$1" in 200:200|endpoint:200|endpoint:404|endpoint:405) ;; *) return 1;; esac
    awk -v actual="$2" -v minimum="$p_min" 'BEGIN {exit !(actual>=minimum)}'
}

verify_installed() {
    for attempt in 1 2 3; do
        probe www.youtube.com/ 200 10000 || return 1
        probe i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg 200 1000 || return 1
        probe youtubei.googleapis.com/ endpoint 0 || return 1
        probe redirector.googlevideo.com/ endpoint 0 || return 1
    done
    if [ -n "$MEDIA_FILE" ]; then
        # URL kept in a root-only curl config, never included in logs/argv.
        m=$(curl --config "$RUN/media.curl" --interface "$WAN_DEV" --noproxy '*' -4 \
          --range 0-1048575 --max-time 30 -sS -o /dev/null -w '%{http_code} %{size_download} %{content_type}') || return 1
        set -- $m
        case "$1/$3" in 206/video/*|200/video/*|206/audio/*|200/audio/*) ;; *) return 1;; esac
        [ "$2" -ge 65536 ] || return 1
    fi
}

prepare_media() {
    [ -n "$MEDIA_FILE" ] || return 0
    [ -f "$MEDIA_FILE" ] || die 'Нет файла media URL.'
    [ "$(awk 'END {print NR}' "$MEDIA_FILE")" -le 1 ] || die 'Ожидается одна строка media URL.'
    url=$(cat "$MEDIA_FILE")
    case "$url" in *[![:print:]]*|*'"'*|*'\\'*) die 'Недопустимые символы media URL.';; esac
    case "$url" in https://*/*) ;; *) die 'Нужен HTTPS media URL.';; esac
    host=${url#https://}; host=${host%%/*}
    case "$host" in *[!A-Za-z0-9.-]*|'') die 'Недопустимый media host.';; *.googlevideo.com) ;; *) die 'Нужен домен *.googlevideo.com.';; esac
    printf 'url = "%s"\n' "$url" > "$RUN/media.curl"
}

apply_profiles() {
    assert_unchanged
    CHANGED=1; : > "$BACKUP/changed"
    if [ "$CACHED" = 1 ] && [ -s "$OWN/quic.txt" ]; then cp "$OWN/quic.txt" "$BACKUP/cached-quic.txt"; fi
    mkdir -p "$OWN"
    rm -f "$OWN/quic.txt"
    printf 'zapret2-youtube-autotune\n' > "$OWN/owner"
    printf '%s\n' youtube.com youtu.be ytimg.com googlevideo.com youtubei.googleapis.com youtube.googleapis.com > "$OWN/youtube.txt"
    chmod 755 "$OWN"; chmod 644 "$OWN/youtube.txt"
    accepted=0; trial=0
    : > "$RUN/accepted-families"
    while IFS= read -r args; do
        chosen_family=$(strategy_family "$args")
        grep -qx "$chosen_family" "$RUN/accepted-families" && continue
        trial=$((trial+1))
        "$BASE/nfq2/nfqws2" --dry-run --qnum=300 \
          "--lua-init=@$BASE/lua/zapret-lib.lua" "--lua-init=@$BASE/lua/zapret-antidpi.lua" \
          --filter-tcp=443 --filter-l7=tls "--hostlist=$OWN/youtube.txt" $args > "$BACKUP/dry-run-$trial.log" 2>&1 || continue
        n=$((accepted+1))
        passed=0
        if [ "$CACHED" = 1 ]; then passed=1; else
        assert_unchanged
        stage_profile "$n" "$args"
        /etc/init.d/zapret2 start > "$BACKUP/start-$trial.log" 2>&1 || die 'Не удалось запустить zapret2.'
        sleep 2
        if pidof nfqws2 >/dev/null && verify_installed; then passed=1; fi
        /etc/init.d/zapret2 stop >> "$BACKUP/start-$trial.log" 2>&1 || die 'Не удалось остановить пробный профиль.'
        # Detect concurrent writes before reverting our staged UCI delta.
        sha256sum -c "$BACKUP/config.sha256" >/dev/null || { : > "$BACKUP/conflict"; die 'Параллельная запись конфигурации.'; }
        if [ "$LAYOUT" = uci ]; then
            uci changes zapret2 > "$RUN/current.changes"
            cmp -s "$RUN/current.changes" "$BACKUP/planned.changes" || { : > "$BACKUP/conflict"; die 'Параллельные UCI-изменения.'; }
            uci revert zapret2
        fi
        fi
        if [ "$passed" = 1 ]; then
            accepted=$n
            printf '%s\n' "$chosen_family" >> "$RUN/accepted-families"
            printf '%s\n' "$args" > "$BACKUP/strategy-$n.txt"
            say "Стратегия $n прошла независимую проверку через службу."
        fi
        [ "$accepted" -lt "$WANT" ] || break
    done < "$RUN/selected"
    if [ "$accepted" -lt 2 ]; then
        printf '\033[1;91mПодтверждено через службу: %s | Итоговое применение: 0 — откат\033[0m\n' "$accepted"
        die 'Через службу прошли меньше двух стратегий; откат.'
    fi
    for n in 1 2 3; do
        rm -f "$OWN/strategy-$n.txt"
        [ ! -f "$BACKUP/strategy-$n.txt" ] || cp "$BACKUP/strategy-$n.txt" "$OWN/strategy-$n.txt"
    done
    assert_unchanged
    if [ "$LAYOUT" = uci ]; then
        for n in 1 2 3; do uci -q delete "zapret2.yta_$n" || true; done
        for n in $(seq 1 "$accepted"); do stage_profile "$n" "$(cat "$BACKUP/strategy-$n.txt")"; done
        disable_strategies
        uci set zapret2.yta_1.enabled=1
        uci commit zapret2
    else stage_profile 1 "$(cat "$BACKUP/strategy-1.txt")"
    fi
    /etc/init.d/zapret2 start > "$BACKUP/final-start.log" 2>&1 || die 'Не удалось включить итоговую стратегию.'
    sleep 2
    pidof nfqws2 >/dev/null || die 'Итоговая стратегия не запущена.'
    if [ "$CACHED" = 1 ]; then verify_installed || die 'Сохранённая активная стратегия не прошла текущую проверку; откат. Повторите с --refresh.'; fi
    /etc/init.d/zapret2 enable
    sha256sum "$CONFIG" > "$BACKUP/config.sha256"
    configure_quic
    install_runtime
    SUCCESS=1
    : > "$BACKUP/finished"
    print_results "$accepted"
    say "Стратегии: $OWN/strategy-N.txt; backup и логи: $BACKUP"
    say "Проверены IPv4 TCP/TLS; QUIC: $QUIC_STATUS. Failover: $MONITOR."
    if [ -z "$MEDIA_FILE" ]; then say 'Поток видео не тестировался: для него нужен свежий --media-url-file и проверка на LAN-устройстве.'; fi
}

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h) help; return;; --version) say "$VERSION"; return;; --check) MODE=check;;
            --no-quic) QUIC_MODE=off;; --refresh) REFRESH=1;; --no-failover) MONITOR=0;;
            --monitor-loop|--failover-once|--status) runtime_main "$1"; return;;
            --base|--wan-network|--want|--scan-seconds|--media-url-file)
                [ "$#" -ge 2 ] || die "Нет значения $1"
                opt=$1; shift
                case "$opt" in --base) BASE=$1;; --wan-network) WAN_NETWORK=$1;; --want) WANT=$1;; --scan-seconds) TIME_LIMIT=$1;; --media-url-file) MEDIA_FILE=$1;; esac;;
            --rollback)
                [ "$#" = 2 ] || die 'Нужны только --rollback и backup.'
                resolved=$(readlink -f "$2")
                case "$resolved" in /root/zapret2-youtube-backup-*) ;; *) die 'Недопустимый backup.';; esac
                exec sh "$resolved/rollback.sh";;
            *) die "Неизвестный параметр: $1";;
        esac
        shift
    done
    banner
    valid_name "$WAN_NETWORK" || die 'Недопустимое имя WAN.'
    case "$WANT" in 2|3) ;; *) die '--want: только 2 или 3.';; esac
    case "$TIME_LIMIT" in ''|*[!0-9]*) die 'Некорректный --scan-seconds.';; esac
    [ "$TIME_LIMIT" -ge 10 ] && [ "$TIME_LIMIT" -le 7200 ] || die 'Лимит сканирования: 10–7200 секунд.'
    preflight
    [ "$MODE" != check ] || return 0
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM
    backup
    write_assets
    prepare_media
    prepare_blockcheck
    choose
    apply_profiles
}

# Family-aware result cache and local OpenWrt procd failover. No external scheduler.
print_results() {
    result_count=$1
    printf '\n\033[1;97;42m РЕЗУЛЬТАТ YOUTUBE AUTOTUNE \033[0m\n'
    printf '\033[1;92mПодтверждено TCP/TLS: %s из 3 семейств\033[0m\n' "$result_count"
    printf '\033[1;96mПрименено TCP/TLS: 1 | Резервных: %s\033[0m\n' "$((result_count-1))"
    for result_n in 1 2 3; do
        [ -s "$OWN/strategy-$result_n.txt" ] || continue
        result_family=$(strategy_family "$(cat "$OWN/strategy-$result_n.txt")")
        case "$result_family" in tcpseg) result_label='TCP Segmentation';; multi) result_label='Multisplit/Multidisorder';; fake) result_label='Fake TLS/Seqovl';; esac
        if [ "$result_n" = 1 ]; then printf '\033[1;92m  %s. %s — АКТИВНА\033[0m\n' "$result_n" "$result_label";
        else printf '\033[1;96m  %s. %s — РЕЗЕРВ\033[0m\n' "$result_n" "$result_label"; fi
    done
    if [ "$QUIC_STATUS" = verified ]; then printf '\033[1;92mQUIC: отдельно проверена и применена 1 UDP-стратегия\033[0m\n';
    else printf '\033[1;93mQUIC: не применена (%s)\033[0m\n' "$QUIC_STATUS"; fi
    if [ "$MONITOR" = 1 ]; then printf '\033[1;92mFailover: включён (3 сбоя → проверка резерва → переключение)\033[0m\n';
    else printf '\033[1;93mFailover: выключен\033[0m\n'; fi
    if [ "$result_count" -lt 3 ]; then printf '\033[1;93mТретье семейство не подтверждено; непроверенная стратегия не добавлена.\033[0m\n'; fi
    if [ "$CACHED" = 1 ]; then printf '\033[1;93mИспользован сохранённый результат; активная стратегия проверена сейчас.\033[0m\n'; fi
}
strategy_family() {
    case "$1" in
        *seqovl=*|*--lua-desync=fake:*) echo fake;;
        *--lua-desync=tcpseg:*) echo tcpseg;;
        *--lua-desync=multisplit:*|*--lua-desync=multidisorder:*) echo multi;;
        *) echo unknown;;
    esac
}
family_count() {
    awk '/seqovl=|--lua-desync=fake:/ {a["fake"]=1;next} /--lua-desync=tcpseg:/ {a["tcpseg"]=1;next} /--lua-desync=multisplit:|--lua-desync=multidisorder:/ {a["multi"]=1} END {for(k in a)n++; print n+0}' "$1"
}
cache_context() {
    {
        printf '%s\n' 'youtube-families-tls12-tls13-v3' "$BASE" "$LAYOUT" "$WAN_NETWORK" "$WAN_DEV"
        cat /etc/openwrt_release
        sha256sum "$BASE/blockcheck2.sh" "$BASE/nfq2/nfqws2" "$BASE/blockcheck2.d/standard/"*.sh "$BASE/blockcheck2.d/standard/def.inc"
        curl --version
        ubus call "network.interface.$WAN_NETWORK" status | jsonfilter -e '@["ipv4-address"][0].address' -e '@.route[*].nexthop'
    } | sha256sum | awk '{print $1}'
}
cache_load() {
    [ -f "$OWN/cache-time" ] && [ -f "$OWN/cache.sha256" ] && [ -f "$OWN/cache-context" ] || return 1
    cached_time=$(cat "$OWN/cache-time"); now=$(date +%s)
    case "$cached_time" in ''|*[!0-9]*) return 1;; esac
    age=$((now-cached_time))
    [ "$age" -ge 0 ] && [ "$age" -le 86400 ] || return 1
    [ "$(cache_context)" = "$(cat "$OWN/cache-context")" ] || return 1
    sha256sum -c "$OWN/cache.sha256" >/dev/null 2>&1 || return 1
    : > "$RUN/selected"
    for index in 1 2 3; do [ ! -s "$OWN/strategy-$index.txt" ] || cat "$OWN/strategy-$index.txt" >> "$RUN/selected"; done
    [ "$(family_count "$RUN/selected")" -ge 2 ]
}

stage_quic() {
    uci -q delete zapret2.yta_quic || true
    [ -n "$QUIC_ARGS" ] || return 0
    uci set zapret2.yta_quic=strategy
    uci set zapret2.yta_quic.enabled=1
    uci set zapret2.yta_quic.port=443
    uci add_list zapret2.yta_quic.protocol=udp
    uci add_list zapret2.yta_quic.filter_l3=ipv4
    uci add_list zapret2.yta_quic.filter_l7=quic
    uci add_list zapret2.yta_quic.hostlist=yta_hosts
    uci set "zapret2.yta_quic.script=$QUIC_ARGS"
    uci set zapret2.main.nfqws_ports_udp=443
}
quic_probe() {
    q=$(curl --interface "$WAN_DEV" --noproxy '*' -4 --http3-only --connect-timeout 5 --max-time 12 \
      -sS -o /dev/null -w '%{http_code} %{size_download} %{http_version}' https://www.youtube.com/) || return 1
    set -- $q
    [ "$#" = 3 ] || return 1
    [ "$1" = 200 ] && [ "$3" = 3 ] && awk -v bytes="$2" 'BEGIN {exit !(bytes>=10000)}'
}
configure_quic() {
    QUIC_STATUS=not_needed
    if [ "$QUIC_MODE" = off ]; then QUIC_STATUS=disabled; return; fi
    if ! curl --version | grep -q ' HTTP3'; then QUIC_STATUS=unsupported_curl; return; fi
    # Need means: healthy TCP, HTTP3 available, two direct QUIC failures.
    if quic_probe; then QUIC_STATUS=direct_ok; return; fi
    sleep 3
    if quic_probe; then QUIC_STATUS=direct_ok; return; fi
    verify_installed || die 'TCP перестал работать перед QUIC; откат.'
    assert_unchanged
    /etc/init.d/zapret2 stop
    printf '%s\n' www.youtube.com > "$RUN/quic-discovery-target"
    printf '%s\n' www.youtube.com i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg > "$RUN/quic-targets"
    : > "$RUN/quic-selected"
    if [ "$CACHED" = 1 ] && [ -s "$BACKUP/cached-quic.txt" ]; then
        cp "$BACKUP/cached-quic.txt" "$RUN/quic-selected"
    else
      : > "$RUN/candidates"
      scan discover-quic discover quic "$RUN/quic-discovery-target"
      select_log "$BACKUP/discover-quic.log" "$RUN/quic-discovery-target" curl_test_http3 1 > "$RUN/quic-pool" || true
      cp "$RUN/quic-pool" "$RUN/candidates"
      if [ -s "$RUN/candidates" ]; then
        scan verify-quic verify quic "$RUN/quic-targets"
        select_log "$BACKUP/verify-quic.log" "$RUN/quic-targets" curl_test_http3 0 > "$RUN/quic-selected" || true
      fi
    fi
    if [ -s "$RUN/quic-selected" ]; then
        QUIC_ARGS=$(sed -n '1p' "$RUN/quic-selected")
        if [ "$LAYOUT" = uci ]; then stage_quic; else stage_profile 1 "$(cat "$BACKUP/strategy-1.txt")"; fi
        /etc/init.d/zapret2 start
        sleep 2
        if quic_probe && quic_probe && verify_installed; then
            if [ "$LAYOUT" = uci ]; then uci commit zapret2; fi
            printf '%s\n' "$QUIC_ARGS" > "$OWN/quic.txt"
            sha256sum "$CONFIG" > "$BACKUP/config.sha256"
            QUIC_STATUS=verified
            return
        fi
        /etc/init.d/zapret2 stop
    fi
    QUIC_ARGS=
    if [ "$LAYOUT" = uci ]; then uci revert zapret2; else stage_profile 1 "$(cat "$BACKUP/strategy-1.txt")"; fi
    rm -f "$OWN/quic.txt"
    /etc/init.d/zapret2 start
    QUIC_STATUS=not_found
}

install_runtime() {
    [ "$(readlink -f "$0")" = "$OWN/control.sh" ] || cp "$0" "$OWN/control.sh"
    chmod 700 "$OWN/control.sh"
    cat > "$OWN/runtime.conf" <<EOF
BASE='$BASE'
LAYOUT='$LAYOUT'
CONFIG='$CONFIG'
WAN_NETWORK='$WAN_NETWORK'
WAN_DEV='$WAN_DEV'
EOF
    printf '1\n' > "$OWN/active"
    sha256sum "$CONFIG" > "$OWN/active.sha256"
    cache_context > "$OWN/cache-context"
    if [ "$CACHED" = 0 ]; then date +%s > "$OWN/cache-time"; fi
    sha256sum "$OWN"/strategy-*.txt > "$OWN/cache.sha256"
    [ ! -s "$OWN/quic.txt" ] || sha256sum "$OWN/quic.txt" >> "$OWN/cache.sha256"
    cat > /etc/init.d/youtube-failover <<'SERVICE'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=96
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh /etc/zapret2-youtube-autotune/control.sh --monitor-loop
    procd_set_param respawn 3600 5 5
    procd_close_instance
}
SERVICE
    chmod 755 /etc/init.d/youtube-failover
    # Cooldown is between switch attempts, not a startup blackout.
    printf '0\n' > "$LAST_SWITCH"
    printf '0\n' > "$FAIL_COUNT"
    if [ "$MONITOR" = 1 ]; then /etc/init.d/youtube-failover enable; /etc/init.d/youtube-failover start;
    else /etc/init.d/youtube-failover disable; fi
}

# Health: 0 healthy, 1 plausible bypass failure, 2 inconclusive (never fail over).
health_probe() {
    hp_target=$1; hp_min=$2
    hp_rc=0
    hp=$(curl --interface "$WAN_DEV" --noproxy '*' -4 --http1.1 --connect-timeout 5 --max-time 12 \
      -sS -o /dev/null -w '%{http_code} %{size_download}' "https://$hp_target") || hp_rc=$?
    case "$hp_rc" in 0) ;; 6|5|2|3|4|60|77) return 2;; *) return 1;; esac
    set -- $hp
    [ "$#" = 2 ] || return 2
    case "$1" in 403|429|5??) return 2;; 200) ;; *) return 1;; esac
    awk -v bytes="$2" -v minimum="$hp_min" 'BEGIN {exit !(bytes>=minimum)}'
}
health_round() {
    h1=0; h2=0
    health_probe www.youtube.com/ 10000 || h1=$?
    health_probe i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg 1000 || h2=$?
    [ "$h1" != 2 ] && [ "$h2" != 2 ] || return 2
    [ "$h1" = 0 ] && [ "$h2" = 0 ]
}
wan_ready() {
    ws=$(ubus call "network.interface.$WAN_NETWORK" status) || return 1
    [ "$(printf '%s' "$ws" | jsonfilter -e '@.up')" = true ] || return 1
    current_dev=$(printf '%s' "$ws" | jsonfilter -e '@.l3_device')
    [ "$current_dev" = "$WAN_DEV" ]
}
monitor_note() { printf '%s %s\n' "$(date +%s)" "$*" > "$MON_STATUS"; }
monitor_once() {
    mkdir -p "$(dirname "$LOCK")"
    mkdir "$LOCK" 2>/dev/null || return 0
    LOCK_HELD=1; printf '%s\n' "$$" > "$LOCK/pid"
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM
    # User edits suspend automatic writes; they never get silently replaced.
    if ! sha256sum -c "$OWN/active.sha256" >/dev/null 2>&1 || [ -n "$(uci changes zapret2)" ]; then monitor_note suspended_config_changed; return; fi
    if ! wan_ready; then printf '0\n' > "$FAIL_COUNT"; monitor_note inconclusive_wan; return; fi
    if [ "$(cache_context)" != "$(cat "$OWN/cache-context")" ]; then monitor_note suspended_context_changed; return; fi
    hc=0; health_round || hc=$?
    if [ "$hc" = 0 ]; then printf '0\n' > "$FAIL_COUNT"; monitor_note healthy; return; fi
    if [ "$hc" = 2 ]; then printf '0\n' > "$FAIL_COUNT"; monitor_note inconclusive_dns_or_http; return; fi
    failures=$(cat "$FAIL_COUNT" 2>/dev/null || echo 0)
    case "$failures" in ''|*[!0-9]*) failures=0;; esac
    failures=$((failures+1)); printf '%s\n' "$failures" > "$FAIL_COUNT"
    monitor_note "failure_$failures"
    [ "$failures" -ge 3 ] || return 0
    last=$(cat "$LAST_SWITCH" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0;; esac
    [ "$(($(date +%s)-last))" -ge 900 ] || return 0
    sha256sum -c "$OWN/cache.sha256" >/dev/null 2>&1 || { monitor_note suspended_cache_changed; return; }
    active=$(cat "$OWN/active")
    case "$active" in 1|2|3) ;; *) monitor_note invalid_active; return;; esac
    # Durable transaction starts only for a confirmed failure, not on every poll.
    backup
    : > "$BACKUP/from-monitor"
    CHANGED=1; : > "$BACKUP/changed"
    date +%s > "$LAST_SWITCH"
    QUIC_ARGS=
    [ ! -s "$OWN/quic.txt" ] || QUIC_ARGS=$(cat "$OWN/quic.txt")
    for alternative in 1 2 3; do
        [ "$alternative" != "$active" ] && [ -s "$OWN/strategy-$alternative.txt" ] || continue
        assert_unchanged
        /etc/init.d/zapret2 stop
        stage_profile "$alternative" "$(cat "$OWN/strategy-$alternative.txt")"
        /etc/init.d/zapret2 start || die 'Failover: служба не запустилась; откат.'
        sleep 3
        good=0
        if wan_ready && health_round; then sleep 5; if health_round; then good=1; fi; fi
        sha256sum -c "$BACKUP/config.sha256" >/dev/null || { : > "$BACKUP/conflict"; die 'Failover: параллельная запись конфигурации.'; }
        if [ "$good" = 1 ]; then
            if [ "$LAYOUT" = uci ]; then
                uci changes zapret2 > "$RUN/current.changes"
                cmp -s "$RUN/current.changes" "$BACKUP/planned.changes" || { : > "$BACKUP/conflict"; die 'Failover: параллельные изменения.'; }
                sha256sum -c "$BACKUP/config.sha256" >/dev/null || { : > "$BACKUP/conflict"; die 'Failover: параллельная запись.'; }
                uci commit zapret2
            fi
            printf '%s\n' "$alternative" > "$OWN/active"
            sha256sum "$CONFIG" > "$OWN/active.sha256"
            printf '0\n' > "$FAIL_COUNT"
            monitor_note "switched_${active}_to_$alternative"
            SUCCESS=1
            return
        fi
        /etc/init.d/zapret2 stop
        if [ "$LAYOUT" = uci ]; then
            sha256sum -c "$BACKUP/config.sha256" >/dev/null || { : > "$BACKUP/conflict"; die 'Failover: параллельная запись.'; }
            uci changes zapret2 > "$RUN/current.changes"
            cmp -s "$RUN/current.changes" "$BACKUP/planned.changes" || { : > "$BACKUP/conflict"; die 'Failover: параллельные изменения.'; }
            uci revert zapret2
        else cp -p "$BACKUP/original-config" "$CONFIG"; sha256sum "$CONFIG" > "$BACKUP/config.sha256"; fi
    done
    monitor_note no_healthy_reserve_restoring_original
    die 'Резервы не прошли проверку; восстанавливается исходная стратегия.'
}
runtime_main() {
    [ "$(id -u)" = 0 ] || die 'Запустите от root.'
    [ -f "$OWN/runtime.conf" ] || die 'Сначала выполните подбор.'
    . "$OWN/runtime.conf"
    MODE=monitor
    case "$1" in
        --status)
            say "Активная TCP-стратегия: $(cat "$OWN/active")"
            cat "$MON_STATUS" 2>/dev/null || true
            say "QUIC: $([ -s "$OWN/quic.txt" ] && echo verified || echo disabled)";;
        --failover-once) monitor_once;;
        --monitor-loop)
            while :; do
                # Child process owns each transaction and releases its own lock.
                sh "$OWN/control.sh" --failover-once || true
                sleep 60
            done;;
    esac
}

write_assets() {
    cat > "$RUN/select.awk" <<'YTA_SELECT_AWK'
# Strict native Blockcheck2 parser. SUMMARY and baseline are never trials.
function safe(s,    n,a,i) {
    # Custom Blockcheck2 uses eval internally: admit only inert argv tokens.
    if (s == "" || s ~ /[^A-Za-z0-9_.,:+=\/@ -]/) return 0
    n=split(s,a,/ +/)
    for(i=1;i<=n;i++) {
        if(a[i] ~ /^--payload=(tls_client_hello|quic_initial)$/) continue
        if(a[i] ~ /^--lua-desync=[A-Za-z0-9_.,:+=\/@-]+$/) continue
        if(a[i] ~ /^--(out-range|in-range|out-seq|in-seq)=[A-Za-z0-9_.,:+=-]+$/) continue
        return 0
    }
    return index(s,"--lua-desync=") > 0
}
BEGIN {
    while ((getline t < targets) > 0) if (t != "" && !(t in wanted)) { wanted[t]=1; nt++ }
    close(targets)
}
FILENAME==ARGV[1] { if($0!="" && $0!~/^#/) allowed[$0]=1; next }
/^- / || /^\* / || /^curl_test_/ {
    current=""; count=0; failed=0
    for(i in seen) delete seen[i]
    prefix="- " protocol " ipv4 "
    if(index($0,prefix)!=1) next
    n=split($0,parts,/ : nfqws2 /)
    if(n!=2 || !safe(parts[2]) || (!discover && !(parts[2] in allowed))) next
    domain=substr(parts[1],length(prefix)+1)
    if(!(domain in wanted)) next
    current=parts[2]
    if(!(current in order)) {order[current]=++ns; ordered[ns]=current}
    blocks[current SUBSEP domain]++
    next
}
current!="" {
    if(index($0,"UNAVAILABLE") || index($0,"curl: (")) failed=1
    if($0~/\[attempt [0-9]+\] AVAILABLE/) {
        k=$0; sub(/.*\[attempt /,"",k); sub(/\].*/,"",k)
        if(k>=1 && k<=repeats && !(k in seen)) {seen[k]=1;count++}
    }
    if($0=="!!!!! AVAILABLE !!!!!") {
        if(!failed && count==repeats) passed[current SUBSEP domain]=1
        current=""
    }
}
END {
    if(nt==0 || repeats<2) exit 3
    found=0
    for(j=1;j<=ns;j++) {
        s=ordered[j];ok=1
        for(t in wanted) if(!passed[s SUBSEP t] || blocks[s SUBSEP t]!=1) ok=0
        if(ok) {print s;found++}
    }
    if(!found) exit 2
}
YTA_SELECT_AWK
}

if [ "${YTA_LIBRARY_ONLY:-0}" != 1 ]; then main "$@"; fi
