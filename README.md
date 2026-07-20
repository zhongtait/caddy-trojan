# caddy-trojan

一键部署 Caddy + Trojan 代理服务。基于 [imgk/caddy-trojan](https://github.com/imgk/caddy-trojan) 模块构建。

支持系统：CentOS/RedHat 7+、Debian 9+、Ubuntu 16+  
支持架构：x86_64 (amd64)、aarch64 (arm64)

## 前置条件

- 已有可用域名，且 **A 记录已指向服务器公网 IP**
- 防火墙放行 TCP **80** 与 **443**
- root 权限

## 特性

- 一键安装；TLS 支持 **auto（Caddy ACME）** 与 **origin（Cloudflare Origin / 文件证书）**
- 支持 WebSocket 传输 + CONNECT 方法
- 伪装站点（file_server）
- 交互式输入密码，降低 shell history 泄露风险
- 下载 Release 时校验 `SHA256SUMS`（可用时）
- Admin API 固定监听 `127.0.0.1:2019`
- 自动启用 BBR（内核支持时）
- 可逆的 sysctl / limits 优化
- 每日检查上游更新并构建最新二进制

## 快速安装

推荐交互式安装（会提示输入域名与密码）：

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/easytrojan.sh -o easytrojan.sh \
  && chmod +x easytrojan.sh \
  && sudo bash easytrojan.sh install --domain yourdomain.com
```

完整参数示例：

```bash
# 密码 + 域名
sudo bash easytrojan.sh install --domain yourdomain.com --password 'your-strong-password'

# 锁定 Release 版本
sudo bash easytrojan.sh install --domain yourdomain.com --password 'your-strong-password' \
  --version 'v2.11.3+trojan.932ef9b'

# 跳过域名 A 记录校验（仅当你确认 DNS 正确时）
sudo bash easytrojan.sh install --domain yourdomain.com --password 'your-strong-password' \
  --skip-domain-check

# Cloudflare Origin 证书（橙云代理长期使用推荐）
sudo bash easytrojan.sh install --domain yourdomain.com --tls-mode origin \
  --origin-cert /path/origin.pem --origin-key /path/origin.key --skip-domain-check
```

兼容旧用法（域名必填）：

```bash
sudo bash easytrojan.sh 'your-strong-password' yourdomain.com
```

安装成功后会显示连接参数与分享链接。

## 放行端口

```bash
# RHEL 系列
firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp && firewall-cmd --reload

# Debian / Ubuntu
sudo ufw allow proto tcp from any to any port 80,443
```

验证：浏览器访问 `https://yourdomain.com`，应看到 **IT-Tools** 工具站（[CorentinTh/it-tools](https://github.com/CorentinTh/it-tools)）。若 GitHub 不可达，会回退到内置 ByteDeck 工具页。

可选：指定 IT-Tools 版本（默认 latest）：

```bash
sudo IT_TOOLS_VERSION=v2024.10.22-7ca5933 bash easytrojan.sh install --domain yourdomain.com
```

## 管理命令

安装后会写入 `/usr/local/bin/easytrojan`（兼容 `easytrojan.sh`）：

```bash
sudo easytrojan status                 # 默认不打印分享链接
sudo easytrojan status --show-link     # 需要时再显示
sudo easytrojan status --show-link --server 104.16.1.1  # CF 优选 IP
sudo easytrojan link --server 104.16.1.1
sudo easytrojan update
sudo easytrojan update --version 'v2.11.3+trojan.932ef9b'
sudo easytrojan renew
sudo easytrojan renew --force          # ACME 强制重签（origin 模式不适用）

# TLS 方案
sudo easytrojan cert status            # 查看 auto / origin
sudo easytrojan cert auto              # 切回 Caddy ACME
sudo easytrojan cert origin --cert /path/origin.pem --key /path/origin.key

# 用户管理
sudo easytrojan user add               # 交互输入密码
sudo easytrojan user add --password 'another-strong-password'
sudo easytrojan user list              # 密码脱敏显示
sudo easytrojan user del --password 'password-to-remove'

用户写入 `passwd.txt`，并生成 Caddyfile 全局块中的 `users "..."`（与 [imgk/caddy-trojan](https://github.com/imgk/caddy-trojan) 官方示例一致）。
删除用户会 `reload` 配置，并调用 Admin API 清理 `caddy` upstream 的 storage 键。

systemctl {start|stop|restart|status} caddy
journalctl -u caddy --no-pager -n 50
cat /etc/caddy/Caddyfile
```

默认 **auto** 模式下证书由 Caddy ACME 自动续签；另有 systemd 每日 timer（`caddy-renew.timer`）做维护检查。**origin** 模式使用你上传的证书文件，需自行在到期前更换（timer 只会告警）。`status` 会显示 TLS 模式与到期时间；分享链接需加 `--show-link`。



## 证书 / TLS 方案

安装脚本支持两种 TLS 方案（写入 `/etc/caddy/trojan/tls-mode.txt`，生成 Caddyfile 时生效）：

| 方案 | 适用场景 | 证书来源 | 续签 |
|------|----------|----------|------|
| **auto**（默认） | 域名直连服务器，或 Cloudflare **仅 DNS（灰云）** | Caddy 自动 ACME（Let's Encrypt 等） | 自动；`caddy-renew.timer` 辅助 |
| **origin** | Cloudflare **橙云代理** 长期使用 | Cloudflare Origin Certificate（或任意 cert/key 文件） | 手动；到期前 `easytrojan cert origin` 替换 |

### 方案 A：auto（推荐入门）

```bash
sudo bash easytrojan.sh install --domain yourdomain.com
```

要求：域名 A 记录指向本机；开放 TCP **80** 与 **443**（ACME HTTP-01 需要 80）。

### 方案 B：origin（Cloudflare 代理）

长期 **橙云** 时推荐：访客用 Cloudflare **边缘证书**，源站用 **Origin Certificate**（只用于 CF 到你的 VPS）。

| 证书 | 谁签发 | 用途 | 是否要你申请 |
|------|--------|------|--------------|
| 边缘证书（Universal SSL 等） | Cloudflare | 浏览器 ↔ Cloudflare | 一般不用，橙云后自动有 |
| Origin Certificate | Cloudflare | Cloudflare ↔ 源站 Caddy | **需要**，见下方步骤 |

#### 如何申请 Cloudflare Origin 证书

1. 域名已接入 [Cloudflare](https://dash.cloudflare.com/)，DNS A/AAAA 指向源站公网 IP。
2. 打开域名 → **SSL/TLS** → **Origin Server**（源服务器）→ **Create Certificate**。
3. 建议选项：
   - 私钥类型：RSA (2048)
   - 主机名：至少包含你的域名（如 `yourdomain.com`；需要子域可加 `*.yourdomain.com`）
   - 有效期：按需选择（最长可数年，到期需自行更换）
4. 创建后分别复制并保存两段 PEM（**Private Key 通常只显示一次**）：

```bash
# 在服务器或本机保存（路径自定）
nano origin.pem   # 粘贴 Origin Certificate（BEGIN CERTIFICATE）
nano origin.key   # 粘贴 Private Key（BEGIN PRIVATE KEY / RSA PRIVATE KEY）
chmod 600 origin.key
```

5. Cloudflare 面板其它设置：
   - **SSL/TLS** 加密模式：**Full (strict)**（不要用 Flexible）
   - 开启 **WebSockets**（详见下方「如何开启 WebSockets」）
   - 源站代理状态：**已代理（橙云）**

#### 安装到本项目

橙云后域名解析到的是 CF IP，安装时通常需要 `--skip-domain-check`：

```bash
# 安装时指定
sudo bash easytrojan.sh install --domain yourdomain.com --tls-mode origin \
  --origin-cert ./origin.pem --origin-key ./origin.key --skip-domain-check

# 已安装后切换 / 更换证书
sudo easytrojan cert origin --cert ./origin.pem --key ./origin.key
sudo easytrojan cert auto    # 改回 ACME
sudo easytrojan cert status
```

证书会复制到 `/etc/caddy/certs/origin.crt` 与 `origin.key`（权限 600，属主 `caddy`）。  
Origin 证书**不会**被普通浏览器直接信任；用户经 Cloudflare 访问时看到的是边缘证书，因此正常。

到期前在 Cloudflare 再创建一张 Origin 证书，然后重新执行 `easytrojan cert origin --cert ... --key ...`（不要用 `renew --force`，那是 ACME 用的）。

### 场景一：还没装（直接用 Origin）

1. 域名接入 Cloudflare：A/AAAA 指向 VPS；代理 **橙云**；SSL/TLS **Full (strict)**；开启 **WebSockets**。
2. 按上文申请 Origin 证书，保存为 `origin.pem` / `origin.key`（私钥只显示一次），并传到服务器。
3. 安装（橙云解析到 CF IP，通常需要跳过本机 IP 校验）：

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/easytrojan.sh -o easytrojan.sh
chmod +x easytrojan.sh

sudo bash easytrojan.sh install --domain yourdomain.com --tls-mode origin \
  --origin-cert /root/origin.pem --origin-key /root/origin.key \
  --skip-domain-check
```

4. 检查：

```bash
sudo easytrojan cert status
sudo easytrojan status
# 浏览器访问 https://yourdomain.com 应能打开伪装站
```

5. 客户端：地址可用域名或 CF 优选 IP；**SNI / WS Host 仍填域名**。

```bash
sudo easytrojan status --show-link --server 优选IP
# 或
sudo easytrojan link --server 优选IP
```

### 场景二：已装好（默认 ACME），要改成 Origin

前提：已通过 `easytrojan install` 安装且服务可运行。

1. Cloudflare 侧完成橙云、**Full (strict)**、**WebSockets**，并申请 Origin 证书传到服务器（同上）。
2. 切换 TLS 方案（密码与用户不改，仍用现有 `passwd.txt`）：

```bash
sudo easytrojan cert origin --cert /root/origin.pem --key /root/origin.key
sudo easytrojan cert status
sudo easytrojan status   # TLS 应为 origin
```

3. 以后只更换到期 Origin 证书时，在 Cloudflare 新建后再次执行 `cert origin`（不要用 `renew --force`，那是 ACME 用的）。
4. 若要改回 ACME（更适合直连或灰云，且 80/443 可供签发）：

```bash
sudo easytrojan cert auto
sudo easytrojan status
```

| | 还没装 | 已装要改 origin |
|--|--------|-----------------|
| 关键命令 | `install --tls-mode origin --origin-cert ... --origin-key ... --skip-domain-check` | `cert origin --cert ... --key ...` |
| 密码 / 用户 | 安装时设置 | 不用动 |
| 域名校验 | 橙云建议 `--skip-domain-check` | 不涉及 |

## Cloudflare 与优选 IP

网络较差时可把域名接入 [Cloudflare](https://www.cloudflare.com/)（DNS 橙云代理），在客户端使用 **CF 优选 IP** 作为连接地址，同时 **SNI / WS Host 仍填你的域名**。

**证书建议：** 长期橙云用 **origin** 方案；灰云或直连用 **auto**。若仍用 auto 且橙云，需保证 ACME 挑战可达（通常更麻烦）。

### 如何开启 WebSockets

Trojan 默认走 **WebSocket**。域名走 Cloudflare **橙云代理** 时必须开启，否则握手容易失败。

1. 打开 [Cloudflare Dashboard](https://dash.cloudflare.com/) → 选中域名。
2. 左侧进入 **Network**（网络）。
3. 找到 **WebSockets**，开关设为 **On**（开启）。
4. 一般拨开即生效，无需额外保存（偶发延迟约 1～2 分钟）。

同时建议确认：

| 位置 | 设置 |
|------|------|
| **DNS** | 记录为 **已代理（橙云）** |
| **SSL/TLS → Overview** | 加密模式 **Full (strict)** |
| **SSL/TLS → Origin Server** | 使用 origin 方案时已创建 Origin 证书 |

说明：

- 该开关为域名级（整区生效），不是按子域单独配置。
- **灰云（仅 DNS）** 时流量不经 CF 代理，通常不依赖此开关；**橙云代理时必须开启**。
- 客户端仍需：传输 WebSocket，SNI / Host 填你的域名。
- 若界面与上述路径不一致，可在域名设置中搜索 **WebSockets**，或在 **Network** 相关页面查找同名开关。

### Cloudflare 侧

1. 域名接入 CF，A 记录指向源站公网 IP，代理状态为 **已代理（橙云）**。
2. SSL/TLS 建议 **Full (strict)**；开启 **WebSockets**（见上方「如何开启 WebSockets」）。
3. 安装脚本默认校验「域名解析 = 本机 IP」。橙云后解析到的是 CF IP，新装可用：

```bash
sudo bash easytrojan.sh install --domain your.domain.com --skip-domain-check
```

更稳妥：先灰云（仅 DNS）完成安装与证书，再改为橙云。

### 客户端

| 字段 | 值 |
|------|-----|
| 地址 | Cloudflare 优选 IP |
| 端口 | 443 |
| SNI | 你的域名 |
| WS Host | 你的域名 |
| path | `/` |
| 传输 | WebSocket |
| 密码 | 安装时设置的密码 |

### 生成分享链接

在服务器上（把 `104.16.1.1` 换成你测出的优选 IP）：

```bash
sudo easytrojan status --show-link --server 104.16.1.1
sudo easytrojan link --server 104.16.1.1
sudo easytrojan link --server 104.16.1.1 --password 'your-password'
```

链接中 `@` 后面是连接地址（优选 IP），查询参数里的 `sni` / `host` 仍是域名。优选测速在客户端完成，服务器不负责扫描 CF IP。

## 安全建议

- 请使用强随机密码：`openssl rand -base64 24`
- 不建议把密码直接写在 shell 命令中
- 不要将 Caddy Admin API 端口 `2019` 暴露到公网
- Release 包建议通过 `SHA256SUMS` 校验完整性
- 更多说明见 [SECURITY.md](SECURITY.md)

## 重新安装

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/easytrojan.sh -o easytrojan.sh \
  && chmod +x easytrojan.sh \
  && sudo bash easytrojan.sh install --domain yourdomain.com
```

重装会自动备份已有证书；若新证书申请失败会尝试恢复备份。同域名重装会尽量复用现有证书，换域名时才会清空并重新申请。未指定 `--tls-mode` 时会保留已有 TLS 方案；origin 模式可复用 `/etc/caddy/certs` 中已安装的证书。

## 完全卸载

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/uninstall.sh -o uninstall.sh \
  && chmod +x uninstall.sh \
  && sudo bash uninstall.sh
```

非交互：`sudo bash uninstall.sh -y`

## 客户端配置

| 参数 | 值 |
|------|------|
| 协议 | trojan |
| 地址 | 你的域名 |
| 端口 | 443 |
| 密码 | 安装时设置的密码 |
| TLS | 开启 |
| ALPN | h2,http/1.1 |
| 传输 | websocket |

## 项目结构

| 文件 | 说明 |
|------|------|
| `easytrojan.sh` | 安装与运维脚本 |
| `uninstall.sh` | 卸载脚本 |
| `sha` | 上游 commit hash，变更触发自动构建 |
| `SECURITY.md` | 安全策略 |
| `CHANGELOG.md` | 变更记录 |
| `.github/workflows/release.yml` | 构建并发布二进制 + SHA256SUMS |
| `.github/workflows/test.yml` | 每日检查上游更新 |

## 致谢

- [caddyserver/caddy](https://github.com/caddyserver/caddy)
- [imgk/caddy-trojan](https://github.com/imgk/caddy-trojan)
- [xcaddy](https://github.com/caddyserver/xcaddy)