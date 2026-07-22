# Changelog

## [Unreleased]

- **fix: Caddyfile `order trojan before handle`** so Trojan WebSocket is not swallowed by camouflage SPA `handle` (client got HTTP 200 HTML instead of WS 101). `update` now regenerates Caddyfile.
- client: share/subscription ALPN back to `h2,http/1.1` (server already enables both).

- fix(hub): detect/link python3.13 and fall back to versioned python in hub service wrapper.

- fix(hub): wait for local hub HTTP ready, fix register/unregister JSON payload, retry with HTTP status body (fixes Failed to register local user right after enable).

- docs/ui: install/status show client ALPN as http/1.1 only (not h2).

- feat(hub): `hub enable --name` / `hub rename` custom display names; `hub url --server/--port` for preferred-IP subscribe URLs.

- docs(hub): clarify subscription `?server=&port=` (all nodes) vs `join --server/--port` (per-node).

- feat(hub): auto-install python3 (>=3.8) via apt/dnf/yum when missing on `hub enable`.

- fix(client): share/subscription links default `alpn=http/1.1` (CF WS latency / TLS disconnect).

- fix(hub): stronger no-cache + Profile-Update-Interval on `/sub` so clients refresh without empty cache.

- fix(hub): wrap camouflage SPA in catch-all handle so /sub and /api are not rewritten to index.html (404).

- fix(hub): skip same-path hub_server.py copy so `hub enable` finishes; fail clearly if service not active.

- ci: add scripts/ci_validate.sh + GitHub Actions CI Validate (shell syntax, module list, hub smoke; no node install).

- docs: README 重组（去重、命令表、FAQ、Hub/优选端口说明）。

- Hub risk harden: python3>=3.8 check; join 持久化 hub-client.json；user add/del 同步远端 Hub；/api/unregister；update 模块下载失败即中止；hub leave。

- Hub: safe token compare when length mismatches; user add/del sync local hub nodes; Caddyfile hub proxy indent.
### Changed

- 拆分 `easytrojan.sh` 为入口 + `lib/*.sh` 模块（common/tls/caddy/camouflage/system/hub/manage/install）；安装/更新同步到 `/usr/local/share/easytrojan/lib`。

### Added

- 节点聚合 Hub：`easytrojan hub enable|disable|status|url|token|list|remove|join`
- 本地 Python 服务 `hub_server.py`（`127.0.0.1:2099`）经 Caddy 反代 `/sub/*`、`/api/*`
- 订阅支持 `?server=` / `?port=` 改写连接地址（Cloudflare 优选 IP）
- `status` / `link` 支持 `--port`；卸载清理 hub 单元与二进制
- `status --server ADDR` / `link --server ADDR`：分享链接支持 Cloudflare 优选 IP（SNI/Host 仍为域名）。
- TLS 方案选项：`auto`（Caddy ACME）与 `origin`（Cloudflare Origin / 文件证书）；`install --tls-mode`、`easytrojan cert {auto|origin|status}`。

### Changed

- Trojan 用户改为 **Caddyfile 静态 `users`**（与 imgk 官方一致）：`passwd.txt` → 生成 Caddyfile → `reload`；不再依赖安装后 Admin API 注入。
- `user add|del` 同步更新 `passwd.txt` 与 Caddyfile；删除时额外调用 `DELETE /trojan/users/delete` 清理 `caddy` upstream 在 storage 中的键（仅改 Caddyfile 不够）。
- `update` 重启后不再 API 同步用户。

### Fixed

- GitHub Actions 构建 Go 版本从 1.23.x 升到 1.25.x（Caddy v2.11.4 要求 go >= 1.25.1）。
- Check Upstream 在检测到更新后通过 workflow_call 直接触发 Build（规避 GITHUB_TOKEN push 不触发其他 workflow 的限制）。
- 修正实现计划中“删除 API 不存在/重启必丢用户”等不准确表述对应的实现路径。

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
- （已取代）用户改为 Caddyfile 静态 `users`，不再依赖 API 重注入。
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
