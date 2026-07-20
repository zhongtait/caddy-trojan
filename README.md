# caddy-trojan

一键部署 Caddy + Trojan 代理服务。基于 [imgk/caddy-trojan](https://github.com/imgk/caddy-trojan) 模块构建。

支持系统：CentOS/RedHat 7+、Debian 9+、Ubuntu 16+  
支持架构：x86_64 (amd64)、aarch64 (arm64)

## 前置条件

- 已有可用域名，且 **A 记录已指向服务器公网 IP**
- 防火墙放行 TCP **80** 与 **443**
- root 权限

## 特性

- 一键安装，自动申请 SSL 证书（使用你提供的域名）
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
sudo easytrojan update
sudo easytrojan update --version 'v2.11.3+trojan.932ef9b'
sudo easytrojan renew
sudo easytrojan renew --force          # 证书损坏时强制重签

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

证书由 Caddy 自动续签；另有 systemd 每日 timer（`caddy-renew.timer`）做维护检查。`status` 会显示证书到期时间与 timer 状态，分享链接需加 `--show-link`。

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

重装会自动备份已有证书；若新证书申请失败会尝试恢复备份。同域名重装会尽量复用现有证书，换域名时才会清空并重新申请。

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