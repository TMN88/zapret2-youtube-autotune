#!/bin/sh
# Own code: MIT. Native Blockcheck2/nfqws2 remain supplied by the user's zapret2 package.
set -eu
VERSION=1.0.0
MODE=autotune
SECTION=main
WAN_NETWORK=wan
REPEATS=5
QUIC=1
REQUIRE_QUIC=0
MEDIA_FILE=
CURL_BIN=
RUN=
BACKUP=
LOCK=/var/lock/zapret2-youtube-autotune.lock
OWN=/etc/zapret2-youtube-autotune
CHANGED=0
SUCCESS=0
SCAN_PID=
TAIL_PID=
CONFLICT=0
MANAGER_ACTIVE=0

say() { printf '%s\n' "$*"; }
die() { say "Ошибка: $*" >&2; exit 1; }
valid_name() { case "$1" in ''|*[!A-Za-z0-9_]*) return 1;; esac; }
valid_device() { case "$1" in ''|*[!A-Za-z0-9_.:-]*) return 1;; esac; }
help() {
    cat <<'HELP'
YouTube-only zapret2 installer/autotuner for OpenWrt 24.10 (opkg, aarch64_cortex-a53).
Usage: sh install.sh [--preset | --check | --rollback BACKUP] [options]
Default: native Blockcheck2 selection and installation, five sequential repeats.
  --preset               Test/apply the TCP pair from the successful pilot; not a per-ISP search.
  --check                Read-only prerequisites/status; no downloads, backups or changes.
  --section NAME         Podkop VPN section (default main); other sections are preserved.
  --wan-network NAME     OpenWrt WAN network (default wan).
  --curl PATH            Existing curl with HTTP3 (otherwise download verified curl into RAM).
  --no-quic              Explicitly skip QUIC; report it as untested.
  --require-quic         Roll back unless QUIC also passes selection/verification.
  --media-url-file FILE  Optional valid YouTube googlevideo media URL, one line, from this WAN.
  --rollback BACKUP      Run the root-only rollback saved by this installer.
  --help | --version
Requires Podkop and Routerich zapret2 (or already installed Zapret Manager to install it).
Never installs firmware or changes Tailscale. Does not replace Forkop or foreign strategies.
HELP
}

# Domain lists are expanded explicitly; all unrelated selections are retained.
expanded_lists() {
    out=
    for item in "$@"; do
        case "$item" in
            russia_inside) items='geoblock block porn news anime hdrezka tiktok meta twitter';;
            youtube) continue;;
            *) items=$item;;
        esac
        for x in $items; do case " $out " in *" $x "*) ;; *) out="${out:+$out }$x";; esac; done
    done
    printf '%s\n' "$out"
}

audit() {
    say "YouTube autotune $VERSION"
    [ -f /etc/openwrt_release ] || die 'Это не OpenWrt.'
    . /etc/openwrt_release
    say "OpenWrt: $DISTRIB_RELEASE / $DISTRIB_ARCH"
    command -v uci >/dev/null || die 'Нет uci.'
    say "Podkop: $(uci -q get "podkop.$SECTION.connection_type" || true)"
    say "Списки: $(uci -q get "podkop.$SECTION.community_lists" || true)"
    say "VPN: $(uci -q get "podkop.$SECTION.interface" || true)"
    if [ -x /opt/zapret2/blockcheck2.sh ]; then say 'Blockcheck2: установлен'; else say 'Blockcheck2: отсутствует'; fi
    if command -v curl >/dev/null; then curl --version | head -n 4; fi
    if [ -x /etc/init.d/zapret2 ]; then /etc/init.d/zapret2 status || true; fi
}

