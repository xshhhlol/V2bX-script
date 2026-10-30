# VMess 兼容加固（2026-10-30）

改动位于并列的 `sing-vmess` 协议库、`V2bX` 集成测试和本配置脚本。VMess 线格式、加密算法协商及客户端选项保持兼容；没有单方面添加客户端无法解析的填充，也没有强制启用复用或引入随机等待。

## 协议库修复

- 按字节流增量读取 AuthID、AEAD 长度、nonce 和请求头，合法分段不再被当成无效请求。
- AEAD 重放缓存按协议时钟保留到请求时间戳彻底失效，包含最后一个有效秒；用加密 AuthID 区分用户。
- 完整头部验证后才原子登记重放，篡改或截断头部不会提前占用真实请求的 AuthID。
- alterId 请求校验 FNV，并检测按用户和时间戳区分的完整头部重放；同一秒的新连接仍可通过。启动后才加入的旧用户也会定时刷新认证 ID。
- 旧协议回落保留分段读取的原始字节；正常请求持有预读数据副本，避免缓冲池复用损坏数据。
- 全用户扫描在锁内预留预算，成功后返还，避免并发失败绕过限制。下行合并写出检测短写，避免静默损坏加密流。

## 配置与客户端兼容

生成配置时，网站回落及整形默认开启；裸连接是否拒绝 `none` / `aes-128-cfb` 单独询问，默认不拒绝。需要限制时选择 y，并把这类客户端的加密改为 auto。已有节点配置不会自动迁移。

```json
"VMessConfig": {
  "RequireEncryption": false,
  "HandshakeTimeout": 30,
  "TrafficShaping": { "Enable": true }
}
```

这是节点配置片段。`RequireEncryption` 只在没有外层 TLS 时生效。网站回落需要另外开启 `FallBackSite`，且面板传输为没有 HTTP header 等额外封装的 TCP。WS、gRPC、HTTPUpgrade 不会自动接入内置网站。证书模式不能代替面板和客户端中的 TLS 设置。

少于 16 字节且未结束发送的输入会等待更多数据或握手期限，因为随机密文前缀不能被可靠当作 HTTP/无效请求。对端半关闭后可以立即把已收字节交给网站；完整 HTTP 请求无需等待整个期限。

## 已验证的范围

- sing-vmess 的原生客户端：auto、none、zero、CFB、AES-GCM、ChaCha20，填充与认证长度选项，AEAD/alterId，TCP/UDP/Mux 头部解析。
- Xray-core v26.3.27 的真实客户端编码：TCP/UDP、整形、大流量和逐字节头部读取。覆盖其常用选项；Xray 与 sing-vmess 原本不互通的 none + AuthenticatedLength 组合仍跳过。
- V2bX 真实入站：TCP、TLS、WebSocket、gRPC、HTTPUpgrade 的分段代理请求；TLS 下 none 可用；HTTP/1.1 和 HTTP/2 回落。
- 回归测试：时间戳窗口边界、并发重放、篡改与截断、跨用户区分、旧用户延迟加入及预读数据所有权、并发扫描预算。

以上验证客户端核心和协议行为，未逐一测试 v2rayN、Shadowrocket 等所有 GUI 版本，也未在真实 DPI 分类器或用户服务器上验证抗识别收益。重放缓存不跨进程重启或独立实例共享；旧式认证仍有其固有局限，优先使用 alterId=0。

## 构建与生效

在本仓库运行 `bash build-vmess-local.sh`；ARM64 使用 `GOARCH=arm64 bash build-vmess-local.sh`。脚本临时覆盖 sing-vmess 依赖，保留发布用 go.mod/go.sum，并生成 Linux 二进制和可移植的 SHA-256 校验文件。

V2bX v1.4.1 起已锁定包含这些修复的 sing-vmess 远程模块版本。已有节点可使用 `V2bX update v1.4.1` 更新服务端；新安装使用对应版本的发布包。更新并重启后，协议读取和重放修复会自动生效，网站及整形仍由配置控制。仅更新管理脚本不会替换服务端协议实现。

裸 VMess 随机首包、上行握手及流量方向/时序无法仅靠这些服务端改动消除。下行整形属于有限扰动，不能据此保证不可识别。
