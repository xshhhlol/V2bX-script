# Panel audit rules

V2Board's **路由管理 → 禁止访问** rules must be associated with each node's route group. V2bX reads them from `UniProxy/config` and applies them at the server. Nodes confirm the config ETag and body hash only after applying the change. A failed user-list poll leaves the config pending. Changes limited to block rules replace the in-memory matcher on the next successful poll and keep listeners, sessions and counters. Other effective configuration changes still reload the node. Existing TCP streams are evaluated at establishment.

## Supported nodes

- AnyTLS on the sing core: TCP destinations and HTTP/TLS sniffed names are checked before dialing the target.
- TUIC on the sing core: TCP and UDP destinations, sniffed names, and detected protocols are checked. Later UDP destination addresses are also checked.
- The independent `hysteria2` core: panel rules run in its request hook and outbound wrapper, in addition to the existing local `hy2config.yaml` ACL. TUIC and Hy2 use QUIC over UDP, while their proxy destinations may use TCP or UDP.

The sing core uses the configured route sniff action when present. When an audit or observation rule requires inspection and the router has not already inspected the TCP stream, the tracker inspects it and restores the consumed bytes. The configuration wizard generates this action:

```json
{ "action": "sniff" }
```

Independent Hy2 inspects traffic when panel domain, regex or protocol rules exist, even with local sniffing disabled. IP-only block lists do not require payload inspection. A nonempty observation list can independently request sniffing. Audit inspection does not rewrite the destination; existing explicit sniff rewriting remains effective. Encrypted or unrecognized application protocols cannot be guaranteed to match protocol rules. Unknown server-first TCP applications may incur the sniff timeout (300 ms by default) when inspection is needed.

When exact IP rules exist, domain requests use the configured resolver. The node checks the IPv4/IPv6 candidates used by the transport and pins the permitted result for forwarding. A blocked candidate rejects the request. Hy2 keeps the native ACL and checks immediately before each actual outbound, including the built-in direct path. Later UDP writes check the destination and inspect recognizable protocol signatures; encrypted payloads do not always expose a name or protocol. The resolver and payload work is additional to matcher benchmarks.

## Visit reporting

For AnyTLS, TUIC and Hysteria2 nodes the node pulls the panel's suffix, keyword and regexp observation lists from `UniProxy/visitRule`. An unchanged ETag retains the current list; a malformed replacement also keeps the last working list. V2bX sends panel block hits directly to `UniProxy/visit` even before its first observation-list refresh succeeds. Successful visits are reported only when they match the observation list. For blacklist rejections the node also sends the panel route ID from the rule snapshot used for the decision. The standalone access audit screen queries those events; older unattributed rows stay in the historical visit log. Events contain the numeric account ID, client IP, destination, matched rule, result and timestamp. TCP acceptance follows a successful outbound connection; UDP acceptance means a successful local outbound write, which UDP cannot turn into a delivery receipt. Consecutive UDP writes to the same observed target are coalesced.

Sending runs off the forwarding path. Each node keeps up to 8192 events in memory and flushes batches of up to 1000 every five seconds. Failure keeps the batch for retry; the panel API has no idempotency key, so loss of the acknowledgement after a successful insert can duplicate records. A full queue drops new records with a count in the node log; a process crash can lose unsent records. Changing an observation list alone does not block connections or ban accounts.

## Match values

One entry per line in the panel:

```text
example.com
*.example.org
regexp:(^|[.:])example\.net(:[0-9]+)?$
protocol:bittorrent
```

Plain domains and `*.` entries match the domain and subdomains, ignoring case. Literal IPs match exactly. Explicit `regexp:` entries use Go regexp syntax; legacy unprefixed regex patterns remain accepted. Patterns can match hostnames, `host:port`, and `tcp:host:port` / `udp:host:port`. Go RE2 does not support lookaround or backreferences. Invalid updates retain the running node and previous rules.

## Matching performance

Plain domains use a suffix set, IPs and protocols use exact sets, and only actual regular expressions use the regex engine. Immutable rule sets are published atomically. Identical actual/sniffed targets are not checked twice. UDP associations cache one destination decision, so memory does not grow with the number of scanned targets; a new rule snapshot or a different destination invalidates the cache.

The Apple M4 single-thread benchmark below uses 1,000 ordinary domains, with an allowed target that misses every rule. These are local matching costs, not end-to-end network delays:

| Check | Initial audit implementation | Indexed implementation |
| --- | ---: | ---: |
| TCP domain | 2.85–2.94 ms | 0.051–0.052 microseconds |
| TCP IP plus sniffed domain | 2.05 ms | 0.089–0.093 microseconds |
| UDP target | 0.70–0.76 ms | 0.043–0.045 microseconds |

The same indexed benchmark with 10,000 domains remains around 0.04–0.09 microseconds. For 1,000 explicit regexes, an uncached UDP target still costs about 0.68–0.71 ms; a repeated target cache hit costs about 0.006 microseconds. Complex regexes and new targets still require matching. Plain domain lists should therefore use plain entries such as `example.com`, reserving `regexp:` for rules that need it.

