#!/bin/bash
# 一键配置

# 检查系统是否有 IPv6 地址
check_ipv6_support() {
    if ip -6 addr | grep -q "inet6"; then
        echo "1"  # 支持 IPv6
    else
        echo "0"  # 不支持 IPv6
    fi
}

add_node_config() {
    echo -e "${green}请选择节点核心类型：${plain}"
    echo -e "${green}1. singbox${plain}"
    echo -e "${green}2. hysteria2${plain}"
    # 当前发布版本未包含 xray 内核；core_type 沿用原编号（2=sing，3=hysteria2）
    while true; do
        read -rp "请输入：" core_choice
        if [ "$core_choice" == "1" ]; then
            core_type="2"
            core="sing"
            core_sing=true
            break
        elif [ "$core_choice" == "2" ]; then
            core_type="3"
            core="hysteria2"
            core_hysteria2=true
            break
        else
            echo "无效的选择。请选择 1 2。"
        fi
    done
    while true; do
        read -rp "请输入节点Node ID：" NodeID
        # 判断NodeID是否为正整数
        if [[ "$NodeID" =~ ^[0-9]+$ ]]; then
            break  # 输入正确，退出循环
        else
            echo "错误：请输入正确的数字作为Node ID。"
        fi
    done

    if [ "$core_hysteria2" = true ] && [ "$core_xray" = false ] && [ "$core_sing" = false ]; then
        NodeType="hysteria2"
    else
        echo -e "${yellow}请选择节点传输协议：${plain}"
        echo -e "${green}1. Shadowsocks${plain}"
        echo -e "${green}2. Vless${plain}"
        echo -e "${green}3. Vmess${plain}"
        if [ "$core_sing" == true ]; then
            echo -e "${green}4. Hysteria${plain}"
            echo -e "${green}5. Hysteria2${plain}"
        fi
        if [ "$core_hysteria2" == true ] && [ "$core_sing" = false ]; then
            echo -e "${green}5. Hysteria2${plain}"
        fi
        echo -e "${green}6. Trojan${plain}"  
        if [ "$core_sing" == true ]; then
            echo -e "${green}7. Tuic${plain}"
            echo -e "${green}8. AnyTLS${plain}"
        fi
        read -rp "请输入：" NodeType
        case "$NodeType" in
            1 ) NodeType="shadowsocks" ;;
            2 ) NodeType="vless" ;;
            3 ) NodeType="vmess" ;;
            4 ) NodeType="hysteria" ;;
            5 ) NodeType="hysteria2" ;;
            6 ) NodeType="trojan" ;;
            7 ) NodeType="tuic" ;;
            8 ) NodeType="anytls" ;;
            * ) NodeType="shadowsocks" ;;
        esac
    fi
    fastopen=true
    isreality=""
    istls=""
    if [ "$NodeType" == "vless" ]; then
        read -rp "请选择是否为reality节点？(y/n)" isreality
    elif [ "$NodeType" == "hysteria" ] || [ "$NodeType" == "hysteria2" ] || [ "$NodeType" == "tuic" ] || [ "$NodeType" == "anytls" ]; then
        fastopen=false
        istls="y"
    fi

    # 原生 SS 入站不使用这里的 TLS 证书配置；询问会让用户误以为
    # 申请证书后客户端就自动有 TLS 封装。
    if [[ "$NodeType" != "shadowsocks" && "$isreality" != "y" && "$isreality" != "Y" && "$istls" != "y" ]]; then
        read -rp "请选择是否进行TLS配置？(y/n)" istls
    fi

    certmode="none"
    certdomain="example.com"
    if [[ "$isreality" != "y" && "$isreality" != "Y" && ( "$istls" == "y" || "$istls" == "Y" ) ]]; then
        echo -e "${yellow}请选择证书申请模式：${plain}"
        echo -e "${green}1. http模式自动申请，节点域名已正确解析${plain}"
        echo -e "${green}2. dns模式自动申请，需填入正确域名服务商API参数${plain}"
        echo -e "${green}3. self模式，自签证书或提供已有证书文件${plain}"
        read -rp "请输入：" certmode
        case "$certmode" in
            1 ) certmode="http" ;;
            2 ) certmode="dns" ;;
            3 ) certmode="self" ;;
        esac
        read -rp "请输入节点证书域名(example.com)：" certdomain
        if [ "$certmode" != "http" ]; then
            echo -e "${red}请手动修改配置文件后重启V2bX！${plain}"
        fi
    fi
    # trojan/anytls 的 TLS 节点、vmess 节点（有无 TLS 均可）：未通过认证的连接回落到 V2bX 内置的伪装网站
    reject_sni=false
    harden_config=""
    external_web=false
    if [[ "$core_sing" == true && ( ( "$certmode" != "none" && ( "$NodeType" == "trojan" || "$NodeType" == "anytls" ) ) || "$NodeType" == "vmess" ) ]]; then
        read -rp "是否启用网站伪装？默认使用内置网站（回车默认 y）(y/n)：" harden_choice
        if [[ ! "$harden_choice" =~ ^[Nn] ]]; then
            if [[ "$core_type" == "2" && "$certmode" != "none" ]]; then
                echo "HTTPS 网站模式：1. 原有内置（默认，无额外依赖） 2. 完整外部前端（HAProxy/OpenSSL + nginx，自动安装与管理）"
                echo "外部模式支持 Trojan TCP+TLS、VMess TCP+TLS（无 HTTP header）和原生 AnyTLS；地址、端口和客户端设置不变。WS/gRPC 请用内置模式。"
                while true; do
                    read -rp "请选择 [1/2，默认 1]：" web_mode
                    case "$web_mode" in
                        ""|1) break ;;
                        2)
                            external_web=true
                            need_external_web=true
                            external_web_count=$((${external_web_count:-0}+1))
                            if [[ "$NodeType" != "trojan" ]]; then external_web_capability=external-web-v2; fi
                            break ;;
                        *) echo "请输入 1 或 2。" ;;
                    esac
                done
            fi
            need_fallback_site=true
            # 只有正规证书才拒绝未知 SNI，自签证书的客户端可能不带 SNI
            if [[ "$certmode" == "http" || "$certmode" == "dns" ]]; then
                reject_sni=true
                echo -e "${yellow}提示：SNI 与证书域名不符的连接会被拒绝；面板节点地址若填 IP，请把 server_name 填为 ${certdomain}${plain}"
            fi
            # 没有 TLS 时 80 端口无处可跳
            redirect_http=true
            if [[ "$certmode" == "none" ]]; then
                redirect_http=false
            fi
            harden_config='
            "FallBackSite": {
                "Enable": true,
                "Root": "/etc/V2bX/www",
                "RedirectHTTP": '"$redirect_http"'
            },'
            if [[ "$external_web" == true ]]; then
                harden_config+='
            "ExternalWeb": {"Enable": true},'
            fi
            if [[ "$NodeType" == "vmess" ]]; then
                # 网站仅用于没有 HTTP header 等额外封装的 TCP 入站。
                # 加密限制单独选择，避免启用网站时切断现有 none/CFB 客户端。
                echo -e "${yellow}提示：VMess 的伪装网站需面板传输协议为 tcp，且未配置 HTTP header；TLS 需在面板开启并同步客户端订阅${plain}"
                require_encryption=false
                if [[ "$certmode" == "none" ]]; then
                    read -rp "是否拒绝 none/aes-128-cfb 客户端？只允许 auto 等认证加密，旧客户端需改配置（回车默认 n）(y/n)：" encryption_choice
                    if [[ "$encryption_choice" =~ ^[Yy]$ ]]; then
                        require_encryption=true
                    fi
                fi
                harden_config+='
            "VMessConfig": {
                "RequireEncryption": '"$require_encryption"',
                "HandshakeTimeout": 30,
                "TrafficShaping": {
                    "Enable": true
                }
            },'
            fi
            if [[ "$NodeType" == "anytls" ]]; then
                harden_config+='
            "AnyTLSConfig": {
                "TrafficShaping": {
                    "Enable": true
                }
            },'
            fi
        fi
    fi
    if [[ "$core_sing" == true && "$NodeType" == "shadowsocks" ]]; then
        local ss_options="" ss_mux="" ss_tcp_choice="" ss_udp_choice=""
        echo -e "\n${green}Shadowsocks 配置指引${plain}"
        echo "面板里的加密方式、服务端口和服务端密钥由 V2bX 自动读取，无需在这里重复填写。"
        echo ""
        echo "面板这样填："
        echo "  • 已有 aes-128-gcm 等普通 SS 节点：保持原加密方式，TCP 优化可用。"
        echo "  • 2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm：支持 TCP 优化和新的 UDP 填充。"
        echo "    只有面板和使用的客户端都支持时才切换 SS2022；切换后需要更新客户端订阅。"
        echo "    SS2022 的服务端密钥请在面板配置好，并与订阅一致，不要随意更换已有密钥。"
        echo "  • 连接地址填写客户端能访问的域名或 IP。"
        echo "  • 直连时，连接端口与服务端口保持一致；有中转或端口映射时分别填写外部入口和后端监听端口。"
        echo "    防火墙放行服务端口的 TCP；需要原生 UDP 时，也要放行 UDP。"
        echo "  • 本向导配置原生 SS，不需要申请 TLS 证书，面板“混淆”选“无/关闭”。"
        echo "    已有插件或混淆的节点需保留配套服务端与客户端设置，不要只修改一侧。"
        echo ""
        echo "下面只设置服务端优化，不修改面板加密方式或客户端订阅。"
        echo "这些优化需要 V2bX v1.4.2 或包含 SS 加固的更新版本；仅更新安装脚本不会生效。"
        read -rp "开启 TCP 兼容优化？客户端无需调整，回车开启 [Y/n]：" ss_tcp_choice
        if [[ ! "$ss_tcp_choice" =~ ^[Nn] ]]; then
            ss_options='
                "HandshakeTimeout": 30,
                "TrafficShaping": { "Enable": true },'
            ss_mux='
            "MultiplexConfig": {
                "Enable": true,
                "Padding": false
            },'
            echo "  TCP：已加入配置，下行整形与 30 秒握手限制将在使用配套服务端后生效。"
        else
            echo "  TCP：保持原发送策略，不开启可选整形。"
        fi
        echo ""
        echo "UDP 填充仅在面板实际使用 SS2022 时生效；aes-128-gcm 等普通 SS 会自动跳过。"
        echo "填充会增加流量，可按需关闭；不会要求现有客户端增加私有配置。"
        read -rp "为 SS2022 节点开启 UDP 小包填充？回车开启 [Y/n]：" ss_udp_choice
        if [[ ! "$ss_udp_choice" =~ ^[Nn] ]]; then
            ss_options+='
                "UDPPadding": {
                    "Enable": true,
                    "MaxPacketSize": 1280,
                    "MaxPaddingBytes": 256
                },'
            echo "  UDP：已加入自动适配开关；普通 SS 不会启用 SS2022 专属填充。"
        else
            echo "  UDP：保持原有策略，不开启新的小包填充。"
        fi
        if [[ -n "$ss_options" ]]; then
            harden_config+='
            "ShadowsocksConfig": {'"${ss_options%,}"'
            },'"$ss_mux"
        fi
        if [[ -n "$ss_mux" ]]; then
            echo "  复用：服务端已允许，普通客户端仍可照常连接，不强制客户端开启复用或填充。"
        fi
        echo "向导结束后会统一保存配置，无需手工编辑这些 JSON 选项。"
        echo "已安装的节点可运行 V2bX generate 重新进入向导；生成前会备份原配置。"
        echo ""
    fi
    ipv6_support=$(check_ipv6_support)
    listen_ip="0.0.0.0"
    if [ "$ipv6_support" -eq 1 ]; then
        listen_ip="::"
    fi
    node_config=""
    if [ "$core_type" == "1" ]; then 
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "0.0.0.0",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "EnableProxyProtocol": false,
            "EnableUot": true,
            "EnableTFO": true,
            "DNSType": "UseIPv4",
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "/etc/V2bX/fullchain.cer",
                "KeyFile": "/etc/V2bX/cert.key",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        },
