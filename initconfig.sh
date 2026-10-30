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
    if [[ "$core_sing" == true && ( ( "$certmode" != "none" && ( "$NodeType" == "trojan" || "$NodeType" == "anytls" ) ) || "$NodeType" == "vmess" ) ]]; then
        read -rp "是否启用伪装网站和抗主动探测？无需安装 nginx（推荐，回车默认 y）(y/n)：" harden_choice
        if [[ ! "$harden_choice" =~ ^[Nn] ]]; then
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
    v2bx restart
}