preflight() {
    [ "$(id -u)" = 0 ] || die 'Запустите от root.'
    [ -f /etc/openwrt_release ] || die 'Это не OpenWrt.'
    . /etc/openwrt_release
    [ "$DISTRIB_ARCH" = aarch64_cortex-a53 ] || die 'Эта упаковка manager/zapret2 поддерживает aarch64_cortex-a53, не MIPS.'
    case "$DISTRIB_RELEASE" in 24.10*) ;; *) die 'В этой версии поддержан OpenWrt 24.10 с opkg.';; esac
    for cmd in uci jq curl sha256sum awk ip ubus opkg jsonfilter sing-box nft; do command -v "$cmd" >/dev/null || die "Нет $cmd"; done
    [ -x /usr/bin/podkop ] || die 'Нужен Podkop; Forkop не заменяется.'
    [ "$(uci -q get "podkop.$SECTION")" = section ] || die 'Неизвестная секция Podkop.'
    [ "$(uci -q get "podkop.$SECTION.connection_type")" = vpn ] || die 'Нужна VPN-секция Podkop.'
    [ "$(uci -q get podkop.settings.enable_output_network_interface || echo 0)" != 1 ] || die 'Для честного WAN-теста нужен выключенный перехват OUTPUT в Podkop. Настройка не менялась.'
    [ -z "$(uci changes podkop)" ] && [ -z "$(uci changes zapret2)" ] || die 'Есть несохранённые изменения LuCI/UCI. Сначала завершите их.'
    [ ! -x /etc/init.d/zapret ] || die 'Обнаружен старый Zapret. Он не удаляется автоматически.'
    if [ -f /tmp/zapret-manager-luci/install_zapret2.pid ] && ! grep -q '^__DONE__ ' /tmp/zapret-manager-luci/install_zapret2.log 2>/dev/null; then
        manager_pid=$(cat /tmp/zapret-manager-luci/install_zapret2.pid)
        case "$manager_pid" in ''|*[!0-9]*) ;; *) kill -0 "$manager_pid" 2>/dev/null && die 'Установка manager ещё выполняется.';; esac
    fi
    if [ -x /etc/init.d/zapret2 ]; then
        [ -f /opt/zapret2/init.d/openwrt/uci2config ] || die 'Нужна UCI-сборка zapret2 из manager/Routerich.'
        # Existing foreign strategies/custom scripts are not silently overwritten or disabled.
        if uci show zapret2 | grep -q '=strategy'; then
            [ -f "$OWN/owner" ] && [ "$(cat "$OWN/owner")" = zapret2-youtube-autotune ] || die 'Имеется чужая стратегия zapret2. Сначала сохраните/уберите её вручную; автоматическая перезапись запрещена.'
            for s in $(uci show zapret2 | sed -n 's/^zapret2\.\([^=]*\)=strategy$/\1/p'); do
                case "$s" in yta_main|yta_api|yta_quic) ;; *) die "Есть чужая стратегия $s.";; esac
            done
        fi
        [ "$(uci -q get zapret2.main.custom_scripts || echo 0)" != 1 ] || die 'Включены сторонние custom.d-скрипты. Автоматически они не отключаются.'
    else
        [ -x /opt/zapret-manager-luci/backend.sh ] || die 'Установите Zapret Manager или его UCI-пакет zapret2.'
    fi
    VPN_NETWORK=$(uci -q get "podkop.$SECTION.interface")
    valid_device "$VPN_NETWORK" || die 'Недопустимое имя VPN.'
    VPN_DEV=$(ubus call "network.interface.$VPN_NETWORK" status | jsonfilter -e '@.l3_device')
    WAN_DEV=$(ubus call "network.interface.$WAN_NETWORK" status | jsonfilter -e '@.l3_device')
    valid_device "$VPN_DEV" && valid_device "$WAN_DEV" || die 'Не удалось определить VPN/WAN device.'
    [ "$WAN_DEV" != "$VPN_DEV" ] || die 'WAN совпал с VPN.'
    if [ -e "$OWN" ]; then
        [ -f "$OWN/owner" ] && [ "$(cat "$OWN/owner")" = zapret2-youtube-autotune ] || die "Папка $OWN уже используется другим владельцем."
    fi
}

