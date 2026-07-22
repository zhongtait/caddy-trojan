# caddy-trojan

一键部署 **Caddy + Trojan**。基于 [imgk/caddy-trojan](https://github.com/imgk/caddy-trojan) 构建。

| | |
|--|--|
| 系统 | CentOS/RHEL 7+、Debian 9+、Ubuntu 16+ |
| 架构 | x86_64 (amd64)、aarch64 (arm64) |

## 目录

- [前置条件](#前置条件)
- [特性](#特性)
- [快速安装](#快速安装)
- [管理命令](#管理命令)
- [证书 / TLS](#证书--tls)
- [Cloudflare](#cloudflare)
- [节点聚合 Hub](#节点聚合-hub)
- [客户端](#客户端)
- [常见问题](#常见问题)
- [安全](#安全)
- [重装与卸载](#重装与卸载)
- [项目结构](#项目结构)
- [致谢](#致谢)

## 前置条件

- 可用域名（安装必填；不使用 nip.io）
- 放行 TCP **80**、**443**
- root 权限

| 接入方式 | 推荐 TLS | 说明 |
|----------|----------|------|
| 域名直连 / Cloudflare **灰云** | `auto` | Caddy ACME 自动证书 |
| Cloudflare **橙云** 长期代理 | `origin` | Cloudflare Origin 证书 |

```bash
# 放行端口（任选）
firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp && firewall-cmd --reload   # RHEL
sudo ufw allow proto tcp from any to any port 80,443                                     # Debian/Ubuntu
```

## 特性

- Trojan：WebSocket + CONNECT；TLS：`auto` / `origin`
- 伪装站：默认 [IT-Tools](https://github.com/CorentinTh/it-tools)，失败回退内置 ByteDeck
- 用户：`passwd.txt` → Caddyfile 静态 `users` → reload（与上游一致）
- Admin API 仅 `127.0.0.1:2019`；Release 校验 `SHA256SUMS`（可用时）
- 脚本模块化：`easytrojan.sh` + `lib/*.sh`（安装到 `/usr/local/share/easytrojan/lib`）
- 可选 Hub：多机聚合 base64 订阅；`?server=` / `?port=` 支持优选 IP

## 快速安装

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/easytrojan.sh -o easytrojan.sh \
  && chmod +x easytrojan.sh \
  && sudo bash easytrojan.sh install --domain yourdomain.com
```

会提示输入 Trojan 密码。一次写完示例：

```bash
# 直连 / 灰云（ACME）
sudo bash easytrojan.sh install --domain yourdomain.com --password 'your-strong-password'

# 橙云 + Origin（跳过「域名 A = 本机 IP」校验）
sudo bash easytrojan.sh install --domain yourdomain.com --password 'your-strong-password' \
  --tls-mode origin --origin-cert /path/origin.pem --origin-key /path/origin.key \
  --skip-domain-check

# 锁定 Release 版本
sudo bash easytrojan.sh install --domain yourdomain.com --password 'your-strong-password' \
  --version 'v2.11.3+trojan.932ef9b'

# 指定 IT-Tools 版本（可选）
sudo IT_TOOLS_VERSION=v2024.10.22-7ca5933 bash easytrojan.sh install --domain yourdomain.com
```

兼容旧用法：`sudo bash easytrojan.sh 'password' yourdomain.com`

安装成功后会打印连接参数；分享链接默认隐藏，用 `easytrojan status --show-link`。

> 只下载入口脚本时，会从本仓库 raw 拉取 `lib/*.sh` 并安装到 `/usr/local/share/easytrojan/lib`；完整 clone 时优先用本地 `lib/`。

浏览器访问 `https://yourdomain.com` 应打开 **IT-Tools**。

## 管理命令

安装后：`/usr/local/bin/easytrojan`（兼容 `easytrojan.sh`）。

| 命令 | 作用 |
|------|------|
| `status` / `status --show-link` | 状态；加 `--show-link` 打印链接 |
| `link --server IP [--port PORT]` | 生成分享链接（优选 IP / 端口） |
| `update [--version VER]` | 更新脚本模块 + Caddy 二进制 |
| `renew` / `renew --force` | ACME 续签辅助（**勿**对 origin 用 `--force`） |
| `cert {auto\|origin\|status}` | 查看 / 切换 TLS 方案 |
| `user {add\|list\|del}` | 管理 Trojan 用户 |
| `hub ...` | 节点聚合（见下文） |

```bash
sudo easytrojan status
sudo easytrojan status --show-link --server 104.16.1.1 --port 443
sudo easytrojan link --server 104.16.1.1 --port 2053
sudo easytrojan update
sudo easytrojan cert status
sudo easytrojan user add --password 'another-strong-password'
sudo easytrojan user del --password 'password-to-remove'

systemctl status caddy
journalctl -u caddy --no-pager -n 50
```

用户文件：`/etc/caddy/trojan/passwd.txt` → Caddyfile `users "..."`。删除时会 reload，并调用 Admin API 清理 `caddy` upstream 在 storage 中的键。

## 证书 / TLS

状态：`/etc/caddy/trojan/tls-mode.txt`。重装未写 `--tls-mode` 时保留原方案；origin 可复用 `/etc/caddy/certs`。

| 方案 | 场景 | 证书 | 续签 |
|------|------|------|------|
| **auto**（默认） | 直连 / 灰云 | Caddy ACME | 自动 + `caddy-renew.timer` |
| **origin** | 橙云长期 | Origin 或任意 cert/key | 手动：`easytrojan cert origin` |

### auto

```bash
sudo bash easytrojan.sh install --domain yourdomain.com
```

域名 A 指本机；开放 80/443（HTTP-01）。

### origin（Cloudflare）

**1. 申请 Origin 证书**

1. [Cloudflare Dashboard](https://dash.cloudflare.com/) → 域名 → **SSL/TLS** → **Origin Server** → **Create Certificate**
2. 主机名含你的域名（可加 `*.yourdomain.com`）
3. 保存 PEM（**Private Key 通常只显示一次**）：

```bash
nano origin.pem   # Certificate
nano origin.key   # Private Key
chmod 600 origin.key
```

**2. Cloudflare 面板**

| 项 | 值 |
|----|-----|
| DNS 代理 | **橙云（已代理）** |
| SSL/TLS | **Full (strict)** |
| Network → WebSockets | **On**（Trojan 默认 WS，橙云必开） |

**3. 安装或切换**

| 场景 | 命令 |
|------|------|
| 新装 | `sudo bash easytrojan.sh install --domain yourdomain.com --tls-mode origin --origin-cert ./origin.pem --origin-key ./origin.key --skip-domain-check` |
| 已装改 origin | `sudo easytrojan cert origin --cert ./origin.pem --key ./origin.key` |
| 改回 ACME | `sudo easytrojan cert auto`（宜灰云/直连） |
| 查看 | `sudo easytrojan cert status` |

文件落在 `/etc/caddy/certs/origin.crt` 与 `origin.key`（600，属主 `caddy`）。

- 访客浏览器证书：Cloudflare 边缘自动提供
- Origin 证书：仅 **Cloudflare ↔ 源站**；浏览器不直接信任
- 到期后在 CF 新建，再执行 `cert origin`；**不要**对 origin 使用 `renew --force`

## Cloudflare

橙云适合线路差时走 CF 边缘；客户端可用 **优选 IP** 作连接地址，**SNI / WS Host 仍填域名**。

### 开启 WebSockets

1. Dashboard → 域名 → **Network**
2. **WebSockets** → **On**（偶发延迟 1～2 分钟）

灰云/直连通常不依赖此开关。路径若变更，在域名设置中搜索 **WebSockets**。

### 安装注意

橙云后解析到 CF IP，「域名 = 本机 IP」校验会失败，请加 `--skip-domain-check`。也可先灰云装好再改橙云。

### 优选 IP 链接

| 字段 | 值 |
|------|-----|
| 地址 | CF 优选 IP（或域名） |
| 端口 | CF HTTPS 端口：443、2053、2083、2087、2096、8443 等（**不必是 443**） |
| SNI / WS Host | 你的域名 |
| path | `/` |
| 传输 | WebSocket |

```bash
sudo easytrojan status --show-link --server 104.16.1.1 --port 443
sudo easytrojan link --server 104.16.1.1 --port 2053
```

链接中 `@` 后为连接地址；`sni` / `host` 仍为域名。优选测速在客户端完成。

## 节点聚合 Hub

多台节点注册到**一台 Hub**，统一输出 base64 订阅。Hub 只监听 `127.0.0.1:2099`，经 Caddy 反代 `/sub/*`、`/api/*`（在伪装站 SPA 之前）。依赖 **python3 ≥ 3.8**。

### Hub 主机

```bash
sudo easytrojan hub enable
sudo easytrojan hub token      # register_token / sub_token / 订阅 URL
sudo easytrojan hub status
sudo easytrojan hub list
sudo easytrojan hub remove --id NODE_ID
sudo easytrojan hub disable    # 关服务与反代，保留 nodes.json
```

`enable` 会安装 `easytrojan-hub` 与 systemd 单元、生成 token、注入 Caddy 反代，并尽量注册本机用户。

### 节点加入

```bash
sudo easytrojan hub join \
  --url https://hub.example.com \
  --token 'REGISTER_TOKEN' \
  --name hk-01 \
  --server hk.example.com \
  --port 443

# 取消本机远端 membership（不清理远端已有条目）
sudo easytrojan hub leave
```

- `--server` / `--port`：写入节点默认连接地址
- 本机 `passwd.txt` 每个用户一条节点（多名用户时名称加 `-2`、`-3`…）
- join 会保存 `/etc/caddy/trojan/hub-client.json`（600），之后 `user add/del` 会同步远端

### 客户端订阅

```text
https://hub.example.com/sub/<sub_token>
https://hub.example.com/sub/<sub_token>?server=104.16.1.1&port=443
https://hub.example.com/sub/<sub_token>?server=104.16.1.1&port=2053
```

- 响应：base64 多行 `trojan://`
- `server` / `port` **只改连接地址**；各节点 SNI / Host 仍是自己的域名
- 取 URL：`easytrojan hub url` 或 `hub token`

### 数据与同步

| 路径 | 说明 |
|------|------|
| `/etc/caddy/trojan/hub/config.json` | register / sub token |
| `/etc/caddy/trojan/hub/nodes.json` | 已注册节点 |
| `/etc/caddy/trojan/hub/enabled` | Hub 开关 |
| `/etc/caddy/trojan/hub-client.json` | 本机 join 的远端 membership |
| `/usr/local/share/easytrojan/hub_server.py` | Hub 实现 |
| `easytrojan-hub.service` | systemd 单元 |

| 场景 | 行为 |
|------|------|
| 本机 `hub enable` 后 `user add/del` | 同步本机 `nodes.json` |
| 节点 `hub join` 后 `user add/del` | 按 membership 自动 re-register / unregister |
| 改密码或换名后远端仍旧 | 再 `hub join`（或 `hub leave` 后重新 join） |
| 取消远端聚合 | `hub leave`（只删本地 membership） |

> **安全：** 勿公开 `register_token`。订阅 URL 含 `sub_token`，泄露等同泄露全部节点密码。`hub-client.json` 含注册凭证，保持 600。

## 客户端

| 参数 | 值 |
|------|-----|
| 协议 | trojan |
| 地址 | 域名，或 CF 优选 IP |
| 端口 | 443 或 CF HTTPS 端口 |
| 密码 | 安装时设置 |
| TLS | 开启 |
| ALPN | h2, http/1.1 |
| 传输 | websocket |
| SNI / Host | **域名**（用优选 IP 时也填域名） |
| path | `/` |

## 常见问题

**浏览器提示证书不安全 / 显示 CloudFlare Origin Certificate**  
直连了源站 IP。橙云 + origin 时应用域名经 Cloudflare 访问，不要用源站 IP。

**`install` 报域名校验失败**  
橙云解析到 CF IP 属正常，加 `--skip-domain-check`。

**优选 IP 后客户端不通**  
检查：WebSockets On、SSL **Full (strict)**、客户端 SNI/Host 为域名、端口为 CF 支持的 HTTPS 端口（可用 `link --port`）。

**延迟测试偶发 fail**  
多与客户端测速 / CF 边缘有关；连上再试几次。优先确认服务 `systemctl is-active caddy` 与 `easytrojan status`。

**`caddy.service` 启动失败，tls 参数错误**  
执行 `sudo caddy validate --config /etc/caddy/Caddyfile`，查看 `journalctl -u caddy -n 30`。origin 的 `tls cert key` 须单独成行；可 `easytrojan cert status` 后重新 `cert origin`。

**只下载了入口脚本、update 拉模块失败**  
确认仓库 `main` 已有 `lib/*.sh`，且机器能访问 `raw.githubusercontent.com`。

## 安全

- 强随机密码：`openssl rand -base64 24`；少把密码写进 shell history
- 勿将 Admin API `2019` 暴露公网
- Release 建议校验 `SHA256SUMS`；Origin 私钥勿进仓库或公开聊天
- 详见 [SECURITY.md](SECURITY.md)

## 重装与卸载

```bash
# 重装
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/easytrojan.sh -o easytrojan.sh \
  && chmod +x easytrojan.sh \
  && sudo bash easytrojan.sh install --domain yourdomain.com
```

- 会备份已有 ACME 证书；新签失败时尝试恢复
- 同域名尽量复用证书；换域名会清空并重签
- 未指定 `--tls-mode` 时保留原方案；origin 可复用 `/etc/caddy/certs`

```bash
# 卸载
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/uninstall.sh -o uninstall.sh \
  && chmod +x uninstall.sh \
  && sudo bash uninstall.sh
```

非交互：`sudo bash uninstall.sh -y`（删除 `/etc/caddy` 等安装产物）。

本地校验（不装节点）：

```bash
bash scripts/ci_validate.sh
```

## 项目结构

| 文件 | 说明 |
|------|------|
| `easytrojan.sh` | 入口（常量、模块加载、命令分发） |
| `lib/*.sh` | 模块：common / tls / caddy / camouflage / system / hub / manage / install |
| `hub_server.py` | 节点聚合 Hub（可选） |
| `uninstall.sh` | 卸载 |
| `sha` | 上游 commit；变更触发构建 |
| `SECURITY.md` / `CHANGELOG.md` | 安全策略 / 变更记录 |
| `.github/workflows/release.yml` | 构建发布 + SHA256SUMS |
| `.github/workflows/ci.yml` | 脚本/Hub 校验（不装节点） |
| `.github/workflows/test.yml` | 检查上游更新 |
| `scripts/ci_validate.sh` | 本地/CI 校验入口 |

## 致谢

- [caddyserver/caddy](https://github.com/caddyserver/caddy)
- [imgk/caddy-trojan](https://github.com/imgk/caddy-trojan)
- [xcaddy](https://github.com/caddyserver/xcaddy)
- [CorentinTh/it-tools](https://github.com/CorentinTh/it-tools)（默认伪装站）
