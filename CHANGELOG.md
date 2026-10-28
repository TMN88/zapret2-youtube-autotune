# Changelog

## 4.0.4 — 2026-10-28

- Separate memory policy for --resume-scan: strict checks use one worker/profile, 44 MiB minimum before launch, a 32 MiB reserve and one-second polling. New parallel discovery still requires 48 MiB or more.
- Refuse any discovery invocation when running with the check-only resume budget. Thresholds are workload limits, not measured hardware memory-safety guarantees.

## 4.0.3 — 2026-10-28

- Retain scan reports saved during graceful deadline termination instead of discarding candidates. Timed-out strict checks are still rejected.
- Account for upstream v0.12.1 SIGTERM report provenance using a separate candidate-only import mode; existing strict check validation is unchanged.
- Added --resume-scan BACKUP to reuse interrupted discovery candidates with matching original configuration; all selected candidates receive fresh strict checks and service validation. Invalid import fails without a new scan.

## 4.0.2 — 2026-10-28

- Added a low-memory policy for 48–64 MiB MemAvailable: two workers, four profiles, one-second polling and a 32 MiB reserve. Below 48 MiB new scanning is refused. Higher-memory policy is unchanged.
- Recheck available memory before every scanner process, including after binary installation; report actual RAM and thresholds. Unknown readings fail closed. No services are stopped to free RAM; no hardware memory-safety claim is made.
- Added boundary, malformed-reading, pre-launch rejection and running-job cleanup regression tests.

## 4.0.1 — 2026-10-28

- Fixed the real-device startup failure on OpenWrt without standalone `od`: ARM/ARM64 and other explicit architecture names no longer require it. Only ambiguous MIPS names read ELF byte order, with a BusyBox applet fallback; unknown byte order still fails safely.
- Added focused regression tests. No scanner, firewall, strategy or Failover behavior changed.

## 4.0.0 — 2026-10-28

- BlockcheckW-only search/check pipeline; Blockcheck2 removed entirely at the user's explicit request. Incompatibility fails fast instead of falling back to a slow engine.
- Official pinned v0.12.1 musl binaries with architecture/endianness detection, SHA256 validation and reuse. No Rust/Python compilation or heavy router dependencies.
- Adaptive 8/16/32 workers and 16/64/128 loaded profiles, CPU/load caps, memory guard and one total search/check budget (600 s default; scan stage capped at 90 s).
- Strict schema-1 JSON provenance and baseline handling, three complete passes, family-specific early stopping, candidate deduplication and reuse of completed TLS evidence.
- Three independent strategy families, one active TCP/TLS strategy, up to two reserves; minimum two confirmed families to apply.
- Preserved local procd Failover, transactional backup/rollback, concurrency protection, 24-hour result cache and optional media validation. Cache v3 is invalidated once because the evidence schema changed.
- QUIC direct probing and safe revalidation of an existing profile retained. No new QUIC search because upstream BlockcheckW does not support it; working TCP is preserved.
- Colored counts, family/status output, actual stage/total times and scanner progress. No numerical speedup claim without device measurements.
- Binary cache kept separately from small configuration backups to reduce flash writes during Failover.

## 3.0.0

- Family-aware selection, cached results, optional QUIC, guarded local Failover and colored result counters.
