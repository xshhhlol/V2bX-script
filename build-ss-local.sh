#!/usr/bin/env bash
# Usage: GOOS=linux GOARCH=amd64 bash build-ss-local.sh [source-parent] [output]
set -euo pipefail

task_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
task_source_parent=${1:-$(dirname -- "$task_script_dir")}
task_server_dir=$(cd -- "$task_source_parent/V2bX" && pwd)
task_box_dir=$(cd -- "$task_source_parent/sing-box_mod" && pwd)
task_ss_dir=$(cd -- "$task_source_parent/sing-shadowsocks" && pwd)
task_target_os=${GOOS:-linux}
task_target_arch=${GOARCH:-amd64}
task_output=${2:-$task_script_dir/output/V2bX-ss-$task_target_os-$task_target_arch}
if [[ "$task_output" != /* ]]; then
    task_output="$PWD/$task_output"
fi

command -v go >/dev/null
test -f "$task_server_dir/go.mod"
test -f "$task_box_dir/protocol/shadowsocks/shadowsocks_user.go"
test -f "$task_ss_dir/shadowaead/replay.go"
task_build_dir=$(mktemp -d)
trap 'rm -rf -- "$task_build_dir"' EXIT
cp "$task_server_dir/go.mod" "$task_build_dir/local.mod"
cp "$task_server_dir/go.sum" "$task_build_dir/local.sum"
mkdir -p -- "$(dirname -- "$task_output")"

cd -- "$task_server_dir"
GOWORK=off go mod edit -modfile "$task_build_dir/local.mod" \
    -replace "github.com/sagernet/sing-box=$task_box_dir" \
    -replace "github.com/sagernet/sing-shadowsocks=$task_ss_dir"
printf 'Building V2bX for %s/%s with local Shadowsocks fixes\n' "$task_target_os" "$task_target_arch"
GOWORK=off GOOS="$task_target_os" GOARCH="$task_target_arch" CGO_ENABLED=0 \
    GOEXPERIMENT=jsonv2 go build -mod=mod -modfile "$task_build_dir/local.mod" \
    -tags 'sing hysteria2 with_quic with_grpc with_utls with_wireguard with_acme with_gvisor' \
    -trimpath -ldflags '-X github.com/InazumaV/V2bX/cmd.version=ss-compat-local -s -w -buildid=' \
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
