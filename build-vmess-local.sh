#!/usr/bin/env bash
# Build the local VMess fixes without publishing modules or modifying go.mod.
# Usage: GOOS=linux GOARCH=amd64 ./build-vmess-local.sh [source-parent] [output]
set -euo pipefail

task_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
task_source_parent=${1:-$(dirname -- "$task_script_dir")}
task_server_dir=$(cd -- "$task_source_parent/V2bX" && pwd)
task_vmess_dir=$(cd -- "$task_source_parent/sing-vmess" && pwd)
task_target_os=${GOOS:-linux}
task_target_arch=${GOARCH:-amd64}
task_output=${2:-$task_script_dir/output/V2bX-$task_target_os-$task_target_arch}
if [[ "$task_output" != /* ]]; then
    task_output="$PWD/$task_output"
fi

command -v go >/dev/null
test -f "$task_server_dir/go.mod"
test -f "$task_vmess_dir/service_replay.go"
task_build_dir=$(mktemp -d)
trap 'rm -rf -- "$task_build_dir"' EXIT
cp "$task_server_dir/go.mod" "$task_build_dir/local.mod"
cp "$task_server_dir/go.sum" "$task_build_dir/local.sum"
mkdir -p -- "$(dirname -- "$task_output")"

cd -- "$task_server_dir"
GOWORK=off go mod edit -modfile "$task_build_dir/local.mod" \
    -replace "github.com/sagernet/sing-vmess=$task_vmess_dir"
printf 'Building V2bX for %s/%s with local sing-vmess: %s\n' \
    "$task_target_os" "$task_target_arch" "$task_vmess_dir"
GOWORK=off GOOS="$task_target_os" GOARCH="$task_target_arch" CGO_ENABLED=0 \
    GOEXPERIMENT=jsonv2 go build -mod=mod -modfile "$task_build_dir/local.mod" \
    -tags 'sing hysteria2 with_quic with_grpc with_utls with_wireguard with_acme with_gvisor' \
    -trimpath -ldflags '-X github.com/InazumaV/V2bX/cmd.version=vmess-compat-local -s -w -buildid=' \
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