Reproduce the benchmark in the V2bX source directory:

```bash
go test ./limiter -run '^$' -bench '^BenchmarkAuditMatching$' -benchmem
```

This optimization does not shorten a required sniff timeout or remove per-destination UDP enforcement. Tests explicitly verify that a cached allowed destination becomes blocked after a rule refresh and that changing UDP targets triggers a new check.

These are not complete Xray routing objects: `geoip:`, `geosite:`, CIDR and `port:` have no special meaning. Use local routing/ACL for those rules. Use the separate observation-list screen for recording successful visits.

## XrayR comparison

The reference `wyx2685-XrayR` source's `api/newV2board.GetNodeRule` joins each panel block list with `|` and compiles a raw Go regexp. Its dispatcher matches the full destination string before selecting an outbound. `RuleListPath` loads additional local regexes; the installation template leaves it unset. Local `route.json` independently handles private IPs and BitTorrent; its path is also unset in that template.

That adapter does not strip `regexp:` or interpret `protocol:` in panel entries. For rules shared with this older adapter, use unprefixed regexes, e.g. `(^|[.:])example\.net(:[0-9]+)?$`. V2bX prefixes are extensions. That adapter's `ReportIllegal` is a no-op, so it does not upload audit-hit records.

V2bX's existing `RuleListPath` field is not a local-rule loader. For this implementation, manage audit entries in the panel; core-local routing remains in `sing_origin.json` and `hy2config.yaml`.

## Build and deploy

Build from sibling `V2bX`, patched `sing-box_mod`, and `sing-quic_mod` sources:

```bash
bash build-audit-local.sh
GOARCH=arm64 bash build-audit-local.sh
```

The optimized `v1.4.9-audit-v2.2-local` binaries and SHA-256 files are created as `output/V2bX-audit-v2.2-linux-amd64` and `output/V2bX-audit-v2.2-linux-arm64`, including sing, Xray and independent Hy2. The build applies `patches/hysteria-request-audit.patch` to a temporary copy of Hysteria core v2.13.0. It gives each TCP request and UDP association its own authenticated reporting context. Local V2bX tests use the equivalent patched sibling `hysteria-core-audit` via go.work. The temporary module file includes sibling VMess/Shadowsocks fixes when available. V2bX checks that the linked sing router can stop rejected connections; an older dependency fails clearly. A normal published release must pin the published sing-box revision containing this router change.

`sing-quic_mod` starts from the pinned `sing-quic` revision `75c3ac4fa12b`. Its small TUIC user-table synchronization patch is recorded in `patches/sing-quic-tuic-users.patch`; it fixes the authentication race exposed by the audit integration tests. The matching sing-box TUIC username maps are also protected. A published release must include both dependency patches.

On an existing server, back up the executable, stop V2bX, replace `/usr/local/V2bX/V2bX` with the binary for its architecture, restore executable permissions and start V2bX. Keep the node configuration and subscriptions. Updating the management script alone does not update the audit implementation.

The panel integration uses these paths relative to the V2Board repository root:

```text
app/Http/Controllers/V1/Admin/Server/RouteController.php
app/Services/ServerService.php
app/Http/Controllers/V1/Admin/ServerVisitLogController.php
app/Http/Controllers/V1/Server/UniProxyController.php
app/Http/Routes/V1/AdminRoute.php
database/migrations/2026_11_19_000000_add_block_route_id_to_server_visit_log.php
```

First install the migration file and run:

```bash
php artisan migrate --path=database/migrations/2026_11_19_000000_add_block_route_id_to_server_visit_log.php --force
```

Then sync the PHP changes. Refresh the Laravel route cache or OPcache if enabled. Deploy the v2-admin static build and the matching V2bX binary. Open the top-level 访问审计 page to edit the same block routes assigned through 节点管理. Its right pane shows native rejections carrying a group ID. Each event retains the rule text and group ID at the time of the rejection. 日志中心 → 观察名单记录 retains previous events with unknown attribution as well as watchlist events.

## Verification

Real AnyTLS TCP, TUIC TCP/UDP and independent Hy2 QUIC clients cover successful forwarding, sniffed-domain blocking, IP blocking, UDP BitTorrent blocking and stopping before an outbound TCP dial. Tests also cover later UDP destinations, malformed panel payloads, raw XrayR-style regexes, concurrent rule refresh, retaining the old node after a bad update, and preservation of Hy2's local ACL. The full sing-core regression suite, including existing Shadowsocks/VMess/fallback tests, passes with Go's race detector.

The panel PHP files were parsed for syntax, and the RE2-compatibility rejection expression was exercised using PCRE2. This workstation has no PHP runtime or Laravel vendor dependencies, so Laravel/SQL integration tests were not run locally.