EOF
)
    elif [ "$core_type" == "2" ]; then
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "$listen_ip",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "EnableTFO": $fastopen,
            "EnableSniff": true,$harden_config
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": $reject_sni,
                "CertDomain": "$certdomain",
                "CertFile": "/etc/V2bX/fullchain.cer",
                "KeyFile": "/etc/V2bX/cert.key",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        },
EOF
)
    elif [ "$core_type" == "3" ]; then
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Hysteria2ConfigPath": "/etc/V2bX/hy2config.yaml",
            "Timeout": 30,
            "ListenIP": "",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "/etc/V2bX/fullchain.cer",
                "KeyFile": "/etc/V2bX/cert.key",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        },
EOF
)
    fi
    nodes_config+=("$node_config")
}

# Inventory package names, not executable paths: Ubuntu's nginx metapackage
# can leave nginx-core/common and modules installed when removed by itself.
external_web_package_inventory() {
    command -v dpkg-query >/dev/null 2>&1 || return 0
    LC_ALL=C dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 'nginx*' 'libnginx-mod-*' haproxy 2>/dev/null |
        awk '$2 == "installed" {sub(/:.*/, "", $1); if ($1 == "haproxy" || $1 ~ /^nginx($|-)/ || $1 ~ /^libnginx-mod-/) print $1}' | LC_ALL=C sort -u
}

