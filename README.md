# EasyTrojan

基于 [Caddy](https://github.com/caddyserver/caddy) 和
[imgk/caddy-trojan](https://github.com/imgk/caddy-trojan) 的一键部署与管理脚本。

项目提供 Trojan over WebSocket、自动 HTTPS、Cloudflare Origin 证书、用户管理、
伪装站以及可选的多节点订阅 Hub。安装完成后，可通过 `easytrojan` 统一管理。

## 功能概览

- 支持 `amd64`、`arm64`，适用于使用 systemd 和 `apt`、`dnf` 或 `yum` 的 Linux
- 支持 Trojan over WebSocket + TLS，SNI 和 WebSocket Host 固定为部署域名
- 支持 Caddy ACME 自动证书和 Cloudflare Origin 证书
- 默认部署 [IT-Tools](https://github.com/CorentinTh/it-tools) 伪装站，下载失败时回退到内置页面
- 支持多用户、分享链接、Cloudflare 优选 IP 和非 443 HTTPS 端口
- 可选多节点 Hub，输出 base64 格式的 `trojan://` 订阅
- Release 资源通过 `SHA256SUMS` 校验
- Caddy Admin API 仅监听 `127.0.0.1:2019`
- 全局 sysctl 和 limits 调优默认关闭，可按需启用

## 开始之前

准备以下环境：

| 要求 | 说明 |
| --- | --- |
| 权限 | root，或可使用 `sudo` |
| 域名 | 必须使用真实域名，不支持 nip.io 等临时通配域名 |
| DNS | 直连或灰云时，域名 A 记录应指向服务器公网 IPv4 |
| 端口 | 安全组和系统防火墙需放行 TCP 80、443 |
| 系统 | systemd Linux；包管理器为 `apt`、`dnf` 或 `yum` |
| 架构 | `x86_64/amd64` 或 `aarch64/arm64` |

放行端口示例（按实际防火墙选择一种）：

```bash
# RHEL / CentOS / Fedora
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload

# Debian / Ubuntu
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

先根据接入方式选择 TLS 模式：

| 接入方式 | TLS 模式 | DNS 状态 | 适用场景 |
| --- | --- | --- | --- |
| 域名直连 | `auto` | 直接解析源站 | Caddy 自动申请和续签 ACME 证书 |
| Cloudflare 灰云 | `auto` | DNS only | 与域名直连相同 |
| Cloudflare 橙云 | `origin` | Proxied | 长期经 Cloudflare 访问源站 |

> `auto` 是默认模式。使用 `auto` 时，80 端口必须能从公网访问，以完成 ACME
> HTTP-01 验证。

## 快速安装

下载入口脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/easytrojan.sh -o easytrojan.sh
chmod +x easytrojan.sh
```

### 直连或 Cloudflare 灰云

```bash
sudo bash easytrojan.sh install --domain example.com
```

脚本会交互式读取并确认 Trojan 密码。安装成功后：

```bash
sudo easytrojan status
sudo easytrojan status --show-link
```

浏览器访问 `https://example.com` 应看到 IT-Tools 伪装站。

### Cloudflare 橙云

先在 Cloudflare 控制台创建 Origin Certificate，并保存证书和私钥：

```bash
chmod 600 origin.key

sudo bash easytrojan.sh install \
  --domain example.com \
  --tls-mode origin \
  --origin-cert ./origin.pem \
  --origin-key ./origin.key \
  --skip-domain-check
```

Cloudflare 侧还需设置：

- DNS 记录：**Proxied（橙云）**
- SSL/TLS 加密模式：**Full (strict)**
- Network -> WebSockets：**On**

橙云解析到的是 Cloudflare IP，因此安装时需要 `--skip-domain-check`。

### 非交互与版本锁定

`--password` 会进入 shell history 或进程参数，自动化场景之外更推荐交互输入。

```bash
# 非交互安装
sudo bash easytrojan.sh install \
  --domain example.com \
  --password 'replace-with-a-strong-password'

# 固定 Caddy-Trojan Release
sudo bash easytrojan.sh install \
  --domain example.com \
  --version 'v2.11.3+trojan.932ef9b'

# 指定 IT-Tools 版本
sudo IT_TOOLS_VERSION=v2024.10.22-7ca5933 \
  bash easytrojan.sh install --domain example.com

# 显式启用全局 sysctl 和 limits 调优
sudo bash easytrojan.sh install --domain example.com --tune-system
```

兼容旧用法：

```bash
sudo bash easytrojan.sh 'password' example.com
```

仅下载入口脚本时，脚本会获取并校验最新 Release 的完整模块包；从仓库运行时，
优先使用本地 `lib/`。

## 管理命令

安装后使用 `/usr/local/bin/easytrojan`：

| 命令 | 作用 |
| --- | --- |
| `easytrojan status` | 查看服务、TLS、域名与用户状态，默认隐藏分享链接 |
| `easytrojan status --show-link` | 查看状态并打印分享链接 |
| `easytrojan doctor` | 只读检查 Caddy、TLS、Hub 和管理状态 |
| `easytrojan link` | 生成分享链接 |
| `easytrojan update [--version VER]` | 更新脚本模块与 Caddy 二进制 |
| `easytrojan renew [--force]` | 执行 ACME 维护；`--force` 会删除证书并重新申请 |
| `easytrojan cert status` | 查看当前 TLS 模式和证书状态 |
| `easytrojan cert auto` | 切换到 Caddy ACME 自动证书 |
| `easytrojan cert origin --cert PATH --key PATH` | 切换到文件证书 |
| `easytrojan user add` | 添加 Trojan 用户 |
| `easytrojan user list` | 查看脱敏后的用户列表 |
| `easytrojan user del --password PASS` | 删除 Trojan 用户 |
| `easytrojan hub ...` | 管理多节点订阅 Hub |

常用诊断命令：

```bash
sudo easytrojan doctor
sudo systemctl status caddy
sudo journalctl -u caddy --no-pager -n 50
sudo caddy validate --config /etc/caddy/Caddyfile
```

### 用户管理

```bash
sudo easytrojan user add
sudo easytrojan user list
sudo easytrojan user del --password 'password-to-remove'
```

用户数据以 `/etc/caddy/trojan/passwd.txt` 为源，并写入 Caddyfile 的静态
`users` 配置。删除用户时，脚本还会清理 Caddy storage 中对应的键并 reload。

### TLS 管理

```bash
# 查看当前模式
sudo easytrojan cert status

# 从 Origin 证书切回 ACME
sudo easytrojan cert auto

# 更新或切换 Origin 证书
sudo easytrojan cert origin --cert ./origin.pem --key ./origin.key
```

TLS 模式记录在 `/etc/caddy/trojan/tls-mode.txt`。同域名重装会尽量保留已有
ACME 材料；未指定 `--tls-mode` 时会沿用原模式。Origin 证书保存为
`/etc/caddy/certs/origin.crt` 和 `origin.key`。

> 不要对 `origin` 模式执行 `renew --force`。Origin 证书到期后，应在
> Cloudflare 重新签发，再运行 `cert origin` 替换。

## Cloudflare 优选 IP

分享链接可将连接地址改为 Cloudflare 优选 IP，同时保持 SNI 和 WebSocket Host
为真实域名：

```bash
sudo easytrojan link --server 104.16.1.1 --port 443 --name sg-01
sudo easytrojan link --server 104.16.1.1 --port 2053 --name sg-01
sudo easytrojan status --show-link --server 104.16.1.1 --port 443
```

Cloudflare 常用 HTTPS 端口包括 `443`、`2053`、`2083`、`2087`、`2096` 和
`8443`。客户端仍需使用部署域名作为 SNI 和 Host，传输方式为 WebSocket，路径
为 `/`。

## 多节点订阅 Hub

Hub 将多台 EasyTrojan 节点聚合为一个 base64 订阅。Hub 服务只监听
`127.0.0.1:2099`，公网请求由 Caddy 反向代理到 `/sub/*` 和 `/api/*`。

Hub 需要 Python 3.8 或更高版本。启用时若未找到合适版本，脚本会尝试通过
`apt`、`dnf` 或 `yum` 安装。

### 1. 在 Hub 主机启用服务

```bash
sudo easytrojan hub enable --name sg-hub
sudo easytrojan hub status
sudo easytrojan hub token
```

`hub token` 会显示：

- `register_token`：节点注册凭证
- `sub_token`：订阅凭证
- 完整订阅 URL

### 2. 在其他节点加入 Hub

```bash
sudo easytrojan hub join \
  --url https://hub.example.com \
  --token 'REGISTER_TOKEN' \
  --name hk-01 \
  --server hk.example.com \
  --port 443
```

`--server` 和 `--port` 只设置当前节点写入 Hub 的默认连接地址。加入信息保存到
`/etc/caddy/trojan/hub-client.json`；此后执行 `user add` 或 `user del` 时会尝试
同步远端 Hub。

### 3. 获取订阅

```bash
sudo easytrojan hub url
sudo easytrojan hub url --server 104.16.1.1 --port 443
```

对应 URL 格式：

```text
https://hub.example.com/sub/<sub_token>
https://hub.example.com/sub/<sub_token>?server=104.16.1.1&port=443
```

订阅 URL 中的 `server` 和 `port` 会在本次拉取时覆盖**全部节点**的连接地址，
但不会修改各节点的 SNI 和 Host。这与 `hub join --server/--port` 的单节点默认值
不同。

### Hub 运维

```bash
sudo easytrojan hub list
sudo easytrojan hub rename --name new-local-name
sudo easytrojan hub rename --id NODE_ID --name new-node-name
sudo easytrojan hub remove --id NODE_ID
sudo easytrojan hub leave
sudo easytrojan hub disable
```

- `hub leave` 只删除本机保存的远端 membership，不会删除远端已有节点
- `hub disable` 停止本机 Hub 并移除反代，但保留 `nodes.json`
- 多用户节点会为每个密码注册一条记录，名称依次追加 `-2`、`-3` 等

Hub 相关数据：

| 路径 | 内容 |
| --- | --- |
| `/etc/caddy/trojan/hub/config.json` | `register_token` 和 `sub_token` |
| `/etc/caddy/trojan/hub/nodes.json` | 已注册节点和密码 |
| `/etc/caddy/trojan/hub/enabled` | 本机 Hub 开关 |
| `/etc/caddy/trojan/hub-client.json` | 本机加入远端 Hub 的凭证 |
| `/usr/local/share/easytrojan/hub_server.py` | Hub 服务实现 |

## 客户端参数

| 参数 | 值 |
| --- | --- |
| 协议 | Trojan |
| 地址 | 部署域名，或 Cloudflare 优选 IP |
| 端口 | 443，或 Cloudflare 支持的 HTTPS 端口 |
| TLS | 开启 |
| ALPN | `h2,http/1.1` |
| 传输 | WebSocket |
| SNI / Host | 部署域名 |
| Path | `/` |

## 常见问题

### 安装时报域名校验失败

先确认域名 A 记录指向服务器公网 IPv4。若使用 Cloudflare 橙云，解析到
Cloudflare IP 属于正常现象，请使用 `--skip-domain-check` 并选择 `origin` 模式。

### 浏览器显示 Cloudflare Origin Certificate 不受信任

Cloudflare Origin 证书只用于 Cloudflare 到源站的连接，浏览器不会直接信任。
请通过已开启橙云代理的域名访问，不要直接访问源站 IP。

### 分享链接使用优选 IP 后无法连接

依次确认：

1. Cloudflare WebSockets 已开启。
2. SSL/TLS 模式为 Full (strict)。
3. 客户端 SNI 和 Host 都是部署域名。
4. 端口是 Cloudflare 支持的 HTTPS 端口。
5. `sudo easytrojan doctor` 和 `systemctl is-active caddy` 无异常。

部分客户端在橙云下进行延迟测试时，可能无法正确协商 ALPN。可在客户端临时将
ALPN 改为仅 `http/1.1` 排查。

### 客户端连上后返回伪装站 HTML

确认 Caddyfile 全局配置包含：

```caddyfile
order trojan before handle
```

然后执行 `sudo easytrojan update`，或重新生成配置并 reload Caddy。

### Hub 订阅为空或更新不及时

```bash
sudo easytrojan hub status
sudo easytrojan hub list
sudo journalctl -u easytrojan-hub --no-pager -n 50
```

订阅响应已设置 no-cache。若客户端仍缓存旧结果，可删除后重新添加订阅，或临时在
URL 后追加 `?t=<timestamp>`；已有查询参数时使用 `&t=<timestamp>`。

### Caddy 因 TLS 配置启动失败

```bash
sudo easytrojan cert status
sudo caddy validate --config /etc/caddy/Caddyfile
sudo journalctl -u caddy --no-pager -n 50
```

Origin 模式需要有效且匹配的证书和私钥。可重新运行 `cert origin` 安装证书。

## 安全说明

- 推荐使用 `openssl rand -base64 24` 生成强随机密码
- 优先交互式输入密码，避免写入 shell history
- 不要将 Caddy Admin API 的 2019 端口暴露到公网
- `register_token` 可增删 Hub 节点，不得公开
- `sub_token` 可读取包含全部节点密码的订阅，应按密码保管
- `hub-client.json` 包含远端 Hub 注册凭证，文件权限应保持 600
- Origin 私钥不得提交到仓库或公开聊天

完整安全边界和文件权限说明见 [SECURITY.md](SECURITY.md)。

## 更新、重装与卸载

```bash
# 更新到最新 Release
sudo easytrojan update

# 更新到指定 Release
sudo easytrojan update --version 'v2.11.3+trojan.932ef9b'
```

重装使用与首次安装相同的命令。同域名重装会尽量复用证书；域名变化时会清理旧
ACME 材料并重新申请。未指定 TLS 模式时会保留当前设置。

卸载：

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/uninstall.sh -o uninstall.sh
chmod +x uninstall.sh
sudo bash uninstall.sh
```

非交互卸载使用 `sudo bash uninstall.sh -y`。卸载脚本只删除带 EasyTrojan
管理标记的 Caddy 资源；如果未检测到标记，会保留现有 Caddy 服务、二进制和
`/etc/caddy`。共享的 `caddy` 系统账户也会保留。

## 本地校验

校验过程不会安装节点：

```bash
bash scripts/ci_validate.sh
```

该脚本检查 Bash 语法、模块清单、LF 换行、命令加载、Python 编译和 Hub API
基本行为。

## 项目结构

| 路径 | 说明 |
| --- | --- |
| `easytrojan.sh` | 入口、模块加载和命令分发 |
| `lib/*.sh` | 安装、Caddy、TLS、Hub、系统与管理模块 |
| `hub_server.py` | 可选的节点聚合 Hub |
| `uninstall.sh` | 卸载脚本 |
| `scripts/ci_validate.sh` | 本地与 CI 校验入口 |
| `sha` | 上游 commit 标记，用于检测插件变化并固定构建 |
| `SECURITY.md` | 安全边界与报告策略 |
| `CHANGELOG.md` | 版本变更记录 |

## 致谢

- [caddyserver/caddy](https://github.com/caddyserver/caddy)
- [imgk/caddy-trojan](https://github.com/imgk/caddy-trojan)
- [xcaddy](https://github.com/caddyserver/xcaddy)
- [CorentinTh/it-tools](https://github.com/CorentinTh/it-tools)

## License

[MIT](LICENSE)
