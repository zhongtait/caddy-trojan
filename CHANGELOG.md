# Changelog

## Unreleased

### Added

- 支持 `install` 子命令。
- 支持交互式输入 Trojan 密码。
- 支持 `--password`、`--domain`、`--version`、`--skip-domain-check` 参数。
- 支持 release 包 SHA256 校验。
- 增加 `SECURITY.md`。
- GitHub Actions release 增加 `SHA256SUMS`。
- 安装后写入 `/usr/local/bin/easytrojan` 管理入口。
- 持久化域名到 `/etc/caddy/trojan/domain.txt`。

### Changed

- 安装必须提供真实域名，不再使用 nip.io 默认域名。

- 安装流程从直接 `curl | tar` 改为先下载、校验、检查归档内容，再安装。
- 域名解析检查从 `ping` 优先改为 `dig` / `getent` / `host`。
- README 增加安全建议和指定版本安装示例。
- Caddyfile 明确限制 Admin API 监听 `127.0.0.1:2019`。
- sysctl / limits 优化范围收敛，便于卸载回滚。
- Release tag 使用 `caddy-version+trojan.<sha7>`，避免插件更新时 tag 冲突。

### Fixed

- 证书续签：改为每日维护 timer；:80 放行 ACME HTTP-01 路径；修正证书存储目录权限。
- `renew` 默认触发维护检查，`--force` 才删证重签。
- 同域名重装保留证书，避免重复申请触发 Let's Encrypt 限速。
- 重装/升级后从 `passwd.txt` 重新同步 Trojan 用户到运行中的 Caddy。
- 域名校验支持多 A 记录（任意一条匹配本机 IP 即可）。
- 域名输入规范化（去协议/路径/端口、小写）。
- systemd 增加 `NoNewPrivileges` / `CapabilityBoundingSet`；下载临时目录自动清理。
- 新增 `user add|list|del` 用户管理子命令。
- `status` 默认隐藏分享链接，需 `--show-link`。
- `update` 先更新脚本再 re-exec，确保后续逻辑使用新版本。
- 伪装站改为部署 [CorentinTh/it-tools](https://github.com/CorentinTh/it-tools) 静态包；下载失败时回退内置 ByteDeck 工具页。
- Caddyfile 对站点使用 SPA `try_files` 回退 `/index.html`。

### Security

- `/etc/caddy/trojan/passwd.txt` 权限设置为 `600`。
- `/etc/caddy/trojan` 权限设置为 `700`。
- 增加 Caddy Admin API 监听地址检查。