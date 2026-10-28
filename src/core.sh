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