backup() {
    mkdir "$LOCK" 2>/dev/null || die "Уже есть запуск/lock: $LOCK. Не запускайте два подбора одновременно."
    printf '%s\n' "$$" > "$LOCK/pid"
    umask 077
    BACKUP="/root/zapret2-youtube-backup-$(date +%Y%m%d-%H%M%S)-$$"
    RUN="/tmp/zapret2-youtube-autotune-$$"
    mkdir "$BACKUP" "$RUN"
    cp -p /etc/config/podkop "$BACKUP/podkop"
    cp -p /etc/config/dhcp "$BACKUP/dhcp"
    printf '0\n' > "$BACKUP/was-installed"
    printf '0\n' > "$BACKUP/was-running"
    printf '0\n' > "$BACKUP/was-enabled"
    if [ -x /etc/init.d/zapret2 ]; then
        printf '1\n' > "$BACKUP/was-installed"
        cp -p /etc/config/zapret2 "$BACKUP/zapret2"
        /etc/init.d/zapret2 status >/dev/null 2>&1 && printf '1\n' > "$BACKUP/was-running" || true
        /etc/init.d/zapret2 enabled >/dev/null 2>&1 && printf '1\n' > "$BACKUP/was-enabled" || true
    fi
    [ ! -d "$OWN" ] || tar -czf "$BACKUP/owned-hostlists.tar.gz" -C /etc zapret2-youtube-autotune
    sha256sum /etc/config/network /etc/config/firewall > "$BACKUP/recovery.sha256"
    sha256sum /etc/config/podkop > "$BACKUP/podkop.before.sha256"
    opkg list-installed > "$BACKUP/packages.before"
    cat > "$BACKUP/rollback.sh" <<'ROLLBACK'
#!/bin/sh
set -eu
b=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || exit 1
test -f "$b/podkop"
/etc/init.d/zapret2 stop >/dev/null 2>&1 || true
uci -q revert podkop || true
uci -q revert zapret2 || true
if [ -f "$b/podkop-touched" ]; then
    cp -p "$b/podkop" /etc/config/podkop
    cp -p "$b/dhcp" /etc/config/dhcp
fi
if [ "$(cat "$b/was-installed")" = 1 ]; then
    cp -p "$b/zapret2" /etc/config/zapret2
else
    uci -q set zapret2.main.enabled=0 || true
    uci -q commit zapret2 || true
fi
[ ! -f "$b/owned-hostlists.tar.gz" ] || tar -xzf "$b/owned-hostlists.tar.gz" -C /etc
if [ -f "$b/podkop-touched" ]; then /usr/bin/podkop reload > "$b/rollback.log" 2>&1; fi
if [ -x /etc/init.d/zapret2 ]; then
    if [ "$(cat "$b/was-enabled")" = 1 ]; then /etc/init.d/zapret2 enable; else /etc/init.d/zapret2 disable; fi
    if [ "$(cat "$b/was-running")" = 1 ]; then /etc/init.d/zapret2 start >> "$b/rollback.log" 2>&1; fi
fi
sha256sum -c "$b/recovery.sha256"
printf 'Исходные Podkop/YouTube и состояние zapret2 восстановлены. Добавленные пакеты сохранены.\n'
ROLLBACK
    chmod 700 "$BACKUP/rollback.sh"
    say "Резервная копия: $BACKUP"
    say "Возврат: sh $BACKUP/rollback.sh"
}

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ -n "$SCAN_PID" ]; then kill -TERM "$SCAN_PID" 2>/dev/null || true; wait "$SCAN_PID" 2>/dev/null || true; fi
    [ -z "$TAIL_PID" ] || kill "$TAIL_PID" 2>/dev/null || true
    if [ "$MANAGER_ACTIVE" = 1 ]; then
        say 'Ожидание завершения пакетной операции manager перед возвратом (opkg принудительно не прерывается).' >&2
        manager_done=0
        for n in $(seq 1 180); do
            if grep -q '^__DONE__ ' /tmp/zapret-manager-luci/install_zapret2.log 2>/dev/null; then manager_done=1; break; fi
            sleep 2
        done
        if [ "$manager_done" != 1 ]; then
            # Only the disabled seed was written; Podkop preparation has not started yet.
            CHANGED=0
            say 'Manager ещё не завершился. Podkop не менялся; начальная конфигурация zapret2 оставлена выключенной. Проверьте журнал manager.' >&2
        fi
    fi
    if [ "$CONFLICT" = 1 ]; then
        say "Обнаружены параллельные изменения UCI: они не перезаписываются. Проверьте состояние вручную. Backup: $BACKUP" >&2
    elif [ "$SUCCESS" != 1 ] && [ "$CHANGED" = 1 ]; then
        say 'Подбор/применение не завершились: возвращаю исходную конфигурацию.' >&2
        if ! sh "$BACKUP/rollback.sh"; then say "Автовозврат не завершился; выполните sh $BACKUP/rollback.sh" >&2; fi
    fi
    if [ -n "$RUN" ]; then rmdir "$LOCK" 2>/dev/null || { rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; }; fi
    exit "$rc"
}

