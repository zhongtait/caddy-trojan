# Security Policy

## 安全范围

本项目包含需要 root 权限执行的一键安装脚本。运行前请先阅读脚本内容，并确认你了解它会修改的系统组件。

## 安装脚本会修改的内容

安装脚本可能创建或修改以下文件和目录：

- `/usr/local/bin/caddy`
- `/usr/local/bin/easytrojan`
- `/usr/local/bin/easytrojan.sh`
- `/etc/caddy`
- `/etc/caddy/Caddyfile`
- `/etc/caddy/trojan/passwd.txt`
- `/etc/caddy/trojan/domain.txt`
- `/etc/systemd/system/caddy.service`
- `/etc/systemd/system/caddy-renew.service`
- `/etc/systemd/system/caddy-renew.timer`
- `/etc/sysctl.d/99-caddy-trojan.conf`
- `/etc/security/limits.d/caddy-trojan.conf`

## 密码安全

建议使用强随机密码：

```bash
openssl rand -base64 24
```

不建议通过命令行参数传入密码，因为密码可能会被 shell history 或进程列表记录。

`easytrojan status` 默认不输出分享链接；需要时使用 `easytrojan status --show-link`。用户列表只显示脱敏密码。

推荐使用交互式安装方式：

```bash
sudo bash easytrojan.sh install
```

Trojan 密码会保存在：

```text
/etc/caddy/trojan/passwd.txt
```

安装脚本会将该文件权限设置为 `600`，目录权限为 `700`。

同一批密码也会以 `users "..."` 形式写入 `/etc/caddy/Caddyfile`（imgk/caddy-trojan 官方配置方式）。该文件权限同样为 `600`，属主 `caddy:caddy`。请勿把 Caddyfile 提交到公开仓库或分享给他人。

使用 `caddy` upstream 时，用户密钥还会落在 Caddy 本地 storage（前缀 `trojan/`）。`easytrojan user del` 会同时更新 passwd.txt、Caddyfile，并调用 Admin API 删除 storage 中的键。

## 端口安全

请只向公网开放必要端口：

- `80/tcp`
- `443/tcp`

Caddy Admin API 应只监听本地地址：

```text
127.0.0.1:2019
```

请不要将 `2019` 端口开放到公网。安装脚本会在 Caddyfile 中写入 `admin 127.0.0.1:2019`，并在启动后做监听地址检查。

## Release 校验

Release 会提供 `SHA256SUMS`。安装脚本会尝试下载并校验 release 包。

你也可以手动校验：

```bash
sha256sum -c SHA256SUMS
```

如果校验失败，请不要继续安装。

## 报告安全问题

如果你发现安全问题，请不要公开提交 issue。

建议通过以下方式报告：

- 如果仓库启用了 GitHub Security Advisories，请优先使用私密安全报告。
- 如果没有启用，请通过维护者提供的私密联系方式报告。
- 报告中建议包含影响范围、复现步骤、相关日志和修复建议。
## 第三方伪装站

默认伪装站使用 [CorentinTh/it-tools](https://github.com/CorentinTh/it-tools) 的 release 静态资源（GPL-3.0）。安装时会从 GitHub 下载 zip 并解压到 `/etc/caddy/www`。请遵守其许可证与上游安全公告。