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

# 伪装网站与抗主动探测

生成配置时，sing 内核的 Trojan / AnyTLS 节点（http、dns、self 证书模式）和 VMess 节点（有无 TLS 均可）会询问是否启用，回车即启用，不需要安装 nginx：

- 未通过认证的连接（探测、浏览器访问）由 V2bX 内置的网站响应，支持 HTTP/2 和 HTTP/1.1
- 网站文件在 `/etc/V2bX/www`，首次生成时随机创建首页，可直接替换成自己的静态网站
- http / dns 证书模式下拒绝 SNI 与证书域名不匹配的握手；如果面板里节点地址填的是 IP，需要把 server_name 填成证书域名
- 80 端口跳转到 https；http 模式申请和续签证书由同一个 80 端口服务响应，互不冲突
- AnyTLS 节点额外开启服务端流量整形，不需要面板或客户端改动
- VMess：面板传输协议为 tcp 时，认证失败、重放、时间戳错误、首包过短等请求一律原样交给伪装网站，不再立即断开；ws/grpc 等由传输层应答
- VMess 未开 TLS 时拒绝 `none`、`aes-128-cfb` 这类不加密或不认证的客户端，客户端加密方式请用 `auto`；下行前几条记录随机拆分，打乱嵌套 TLS 握手的长度特征
- 以上都只改服务端，sing-box、Xray（v2rayN 等）客户端无需改动；但裸 VMess 首包全随机的被动特征无法在服务端消除，能用 TLS 尽量用 TLS
