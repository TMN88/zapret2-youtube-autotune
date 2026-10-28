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
