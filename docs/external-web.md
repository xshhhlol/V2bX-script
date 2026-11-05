# 可选的完整外部前端

安装和 `V2bX generate` 入口保持原样。选择 sing 核心的 Trojan / VMess / AnyTLS，配置 TLS 并启用网站伪装后，再选择部署方式：

1. 内置（默认）：一个 V2bX 进程，不安装其他依赖；应用错误页改用 HTML，可在网站目录放置 `404.html`、`405.html` 等自定义页面。
2. 完整外部前端：脚本准备 HAProxy、nginx、Python 3。V2bX 自动生成私有配置并管理子进程，公网地址、端口、密码、客户端和面板设置不变。

外部模式支持 **Trojan TCP+TLS、VMess TCP+TLS（无 HTTP header）和原生 AnyTLS**。不开启伪装网站时不询问部署方式；没有 TLS 的 VMess 保留原有内置 HTTP 网站，不提供外部 HTTPS 选项。WS、gRPC、HTTPUpgrade、其他协议和 REALITY 使用内置模式；不会自动修改面板或订阅。系统已有启用或运行中的 nginx/HAProxy 时会中止准备，保留已有 Web 服务。首次 HTTP-01 申请仍由 V2bX 完成，之后公网 80 转交 nginx，验证路径转发到回环 ACME 服务，续签后自动重载 OpenSSL。

外部链路：

```text
客户端 → HAProxy/OpenSSL（公网 TLS）→ 回环 Trojan / VMess / AnyTLS 认证
                                      ├─ 已认证：V2bX 代理与用户统计
                                      └─ 未认证：回环 nginx HTTP/1.1 或 HTTP/2
公网 80 → nginx → HTTPS 跳转 / 回环 ACME 验证
```

HAProxy 用 PROXY v2 携带真实 IP 和 ALPN，三个协议共用同一套解析与校验。此入口必须绑定回环地址，拒绝公网对等端以及错误或超长的 PROXY 头；不会启用 sing-box 已移除的通用 `proxy_protocol` 监听配置。连接来自不带 ALPN 的常规客户端时默认回落 HTTP/1.1；协商 h2 的合法代理客户端仍先认证。VMess 的外部 TLS 与原有 TLS 具有相同的加密策略，不会因回环后端是明文而拒绝原来允许的 `none` 客户端。AnyTLS 的复用、会话管理与流量整形保留。

依赖可由 apt、apk、dnf、yum 或 pacman 准备；不使用系统 nginx/HAProxy 服务，也不覆盖其配置。私有配置和合并后的证书位于 V2bX 的临时运行目录；私钥和清单只允许运行用户读取。V2bX 停止或删除最后一个外部节点时清理子进程和运行目录。两种模式可以共存，但公网端口不能重复占用。

现有 Docker 镜像保留原来的运行依赖；容器中使用外部模式时，需要派生镜像安装 nginx、HAProxy 和 Python 3，并按需映射公网 80 和节点端口。宿主机一键安装由向导自动处理这些依赖。

## 卸载与依赖保留

Ubuntu / Debian 安装外部组件时，脚本比较安装前后的软件包清单，将本次新增的 nginx、HAProxy 及 nginx 模块记录到 `/var/lib/V2bX-script/external-packages`。机器原有的包不记为脚本安装，Python 始终不进入可删除清单。

卸载 V2bX 时会列出记录中的组件，询问是否一并卸载，默认保留。保留依赖时来源记录也保留，以便下次重装继续识别。旧版本没有安装来源记录的组件会单独标明“来源无法确认”，默认不动，只有明确选择才移除。

如果管理员后来启动或启用了系统 nginx/HAProxy 服务，卸载时保留对应组件。删除前先模拟 apt 计划：若会连带删除 Python 或其他未选软件，则取消组件卸载；不执行 autoremove，不清除系统 Web 配置。非 apt 系统保留组件，不自动卸载。

已有机器请先执行 `V2bX update_shell` 更新管理脚本，再运行 `V2bX uninstall`，否则旧卸载脚本没有这个选项。

向导在准备依赖后备份当前配置及证书，再停止旧进程并生成配置；等待新进程及全部外部节点就绪，失败时恢复备份并按此前运行状态恢复服务。一个 V2bX 实例只使用一个 sing 核心管理公网 Web 前端。多个外部节点共用公网 80；同域名配置多个 HTTPS 端口时，HTTP 跳转优先选 443，否则按节点名称选择第一个端口。

Ubuntu 22.04 LTS（nginx 1.18）和 Ubuntu 24.04 使用同一套启动参数，不要求升级 nginx 或添加第三方源。请使用 v1.4.5 或带 `external-web-ubuntu-lts-v1` 能力的新二进制；v1.4.4 的 nginx 1.18 兼容问题仅靠更新脚本无法修复。两种 Ubuntu 环境均纳入发布验证。

明确的前端错误或进程退出会立即报告，不再空等 120 秒。失败配置、证书和本次日志保存在仅 root 可读的 `/etc/V2bX/failed-external.*`；恢复后只重启之前确实运行中的服务。首次安装没有运行中的旧服务时保持停止，不反复启动发布包自带的示例配置。卸载会删除 `/etc/V2bX`，如需保留故障现场请先复制该目录。

## 构建与启用

需要同时包含脚本和核心改动的新二进制。向导会调用 `V2bX features`：Trojan 要求 `external-web-v1`，VMess / AnyTLS 要求 `external-web-v2`。旧二进制不会误写外部配置。尚未包含该能力的发布包，仅更新脚本不能启用此功能。

```bash
bash build-web-local.sh
# ARM64：GOARCH=arm64 bash build-web-local.sh
```

产物为 `output/V2bX-web-linux-amd64` 和 SHA-256 文件。构建临时替换并列的 `sing-box_mod`，不修改发布模块依赖。安装此二进制后，原来的 `V2bX generate` 会显示部署选择。手工配置的对应开关是节点中的 `"ExternalWeb": {"Enable": true}`，配合正常的证书配置及网站目录。

发布时需先发布新的 `sing-box_mod`，再更新 V2bX 的模块版本。普通构建继续兼容旧协议模块，但不会报告 `external-web-v1` 能力；向导因此不会把不支持该功能的二进制切到外部模式。

内置模式只替换应用层错误/跳转响应，HTTP 解析器在进入 Handler 前产生的错误、Go TLS 和 HTTP/2 行为仍然存在。外部模式让公网 TLS 与网页由实际 OpenSSL/nginx 实现，但并不承诺无法识别代理、避免封锁或修复已经存在的 IP/线路故障。
