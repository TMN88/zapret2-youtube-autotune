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