fetch() {
    # Public downloads/DoH only use the selected VPN; measurements never do.
    curl --interface "$VPN_DEV" --noproxy '*' -fsSL --retry 1 --connect-timeout 10 --max-time 120 "$1" -o "$2"
}

ensure_zapret2() {
    [ ! -x /etc/init.d/zapret2 ] || return 0
    CHANGED=1
    cat > /etc/config/zapret2 <<'SEED'
#nochange
config zapret2 'main'
    option enabled '0'
    option custom_scripts '0'
    option nfqws_ports_tcp '443'
    option nfqws_ports_udp '443'
    option flowoffload 'donttouch'
SEED
    /opt/zapret-manager-luci/backend.sh zapret2_action install > "$BACKUP/manager-start.log"
    [ "$(jq -r '.started // false' "$BACKUP/manager-start.log")" = true ] || die 'Manager не начал установку.'
    MANAGER_ACTIVE=1
    say 'Установка zapret2 через установленный manager…'
    done_install=0
    for n in $(seq 1 180); do
        log=/tmp/zapret-manager-luci/install_zapret2.log
        if [ -f "$log" ] && grep -q '^__DONE__ ' "$log"; then
            grep -q '^__DONE__ 0' "$log" || die 'Manager сообщил ошибку установки.'
            done_install=1; MANAGER_ACTIVE=0; break
        fi
        sleep 2
    done
    [ "$done_install" = 1 ] || die 'Не дождались установки manager; проверьте его журнал.'
    cp "$log" "$BACKUP/manager-install.log"
    [ -x /opt/zapret2/blockcheck2.sh ] || die 'После установки нет Blockcheck2.'
    [ -f /opt/zapret2/init.d/openwrt/uci2config ] || die 'Нет UCI-преобразователя zapret2.'
    [ "$(uci -q get zapret2.main.enabled)" = 0 ] || die 'Manager не сохранил безопасное выключенное начальное состояние.'
}

ensure_curl() {
    if [ -z "$CURL_BIN" ] && curl --version | grep -q ' HTTP3'; then CURL_BIN=$(command -v curl); fi
    if [ -n "$CURL_BIN" ]; then
        [ -x "$CURL_BIN" ] || die 'Указанный curl не исполняемый.'
        "$CURL_BIN" --version | grep -q ' HTTP3' || die 'Указанный curl не имеет HTTP3.'
    elif [ "$QUIC" = 1 ]; then
        free_kb=$(df -k /tmp | awk 'NR==2 {print $4}')
        [ "$free_kb" -ge 35000 ] || die 'Для HTTP3 нужно не менее 35 МБ свободного /tmp.'
        if ! command -v xz >/dev/null; then
            say 'Установка signed-feed зависимости xz-utils для распаковки curl.'
            opkg update > "$BACKUP/opkg-update.log" 2>&1
            opkg install xz-utils > "$BACKUP/opkg-xz.log" 2>&1
        fi
        fetch 'https://github.com/stunnel/static-curl/releases/download/8.23.0-1/curl-linux-aarch64-musl-8.23.0-1.tar.xz' "$RUN/curl.tar.xz"
        printf '%s  %s\n' e20f26e5b87c1883608f286f86bdabf39d3b8556e8a8e75dfe205e14bd206199 "$RUN/curl.tar.xz" | sha256sum -c -
        xz -dc "$RUN/curl.tar.xz" > "$RUN/curl.tar"
        tar -xOf "$RUN/curl.tar" curl > "$RUN/curl-http3"
        chmod 700 "$RUN/curl-http3"
        CURL_BIN="$RUN/curl-http3"
        "$CURL_BIN" --version | grep -q ' HTTP3' || die 'Загруженный curl не имеет HTTP3.'
    else CURL_BIN=$(command -v curl)
    fi
    case "$CURL_BIN" in *[!A-Za-z0-9_./-]*) die 'Путь curl должен быть без пробелов и специальных символов.';; esac
    export YTA_CURL="$CURL_BIN" YTA_WAN="$WAN_DEV" YTA_VPN="$VPN_DEV"
    cat > "$RUN/curl-wrapper" <<'WRAPPER'
