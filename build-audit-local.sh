#!/usr/bin/env bash
# Usage: GOARCH=amd64 bash build-audit-local.sh [source-parent] [output]
set -euo pipefail

task_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
task_source_parent=${1:-$(dirname -- "$task_script_dir")}
task_server_dir=$(cd -- "$task_source_parent/V2bX" && pwd)
task_box_dir=$(cd -- "$task_source_parent/sing-box_mod" && pwd)
task_quic_dir=$(cd -- "$task_source_parent/sing-quic_mod" && pwd)
task_target_os=${GOOS:-linux}
task_target_arch=${GOARCH:-amd64}
task_output=${2:-$task_script_dir/output/V2bX-audit-v2.2-$task_target_os-$task_target_arch}
if [[ "$task_output" != /* ]]; then task_output="$PWD/$task_output"; fi

command -v go >/dev/null
test -f "$task_server_dir/core/hy2/audit.go"
test -f "$task_box_dir/route/router_v2bx.go"
task_build_dir=$(mktemp -d)
trap 'rm -rf -- "$task_build_dir"' EXIT
cp "$task_server_dir/go.mod" "$task_build_dir/local.mod"
cp "$task_server_dir/go.sum" "$task_build_dir/local.sum"
mkdir -p -- "$(dirname -- "$task_output")"

cd -- "$task_server_dir"
# Apply the reviewable request-scope patch to the exact dependency used by this build.
task_hy_module=github.com/apernet/hysteria/core/v2
task_hy_version=$(GOWORK=off go list -modfile "$task_build_dir/local.mod" -m -f '{{.Version}}' "$task_hy_module")
if [[ "$task_hy_version" != v2.13.0 ]]; then
    echo "Review the Hysteria audit patch for $task_hy_version before building." >&2
    exit 1
fi
GOWORK=off go mod download "$task_hy_module@$task_hy_version"
task_hy_dir="$task_build_dir/hysteria-core"
cp -R "$(go env GOMODCACHE)/$task_hy_module@$task_hy_version" "$task_hy_dir"
chmod -R u+w "$task_hy_dir"
patch -s -p1 -d "$task_hy_dir" < "$task_script_dir/patches/hysteria-request-audit.patch"
GOWORK=off go mod edit -modfile "$task_build_dir/local.mod" \
    -replace "github.com/apernet/hysteria/core/v2=$task_hy_dir" \
    -replace "github.com/sagernet/sing-box=$task_box_dir" \
    -replace "github.com/sagernet/sing-quic=$task_quic_dir"
for task_module in sing-vmess sing-shadowsocks; do
    if [[ -f "$task_source_parent/$task_module/go.mod" ]]; then
        GOWORK=off go mod edit -modfile "$task_build_dir/local.mod" \
            -replace "github.com/sagernet/$task_module=$task_source_parent/$task_module"
    fi
done
GOWORK=off GOOS="$task_target_os" GOARCH="$task_target_arch" CGO_ENABLED=0 \
    GOEXPERIMENT=jsonv2 go build -mod=mod -modfile "$task_build_dir/local.mod" \
    -tags 'sing xray hysteria2 with_quic with_grpc with_utls with_wireguard with_acme with_gvisor' \
    -trimpath -ldflags '-X github.com/InazumaV/V2bX/cmd.version=v1.4.9-audit-v2.2-local -s -w -buildid=' \
    -o "$task_output" .
(
    cd -- "$(dirname -- "$task_output")"
    task_output_name=$(basename -- "$task_output")
    if command -v sha256sum >/dev/null; then
        sha256sum -- "$task_output_name" > "$task_output_name.sha256"
    else
        shasum -a 256 -- "$task_output_name" > "$task_output_name.sha256"
    fi
)
printf 'Built: %s\nChecksum: %s.sha256\n' "$task_output" "$task_output"
