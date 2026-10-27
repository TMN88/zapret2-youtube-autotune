# Accept only allowlisted commands with every repeat successful on every target.
BEGIN {
    while ((getline t < targets) > 0) if (t != "") { wanted[t] = 1; nt++ }
    close(targets)
    if (nt == 0 || repeats < 2) exit 3
}
NR == FNR { if ($0 != "" && $0 !~ /^#/) { allowed[$0] = 1; order[$0] = NR }; next }
/^- curl_test_/ {
    current = ""; count = 0; failed = 0
    for (i in seen) delete seen[i]
    prefix = "- " protocol " ipv4 "
    if (index($0, prefix) != 1) next
    n = split($0, parts, / : nfqws2 /)
    if (n != 2 || !(parts[2] in allowed)) next
    domain = substr(parts[1], length(prefix) + 1)
    if (!(domain in wanted)) next
    current = parts[2]
    blocks[current SUBSEP domain]++
    next
}
current != "" {
    if (index($0, "UNAVAILABLE") || index($0, "curl: (")) failed = 1
    if ($0 ~ /\[attempt [0-9]+\] AVAILABLE/) {
        k = $0; sub(/.*\[attempt /, "", k); sub(/\].*/, "", k)
        if (k >= 1 && k <= repeats && !(k in seen)) { seen[k] = 1; count++ }
    }
    if ($0 == "!!!!! AVAILABLE !!!!!" && !failed && count == repeats)
        passed[current SUBSEP domain] = 1
}
END {
    if (nt == 0 || repeats < 2) exit 3
    best = ""; bestcost = 1000000000
    for (s in allowed) {
        ok = 1
        for (t in wanted) if (!((s SUBSEP t) in passed) || blocks[s SUBSEP t] != 1) ok = 0
        if (!ok) continue
        # Prefer no fake injection, then simpler/shorter arguments. No claim of global optimality.
        cost = (index(s, "--lua-desync=fake:") > 0) * 100000 + length(s)
        if (best == "" || cost < bestcost || (cost == bestcost && order[s] < order[best])) {
            best = s; bestcost = cost
        }
    }
    if (best == "") exit 2
    print best
}
