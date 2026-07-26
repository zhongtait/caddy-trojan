# Changelog

## [Unreleased]

### Added

- feat(system): 默认随 BBR 一并应用并持久化 `tcp_slow_start_after_idle=0` 与 `tcp_notsent_lowat=16384`（长连接恢复满速、降低每连接内存）；安装与 `update` 均生效。
- feat(system): 为 Caddy 服务设置软内存上限 `GOMEMLIMIT`（约 75% 内存）作为小内存 VPS 的 OOM 兜底；内存无法探测或过小时跳过。
- ci: 将 `shellcheck`（warning 级）接入 `scripts/ci_validate.sh` 与 GitHub Actions，新增 `.shellcheckrc`。
- test(hub): 单元测试自 7 增至 12（节点缓存与拷贝隔离、落盘失败、`build_link` tcp/IPv6、`delete_by_credentials`、订阅体等）。

### Changed

- perf(hub): 按文件标识（mtime/size/inode）缓存已校验的节点与默认订阅体，重复 `/sub` 拉取不再重复解析和校验；`/sub` 走 HTTP/1.1 keep-alive（写操作强制关闭连接）。
- refactor: 抽取 `detect_share_transport`、`hub_json_field`、`hub_register_payload`、`hub_indexed_name`、`hub_unregister_password`、`validate_port`、`http_send_json` 等公共函数并去重多处逻辑。

### Security

- security(hub): 所有注册/注销/删除及 Admin API 删除用户改用 `http_send_json`，密码与令牌经 `0600` 临时文件传递，不再出现在进程参数（`ps auxww`）中。
- security(hub): 内部状态错误统一返回通用 `hub state unavailable`（503），不向未认证请求泄漏服务器文件路径；认证失败写审计日志、访问日志保持安静。
- security(hub): 用 `hub_server.py --init` 统一初始化 Hub 状态（原子写、损坏即 fail-closed），移除会轮换 token 且非原子写的内嵌实现；`hub token` 失败提示不再打印真实 `register_token`；密码脱敏对长度 ≤ 8 全掩。

### Fixed

- fix(hub): `_save_json` 的磁盘/权限错误转为 `DataStoreError`（干净 503）而非断连；负 `Content-Length` 返回 400（原 413）。
- fix: `--port` 非数字即报错（避免注入非法 JSON）；安装证书回滚分支在 `set -e` 下不再中途退出；`uninstall.sh` 接受 `yes`。

<!-- 以下为更早累积的未发布记录 -->

- fix(camouflage): correct the inverted ZIP path-safety condition and pin the default IT-Tools archive SHA256.
- fix(bootstrap): make standalone installs and updates load one current repository snapshot instead of stale installed/Release modules, so camouflage fallback and WebSocket ALPN fixes take effect.
- fix(ui): report expected firewall and pinned-asset integrity notices as informational messages; reserve warnings for actual failures.
- feat(system): enable and persist `fq` + BBR during installation when supported; keep broader sysctl/limits tuning opt-in.
- security: update scripts from a pinned repository snapshot with checksummed Release fallback; detect Caddy plugin changes by binary digest and restart safely.
- security: validate Caddyfile before atomic activation, isolate Caddy runtime data under `/var/lib/caddy`, and keep configuration root-owned.
- security: pin the camouflage release, verify SHA256 when published or explicitly configured, validate archive paths, and preserve the previous site on failure.
- fix(camouflage): retry downloads and use the pinned release asset URL when old GitHub releases do not expose asset digest metadata.
- fix(hub): implement HTTP HEAD so subscription Cache-Control is visible to curl -I / CI.
- **fix: Caddyfile `order trojan before handle`** so Trojan WebSocket is not swallowed by camouflage SPA `handle` (client got HTTP 200 HTML instead of WS 101). `update` now regenerates Caddyfile.
- fix(client): force WebSocket share/subscription ALPN to `http/1.1`; h2-first negotiation caused intermittent latency-test and connection failures.

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
# Unreleased

- fix: keep `sha` as the upstream-change marker while pinning release builds to that commit.
- fix(hub): serialize node mutations, fail closed on corrupt state, add backups, request limits, field validation, and bounded worker threads.
- harden(hub): run the Hub as `easytrojan-hub` with a restricted systemd unit.
- fix: make sysctl tuning opt-in, validate origin certificate/key pairs, and stop the renewal timer from starting Caddy.
- fix: stage script updates, roll back unhealthy Caddy upgrades, and protect unrelated Caddy installations during install/uninstall.