#!/bin/sh
case " $* " in
    *'https://dns.google/dns-query'*) exec "$YTA_CURL" --interface "$YTA_VPN" --noproxy '*' "$@" ;;
    *) exec "$YTA_CURL" --interface "$YTA_WAN" --noproxy '*' "$@" ;;
esac
WRAPPER
    chmod 700 "$RUN/curl-wrapper"
}

prepare_podkop() {
    CHANGED=1
    : > "$BACKUP/podkop-touched"
    /etc/init.d/zapret2 stop > "$BACKUP/stop-zapret2.log" 2>&1
    pidof nfqws2 >/dev/null && die 'Остался посторонний nfqws2: измерения смешались бы.'
    uci set zapret2.main.enabled=0
    lists=$(uci -q get "podkop.$SECTION.community_lists" || true)
    new=$(expanded_lists $lists)
    [ -n "$new" ] || die 'После удаления YouTube список пуст; настройте остальные сервисы вручную.'
    uci -q delete "podkop.$SECTION.community_lists" || true
    for item in $new; do uci add_list "podkop.$SECTION.community_lists=$item"; done
    # Staged UCI changes: a power loss before final commit leaves the original Podkop file.
    /usr/bin/podkop reload > "$BACKUP/prepare-podkop.log" 2>&1
    # Supported Podkop reload must not have committed the staged routing configuration.
    sha256sum -c "$BACKUP/podkop.before.sha256" >/dev/null || die 'Podkop неожиданно сохранил конфигурацию при reload; выполняется возврат.'
    uci changes podkop > "$BACKUP/planned-podkop.changes"
    sing-box check -c /etc/sing-box/config.json
    nft list table inet PodkopTable >/dev/null
    for host in www.youtube.com i.ytimg.com youtubei.googleapis.com; do
        ips=$(printf '%s\n' "$host" | /opt/zapret2/mdig/mdig --family=4)
        [ -n "$ips" ] || die "Нет DNS для $host."
        if printf '%s\n' "$ips" | grep -Eq '(^|[[:space:]])198\.(18|19)\.'; then
            die "Остался FakeIP для $host; проверьте дополнительные секции/пользовательские списки. Они не удалялись."
        fi
    done
    say 'YouTube временно исключён из выбранной VPN-секции; остальные секции сохранены.'
}

scan() {
    label=$1; targets_file=$2; protocol=$3
    domains=$(tr '\n' ' ' < "$targets_file")
    log="$BACKUP/$label.log"
    say "Blockcheck2: $label, $REPEATS повторов. Журнал: $log"
    (
        export CURL="$RUN/curl-wrapper" TEST=custom DOMAINS="$domains" BATCH=1 IPVS=4
        export SCANLEVEL=force PARALLEL=0 REPEATS
        export LIST_HTTPS_TLS13="$RUN/tcp.txt" LIST_HTTPS_TLS12="$RUN/tcp.txt" LIST_QUIC="$RUN/quic.txt"
        export ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=0 ENABLE_HTTPS_TLS13=0 ENABLE_HTTP3=0
        if [ "$protocol" = curl_test_http3 ]; then export ENABLE_HTTP3=1; else export ENABLE_HTTPS_TLS13=1; fi
        export SECURE_DNS=1 SKIP_DNSCHECK=1 SKIP_IPBLOCK=1 DOH_SERVER=https://dns.google/dns-query
        export CURL_MAX_TIME=5 CURL_MAX_TIME_QUIC=5 CURL_MAX_TIME_DOH=8 CURL_HTTPS_GET=1 PACE=500
        exec /opt/zapret2/blockcheck2.sh
    ) > "$log" 2>&1 &
    SCAN_PID=$!
    tail -f "$log" & TAIL_PID=$!
    scan_rc=0; wait "$SCAN_PID" || scan_rc=$?
    SCAN_PID=
    kill "$TAIL_PID" 2>/dev/null || true; wait "$TAIL_PID" 2>/dev/null || true; TAIL_PID=
    [ "$scan_rc" = 0 ] || die "Blockcheck2 завершился с кодом $scan_rc."
}