record_external_web_packages() (
    command -v apt-get >/dev/null 2>&1 || return 0
    command -v dpkg-query >/dev/null 2>&1 || return 0
    umask 077
    local state=/var/lib/V2bX-script/external-packages
    local before=$1 after package temporary
    after=$(external_web_package_inventory)
    mkdir -p "$(dirname "$state")" || return 1
    temporary=$(mktemp "${state}.XXXXXX") || return 1
    if [[ -f "$state" ]]; then
        while IFS= read -r package; do
            case "$package" in nginx|nginx-*|libnginx-mod-*|haproxy) printf '%s\n' "$package" ;; esac
        done < "$state" >> "$temporary"
    fi
    while IFS= read -r package; do
        [[ -z "$package" ]] && continue
        if ! grep -Fxq "$package" <<< "$before"; then printf '%s\n' "$package" >> "$temporary"; fi
    done <<< "$after"
    LC_ALL=C sort -u "$temporary" -o "$temporary"
    mv -f -- "$temporary" "$state"
)

# Optional dependencies are installed without enabling distribution services:
# V2bX supervises its own private configs and processes. Refuse to displace an
# existing host web server, including one started automatically by a package.
prepare_external_web() (
    PATH="$PATH:/usr/sbin:/sbin"
    local binary=/usr/local/V2bX/V2bX
    local required_capability=${external_web_capability:-external-web-v1}
    local features
    features=$("$binary" features 2>/dev/null) || {
        echo "当前二进制不支持外部前端能力检查，请先更新到 v1.4.5 或包含修复的版本。"
        return 1
    }
    if ! grep -qx "$required_capability" <<< "$features"; then
        echo "当前 V2bX 二进制不支持所选协议的完整外部前端，请先安装支持 $required_capability 的版本。"
        return 1
    fi
    if ! grep -qx 'external-web-ubuntu-lts-v1' <<< "$features"; then
        echo "当前二进制缺少 Ubuntu 22.04/24.04 外部前端兼容修复，请先更新到 v1.4.5 或包含该修复的版本。"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx || systemctl is-active --quiet haproxy || systemctl is-enabled --quiet nginx || systemctl is-enabled --quiet haproxy; then
            echo "检测到正在运行或已启用的系统 nginx/HAProxy，保留现有服务，请先处理端口归属后再选择外部模式。"
            return 1
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service nginx status >/dev/null 2>&1 || rc-service haproxy status >/dev/null 2>&1; then
            echo "检测到现有 Web 服务，未修改其配置。"
            return 1
        fi
    fi
    if command -v nginx >/dev/null 2>&1 && command -v haproxy >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        return 0
    fi
    local packages_before
    packages_before=$(external_web_package_inventory)
    # Debian packages may auto-start services. A temporary policy prevents
    # that; preserve any administrator-owned policy-rc.d without overwriting it.
    local policy_created=false status=0
    trap 'if [[ "$policy_created" == true ]]; then rm -f /usr/sbin/policy-rc.d; fi' EXIT
    if command -v apt-get >/dev/null 2>&1; then
        if [[ ! -e /usr/sbin/policy-rc.d && ! -L /usr/sbin/policy-rc.d ]]; then
            printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
            chmod 755 /usr/sbin/policy-rc.d
            policy_created=true
        fi
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y nginx haproxy python3 || status=$?
        if [[ "$policy_created" == true ]]; then rm -f /usr/sbin/policy-rc.d; fi
    elif command -v apk >/dev/null 2>&1; then
        apk add nginx haproxy python3 || status=$?
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nginx haproxy python3 || status=$?
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nginx haproxy python3 || status=$?
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm nginx haproxy python || status=$?
    else
        echo "未找到支持的包管理器；请安装 nginx、haproxy、python3 后重试。"
        return 1
    fi
    # Record actual additions even if apt only partially completed. Python
    # is deliberately excluded, and records survive normal V2bX uninstall.
    record_external_web_packages "$packages_before" || echo "注意：无法保存 Web 依赖安装记录，卸载时将按来源不明处理。"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now nginx haproxy >/dev/null 2>&1 || true
    fi
    if [[ "$status" != 0 ]]; then return "$status"; fi
    command -v nginx >/dev/null && command -v haproxy >/dev/null && command -v python3 >/dev/null
)

