# V2bX
A V2board node server based on Xray-Core.

一个基于Xray的V2board节点服务端，支持V2ay,Trojan,Shadowsocks协议

Find the source code here: [xshhhlol/V2bX](https://github.com/xshhhlol/V2bX)

如对脚本不放心，可使用此沙箱先测一遍再使用：https://killercoda.com/playgrounds/scenario/ubuntu

# 详细使用教程

[教程](https://v2bx.v-50.me/)

# 一键安装

```
wget -N https://raw.githubusercontent.com/xshhhlol/V2bX-script/master/install.sh && bash install.sh
```

# XHTTP / HTTP/3 一键配置

先在面板创建 **VLESS** 节点，传输选择 **XHTTP**，开启 **TLS**，清空 flow。HTTP/3 的 ALPN 只填 `h3`；证书域名填在 TLS `server_name`。路径、mode 和上下行分离等高级参数在面板配置。

安装时进入配置向导，或安装后运行 `V2bX generate`，选择 **3. VLESS + XHTTP / HTTP/3**。填写面板根地址、对接 API Key 和节点 ID，向导会读取节点设置，并引导自动申请证书或使用已有证书文件，不需要手写 JSON。

- H3 需要放行面板服务端口的 **UDP**；HTTP 自动申请证书还需要放行 **TCP 80**，并将证书域名解析到本机。
- path、mode、extra 等配置由内核持续从面板拉取；**ALPN 在生成配置时复制到本机，切换 H2/H3 后需要重新运行向导**。
- 下载包会先校验 SHA256，下载失败不会删除旧程序；更新保留现有配置、证书及服务自定义设置。指定版本运行 `V2bX update v1.4.8`，该架构安装包尚未发布时会保留旧版并提示重试。

详细步骤、证书续签和面板填写示例见 [XHTTP 安装说明](docs/xhttp.md)。

# 默认 BT 拦截

配置向导生成的 `/etc/V2bX/sing_origin.json` 默认先嗅探流量，再拒绝识别为 `bittorrent` 的连接，规则位于最终直连之前。所有使用该 sing 内核的 SS / SS2022、VMess、Trojan、AnyTLS、TUIC 和 Hy2 节点共用这些规则，客户端无需修改。

V2bX 发布包的示例配置也包含这些规则，安装时仅在目标文件不存在且发布包附带该文件时复制；更新安装脚本不会自动改写已有配置。已有节点可在 `sing_origin.json` 的 `route.rules` 数组开头加入以下两条，保留后面的原有规则，然后运行 `V2bX restart`：

```json
{ "action": "sniff" },
{ "protocol": ["bittorrent"], "action": "reject" }
```

重新运行 `V2bX generate` 也会生成这些规则，但会重写节点及辅助配置，有自定义规则时应先备份。独立 `hysteria2` 内核不加载此文件；加密或再次套隧道的 BT 可能无法识别，不能保证阻断全部 BT 流量。

# 伪装网站与抗主动探测

生成配置时，sing 内核的 Trojan / AnyTLS 节点（http、dns、self 证书模式）和 VMess 节点（有无 TLS 均可）会询问是否启用，回车即启用，不需要安装 nginx：

- 未通过认证的连接（探测、浏览器访问）由 V2bX 内置的网站响应，支持 HTTP/2 和 HTTP/1.1
- 网站文件在 `/etc/V2bX/www`，首次生成时随机创建首页，可直接替换成自己的静态网站
- Trojan、VMess、AnyTLS 启用 HTTPS 网站伪装后，可继续选择“原有内置”或“完整外部前端”：脚本自动准备 HAProxy、nginx 和 Python 3；V2bX 管理其私有配置、启动停止和证书重载，无需另写 Web 配置。外部模式支持 Trojan TCP+TLS、VMess TCP+TLS（无 HTTP header）及原生 AnyTLS；HAProxy/OpenSSL 接管公网 TLS，nginx 处理 HTTP/1.1、HTTP/2 和 ACME 转发，V2bX 只在回环地址接收认证与代理流量，保留原始客户端 IP 和 ALPN。默认仍为内置模式，不增加依赖。参见[外部前端说明](docs/external-web.md)。
- http / dns 证书模式下拒绝 SNI 与证书域名不匹配的握手；如果面板里节点地址填的是 IP，需要把 server_name 填成证书域名
- 80 端口跳转到 https；http 模式申请和续签证书由同一个 80 端口服务响应，互不冲突
- AnyTLS 节点额外开启服务端流量整形，不需要面板或客户端改动
- VMess：面板传输协议为 tcp 且没有 HTTP header 等额外封装时，认证失败、重放、时间戳错误等请求原样交给伪装网站；ws/grpc 等由传输层应答，不会自动接入该网站
- VMess 的网站回落和下行整形不要求修改客户端；裸连接是否拒绝 `none`、`aes-128-cfb` 单独询问，默认保留兼容。选择拒绝时，客户端加密方式请用 `auto`。已有配置里的 `RequireEncryption` 不会被自动修改
- 请求头分段到达时继续读取，不以单次读取长度判断有效性。少于 16 字节且对端不结束发送的请求，会等待剩余数据或握手期限；正常完整 HTTP 请求不需要等到期限
- 下行前几条 VMess 记录随机拆分，响应头与数据合并写入；这不能保证 TCP 包长与普通 HTTPS 相同，也不隐藏上行、突发规模、方向和时序
- 以上都只改服务端，sing-box、Xray（v2rayN 等）客户端无需改动；但裸 VMess 首包全随机的被动特征无法在服务端消除，能用 TLS 尽量用 TLS

上述分段读取和重放窗口修复从 V2bX v1.4.1 起提供。已有节点可运行 `V2bX update v1.4.1` 更新服务端；只更新管理脚本不会更新协议实现。TLS 需要面板和客户端同步配置，仅选择证书模式不会自动改变面板传输设置。

本地源码目录下 `V2bX`、`sing-vmess` 与本仓库并列时，可构建包含本地协议修复的 Linux 服务端：

```bash
bash build-vmess-local.sh
# ARM64：GOARCH=arm64 bash build-vmess-local.sh
```

输出为 `output/V2bX-linux-amd64` 和 SHA-256 校验文件。构建使用临时模块文件，不修改 V2bX 发布依赖，也不依赖开发机的 `go.work`。现有节点使用新二进制重启后，分段读取和重放修复自动生效；网站和整形仍由节点配置控制。

本次修复、客户端验证范围及限制见 [VMess 兼容加固说明](docs/vmess-hardening.md)。

SS / SS2022 的面板填写方法、兼容加固、本地构建方式和验证范围见 [Shadowsocks 加固说明](docs/shadowsocks-hardening.md)。首次安装时可选择生成配置；已有安装运行 `V2bX generate` 进入向导。选择 Shadowsocks 后会说明加密方式、端口和可选优化，原生 SS 不询问证书。

已有 `aes-128-gcm` 节点可保持原算法，开启 TCP 优化。UDP 新填充只对 SS2022 生效，普通 SS 自动跳过；客户端不强制开启复用。本地构建使用 `bash build-ss-local.sh`，需要并列的 `V2bX`、`sing-box_mod`、`sing-shadowsocks`。已有配置需要添加说明中的 `ShadowsocksConfig` 才会开启可选整形/填充；SS 加固从 V2bX v1.4.2 起提供，已有节点可运行 `V2bX update v1.4.2` 更新服务端；仅更新脚本不会启用协议修复。

# Trojan 修复与加固

从 V2bX v1.4.3 起提供。只改服务端，客户端和面板设置都不用改。已有节点运行 `V2bX update v1.4.3` 更新服务端；只更新管理脚本不会生效。

- 修复：v1.3.x 起，面板传输协议为 ws、grpc、h2 的 Trojan 节点，每个连接都会被断开，日志显示 `set handshake deadline: invalid argument`。tcp 和 httpupgrade 节点不受影响
- 伪装网站沿用连接开始时的请求头期限（30 秒），不再重新计时。探测无论何时打破 Trojan 格式，都不会多拿一轮等待。浏览器发完请求头后，长连接和上传由网站自己的超时控制
- 请求头和 UDP 帧里的分隔符严格校验，格式不对的请求直接拒绝
- 删除用户时，该用户的 UDP 连接（如游戏、语音）也会断开，此前只断开 TCP
- 每个节点同时转交给伪装网站的连接最多 1024 个，超出直接关闭，不影响已认证用户。内置网站加了 2 分钟写入超时
- 扫描造成的握手失败日志每分钟只记一条 error，其余降为 debug；日志级别设为 debug 时仍可看到每一条