rank() {
    candidates=$1; targets_file=$2; log=$3; proto=$4; dest=$5
    awk -v targets="$targets_file" -v repeats="$REPEATS" -v protocol="$proto" \
        -f "$RUN/select.awk" "$candidates" "$log" > "$dest"
}

choose() {
    printf '%s\n' www.youtube.com 'i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg' > "$RUN/main-targets"
    printf '%s\n' youtubei.googleapis.com > "$RUN/api-targets"
    if [ "$MODE" = preset ]; then
        sed -n '1p' "$RUN/tcp.txt" > "$RUN/main-selected"
        sed -n '2p' "$RUN/tcp.txt" > "$RUN/api-selected"
        say 'Режим preset: проверенный TCP-профиль пилота, а не новый поиск для провайдера.'
    else
        scan tcp-main "$RUN/main-targets" curl_test_https_tls13
        rank "$RUN/tcp.txt" "$RUN/main-targets" "$BACKUP/tcp-main.log" curl_test_https_tls13 "$RUN/main-selected" || die 'Нет общего TCP-кандидата для страницы и превью.'
        scan tcp-api "$RUN/api-targets" curl_test_https_tls13
        rank "$RUN/tcp.txt" "$RUN/api-targets" "$BACKUP/tcp-api.log" curl_test_https_tls13 "$RUN/api-selected" || die 'Нет TCP-кандидата для API.'
    fi
    if [ "$QUIC" = 1 ]; then
        scan quic "$RUN/main-targets" curl_test_http3
        if rank "$RUN/quic.txt" "$RUN/main-targets" "$BACKUP/quic.log" curl_test_http3 "$RUN/quic-selected"; then
            QUIC_STATUS=selected
        else QUIC_STATUS=not_found; rm -f "$RUN/quic-selected"; fi
    else QUIC_STATUS=not_tested
    fi
    [ "$REQUIRE_QUIC" = 0 ] || [ "$QUIC_STATUS" = selected ] || die 'QUIC обязателен, но рабочего варианта нет.'
}

add_profile() {
    group=$1; protocol=$2; args_file=$3; hosts=$4; allow=$5
    args=$(cat "$args_file")
    grep -Fxq -- "$args" "$allow" || die 'Выбранные параметры отсутствуют в доверенном наборе.'
    if [ "$protocol" = tcp ]; then l7=tls; else l7=quic; fi
    # Word splitting creates argv from the allowlist. Never eval parser/log content.
    /opt/zapret2/nfq2/nfqws2 --dry-run --qnum=300 \
      --lua-init=@/opt/zapret2/lua/zapret-lib.lua --lua-init=@/opt/zapret2/lua/zapret-antidpi.lua \
      "--filter-$protocol=443" "--filter-l7=$l7" "--hostlist=$hosts" $args > "$BACKUP/dry-run-$group.log" 2>&1
    uci -q delete "zapret2.yta_$group" || true
    uci -q delete "zapret2.yta_${group}_hosts" || true
    uci set "zapret2.yta_${group}_hosts=list"
    uci set "zapret2.yta_${group}_hosts.path=$hosts"
    uci set "zapret2.yta_$group=strategy"
    uci set "zapret2.yta_$group.enabled=1"
    uci set "zapret2.yta_$group.port=443"
    uci add_list "zapret2.yta_$group.protocol=$protocol"
    uci add_list "zapret2.yta_$group.filter_l3=ipv4"
    uci add_list "zapret2.yta_$group.filter_l7=$l7"
    uci add_list "zapret2.yta_$group.hostlist=yta_${group}_hosts"
    uci set "zapret2.yta_$group.script=$args"
}