# A root-owned readiness marker is published only after both frontends listen.
# Match the service PID and the requested number of external nodes to avoid
# accepting a marker left by an older process or only the first of many nodes.
external_web_ready() {
    local expected_pid
    if command -v systemctl >/dev/null 2>&1; then
        expected_pid=$(systemctl show V2bX -p MainPID --value 2>/dev/null)
    else
        expected_pid=$(cat /run/V2bX.pid 2>/dev/null)
    fi
    python3 - "$expected_pid" "$external_web_count" <<'PY'
import json, os, sys
try:
    state = json.load(open('/run/V2bX/external-web-ready.json'))
    pid, count = int(sys.argv[1]), int(sys.argv[2])
    assert pid > 0 and state['pid'] == pid and state['nodes'] == count
    os.kill(pid, 0)
except (OSError, ValueError, KeyError, AssertionError):
    sys.exit(1)
PY
}

external_web_failed() {
    if python3 - <<'PY'
import json, sys
try:
    state = json.load(open('/run/V2bX/external-web-ready.error.json'))
    error = state.get('error')
    if isinstance(error, str) and error:
        print('外部前端启动错误：' + error[:4000])
        sys.exit(0)
except (OSError, ValueError, TypeError):
    pass
sys.exit(1)
PY
    then
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        local state
        state=$(systemctl show V2bX -p SubState --value 2>/dev/null)
        if [[ "$state" == auto-restart || "$state" == failed ]]; then
            echo "V2bX 进程已经退出，无法完成外部前端启动。"
            return 0
        fi
    fi
    return 1
}

