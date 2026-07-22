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
- [放行端口与伪装站](#放行端口与伪装站)
- [管理命令](#管理命令)
- [证书 / TLS 方案](#证书--tls-方案)
- [Cloudflare](#cloudflare)
- [节点聚合 / 订阅](#节点聚合--订阅)
- [客户端配置](#客户端配置)
- [安全建议](#安全建议)
- [重装与卸载](#重装与卸载)
- [项目结构](#项目结构)
- [致谢](#致谢)

## 前置条件

- 可用域名（安装时必填，不再使用 nip.io）
- 防火墙放行 TCP **80**、**443**
- root 权限

按接入方式选 TLS：

| 接入方式 | 推荐 TLS | 说明 |
|----------|----------|------|
| 域名直连服务器 / Cloudflare **灰云** | `auto` | Caddy ACME 自动证书 |
| Cloudflare **橙云** 长期代理 | `origin` | Cloudflare Origin 证书 |

## 特性

- 一键安装；TLS：`auto`（ACME）与 `origin`（文件 / Cloudflare Origin）
- Trojan：WebSocket + CONNECT
- 伪装站：默认 [IT-Tools](https://github.com/CorentinTh/it-tools)，失败时回退内置 ByteDeck
- 交互输入密码；Release 校验 `SHA256SUMS`（可用时）
- Admin API 仅 `127.0.0.1:2019`
- 可选 BBR、可逆 sysctl/limits；CI 每日检查上游并构建
- 脚本模块化：`easytrojan.sh` + `lib/*.sh`（安装时复制到 `/usr/local/share/easytrojan/lib`）
- 可选**节点聚合 Hub**：多机注册到一台服务端，生成 base64 订阅；支持 `?server=` / `?port=` 优选 IP

## 快速安装

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/easytrojan.sh -o easytrojan.sh \
  && chmod +x easytrojan.sh \
  && sudo bash easytrojan.sh install --domain yourdomain.com
```

会提示输入 Trojan 密码（也可用参数一次写完）：

```bash
# 常用
sudo bash easytrojan.sh install --domain yourdomain.com --password 'your-strong-password'

# 锁定 Release 版本
sudo bash easytrojan.sh install --domain yourdomain.com --password 'your-strong-password' \
  --version 'v2.11.3+trojan.932ef9b'

# 跳过「域名 A 记录 = 本机 IP」校验（橙云时几乎必用）
sudo bash easytrojan.sh install --domain yourdomain.com --password 'your-strong-password' \
  --skip-domain-check

# Cloudflare Origin（橙云推荐）
sudo bash easytrojan.sh install --domain yourdomain.com --tls-mode origin \
  --origin-cert /path/origin.pem --origin-key /path/origin.key \
  --skip-domain-check
```

兼容旧用法（密码 + 域名，域名必填）：

```bash
sudo bash easytrojan.sh 'your-strong-password' yourdomain.com
```

安装成功后会打印连接参数；分享链接默认隐藏，需 `status --show-link`。

> 仓库已将逻辑拆到 `lib/*.sh`。只下载 `easytrojan.sh` 时，入口会按需从本仓库 raw 拉取模块，并安装到 `/usr/local/share/easytrojan/lib`；完整 clone 时优先使用本地 `lib/`。

## 放行端口与伪装站

```bash
# RHEL 系列
firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp && firewall-cmd --reload

# Debian / Ubuntu
sudo ufw allow proto tcp from any to any port 80,443
```

浏览器访问 `https://yourdomain.com` 应打开 **IT-Tools**。指定版本（可选）：

```bash
sudo IT_TOOLS_VERSION=v2024.10.22-7ca5933 bash easytrojan.sh install --domain yourdomain.com
```

> **橙云 + origin：** 浏览器须走 Cloudflare（DNS 橙云）。若证书显示 *CloudFlare Origin Certificate*，说明直连了源站，浏览器会提示不安全——应橙云访问域名，不要用源站 IP。

## 管理命令

安装后提供 `/usr/local/bin/easytrojan`（兼容 `easytrojan.sh`）：

```bash
# 状态与链接
sudo easytrojan status
sudo easytrojan status --show-link
sudo easytrojan status --show-link --server 104.16.1.1   # CF 优选 IP
sudo easytrojan link --server 104.16.1.1

# 升级二进制
sudo easytrojan update
sudo easytrojan update --version 'v2.11.3+trojan.932ef9b'

# 证书维护（auto / ACME）
sudo easytrojan renew
sudo easytrojan renew --force          # 仅 ACME；origin 请用 cert origin 换文件

# TLS 方案切换
sudo easytrojan cert status
sudo easytrojan cert auto
sudo easytrojan cert origin --cert /path/origin.pem --key /path/origin.key

# 用户（passwd.txt → Caddyfile users → reload）
sudo easytrojan user add
sudo easytrojan user add --password 'another-strong-password'
sudo easytrojan user list
sudo easytrojan user del --password 'password-to-remove'

# 服务
systemctl {start|stop|restart|status} caddy
journalctl -u caddy --no-pager -n 50
cat /etc/caddy/Caddyfile

# 节点聚合 Hub（需 python3）
sudo easytrojan hub enable
sudo easytrojan hub token
sudo easytrojan hub list
sudo easytrojan hub join --url https://hub.example.com --token REG_TOKEN
```

用户写入 `/etc/caddy/trojan/passwd.txt`，生成 Caddyfile 中的 `users "..."`（与 [imgk 官方用法](https://github.com/imgk/caddy-trojan) 一致）。删除用户会 reload，并调用 Admin API 清理 `caddy` upstream 在 storage 中的键。

## 证书 / TLS 方案

状态文件：`/etc/caddy/trojan/tls-mode.txt`。重装未指定 `--tls-mode` 时保留已有方案；origin 可复用 `/etc/caddy/certs`。

| 方案 | 场景 | 证书 | 续签 |
|------|------|------|------|
| **auto**（默认） | 直连或 CF **灰云** | Caddy ACME（Let's Encrypt 等） | 自动；`caddy-renew.timer` 辅助 |
| **origin** | CF **橙云** 长期 | Origin 或任意 cert/key 文件 | 手动：`easytrojan cert origin` |

### auto

```bash
sudo bash easytrojan.sh install --domain yourdomain.com
```

要求：域名 A 指向本机；开放 **80**、**443**（HTTP-01）。

### origin（Cloudflare）

**1. 申请 Origin 证书**

1. [Cloudflare Dashboard](https://dash.cloudflare.com/) → 域名 → **SSL/TLS** → **Origin Server** → **Create Certificate**
2. 主机名含你的域名（可加 `*.yourdomain.com`）；私钥 RSA 2048 即可
3. 保存两段 PEM（**Private Key 通常只显示一次**）：

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
| Network → WebSockets | **On** |

**3. 安装或切换**

| 场景 | 命令 |
|------|------|
| 尚未安装 | `sudo bash easytrojan.sh install --domain yourdomain.com --tls-mode origin --origin-cert ./origin.pem --origin-key ./origin.key --skip-domain-check` |
| 已安装（改 origin） | `sudo easytrojan cert origin --cert ./origin.pem --key ./origin.key` |
| 改回 ACME | `sudo easytrojan cert auto`（宜灰云/直连，80/443 可签发） |
| 查看 | `sudo easytrojan cert status` |

证书安装到 `/etc/caddy/certs/origin.crt` 与 `origin.key`（600，属主 `caddy`）。

说明：

- 边缘证书（访客浏览器）：Cloudflare 自动提供  
- Origin 证书：仅 **Cloudflare ↔ 源站**，浏览器不直接信任  
- 到期后在 CF 新建证书，再执行 `cert origin`；**不要**对 origin 使用 `renew --force`

## Cloudflare

网络较差时可将域名接入 [Cloudflare](https://www.cloudflare.com/)（橙云），客户端用 **优选 IP** 作连接地址，**SNI / WS Host 仍填域名**。

### 开启 WebSockets

Trojan 默认 WebSocket；**橙云时必须开启**。

1. Dashboard → 域名 → **Network**
2. **WebSockets** → **On**（拨开即生效，偶发延迟 1～2 分钟）

灰云不经 CF 代理时通常不依赖此开关。界面路径若变更，在域名设置中搜索 **WebSockets**。

### 安装注意

橙云后解析到 CF IP，安装校验「域名 = 本机 IP」会失败，请加 `--skip-domain-check`。也可先灰云装好再改橙云（auto 场景更稳）。

### 优选 IP 与分享链接

| 字段 | 值 |
|------|-----|
| 地址 | CF 优选 IP（或域名） |
| 端口 | 443 |
| SNI / WS Host | 你的域名 |
| path | `/` |
| 传输 | WebSocket |
| 密码 | 安装时设置的密码 |

```bash
sudo easytrojan status --show-link --server 104.16.1.1
sudo easytrojan link --server 104.16.1.1
sudo easytrojan link --server 104.16.1.1 --password 'your-password'
```

链接中 `@` 后为连接地址；`sni` / `host` 仍为域名。优选测速在客户端完成。


## 节点聚合 / 订阅

把多台用本脚本安装的节点注册到**一台 Hub 主机**，由 Hub 统一输出 base64 订阅。Hub 进程只监听 `127.0.0.1:2099`，经 Caddy 反代 `/sub/*` 与 `/api/*`（在伪装站 SPA 之前）。

### 1. Hub 主机（聚合端）

依赖：已安装 easytrojan + **python3**。

```bash
sudo easytrojan hub enable
sudo easytrojan hub token      # register_token / sub_token / 订阅 URL
sudo easytrojan hub status
sudo easytrojan hub list
sudo easytrojan hub remove --id NODE_ID
sudo easytrojan hub disable    # 关闭反代与服务，保留 nodes.json
```

`enable` 会：

1. 安装 `/usr/local/bin/easytrojan-hub` 与 systemd 单元 `easytrojan-hub.service`
2. 生成 `/etc/caddy/trojan/hub/config.json`（`register_token`、`sub_token`）
3. 在 Caddyfile 注入 `handle /sub/*`、`handle /api/*` → `127.0.0.1:2099`
4. 尽量把本机用户写入节点列表

### 2. 节点主机（加入端）

在**已安装**的节点上执行（把 URL/token 换成 Hub 上 `hub token` 的输出）：

```bash
sudo easytrojan hub join \
  --url https://hub.example.com \
  --token 'REGISTER_TOKEN' \
  --name hk-01 \
  --server hk.example.com \
  --port 443
```

- `--server` / `--port`：写入节点记录的默认连接地址（可与域名不同）
- 本机 `passwd.txt` 中每个用户会注册一条节点（多名用户时名称加 `-2`、`-3`…）

### 3. 客户端订阅

```text
https://hub.example.com/sub/<sub_token>
https://hub.example.com/sub/<sub_token>?server=104.16.1.1&port=443
https://hub.example.com/sub/<sub_token>?server=104.16.1.1&port=2053
```

- 响应为 **base64** 多行 `trojan://` 链接
- `server` / `port` 只改**连接地址**；SNI / WS Host 仍为各节点自己的域名（适合 Cloudflare 优选 IP）
- 端口可用 CF HTTPS 端口（443、2053、2083、2087、2096、8443 等），不必须是 443

获取订阅 URL：

```bash
sudo easytrojan hub url
# 或
sudo easytrojan hub token
```

### 4. 数据位置

| 路径 | 说明 |
|------|------|
| `/etc/caddy/trojan/hub/config.json` | register/sub token |
| `/etc/caddy/trojan/hub/nodes.json` | 已注册节点 |
| `/etc/caddy/trojan/hub/enabled` | Hub 开关标记 |
| `/etc/caddy/trojan/hub-client.json` | 本机 join 远端 Hub 的 membership（url/token） |
| `/usr/local/share/easytrojan/hub_server.py` | Hub 实现 |
| `easytrojan-hub.service` | systemd 单元 |

### 5. 同步与限制

| 场景 | 行为 |
|------|------|
| 本机 hub enable 后 user add/del | 自动同步本机 nodes.json |
| 节点 hub join 后 user add/del | 读取 /etc/caddy/trojan/hub-client.json 自动 re-register / unregister |
| 改过密码或换名后远端仍旧 | 再执行一次 hub join（或 hub leave 后重新 join） |
| 取消远端聚合 | easytrojan hub leave（删 membership 文件，不改远端已有条目） |
| Hub 依赖 | python3 >= 3.8；服务仅监听 127.0.0.1:2099 |

> **模块安装：** 仅下载入口脚本时会从本仓库 raw 拉 lib/*.sh。main 上尚未推送 lib/ 时，update/install 会明确报模块下载失败，而不是静默半更新。

> **安全：** 不要公开 register_token（可注册任意节点）。订阅 URL 含 sub_token，泄露等于泄露全部节点密码；请当密码保管。Hub API 经域名暴露时同样依赖 token。hub-client.json 含 register_token，权限应为 600。

## 客户端配置

| 参数 | 值 |
|------|-----|
| 协议 | trojan |
| 地址 | 域名，或 CF 优选 IP |
| 端口 | 443 |
| 密码 | 安装时设置 |
| TLS | 开启 |
| ALPN | h2,http/1.1 |
| 传输 | websocket |
| SNI / Host | 域名（用优选 IP 时也填域名） |

## 安全建议

- 强随机密码：`openssl rand -base64 24`；尽量避免把密码写进 shell history
- 勿将 Admin API `2019` 暴露公网
- Release 建议校验 `SHA256SUMS`
- Origin 私钥勿提交仓库或发到公开聊天
- 详见 [SECURITY.md](SECURITY.md)

## 重装与卸载

**重装：**

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/easytrojan.sh -o easytrojan.sh \
  && chmod +x easytrojan.sh \
  && sudo bash easytrojan.sh install --domain yourdomain.com
```

- 会备份已有 ACME 证书；新签失败时尝试恢复  
- 同域名尽量复用证书；换域名会清空并重签  
- 未指定 `--tls-mode` 时保留原 TLS 方案；origin 可复用 `/etc/caddy/certs`

**卸载：**

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/uninstall.sh -o uninstall.sh \
  && chmod +x uninstall.sh \
  && sudo bash uninstall.sh
```

非交互：`sudo bash uninstall.sh -y`（删除 `/etc/caddy` 等安装产物）。

## 项目结构

| 文件 | 说明 |
|------|------|
| `easytrojan.sh` | 入口（常量、模块加载、命令分发） |
| `lib/*.sh` | 功能模块（common/tls/caddy/camouflage/system/hub/manage/install） |
| `hub_server.py` | 节点聚合 Hub（可选，需 python3） |
| `uninstall.sh` | 卸载 |
| `sha` | 上游 commit；变更触发构建 |
| `SECURITY.md` | 安全策略 |
| `CHANGELOG.md` | 变更记录 |
| `.github/workflows/release.yml` | 构建发布 + SHA256SUMS |
| `.github/workflows/test.yml` | 检查上游更新 |

## 致谢

- [caddyserver/caddy](https://github.com/caddyserver/caddy)
- [imgk/caddy-trojan](https://github.com/imgk/caddy-trojan)
- [xcaddy](https://github.com/caddyserver/xcaddy)
- [CorentinTh/it-tools](https://github.com/CorentinTh/it-tools)（默认伪装站）