apply_profiles() {
    mkdir -p "$OWN"; chmod 755 "$OWN"
    cp "$RUN/main-hosts.txt" "$OWN/main.txt"
    cp "$RUN/api-hosts.txt" "$OWN/api.txt"
    chmod 644 "$OWN/main.txt" "$OWN/api.txt"
    printf 'zapret2-youtube-autotune\n' > "$OWN/owner"
    add_profile main tcp "$RUN/main-selected" "$OWN/main.txt" "$RUN/tcp.txt"
    add_profile api tcp "$RUN/api-selected" "$OWN/api.txt" "$RUN/tcp.txt"
    uci -q delete zapret2.yta_quic || true
    uci -q delete zapret2.yta_quic_hosts || true
    if [ -s "$RUN/quic-selected" ]; then add_profile quic udp "$RUN/quic-selected" "$OWN/main.txt" "$RUN/quic.txt"; fi
    uci set zapret2.main.enabled=1
    uci set zapret2.main.custom_scripts=0
    uci set "zapret2.main.openwrt_wan4=$WAN_NETWORK"
    uci set zapret2.main.openwrt_lan=lan
    uci set zapret2.main.flowoffload=donttouch
    /etc/init.d/zapret2 start > "$BACKUP/start.log" 2>&1
    ready=0
    for n in 1 2 3 4 5; do if pidof nfqws2 >/dev/null; then ready=1; break; fi; sleep 1; done
    [ "$ready" = 1 ] || die 'Не запустился nfqws2.'
    nft list table inet zapret2 > "$BACKUP/nft.after"
    uci changes zapret2 > "$BACKUP/planned-zapret2.changes"
    sha256sum /etc/config/zapret2 > "$BACKUP/zapret2.disk.sha256"
}

probe() {
    target=$1; kind=$2; expected=$3; minbytes=$4
    if [ "$kind" = quic ]; then opt=--http3-only; else opt=--http2; fi
    metrics=$("$CURL_BIN" --interface "$WAN_DEV" --noproxy '*' -4 "$opt" \
      --connect-timeout 5 --max-time 20 -sS -o /dev/null \
      -w '%{http_code} %{size_download} %{http_version}' "https://$target") || return 1
    set -- $metrics
    say "$kind $target: HTTP $1, $2 bytes, HTTP/$3"
    printf '%s\n' "$kind $target $metrics" >> "$BACKUP/verification.log"
    [ "$1" = "$expected" ] && [ "$2" -ge "$minbytes" ] || return 1
    [ "$kind" != quic ] || [ "$3" = 3 ]
}