external_web_service_running() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet V2bX
    else
        service V2bX status >/dev/null 2>&1
    fi
}

# Capture the failed attempt before restoring anything; the private directory
# includes credentials/certificates and must never be made world-readable.
rollback_external_web() {
    v2bx stop
    local failed_dir file
    failed_dir=$(mktemp -d /etc/V2bX/failed-external.XXXXXX) || return 1
    for file in "${web_files[@]}"; do
        if [[ -f "/etc/V2bX/$file" ]]; then cp -p -- "/etc/V2bX/$file" "$failed_dir/" || return 1; fi
    done
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u V2bX --since "@$web_started_at" --no-pager > "$failed_dir/service.log" 2>&1 || true
    fi
    for file in "${web_files[@]}"; do
        if [[ -f "$web_backup/$file" ]]; then
            cp -p -- "$web_backup/$file" "/etc/V2bX/$file" || return 1
        else
            rm -f -- "/etc/V2bX/$file"
        fi
    done
    echo "失败配置、证书和日志已保存在：$failed_dir"
    if [[ "$web_was_running" == true ]]; then
        echo "恢复先前正在运行的配置。"
        v2bx restart
        if ! external_web_service_running; then
            v2bx stop
            echo "旧配置也未能运行，已保持停止；请查看日志后再启动。"
        fi
    else
        echo "此前没有运行中的服务，已恢复原文件并保持停止，不启动示例配置。"
    fi
    rm -rf -- "$web_backup"
}

