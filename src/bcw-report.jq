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