verify() {
    say 'Проверка после применения (TCP, полные тела ответов).'
    for n in $(seq 1 "$REPEATS"); do
        probe www.youtube.com/ tcp 200 10000 || die 'Не прошла загрузка страницы.'
        probe i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg tcp 200 1000 || die 'Не прошла загрузка превью.'
        # The API root is not an API request: 404/405 are valid server replies, not API functionality proof.
        metrics=$("$CURL_BIN" --interface "$WAN_DEV" --noproxy '*' -4 --max-time 10 -sS -o /dev/null -w '%{http_code}' https://youtubei.googleapis.com/) || die 'Нет ответа API endpoint.'
        case "$metrics" in 200|404|405) ;; *) die "Неожиданный ответ API: $metrics";; esac
    done
    if [ "$QUIC_STATUS" = selected ]; then
        for n in $(seq 1 "$REPEATS"); do
            probe www.youtube.com/ quic 200 10000 && probe i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg quic 200 1000 || die 'QUIC не прошёл финальную проверку.'
        done
    fi
    if [ -n "$MEDIA_FILE" ]; then
        [ -f "$MEDIA_FILE" ] || die 'Нет файла media URL.'
        if LC_ALL=C grep -q '[[:cntrl:]]' "$MEDIA_FILE"; then die 'Media URL содержит управляющие символы.'; fi
        [ "$(awk 'END {print NR}' "$MEDIA_FILE")" -le 1 ] || die 'В media URL должна быть одна строка.'
        url=$(cat "$MEDIA_FILE")
        case "$url" in https://*/*) ;; *) die 'Нужен HTTPS media URL.';; esac
        host=${url#https://}; host=${host%%/*}
        case "$host" in *[!A-Za-z0-9.-]*|'') die 'Некорректный media host.';; *.googlevideo.com) ;; *) die 'Media URL должен вести на googlevideo.com.';; esac
        case "$url" in *'"'*|*'\'*) die 'Некорректный media URL.';; esac
        printf 'url = "%s"\n' "$url" > "$RUN/media.curl"
        for n in 1 2 3; do
            m=$("$CURL_BIN" --config "$RUN/media.curl" --interface "$WAN_DEV" --noproxy '*' -4 --http2 --range 0-1048575 --max-time 30 -sS -o /dev/null -w '%{http_code} %{size_download} %{content_type}') || die 'Ошибка загрузки media.'
            set -- $m
            case "$1/$3" in 206/video/*|200/video/*|206/audio/*|200/audio/*) ;; *) die 'Ответ не похож на media.';; esac
            [ "$2" -ge 65536 ] || die 'Media ответ слишком короткий.'
            say "Media: HTTP $1, $2 bytes, $3"
        done
    fi
    sha256sum -c "$BACKUP/recovery.sha256"
    sing-box check -c /etc/sing-box/config.json
    pidof sing-box >/dev/null
    # Commit only once the real WAN verification has passed.
    if ! sha256sum -c "$BACKUP/podkop.before.sha256" >/dev/null || ! sha256sum -c "$BACKUP/zapret2.disk.sha256" >/dev/null; then
        CONFLICT=1; die 'Конфигурация изменена другим процессом во время подбора.'
    fi
    uci changes podkop > "$RUN/podkop.changes"
    uci changes zapret2 > "$RUN/zapret2.changes"
    if ! cmp -s "$RUN/podkop.changes" "$BACKUP/planned-podkop.changes" || ! cmp -s "$RUN/zapret2.changes" "$BACKUP/planned-zapret2.changes"; then
        CONFLICT=1; die 'Во время подбора появились посторонние UCI-изменения.'
    fi
    uci commit podkop
    uci commit zapret2
    /etc/init.d/zapret2 enable
    cp "$RUN/main-selected" "$BACKUP/selected-main.txt"
    cp "$RUN/api-selected" "$BACKUP/selected-api.txt"
    [ ! -s "$RUN/quic-selected" ] || cp "$RUN/quic-selected" "$BACKUP/selected-quic.txt"
    printf '%s\n' "$QUIC_STATUS" > "$BACKUP/quic-status"
    SUCCESS=1
    say "Готово: TCP установлен. QUIC: $QUIC_STATUS. Backup: $BACKUP"
    say 'Проверьте приложение на LAN-устройстве. Успех страницы/превью не доказывает работу всех CDN, 4K или QUIC media.'
}

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h) help; return;; --version) say "$VERSION"; return;;
            --check) MODE=check;; --preset) MODE=preset;;
            --no-quic) QUIC=0;; --require-quic) REQUIRE_QUIC=1;;
            --section|--wan-network|--curl|--media-url-file)
                [ "$#" -ge 2 ] || die "Нет значения $1"
                opt=$1; shift
                case "$opt" in --section) SECTION=$1;; --wan-network) WAN_NETWORK=$1;; --curl) CURL_BIN=$1;; --media-url-file) MEDIA_FILE=$1;; esac;;
            --rollback)
                [ "$#" = 2 ] || die 'Укажите только --rollback и путь копии.'
                resolved=$(readlink -f "$2")
                case "$resolved" in /root/zapret2-youtube-backup-*) ;; *) die 'Недопустимый путь backup.';; esac
                [ -f "$resolved/rollback.sh" ] || die 'Нет rollback.sh.'
                exec sh "$resolved/rollback.sh";;
            *) die "Неизвестный параметр: $1";;
        esac
        shift
    done
    valid_name "$SECTION" && valid_name "$WAN_NETWORK" || die 'Некорректное имя секции/WAN.'
    [ "$MODE" != check ] || { audit; return; }
    [ "$REQUIRE_QUIC" = 0 ] || [ "$QUIC" = 1 ] || die '--require-quic несовместим с --no-quic.'
    preflight
    backup
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM
    ensure_zapret2
    ensure_curl
    write_assets
    prepare_podkop
    choose
    apply_profiles
    verify
}
