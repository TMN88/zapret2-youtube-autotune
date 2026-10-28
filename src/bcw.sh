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