# 生成伪装网站首页；已存在则保留，可自行替换 /etc/V2bX/www 下的文件
generate_fallback_site() {
    local site_dir=/etc/V2bX/www
    if [ -f "$site_dir/index.html" ]; then
        return
    fi
    mkdir -p "$site_dir"
    local names=("Field Notes" "Small Workshop" "Quiet Corner" "Weekend Log" "Paper Trail" "Slow Notes" "Night Shift" "Open Drawer")
    local topics=("home server maintenance" "film photography" "bread baking" "trail running" "keyboard building" "city cycling" "houseplants" "old radios")
    local site_name=${names[$((RANDOM % ${#names[@]}))]}
    local topic_a=${topics[$((RANDOM % ${#topics[@]}))]}
    local topic_b=${topics[$((RANDOM % ${#topics[@]}))]}
    local year
    year=$(date +%Y)
    cat <<SITE > "$site_dir/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$site_name</title>
<style>
body{max-width:42rem;margin:3rem auto;padding:0 1rem;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:#222;background:#fff}
.meta{color:#777;font-size:.9rem}
article{margin:2rem 0;border-top:1px solid #eee;padding-top:1rem}
footer{margin-top:3rem;color:#999;font-size:.85rem}
</style>
</head>
<body>
<header>
<h1>$site_name</h1>
<p class="meta">A personal notebook about $topic_a and other things.</p>
</header>
<article>
<h2>Notes on $topic_a</h2>
<p class="meta">$year</p>
<p>Collected notes, mistakes and small fixes, written down so the next attempt goes a little better than the last one.</p>
</article>
<article>
<h2>Getting started with $topic_b</h2>
<p class="meta">$((year - 1))</p>
<p>What worked, what did not, and a short list of things to try next time.</p>
</article>
<footer>&copy; $year $site_name</footer>
</body>
</html>
SITE
}

generate_config_file() {
    echo -e "${green}V2bX 配置向导${plain}"
    echo "请先在面板建好节点，准备面板地址、对接 API Key 和节点 ID。"
    echo "按面板实际协议选择，向导会说明对应的证书要求和可选优化。"
    echo "配置保存到 /etc/V2bX/config.json；原配置会备份到 config.json.bak。"
    echo "生成的基础配置包含默认审计设置，完成后请核对配置再使用。"
    read -rp "开始配置？回车继续 [Y/n]：" continue_prompt
    if [[ "$continue_prompt" =~ ^[Nn][Oo]? ]]; then
        exit 0
    fi
    
    nodes_config=()
    first_node=true
    core_xray=false
    core_sing=false
    core_hysteria2=false
    need_fallback_site=false
    need_external_web=false
    external_web_count=0
    external_web_capability=external-web-v1
    fixed_api_info=false
    check_api=false
    
    while true; do
        if [ "$first_node" = true ]; then
            read -rp "请输入机场网址(https://example.com)：" ApiHost
            read -rp "请输入面板对接API Key：" ApiKey
            read -rp "是否设置固定的机场网址和API Key？(y/n)" fixed_api
            if [ "$fixed_api" = "y" ] || [ "$fixed_api" = "Y" ]; then
                fixed_api_info=true
                echo -e "${red}成功固定地址${plain}"
            fi
            first_node=false
            add_node_config
        else
            read -rp "是否继续添加节点配置？(回车继续，输入n或no退出)" continue_adding_node
            if [[ "$continue_adding_node" =~ ^[Nn][Oo]? ]]; then
                break
            elif [ "$fixed_api_info" = false ]; then
                read -rp "请输入机场网址(https://example.com)：" ApiHost
                read -rp "请输入面板对接API Key：" ApiKey
            fi
            add_node_config
        fi
    done

    # Dependency and binary checks precede any changes to the active config.
    if [[ "$need_external_web" == true ]]; then
        if ! prepare_external_web; then
            echo "外部模式准备失败，已有节点配置未改动。"
            return 1
        fi
    fi

    # 初始化核心配置数组
    cores_config="["

    # 检查并添加xray核心配置
    if [ "$core_xray" = true ]; then
        cores_config+="
    {
        \"Type\": \"xray\",
        \"Log\": {
            \"Level\": \"error\",
            \"ErrorPath\": \"/etc/V2bX/error.log\"
        },
        \"OutboundConfigPath\": \"/etc/V2bX/custom_outbound.json\",
        \"RouteConfigPath\": \"/etc/V2bX/route.json\"
    },"
    fi

    # 检查并添加sing核心配置
    if [ "$core_sing" = true ]; then
        cores_config+="
    {
        \"Type\": \"sing\",
        \"Log\": {
            \"Level\": \"error\",
            \"Timestamp\": true
        },
        \"NTP\": {
            \"Enable\": false,
            \"Server\": \"time.apple.com\",
            \"ServerPort\": 0
        },
        \"OriginalPath\": \"/etc/V2bX/sing_origin.json\"
    },"
    fi

    # 检查并添加hysteria2核心配置
    if [ "$core_hysteria2" = true ]; then
        cores_config+="
    {
        \"Type\": \"hysteria2\",
        \"Log\": {
            \"Level\": \"error\"
        }
    },"
    fi

    # 移除最后一个逗号并关闭数组
    cores_config+="]"
    cores_config=$(echo "$cores_config" | sed 's/},]$/}]/')

    # 切换到配置文件目录
    cd /etc/V2bX

    local web_backup="" web_was_running=false web_started_at=0
    local web_files=(config.json config.json.bak custom_outbound.json route.json sing_origin.json hy2config.yaml fullchain.cer cert.key)
    if [[ "$need_external_web" == true ]]; then
        if external_web_service_running; then web_was_running=true; fi
        web_backup=$(mktemp -d /etc/V2bX/.web-rollback.XXXXXX) || return 1
        local web_file
        for web_file in "${web_files[@]}"; do
            if [[ -f "$web_file" ]]; then cp -p -- "$web_file" "$web_backup/" || return 1; fi
        done
        # Avoid the config watcher reading a partially generated set of files.
        v2bx stop
        rm -f /run/V2bX/external-web-ready.error.json
    fi
    
    # 备份旧的配置文件
    mv config.json config.json.bak
    nodes_config_str="${nodes_config[*]}"
    formatted_nodes_config="${nodes_config_str%,}"
    if [ "$need_fallback_site" = true ]; then
        generate_fallback_site
    fi

    # 创建 config.json 文件
    cat <<EOF > /etc/V2bX/config.json
{
    "Log": {
        "Level": "error",
        "Output": ""
    },
    "Cores": $cores_config,
    "Nodes": [$formatted_nodes_config]
}
EOF
    
    # 创建 custom_outbound.json 文件
    cat <<EOF > /etc/V2bX/custom_outbound.json
[
    {
        "tag": "IPv4_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv4v6"
        }
    },
    {
        "tag": "IPv6_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv6"
        }
    },
    {
        "protocol": "blackhole",
        "tag": "block"
    }
]
EOF
    
    # 创建 route.json 文件
    cat <<EOF > /etc/V2bX/route.json
{
    "domainStrategy": "AsIs",
    "rules": [
        {
            "outboundTag": "block",
            "ip": [
                "geoip:private"
            ]
        },
        {
            "outboundTag": "block",
            "domain": [
                "regexp:(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
                "regexp:(.+.|^)(360|so).(cn|com)",
                "regexp:(Subject|HELO|SMTP)",
                "regexp:(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
                "regexp:(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
                "regexp:(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
                "regexp:(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
                "regexp:(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
                "regexp:(.+.|^)(360).(cn|com|net)",
                "regexp:(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
                "regexp:(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
                "regexp:(.*.||)(netvigator|torproject).(com|cn|net|org)",
                "regexp:(..||)(visa|mycard|gash|beanfun|bank).",
                "regexp:(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
                "regexp:(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
                "regexp:(.*.||)(mycard).(com|tw)",
                "regexp:(.*.||)(gash).(com|tw)",
                "regexp:(.bank.)",
                "regexp:(.*.||)(pincong).(rocks)",
                "regexp:(.*.||)(taobao).(com)",
                "regexp:(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
                "regexp:(flows|miaoko).(pages).(dev)"
            ]
        },
        {
            "outboundTag": "block",
            "ip": [
                "127.0.0.1/32",
                "10.0.0.0/8",
                "fc00::/7",
                "fe80::/10",
                "172.16.0.0/12"
            ]
        },
        {
            "outboundTag": "block",
            "protocol": [
                "bittorrent"
            ]
        },
        {
            "outboundTag": "IPv4_out",
            "network": "udp,tcp"
        }
    ]
}
EOF
    ipv6_support=$(check_ipv6_support)
    dnsstrategy="ipv4_only"
    if [ "$ipv6_support" -eq 1 ]; then
        dnsstrategy="prefer_ipv4"
    fi
    # 创建 sing_origin.json 文件
    cat <<EOF > /etc/V2bX/sing_origin.json
{
  "dns": {
    "servers": [
      {
        "tag": "cf",
        "type": "udp",
        "server": "1.1.1.1"
      }
    ],
    "strategy": "$dnsstrategy"
  },
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct",
      "domain_resolver": {
        "server": "cf",
        "strategy": "$dnsstrategy"
      }
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      },
      {
        "protocol": ["bittorrent"],
        "action": "reject"
      },
      {
        "ip_is_private": true,
        "action": "reject"
      },
      {
        "domain_regex": [
            "(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
            "(.+.|^)(360|so).(cn|com)",
            "(Subject|HELO|SMTP)",
            "(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
            "(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
            "(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
            "(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
            "(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
            "(.+.|^)(360).(cn|com|net)",
            "(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
            "(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
            "(.*.||)(netvigator|torproject).(com|cn|net|org)",
            "(..||)(visa|mycard|gash|beanfun|bank).",
            "(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
            "(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
            "(.*.||)(mycard).(com|tw)",
            "(.*.||)(gash).(com|tw)",
            "(.bank.)",
            "(.*.||)(pincong).(rocks)",
            "(.*.||)(taobao).(com)",
            "(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
            "(flows|miaoko).(pages).(dev)"
        ],
        "action": "reject"
      },
      {
        "outbound": "direct",
        "network": [
          "udp","tcp"
        ]
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    }
  }
}
EOF

    # 创建 hy2config.yaml 文件           
    cat <<EOF > /etc/V2bX/hy2config.yaml
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
ignoreClientBandwidth: false
disableUDP: false
udpIdleTimeout: 60s
resolver:
  type: system
acl:
  inline:
    - direct(geosite:google)
    - reject(geosite:cn)
    - reject(geoip:cn)
masquerade:
  type: 404
EOF
    echo -e "${green}V2bX 配置文件生成完成,正在重新启动服务${plain}"
    web_started_at=$(date +%s)
    local web_launch_failed=false
    if [[ "$need_external_web" == true ]]; then
        # A systemd start job completing does not mean node initialization has
        # finished. Print success only after the frontend readiness checks.
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart V2bX || web_launch_failed=true
        else
            service V2bX restart || web_launch_failed=true
        fi
    else
        v2bx restart
    fi
    if [[ "$need_external_web" == true ]]; then
        echo "等待外部前端和证书就绪（最多 120 秒）……"
        local web_wait web_ok=false
        for ((web_wait=0;web_wait<120;web_wait++)); do
            if [[ "$web_launch_failed" == true ]]; then break; fi
            if external_web_failed; then break; fi
            if external_web_ready; then
                sleep 2
                if external_web_ready; then web_ok=true; break; fi
            fi
            sleep 1
        done
        if [[ "$web_ok" != true ]]; then
            echo "外部前端启动失败，保留失败现场并恢复原配置。"
            rollback_external_web || echo "自动恢复未完成，请保留备份目录：$web_backup"
            return 1
        fi
        rm -rf -- "$web_backup"
        echo "外部前端已就绪；以后仍使用 V2bX start/stop/restart 管理。"
    fi
}
