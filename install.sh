#!/bin/sh
# MIT. BlockcheckW-only search; does not replace the installed zapret2.
set -eu
VERSION=4.0.2
BASE=/opt/zapret2
OWN=/etc/zapret2-youtube-autotune
LOCK=/var/lock/zapret2-youtube-autotune.lock
WAN_NETWORK=wan
REPEATS=3
WANT=3
TIME_LIMIT=600
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
YouTube Autotune 4 — Fast Strategy Scanner (BlockcheckW only).
sh install.sh [--want 2|3] [--base /opt/zapret2] [--wan-network wan]
  --scan-seconds N        Total search/check budget in seconds (default 600).
  --workers N            Cap adaptive workers at 1–32.
  --media-url-file FILE   Optional fresh HTTPS googlevideo media URL from this WAN.
  --check                Read-only prerequisites, no network tests.
  --refresh              Ignore the 24-hour WAN/engine-scoped result cache.
  --no-quic              Skip direct QUIC and revalidation of an existing QUIC profile.
  --no-failover          Do not enable the local failover service.
  --status               Show the installed monitor status and active TCP strategy.
  --rollback BACKUP      Restore the original stopped service and configuration.
  --help | --version
Default: one verified alternative per TCP Segmentation / Multi / Fake-Seqovl family.
One active, up to two reserves; local procd failover. Existing QUIC may be revalidated; this scanner has no QUIC search.
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
    [ "${available_kb:-0}" -ge 24576 ] || die 'Для подбора недостаточно RAM (нужно 24 МБ MemAvailable для применения кэша; минимум 48 МБ для облегчённого поиска).'
    for cmd in uci curl awk sed sort cmp sha256sum setsid nft ubus jsonfilter tar ip cut head; do
        command -v "$cmd" >/dev/null || die "Нет $cmd. Установите недостающую зависимость вручную (opkg на 24 / apk на 25)."
    done
    case "$BASE" in /*) ;; *) die 'Нужен абсолютный --base.';; esac
    case "$BASE" in *[!A-Za-z0-9_./-]*) die 'Недопустимый --base.';; esac
    BASE=$(readlink -f "$BASE")
    [ -x "$BASE/nfq2/nfqws2" ] || die 'Установите zapret2 вручную.'
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
    say "YouTube Autotune 4 — Fast Strategy Scanner $VERSION: OpenWrt $DISTRIB_RELEASE, $DISTRIB_ARCH, $LAYOUT, WAN $WAN_DEV."
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
for f in control.sh runtime.conf active active.sha256 cache-context cache-time cache.sha256 quic.txt engine-path; do
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
    for f in control.sh runtime.conf active active.sha256 cache-context cache-time cache.sha256 quic.txt engine-path; do
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
    t=$(cat "$b/scan-table" 2>/dev/null || true)
    case "$t" in "yta_bcw_${parent}_"*) nft delete table inet "$t" 2>/dev/null || true;; esac
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
    if [ -n "${SCAN_TABLE:-}" ]; then
        case "$SCAN_TABLE" in "yta_bcw_$$_"*) nft delete table inet "$SCAN_TABLE" 2>/dev/null || true;; esac
    fi
    SCAN_TABLE=
    SCAN_PID=
    rm -f "$BACKUP/scan-pid" "$BACKUP/scan-table"
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
    if [ "$MODE" = autotune ] && [ "$rc" != 0 ]; then
        printf '\033[1;91mКандидатов: %s | Успешное применение этого запуска: 0\033[0m\n' "$CANDIDATES" >&2
        [ ! -f "$BACKUP/rollback.sh" ] || say "Восстановление: sh $BACKUP/rollback.sh" >&2
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
    for attempt in 1; do
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
    if [ -s "$OWN/quic.txt" ] && [ -f "$OWN/cache.sha256" ] && sha256sum -c "$OWN/cache.sha256" >/dev/null 2>&1; then cp "$OWN/quic.txt" "$BACKUP/cached-quic.txt"; fi
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
    phase_end
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
            --base|--wan-network|--want|--scan-seconds|--media-url-file|--workers)
                [ "$#" -ge 2 ] || die "Нет значения $1"
                opt=$1; shift
                case "$opt" in --base) BASE=$1;; --wan-network) WAN_NETWORK=$1;; --want) WANT=$1;; --scan-seconds) TIME_LIMIT=$1;; --media-url-file) MEDIA_FILE=$1;; --workers) WORKERS_LIMIT=$1;; esac;;
            --rollback)
                [ "$#" = 2 ] || die 'Нужны только --rollback и backup.'
                resolved=$(readlink -f "$2")
                case "$resolved" in /root/zapret2-youtube-backup-*) ;; *) die 'Недопустимый backup.';; esac
                exec sh "$resolved/rollback.sh";;
            *) die "Неизвестный параметр: $1";;
        esac
        shift
    done
    STARTED=$(date +%s)
    printf '\033[1;96mYouTube Autotune 4 — Fast Strategy Scanner\033[0m\n'
    banner
    case "$WORKERS_LIMIT" in ''|*[!0-9]*) die 'Некорректный --workers.';; esac
    [ "$WORKERS_LIMIT" -ge 1 ] && [ "$WORKERS_LIMIT" -le 32 ] || die '--workers: 1–32.'
    valid_name "$WAN_NETWORK" || die 'Недопустимое имя WAN.'
    case "$WANT" in 2|3) ;; *) die '--want: только 2 или 3.';; esac
    case "$TIME_LIMIT" in ''|*[!0-9]*) die 'Некорректный --scan-seconds.';; esac
    [ "$TIME_LIMIT" -ge 10 ] && [ "$TIME_LIMIT" -le 7200 ] || die 'Лимит сканирования: 10–7200 секунд.'
    preflight
    [ "$MODE" != check ] || return 0
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM
    phase_start 'Подготовка и резервная копия'
    backup
    write_assets
    prepare_media
    phase_end
    choose
    phase_start 'Применение и проверка через службу zapret2'
    apply_profiles
}

# Family-aware result cache and local OpenWrt procd failover. No external scheduler.
print_results() {
    result_count=$1
    printf '\n\033[1;97;42m РЕЗУЛЬТАТ YOUTUBE AUTOTUNE 4 \033[0m\n'
    printf '\033[1;96mДвижок: %s | Время: %s с | Кандидатов: %s | Backup: %s\033[0m\n' "$ENGINE" "$(($(date +%s)-STARTED))" "$CANDIDATES" "$BACKUP"
    printf '\033[1;92mПодтверждено TCP/TLS: %s из 3 семейств\033[0m\n' "$result_count"
    printf '\033[1;96mПрименено TCP/TLS: 1 | Резервных: %s\033[0m\n' "$((result_count-1))"
    for result_n in 1 2 3; do
        [ -s "$OWN/strategy-$result_n.txt" ] || continue
        result_family=$(strategy_family "$(cat "$OWN/strategy-$result_n.txt")")
        case "$result_family" in tcpseg) result_label='TCP Segmentation';; multi) result_label='Multisplit/Multidisorder';; fake) result_label='Fake TLS/Seqovl';; esac
        if [ "$result_n" = 1 ]; then printf '\033[1;92m  %s. %s — АКТИВНА\033[0m\n' "$result_n" "$result_label";
        else printf '\033[1;96m  %s. %s — РЕЗЕРВ\033[0m\n' "$result_n" "$result_label"; fi
    done
    if [ "$QUIC_STATUS" = verified ] || [ "$QUIC_STATUS" = verified_existing ]; then printf '\033[1;92mQUIC: отдельно проверена и применена 1 UDP-стратегия\033[0m\n';
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
        printf '%s\n' 'youtube-bcw-full-body-v4' "$BASE" "$LAYOUT" "$WAN_NETWORK" "$WAN_DEV"
        cat /etc/openwrt_release
        sha256sum "$BASE/nfq2/nfqws2" "$BASE/lua/zapret-lib.lua" "$BASE/lua/zapret-antidpi.lua"
        if [ -f "$OWN/engine-path" ]; then engine_file=$(cat "$OWN/engine-path"); [ ! -f "$engine_file" ] || sha256sum "$engine_file"; fi
        curl --version
        ubus call "network.interface.$WAN_NETWORK" status | jsonfilter -e '@["ipv4-address"][0].address' -e '@.route[*].nexthop'
    } | sha256sum | awk '{print $1}'
}
cache_load() {
    [ -f "$OWN/active.sha256" ] && sha256sum -c "$OWN/active.sha256" >/dev/null 2>&1 || return 1
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
    if quic_probe; then QUIC_STATUS=direct_ok; return; fi
    sleep 3
    if quic_probe; then QUIC_STATUS=direct_ok; return; fi
    # BlockcheckW 0.12.1 has no QUIC. Revalidate a saved profile, never launch a legacy scanner.
    QUIC_STATUS=unsupported_by_scanner
    [ -s "$BACKUP/cached-quic.txt" ] || return 0
    old_quic=$(cat "$BACKUP/cached-quic.txt")
    printf '%s\n' "$old_quic" | awk -f "$RUN/safe.awk" | grep -Fxq -- "$old_quic" || return 0
    "$BASE/nfq2/nfqws2" --dry-run --qnum=300 "--lua-init=@$BASE/lua/zapret-lib.lua" \
      "--lua-init=@$BASE/lua/zapret-antidpi.lua" --filter-udp=443 --filter-l7=quic $old_quic > "$BACKUP/quic-dry-run.log" 2>&1 || return 0
    assert_unchanged
    /etc/init.d/zapret2 stop
    QUIC_ARGS=$old_quic
    if [ "$LAYOUT" = uci ]; then stage_quic; uci changes zapret2 > "$BACKUP/quic.changes";
    else stage_profile 1 "$(cat "$BACKUP/strategy-1.txt")"; fi
    quic_ok=0
    if /etc/init.d/zapret2 start > "$BACKUP/quic-start.log" 2>&1; then
        sleep 2
        if quic_probe && quic_probe && verify_installed; then quic_ok=1; fi
    fi
    sha256sum -c "$BACKUP/config.sha256" >/dev/null || { : > "$BACKUP/conflict"; die 'Параллельная запись во время проверки QUIC.'; }
    if [ "$LAYOUT" = uci ]; then
        uci changes zapret2 > "$RUN/current.changes"
        cmp -s "$RUN/current.changes" "$BACKUP/quic.changes" || { : > "$BACKUP/conflict"; die 'Параллельные UCI-изменения во время QUIC.'; }
    fi
    if [ "$quic_ok" = 1 ]; then
        [ "$LAYOUT" != uci ] || uci commit zapret2
        printf '%s\n' "$QUIC_ARGS" > "$OWN/quic.txt"
        sha256sum "$CONFIG" > "$BACKUP/config.sha256"
        QUIC_STATUS=verified_existing
        return
    fi
    /etc/init.d/zapret2 stop || true
    QUIC_ARGS=
    if [ "$LAYOUT" = uci ]; then uci revert zapret2; else stage_profile 1 "$(cat "$BACKUP/strategy-1.txt")"; fi
    /etc/init.d/zapret2 start || die 'Не удалось вернуть рабочий TCP после проверки QUIC.'
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
    [ -z "$BCW_BIN" ] || printf '%s\n' "$BCW_BIN" > "$OWN/engine-path"
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

# BlockcheckW-only adapter. Pinned official musl release; no Rust on the router.
BCW_VERSION=v0.12.1
BCW_BIN=
BCW_TOOLS=/usr/libexec/youtube-autotune
BCW_WORKERS=0
BCW_PROFILES=0
BCW_START_KB=65536
BCW_RESERVE_KB=24576
BCW_POLL_SECONDS=2
BCW_TABLE=
BCW_QNUM=
SCAN_TABLE=
CANDIDATES=0
ENGINE=BlockcheckW
STARTED=0
SCAN_DEADLINE=0
FAST_SECONDS=90
WORKERS_LIMIT=32

phase_start() { PHASE=$1; PHASE_AT=$(date +%s); printf '\033[1;96m%s\033[0m\n' "$PHASE"; }
phase_end() { printf '\033[1;96m%s: %s с\033[0m\n' "$PHASE" "$(($(date +%s)-PHASE_AT))"; }
bcw_arch() {
    case "$1" in
        aarch64*|arm64*) echo arm64;; arm*) echo arm;; x86_64*) echo x86_64;; i?86*|x86) echo x86;;
        mipsel*|mipsle*) echo mipsel;; mips64el*) return 1;; mips64*) echo mips64;; mips*)
            case "$2" in 1) echo mipsel;; 2) echo mips;; *) return 1;; esac;;
        riscv64*) echo riscv64;; ppc*|powerpc*) echo ppc;; *) return 1;;
    esac
}
bcw_detect_arch() {
    arch=${DISTRIB_ARCH:-$(uname -m)}
    # ARM/x86 and explicit MIPSEL names need no ELF reader at all.
    if bcw_arch "$arch" ''; then return 0; fi
    case "$arch" in mips64el*) return 1;; mips*) ;; *) return 1;; esac
    # OpenWrt may provide the applet without a standalone od symlink.
    byte=$(od -An -tu1 -j5 -N1 /bin/busybox 2>/dev/null) ||
      byte=$(busybox od -An -tu1 -j5 -N1 /bin/busybox 2>/dev/null) || return 1
    byte=$(printf '%s' "$byte" | tr -d ' \n\r\t')
    bcw_arch "$arch" "$byte"
}
bcw_sha() {
    case "$1" in
        arm) echo ad61c9efe034c02a6d5956379cf3ae093aec9c6093f087f8f75f81c3aa56b96c;;
        arm64) echo 689c37a7a47514dd04033e487599989dab9ad7699a9ca02136b059b9359ebc31;;
        mips) echo b61c9a43a4901ebad00687e4a029fe69d599d75a2bedca1fbc69e77f2f831532;;
        mipsel) echo cb67663bcd52557e106f07d798feced1bf62a0e348b15db6a9a0f2f2eb4e8694;;
        mips64) echo f971449f97843eca790bc56c44377f4b80036d63b0b9792340ddfd4d135ce18f;;
        x86_64) echo db4e959f8675c62fcbfb63e1ba68c63fc0903d2258aaa9090d00bd5610978da9;;
        x86) echo c53adb01c3d8acba3928481f23c26a27cb1e32c5202c851adea8cef6cbae6dc1;;
        ppc) echo c0a24cac011ff42ded388d7af1bc1d0b31bc42a0da35e30808d1805d94a13367;;
        riscv64) echo 7c5b1ae4ae36a048987bd25b49a54ac3e2b09134d302bff239832c0cb1bd9b34;;
        *) return 1;;
    esac
}
bcw_resources() {
    case "$1" in ''|*[!0-9]*) return 1;; esac
    BCW_START_KB=65536; BCW_RESERVE_KB=24576; BCW_POLL_SECONDS=2
    if [ "$1" -lt 49152 ]; then return 1
    elif [ "$1" -lt 65536 ]; then
        BCW_WORKERS=2; BCW_PROFILES=4
        BCW_START_KB=49152; BCW_RESERVE_KB=32768; BCW_POLL_SECONDS=1
    elif [ "$1" -lt 98304 ]; then BCW_WORKERS=8; BCW_PROFILES=16
    elif [ "$1" -lt 163840 ]; then BCW_WORKERS=16; BCW_PROFILES=64
    else BCW_WORKERS=32; BCW_PROFILES=128; fi
    [ "$BCW_WORKERS" -le "$WORKERS_LIMIT" ] || BCW_WORKERS=$WORKERS_LIMIT
}
bcw_memory_available() { awk '/^MemAvailable:/ {print $2}' /proc/meminfo; }
bcw_memory_at_least() {
    current_kb=$(bcw_memory_available)
    case "$current_kb" in ''|*[!0-9]*) return 1;; esac
    [ "$current_kb" -ge "$1" ]
}
bcw_capability() {
    "$BASE/nfq2/nfqws2" --help > "$RUN/nfq-help" 2>&1 || true
    grep -Eq -- '--filter-mark([^A-Za-z0-9_-]|$)' "$RUN/nfq-help" || return 1
    "$BASE/nfq2/nfqws2" --dry-run --qnum=300 --filter-mark=1/0xFFFF \
      "--lua-init=@$BASE/lua/zapret-lib.lua" "--lua-init=@$BASE/lua/zapret-antidpi.lua" \
      --payload=tls_client_hello --lua-desync=multisplit:pos=1 > "$RUN/mark-dry-run" 2>&1
}
bcw_binary_ok() {
    [ -x "$1" ] || return 1
    "$1" --help > "$RUN/bcw-help" 2>&1 || return 1
    for flag in embedded profiles-per-instance qnum nft-table mark-base desync-mark smoke-qnum-base progress; do
        grep -q -- "--$flag" "$RUN/bcw-help" || return 1
    done
}
bcw_install() {
    BCW_ARCH=$(bcw_detect_arch) || die 'Не удалось определить совместимую архитектуру BlockcheckW (для неоднозначного MIPS нужен od или busybox od).'
    candidate=$(command -v blockcheckw 2>/dev/null || true)
    if [ -n "$candidate" ] && bcw_binary_ok "$candidate"; then BCW_BIN=$candidate; return; fi
    if [ -e "$BCW_TOOLS" ]; then
        [ -f "$BCW_TOOLS/owner" ] && [ "$(cat "$BCW_TOOLS/owner")" = zapret2-youtube-autotune ] || die 'Каталог бинарников занят другой программой.'
    fi
    candidate="$BCW_TOOLS/blockcheckw-$BCW_VERSION-$BCW_ARCH"
    if [ -f "$candidate.sha256" ] && sha256sum -c "$candidate.sha256" >/dev/null 2>&1 && bcw_binary_ok "$candidate"; then BCW_BIN=$candidate; return; fi
    tarball="blockcheckw-linux-$BCW_ARCH.tar.gz"
    expected=$(bcw_sha "$BCW_ARCH") || die 'Нет доверенной SHA256 для архитектуры.'
    curl --interface "$WAN_DEV" --noproxy '*' -fSL --connect-timeout 10 --max-time 90 \
      "https://github.com/rcd27/blockcheckw/releases/download/$BCW_VERSION/$tarball" -o "$RUN/bcw.tar.gz" || die 'Не удалось скачать официальный BlockcheckW. Резервного движка нет.'
    printf '%s  %s\n' "$expected" "$RUN/bcw.tar.gz" | sha256sum -c - || die 'SHA256 BlockcheckW не совпала; файл не запускается.'
    # Extract one known regular member into our private file; never unpack paths from the archive.
    tar -xOzf "$RUN/bcw.tar.gz" blockcheckw > "$RUN/blockcheckw" || die 'Не удалось извлечь бинарник.'
    rm -f "$RUN/bcw.tar.gz"
    chmod 700 "$RUN/blockcheckw"
    bcw_binary_ok "$RUN/blockcheckw" || die 'Бинарник BlockcheckW не запускается или не поддерживает безопасный embedded-режим.'
    bytes=$(wc -c < "$RUN/blockcheckw")
    flash_kb=$(df -k /usr | awk 'END {print $4}')
    case "$flash_kb" in ''|*[!0-9]*) die 'Не удалось проверить свободное место для бинарника.';; esac
    [ "$flash_kb" -ge "$((bytes/1024+2048))" ] || die 'Недостаточно flash: нужен размер бинарника и ещё 2 МБ для журналов/восстановления.'
    # Binary cache is separate from configuration backups: do not write megabytes
    # of identical binaries to flash on every failover transaction.
    mkdir -p "$BCW_TOOLS"
    chmod 700 "$BCW_TOOLS"
    printf 'zapret2-youtube-autotune\n' > "$BCW_TOOLS/owner"
    if ! cp "$RUN/blockcheckw" "$candidate.part"; then rm -f "$candidate.part"; die 'Не удалось сохранить бинарник; временный файл удалён.'; fi
    mv "$candidate.part" "$candidate"
    chmod 700 "$candidate"
    sha256sum "$candidate" > "$candidate.sha256"
    rm -f "$RUN/blockcheckw"
    BCW_BIN=$candidate
}
bcw_prepare() {
    command -v jq >/dev/null || die 'Нужен небольшой пакет jq для строгой проверки JSON. Установите его через opkg/apk; тяжёлые зависимости не требуются.'
    [ "$BASE" = /opt/zapret2 ] || die 'Текущий BlockcheckW поддерживает только /opt/zapret2. Путь zapret2 не изменялся.'
    available_kb=$(bcw_memory_available)
    bcw_resources "$available_kb" || die "Для облегчённого поиска нужно минимум 48 МБ MemAvailable; сейчас ${available_kb:-неизвестно} КБ. Другие службы не останавливаются."
    printf '\033[1;96mMemAvailable: %s КБ | Минимум перед пробой: %s КБ | Резерв при работе: %s КБ\033[0m\n' "$available_kb" "$BCW_START_KB" "$BCW_RESERVE_KB"
    if [ "$BCW_START_KB" = 49152 ]; then
        printf '\033[1;93mОблегчённый режим: 2 воркера, 4 профиля; контроль RAM каждую секунду. Расход памяти на этой модели ещё не измерен.\033[0m\n'
    fi
    cpu_count=$(awk '/^processor[[:space:]]*:/ {n++} END {print n+0}' /proc/cpuinfo)
    if [ "$cpu_count" -lt 2 ]; then cpu_cap=8; elif [ "$cpu_count" -lt 4 ]; then cpu_cap=16; else cpu_cap=32; fi
    if awk -v cores="${cpu_count:-1}" '{exit !($1>2*(cores>0?cores:1))}' /proc/loadavg; then cpu_cap=4; fi
    [ "$BCW_WORKERS" -le "$cpu_cap" ] || BCW_WORKERS=$cpu_cap
    [ "$BCW_PROFILES" -le "$((BCW_WORKERS*4))" ] || BCW_PROFILES=$((BCW_WORKERS*4))
    bcw_capability || die 'Установленный nfqws2 не поддерживает --filter-mark (нужен zapret2 >= 1.0.5). Движок не заменялся.'
    bcw_install
    BCW_QNUM=$((52000+($$ % 1000)*10))
    # One data queue plus a disjoint ten-queue smoke-test range, all within u16.
    if [ -r /proc/net/netfilter/nfnetlink_queue ]; then
        awk -v first="$BCW_QNUM" '$1>=first && $1<=first+11 {busy=1} END {exit busy}' /proc/net/netfilter/nfnetlink_queue || die 'Выбранный диапазон NFQUEUE занят; повторите запуск.'
    fi
    # This is a local route lookup, not an Internet probe. Never change policy routing.
    for mark in 0x20000001 0x2000ffff; do
        route=$(ip -4 route get 8.8.8.8 mark "$mark") || die 'Не удалось проверить маршрут помеченных проб.'
        case " $route " in *" dev $WAN_DEV "*) ;; *) die 'Помеченные пробы BlockcheckW уйдут не через выбранный WAN. Маршруты не менялись.';; esac
    done
    mkdir -p "$RUN/bcw-tools"
    export YTA_CURL="$(command -v curl)" YTA_WAN="$WAN_DEV"
    # Upstream invokes curl for optional ISP information. Suppress that unrelated request.
    cat > "$RUN/bcw-tools/curl" <<'CURL'
#!/bin/sh
for arg in "$@"; do
    case "$arg" in *ipinfo.io*|*api.github.com*) exit 1;; esac
done
exec "$YTA_CURL" --interface "$YTA_WAN" --noproxy '*' "$@"
CURL
    chmod 700 "$RUN/bcw-tools/curl"
    printf '\033[1;96mДвижок: BlockcheckW %s | Архитектура: %s | Воркеров: %s | Профилей: %s | Лимит: %s с\033[0m\n' "$BCW_VERSION" "$BCW_ARCH" "$BCW_WORKERS" "$BCW_PROFILES" "$TIME_LIMIT"
}
bcw_remaining() { left=$((SCAN_DEADLINE-$(date +%s))); [ "$left" -gt 0 ] || left=0; echo "$left"; }
bcw_run() {
    # $1 label, $2 scan|check, $3 input for check, $4 domain, $5 path, $6 take.
    job_label=$1; job_kind=$2; job_input=$3; job_domain=$4; job_path=$5; job_take=$6
    job_left=$(bcw_remaining)
    [ "$job_left" -ge 5 ] || return 1
    # Recheck after download/extraction and before every new scanner process.
    bcw_memory_at_least "$BCW_START_KB" || die "Подбор не запущен: MemAvailable ${current_kb:-неизвестно} КБ, нужно $BCW_START_KB КБ."
    job_seconds=$job_left
    if [ "$job_kind" = scan ]; then [ "$job_seconds" -le "$FAST_SECONDS" ] || job_seconds=$FAST_SECONDS
    else [ "$job_seconds" -le 60 ] || job_seconds=60; fi
    job_dir="$BACKUP/$job_label"
    mkdir "$job_dir" || return 1
    SCAN_TABLE="yta_bcw_$$_$job_label"
    printf '%s\n' "$SCAN_TABLE" > "$BACKUP/scan-table"
    say "BlockcheckW: $job_label, лимит $job_seconds с"
    (
        cd "$job_dir" || exit 1
        set -- "$BCW_BIN" --embedded --no-conflict-cleanup --auto --progress \
          -w "$BCW_WORKERS" --profiles-per-instance "$BCW_PROFILES" --qnum "$BCW_QNUM" \
          --smoke-qnum-base "$((BCW_QNUM+2))" --nft-table "$SCAN_TABLE" --mark-base 0x20000000 --desync-mark 0x10000000
        if [ "$job_kind" = scan ]; then
            set -- "$@" scan -d www.youtube.com -p tls13,tls12 --dns doh --timeout "$job_seconds" --top 0
        else
            set -- "$@" check --from-file "$job_input" -d "$job_domain" --dns doh --passes 3 \
              --take "$job_take" --timeout 8 --idle-ms 1500 --deadline "$job_seconds" --probe-path "$job_path" --identity-path /robots.txt --output "$job_dir/report.json"
        fi
        exec env PATH="$RUN/bcw-tools:$PATH" HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= http_proxy= https_proxy= all_proxy= \
          setsid "$@"
    ) > "$job_dir/stdout.json" 2> "$job_dir/progress.log" &
    SCAN_PID=$!
    JOB_PID=$SCAN_PID
    JOB_TABLE=$SCAN_TABLE
    printf '%s\n' "$SCAN_PID" > "$BACKUP/scan-pid"
    job_end=$(($(date +%s)+job_seconds+10))
    [ "$job_end" -le "$SCAN_DEADLINE" ] || job_end=$SCAN_DEADLINE
    job_polls=0
    while kill -0 "$SCAN_PID" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$job_end" ]; then stop_scan; return 1; fi
        if ! bcw_memory_at_least "$BCW_RESERVE_KB"; then
            stop_scan; die "Подбор остановлен: MemAvailable ${current_kb:-неизвестно} КБ ниже резерва $BCW_RESERVE_KB КБ. Другие службы не тронуты."
        fi
        sleep "$BCW_POLL_SECONDS"
        job_polls=$((job_polls+1))
        if [ "$((job_polls*BCW_POLL_SECONDS % 10))" = 0 ]; then say "$job_label: работа продолжается, общий остаток $(bcw_remaining) с"; fi
    done
    job_rc=0; wait "$SCAN_PID" || job_rc=$?
    stop_scan
    [ "$job_rc" = 0 ] || return 1
    if [ "$job_kind" = scan ]; then
        JOB_REPORT=
        for f in "$job_dir/"*_scan.json; do [ ! -f "$f" ] || JOB_REPORT=$f; done
        [ -n "$JOB_REPORT" ] || return 1
    else JOB_REPORT="$job_dir/report.json"; fi
    [ -s "$JOB_REPORT" ]
}
bcw_read() {
    # Validate report provenance before reading any candidate args.
    jq -er --arg mode "$1" --arg domain "$2" --arg table "$JOB_TABLE" --argjson pid "$JOB_PID" \
      --argjson qnum "$BCW_QNUM" --argjson workers "$BCW_WORKERS" --argjson profiles "$BCW_PROFILES" \
      -f "$RUN/bcw-report.jq" "$JOB_REPORT" 2>> "$BACKUP/json-errors.log"
}
bcw_input() {
    # $1 lines of safe args, $2 protocol, $3 destination. Use JSON, never eval.
    jq -Rn --arg protocol "$2" '[inputs | select(length>0) | {protocol:$protocol,args:.,coverage:1}] | {strategies:.}' < "$1" > "$3"
}
bcw_validate() {
    candidate_args=$1; family=$2; serial=$3
    printf '%s\n' "$candidate_args" > "$RUN/one-args"
    # TLS1.3 on www was just checked: do not repeat it.
    for target_id in main preview api cdn; do
        case "$target_id" in
            main) target_host=www.youtube.com; target_path=/; protocols='HTTPS/TLS1.2';;
            preview) target_host=i.ytimg.com; target_path=/vi/jNQXAC9IVRw/hqdefault.jpg; protocols='HTTPS/TLS1.2 HTTPS/TLS1.3';;
            api) target_host=youtubei.googleapis.com; target_path=/; protocols='HTTPS/TLS1.2 HTTPS/TLS1.3';;
            cdn) target_host=redirector.googlevideo.com; target_path=/; protocols='HTTPS/TLS1.2 HTTPS/TLS1.3';;
        esac
        jq -n --arg args "$candidate_args" --arg protocols "$protocols" \
          '{strategies:($protocols|split(" ")|map({protocol:.,args:$args,coverage:1}))}' > "$RUN/check-input.json"
        bcw_run "verify_${family}_${serial}_$target_id" check "$RUN/check-input.json" "$target_host" "$target_path" 1 || return 1
        bcw_read auxiliary "$target_host" > "$RUN/verified.tsv" || return 1
        for proto in $protocols; do
            awk -F '\t' -v proto="$proto" -v args="$candidate_args" '$1==proto && $2==args {ok=1} END {exit !ok}' "$RUN/verified.tsv" || return 1
        done
    done
}
choose() {
    phase_start 'Быстрое сканирование и проверка кэша'
    if [ "$REFRESH" = 0 ] && cache_load; then
        CACHED=1; CANDIDATES=$(wc -l < "$RUN/selected"); ENGINE='BlockcheckW (кэш)'; phase_end; return
    fi
    bcw_prepare
    SCAN_DEADLINE=$(($(date +%s)+TIME_LIMIT))
    bcw_run scan scan '' www.youtube.com / 0 || die 'BlockcheckW не завершил быстрый поиск. См. backup; медленного резервного пути нет.'
    bcw_read scan www.youtube.com > "$RUN/discovered.tsv" || die 'BlockcheckW: нет доказанного поиска (доступно напрямую, ошибка или недопустимый JSON).'
    cut -f2 "$RUN/discovered.tsv" | awk '!seen[$0]++' | awk -f "$RUN/safe.awk" > "$RUN/pool"
    CANDIDATES=$(wc -l < "$RUN/pool")
    say "Найдено безопасных разных кандидатов: $CANDIDATES"
    phase_end
    phase_start 'Контрольные тесты: 3 полные загрузки, TLS 1.3 / TLS 1.2'
    : > "$RUN/selected"
    for family in tcpseg multi fake; do
        : > "$RUN/family-args"
        while IFS= read -r args; do
            [ "$(strategy_family "$args")" != "$family" ] || printf '%s\n' "$args" >> "$RUN/family-args"
        done < "$RUN/pool"
        # A bounded family pool avoids spending the entire budget on small variations.
        head -n 4 "$RUN/family-args" > "$RUN/todo"
        serial=0
        while [ -s "$RUN/todo" ]; do
            serial=$((serial+1))
            bcw_input "$RUN/todo" HTTPS/TLS1.3 "$RUN/check-input.json"
            bcw_run "check_${family}_$serial" check "$RUN/check-input.json" www.youtube.com / 1 || break
            bcw_read causal www.youtube.com > "$RUN/checked.tsv" || break
            selected=$(awk -F '\t' '$1=="HTTPS/TLS1.3" {print $2;exit}' "$RUN/checked.tsv")
            [ -n "$selected" ] || break
            # Input membership plus token validation; never trust newly invented report args.
            grep -Fxq -- "$selected" "$RUN/todo" || die 'JSON вернул неизвестную стратегию.'
            printf '%s\n' "$selected" | awk -f "$RUN/safe.awk" | grep -Fxq -- "$selected" || die 'Недопустимые параметры в JSON.'
            if bcw_validate "$selected" "$family" "$serial"; then
                printf '%s\n' "$selected" >> "$RUN/selected"
                printf '\033[1;92mПодтверждено семейство: %s\033[0m\n' "$family"
                break
            fi
            awk -v selected="$selected" '$0!=selected' "$RUN/todo" > "$RUN/next"; mv "$RUN/next" "$RUN/todo"
        done
        [ "$(family_count "$RUN/selected")" -lt "$WANT" ] || break
    done
    phase_end
    confirmed=$(family_count "$RUN/selected")
    if [ "$confirmed" -lt 2 ]; then
        printf '\033[1;91mПодтверждено: %s | Применено: 0\033[0m\n' "$confirmed"
        die 'Недостаточно подтверждённых семейств для Failover. Повторный медленный поиск не запускается.'
    fi
}

write_assets() {
    cat > "$RUN/safe.awk" <<'YTA_SAFE_AWK'
# Admit inert nfqws2 argv only. Never eval output from any scanner.
{
    if ($0=="" || $0 ~ /[^A-Za-z0-9_.,:+=\/@ -]/) next
    n=split($0,a,/ +/); ok=1; desync=0
    for(i=1;i<=n;i++) {
        if(a[i]=="--payload=tls_client_hello" || a[i]=="--payload=quic_initial") continue
        if(a[i] ~ /^--lua-desync=luaexec:/) {ok=0;continue}
        if(a[i] ~ /^--lua-desync=[A-Za-z0-9_.,:+=\/@-]+$/) {desync=1;continue}
        if(a[i] ~ /^--(out-range|in-range|out-seq|in-seq)=[A-Za-z0-9_.,:+=-]+$/) continue
        ok=0
    }
    if(ok && desync) print
}
YTA_SAFE_AWK
    cat > "$RUN/bcw-report.jq" <<'YTA_BCW_REPORT_JQ'
# JSON contract of BlockcheckW 0.12.1 (schema 1), not its human-readable output.
def fail($s): error($s);
if .schema != 1 or .domain != $domain then fail("schema/domain mismatch") else . end |
if (.run.embedded != true or .run.dns != "doh" or .run.qnum != $qnum or
    .run.nft_table != $table or .run.process_group != $pid or
    .run.mark_base != "0x20000000" or .run.desync_mark != "0x10000000" or
    (.run.bcw_version|type) != "string" or (.run.bcw_version|length)==0) then fail("untrusted run provenance") else . end |
if ($mode=="scan" and (.run.workers != $workers or .run.profiles_per_instance != $profiles)) or
   ($mode!="scan" and (.run.workers != 1 or .run.profiles_per_instance != 1))
then fail("resource profile mismatch") else . end |
if .outcome=="broken" or .outcome=="censored" or .outcome=="nothing_works" then fail("no completed evidence") else . end |
if $mode!="scan" and ((.control|type)!="object" or (.inconclusive|type)!="boolean") then fail("missing control evidence") else . end |
if $mode!="auxiliary" and (.outcome!="found" or .inconclusive==true) then fail("control passed or no evidence") else . end |
if $mode=="auxiliary" and (.outcome!="found" and .outcome!="not_blocked") then fail("invalid outcome") else . end |
if (.strategies|type)!="array" then fail("missing strategies") else . end |
.strategies[] |
select(.protocol=="HTTPS/TLS1.2" or .protocol=="HTTPS/TLS1.3") |
select((.args|type)=="string" and (.args|test("^[A-Za-z0-9_.,:+=/@ -]+$"))) |
select($mode=="scan" or
       (.working==true and .passes_ok==3 and .passes_total==3 and .observed=="Bytes" and
        (.admits|type)=="array" and (.admits|length)>0 and .admits!=["Mirage"])) |
[.protocol,.args] | @tsv
YTA_BCW_REPORT_JQ
}

if [ "${YTA_LIBRARY_ONLY:-0}" != 1 ]; then main "$@"; fi
