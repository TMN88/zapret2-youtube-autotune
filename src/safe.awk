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
