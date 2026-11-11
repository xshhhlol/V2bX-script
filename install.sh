#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates jq iproute -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates jq iproute2 >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates jq iproute2 -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat jq iproute2 -y >/dev/null 2>&1
        apt-get install ca-certificates wget -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat jq iproute2 >/dev/null 2>&1
        pacman -S --noconfirm --needed ca-certificates wget >/dev/null 2>&1
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/V2bX/V2bX ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service V2bX status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        if systemctl is-active --quiet V2bX; then
            return 0
        else
            return 1
        fi
    fi
}

install_V2bX() {
    local stage candidate_version expected_hash actual_hash entry auto_version=false
    if [[ $# == 0 || -z "$1" ]]; then
        auto_version=true
        last_version=$(curl -fsS --connect-timeout 10 --max-time 30 "https://api.github.com/repos/xshhhlol/V2bX/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ -z "$last_version" ]]; then
            echo "无法查询最新稳定版本，请检查网络，或运行 V2bX update v1.4.9 指定版本。"
            return 1
        fi
    else
        last_version=$1
        if [[ "$last_version" != v* ]]; then last_version="v$last_version"; fi
    fi
    if [[ ! "$last_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
        echo "版本号无效，请填写类似 v1.4.9 的版本号。"
        return 1
    fi
    if [[ "$auto_version" == true && -x /usr/local/V2bX/V2bX ]]; then
        local current_version current_major current_minor current_patch target_major target_minor target_patch
        current_version=$(/usr/local/V2bX/V2bX version 2>/dev/null)
        if [[ "$current_version" =~ V2bX\ v([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
            current_major=${BASH_REMATCH[1]}; current_minor=${BASH_REMATCH[2]}; current_patch=${BASH_REMATCH[3]}
            IFS=. read -r target_major target_minor target_patch <<< "${last_version#v}"
            target_patch=${target_patch%%-*}
            if (( current_major > target_major || (current_major == target_major && current_minor > target_minor) ||
                  (current_major == target_major && current_minor == target_minor && current_patch > target_patch) )); then
                echo "当前程序比最新完整发布版 ${last_version} 更新，保持现状，不自动降级。"
                echo "如需手动降级，请明确指定版本，例如 V2bX update ${last_version}。"
                return 0
            fi
        fi
    fi
    echo "准备安装 V2bX ${last_version}；先下载和校验，成功后才替换当前程序。"
    stage=$(mktemp -d /tmp/v2bx-install.XXXXXX) || return 1
    local url="https://github.com/xshhhlol/V2bX/releases/download/$last_version/V2bX-linux-${arch}.zip"
    if ! curl -fLsS --retry 2 --connect-timeout 15 --max-time 180 "$url" -o "$stage/package.zip" ||
       ! curl -fLsS --retry 2 --connect-timeout 15 --max-time 60 "$url.dgst" -o "$stage/package.dgst"; then
        echo "该版本的安装包或校验文件尚未发布，或下载失败。旧程序和配置未改动，请稍后重试。"
        rm -rf -- "$stage"
        return 1
    fi
    expected_hash=$(awk 'tolower($0) ~ /sha.*256/ {print $NF; exit}' "$stage/package.dgst")
    actual_hash=$(sha256sum "$stage/package.zip" | awk '{print $1}')
    if [[ ! "$expected_hash" =~ ^[a-fA-F0-9]{64}$ || "$actual_hash" != "$expected_hash" ]] ||
       ! unzip -q "$stage/package.zip" -d "$stage/files" || [[ ! -s "$stage/files/V2bX" ]]; then
        echo "安装包校验或解压失败，旧程序和配置未改动。"
        rm -rf -- "$stage"
        return 1
    fi
    chmod +x "$stage/files/V2bX"
    candidate_version=$("$stage/files/V2bX" version 2>/dev/null)
    if [[ "$candidate_version" != *"V2bX $last_version "* ]]; then
        echo "安装包版本不符或无法运行，请检查系统架构与版本。旧程序未改动。"
        rm -rf -- "$stage"
        return 1
    fi
    mkdir -p /usr/local/V2bX /etc/V2bX || { rm -rf -- "$stage"; return 1; }
    if [[ -f /usr/local/V2bX/V2bX ]]; then
        cp -p /usr/local/V2bX/V2bX /usr/local/V2bX/V2bX.previous || { rm -rf -- "$stage"; return 1; }
    fi
    for entry in "$stage/files/"*; do
        [[ "${entry##*/}" == V2bX ]] && continue
        cp -R -- "$entry" /usr/local/V2bX/ || { rm -rf -- "$stage"; return 1; }
    done
    install -m 755 "$stage/files/V2bX" /usr/local/V2bX/V2bX.new &&
        mv -f /usr/local/V2bX/V2bX.new /usr/local/V2bX/V2bX || { rm -rf -- "$stage"; return 1; }
    rm -rf -- "$stage"
    cd /usr/local/V2bX/ || return 1
    for entry in geoip.dat geosite.dat; do
        if [[ -f "$entry" ]]; then cp "$entry" /etc/V2bX/; fi
    done
    if [[ x"${release}" == x"alpine" ]]; then
        if [[ ! -f /etc/init.d/V2bX ]]; then
        cat <<EOF > /etc/init.d/V2bX
#!/sbin/openrc-run

name="V2bX"
description="V2bX"

command="/usr/local/V2bX/V2bX"
command_args="server"
command_user="root"

pidfile="/run/V2bX.pid"
command_background="yes"

depend() {
        need net
}
EOF
        fi
        chmod +x /etc/init.d/V2bX
        rc-update add V2bX default
        echo -e "${green}V2bX ${last_version}${plain} 安装完成，已设置开机自启"
    else
        if [[ ! -f /etc/systemd/system/V2bX.service ]]; then
        cat <<EOF > /etc/systemd/system/V2bX.service
[Unit]
Description=V2bX Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/V2bX/
ExecStart=/usr/local/V2bX/V2bX server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        fi
        systemctl daemon-reload
        systemctl stop V2bX
        systemctl enable V2bX
        echo -e "${green}V2bX ${last_version}${plain} 安装完成，已设置开机自启"
    fi

    # 新发布包附带 sing 配置；保留已有节点的自定义规则，兼容未附带该文件的旧发布包。
    if [[ ! -f /etc/V2bX/sing_origin.json && -f sing_origin.json ]]; then
        cp sing_origin.json /etc/V2bX/
    fi

    if [[ ! -f /etc/V2bX/config.json ]]; then
        cp config.json /etc/V2bX/
        echo -e ""
        echo -e "下一步：在面板建好节点，准备面板地址、API Key 和节点 ID，再按向导生成配置。"
        echo "XHTTP/H3 请选择向导第 3 项；路径、mode 和高级参数在面板配置，向导会读取检查。"
        first_install=true
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service V2bX start
        else
            systemctl start V2bX
        fi
        sleep 2
        echo -e ""
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}V2bX 重启成功${plain}"
        else
            echo "新版未能启动。请运行 V2bX log 查看原因。"
            if [[ -f /usr/local/V2bX/V2bX.previous ]]; then
                cp -p /usr/local/V2bX/V2bX.previous /usr/local/V2bX/V2bX.rollback &&
                    mv -f /usr/local/V2bX/V2bX.rollback /usr/local/V2bX/V2bX
                if [[ "$release" == alpine ]]; then service V2bX restart; else systemctl restart V2bX; fi
                echo "已恢复上一个程序版本；/etc/V2bX 中的节点配置和证书保留。"
            fi
            return 1
        fi
        first_install=false
    fi

    if [[ ! -f /etc/V2bX/dns.json ]]; then
        cp dns.json /etc/V2bX/
    fi
    if [[ ! -f /etc/V2bX/route.json ]]; then
        cp route.json /etc/V2bX/
    fi
    if [[ ! -f /etc/V2bX/custom_outbound.json ]]; then
        cp custom_outbound.json /etc/V2bX/
    fi
    if [[ ! -f /etc/V2bX/custom_inbound.json ]]; then
        cp custom_inbound.json /etc/V2bX/
    fi
    local manager_tmp
    manager_tmp=$(mktemp /usr/bin/.v2bx-manager.XXXXXX) || return 1
    if curl -fLsS --connect-timeout 10 --max-time 30 -o "$manager_tmp" https://raw.githubusercontent.com/xshhhlol/V2bX-script/master/V2bX.sh && bash -n "$manager_tmp"; then
        chmod +x "$manager_tmp"
        mv -f "$manager_tmp" /usr/bin/V2bX
    else
        rm -f -- "$manager_tmp"
        echo "程序已安装，但管理脚本下载失败；已有管理脚本保留，请稍后重新运行安装器。"
        return 1
    fi
    if [ ! -L /usr/bin/v2bx ]; then
        ln -s /usr/bin/V2bX /usr/bin/v2bx
        chmod +x /usr/bin/v2bx
    fi
    # 自动做网络优化（BBR、闲置不重新慢启动等），不更换内核
    /usr/bin/V2bX optimize
    cd $cur_dir
    echo -e ""
    echo "V2bX 管理脚本使用方法 (兼容使用V2bX执行，大小写不敏感): "
    echo "------------------------------------------"
    echo "V2bX              - 显示管理菜单 (功能更多)"
    echo "V2bX start        - 启动 V2bX"
    echo "V2bX stop         - 停止 V2bX"
    echo "V2bX restart      - 重启 V2bX"
    echo "V2bX status       - 查看 V2bX 状态"
    echo "V2bX enable       - 设置 V2bX 开机自启"
    echo "V2bX disable      - 取消 V2bX 开机自启"
    echo "V2bX log          - 查看 V2bX 日志"
    echo "V2bX x25519       - 生成 x25519 密钥"
    echo "V2bX generate     - 生成 V2bX 配置文件"
    echo "V2bX optimize     - 网络优化 (BBR 等)"
    echo "V2bX update       - 更新 V2bX"
    echo "V2bX update x.x.x - 更新 V2bX 指定版本"
    echo "V2bX install      - 安装 V2bX"
    echo "V2bX uninstall    - 卸载 V2bX"
    echo "V2bX version      - 查看 V2bX 版本"
    echo "------------------------------------------"
    curl -fsS --max-time 10 "https://api.v-50.me/counter_v2bx" || true
    # 首次安装询问是否生成配置文件
    if [[ $first_install == true ]]; then
        read -rp "现在根据面板信息生成配置？回车暂不生成，也可稍后运行 V2bX generate [y/N]：" if_generate
        if [[ $if_generate == [Yy] ]]; then
            local wizard
            wizard=$(mktemp) || return 1
            if ! curl -fLsS --connect-timeout 10 --max-time 30 -o "$wizard" https://raw.githubusercontent.com/xshhhlol/V2bX-script/master/initconfig.sh || ! bash -n "$wizard"; then
                rm -f -- "$wizard"
                echo "配置向导下载失败，请稍后运行 V2bX generate。"
                return 1
            fi
            source "$wizard"
            rm -f -- "$wizard"
            generate_config_file || return 1
        else
            echo "准备好面板信息后，运行 V2bX generate，按提示完成配置即可。"
        fi
    fi
}

echo -e "${green}开始安装${plain}"
install_base
install_V2bX "$@"
