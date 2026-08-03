# Changelog

本文件记录项目的重要变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [Unreleased]

### 新增

- 网络：安装时可选择 Trojan 出站 IPv4 或 IPv6 优先级，默认 IPv4；另一地址族保持自动回退，选择会持久化并显示在 status 中。
- 系统：默认随 BBR 一并应用并持久化 `tcp_slow_start_after_idle=0` 与 `tcp_notsent_lowat=16384`（长连接空闲后恢复满速、降低每连接内存）；安装与 `update` 均生效。
- 系统：为 Caddy 服务设置软内存上限 `GOMEMLIMIT`（约 75% 内存），作为小内存 VPS 的 OOM 兜底；内存无法探测或过小时自动跳过。
- 系统：安装时在内核支持的情况下启用并持久化 `fq` + BBR；更广泛的 sysctl / limits 调优保持可选。
- Hub：节点聚合 Hub `easytrojan hub enable|disable|status|url|token|list|remove|join`。
- Hub：本地 Python 服务 `hub_server.py`（`127.0.0.1:2099`），经 Caddy 反代 `/sub/*`、`/api/*`。
- Hub：订阅支持 `?server=` / `?port=` 改写连接地址（Cloudflare 优选 IP）。
- Hub：`hub enable --name` / `hub rename` 支持自定义显示名；`hub url --server/--port` 生成优选 IP 订阅链接。
- Hub：`hub enable` 时若缺少 python3（>= 3.8），自动通过 apt / dnf / yum 安装。
- Hub：实现 HTTP HEAD，使订阅的 Cache-Control 对 `curl -I` 与 CI 可见。
- TLS：新增 `auto`（Caddy ACME）与 `origin`（Cloudflare Origin / 文件证书）两种模式；`install --tls-mode`、`easytrojan cert {auto|origin|status}`。
- 命令行：支持 `install` 子命令、交互式输入 Trojan 密码，以及 `--password`、`--domain`、`--version`、`--skip-domain-check` 参数。
- 命令行：新增 `user add|list|del` 用户管理子命令。
- 命令行：`status --server ADDR` / `link --server ADDR` 让分享链接支持 Cloudflare 优选 IP（SNI / Host 仍为域名）；`status` / `link` 支持 `--port`。
- 命令行：安装后写入 `/usr/local/bin/easytrojan` 管理入口；域名持久化到 `/etc/caddy/trojan/domain.txt`。
- 发布：支持 release 包 SHA256 校验；GitHub Actions release 增加 `SHA256SUMS`。
- 文档：新增 `SECURITY.md`。
- CI：将 `shellcheck`（warning 级）接入 `scripts/ci_validate.sh` 与 GitHub Actions，新增 `.shellcheckrc`。
- CI：新增 `scripts/ci_validate.sh` 与 GitHub Actions CI Validate（shell 语法、模块清单、Hub 冒烟测试；不安装节点）。
- 测试：Hub 单元测试自 7 增至 12（节点缓存与拷贝隔离、落盘失败、`build_link` 的 tcp/IPv6、`delete_by_credentials`、订阅体等）。

### 变更

- Hub 性能：按文件标识（mtime / size / inode）缓存已校验的节点与默认订阅体，重复 `/sub` 拉取不再重复解析与校验；`/sub` 启用 HTTP/1.1 keep-alive（写操作强制关闭连接）。
- 重构：抽取 `detect_share_transport`、`hub_json_field`、`hub_register_payload`、`hub_indexed_name`、`hub_unregister_password`、`validate_port`、`http_send_json` 等公共函数，消除多处重复逻辑。
- 重构：拆分 `easytrojan.sh` 为入口 + `lib/*.sh` 模块（common / tls / caddy / camouflage / system / hub / manage / install）；安装与更新同步到 `/usr/local/share/easytrojan/lib`。
- 用户管理：Trojan 用户改为 Caddyfile 静态 `users`（与 imgk 官方一致）：`passwd.txt` → 生成 Caddyfile → `reload`，不再依赖安装后的 Admin API 注入。
- 用户管理：`user add|del` 同步更新 `passwd.txt` 与 Caddyfile；删除时额外调用 `DELETE /trojan/users/delete` 清理 `caddy` upstream 在 storage 中的键（仅改 Caddyfile 不够）。
- 用户管理：`update` 重启后不再通过 API 同步用户。
- 安装：必须提供真实域名，不再使用 nip.io 默认域名。
- 安装：流程从直接 `curl | tar` 改为先下载、校验、检查归档内容，再安装。
- 安装：域名解析检查从优先 `ping` 改为优先 `dig` / `getent` / `host`。
- 伪装站：改为部署 [CorentinTh/it-tools](https://github.com/CorentinTh/it-tools) 静态包，下载失败时回退内置 ByteDeck 工具页；Caddyfile 对站点使用 SPA `try_files` 回退 `/index.html`。
- Caddy：Caddyfile 明确限制 Admin API 监听 `127.0.0.1:2019`。
- 系统：sysctl / limits 优化范围收敛，便于卸载回滚。
- 发布：Release tag 使用 `caddy-version+trojan.<sha7>`，避免插件更新时 tag 冲突。
- 界面：`status` 默认隐藏分享链接，需 `--show-link`。
- 界面：install / status 显示客户端 ALPN 为 `http/1.1` only（而非 h2）。
- 界面：将预期内的防火墙与固定资源完整性提示改为信息级消息，warning 仅保留给真正的失败。
- 文档：README 增加安全建议与指定版本安装示例。
- 文档：README 重组（去重、命令表、FAQ、Hub 与优选端口说明）。
- 文档：澄清订阅 `?server=&port=`（作用于全部节点）与 `join --server/--port`（单节点默认值）的区别。

### 修复

- Caddy：Trojan-over-WebSocket 配置不再启用 raw `listener_wrappers { trojan }`，避免其在 TLS 前拦截普通 443 流量并造成间歇性空响应；从旧配置迁移时自动完整重启 Caddy，防止旧 listener 在 graceful reload 后继续存活。
- Hub：`_save_json` 的磁盘 / 权限错误转为 `DataStoreError`（干净的 503）而非直接断连；负数 `Content-Length` 返回 400（原为 413）。
- 命令行：`--port` 非数字即报错，避免注入非法 JSON；安装证书回滚分支在 `set -e` 下不再中途退出；`uninstall.sh` 接受 `yes`。
- 安装：增加完整的运行依赖预检，按 Debian / RHEL 正确映射 `iproute2` / `iproute` 与 `passwd` / `shadow-utils`，并在安装后确认所需命令确实可用。
- Caddy：Caddyfile 增加 `order trojan before handle`，避免 Trojan WebSocket 被伪装站 SPA `handle` 吞掉（客户端拿到 HTTP 200 HTML 而非 WS 101）；`update` 现在会重新生成 Caddyfile。
- 客户端：强制 WebSocket 分享 / 订阅链接的 ALPN 为 `http/1.1`，h2 优先协商会导致延迟测试与连接间歇失败。
- 客户端：分享 / 订阅链接默认 `alpn=http/1.1`，修复 Cloudflare WebSocket 延迟与 TLS 断连。
- 伪装站：修正反向的 ZIP 路径安全判断，并固定默认 IT-Tools 归档的 SHA256。
- 伪装站：下载失败时重试；旧 GitHub release 不提供 asset digest 元数据时，改用固定的 release 资源 URL。
- 伪装站：为独立加载的模块提供默认 IT-Tools 仓库，并将临时目录清理隔离到子 shell 的 `EXIT` trap，避免 `set -u` 未绑定变量及 `RETURN` trap 泄漏。
- 引导：独立安装与更新改为加载同一份当前仓库快照，而非机器上残留的旧模块或旧 Release，使伪装站回退与 WebSocket ALPN 修复得以生效。
- Hub：等待本地 Hub HTTP 就绪，修正 register / unregister 的 JSON 载荷，并带 HTTP 状态与响应体重试（修复 `hub enable` 后立即注册失败）。
- Hub：检测并链接 python3.13，服务包装脚本回退到带版本号的 python。
- Hub：`/sub` 增强 no-cache 并加入 Profile-Update-Interval，避免客户端拿到空的缓存结果。
- Hub：将伪装站 SPA 包进 catch-all handle，避免 `/sub` 与 `/api` 被重写到 index.html（404）。
- Hub：跳过同路径的 `hub_server.py` 拷贝，使 `hub enable` 能正常结束；服务未激活时明确报错。
- Hub：序列化节点写操作，状态损坏时 fail closed，并增加备份、请求大小限制、字段校验与有界工作线程。
- Hub：长度不一致时使用安全的 token 比较；`user add/del` 同步本地 Hub 节点；修正 Caddyfile 中 Hub 反代的缩进。
- Hub：风险加固——python3 >= 3.8 检查、`join` 持久化 `hub-client.json`、`user add/del` 同步远端 Hub、新增 `/api/unregister`、`update` 模块下载失败即中止、新增 `hub leave`。
- 证书：续签改为每日维护 timer；`:80` 放行 ACME HTTP-01 路径；修正证书存储目录权限。
- 证书：`renew` 默认触发维护检查，`--force` 才删证重签。
- 证书：同域名重装保留证书，避免重复申请触发 Let's Encrypt 限速。
- 证书：验证 origin 证书与私钥是否匹配；续期 timer 不再自行拉起 Caddy。
- 安装：域名校验支持多条 A 记录（任意一条匹配本机 IP 即可）；域名输入规范化（去协议 / 路径 / 端口、转小写）。
- 更新：`update` 先更新脚本再 re-exec，确保后续逻辑使用新版本。
- 更新：暂存脚本更新，回滚不健康的 Caddy 升级，并在安装 / 卸载时保护无关的 Caddy 安装。
- 发布：保持 `sha` 作为上游变更标记，同时将 release 构建固定到该 commit。
- CI：GitHub Actions 构建 Go 版本从 1.23.x 升到 1.25.x（Caddy v2.11.4 要求 go >= 1.25.1）。
- CI：Check Upstream 在检测到更新后通过 workflow_call 直接触发 Build，规避 GITHUB_TOKEN push 不触发其他 workflow 的限制。
- 文档：修正实现计划中“删除 API 不存在 / 重启必丢用户”等不准确表述对应的实现路径。
- （已取代）用户改为 Caddyfile 静态 `users`，不再依赖 API 重注入。

### 安全

- Hub：所有注册 / 注销 / 删除，以及 Admin API 删除用户，改用 `http_send_json`，密码与令牌经 `0600` 临时文件传递，不再出现在进程参数（`ps auxww`）中。
- Hub：内部状态错误统一返回通用的 `hub state unavailable`（503），不向未认证请求泄漏服务器文件路径；认证失败写审计日志，访问日志保持安静。
- Hub：用 `hub_server.py --init` 统一初始化状态（原子写、损坏即 fail closed），移除会轮换 token 且非原子写的内嵌实现；`hub token` 失败提示不再打印真实的 `register_token`；密码脱敏对长度 ≤ 8 的短密码全掩。
- Hub：以受限的 systemd 单元与独立的 `easytrojan-hub` 用户运行。
- 更新：从固定的仓库快照更新脚本，并以带校验和的 Release 作为回退；通过二进制摘要检测 Caddy 插件变化并安全重启。
- Caddy：激活前先校验 Caddyfile 再原子替换；运行时数据隔离到 `/var/lib/caddy`；配置保持 root 属主。
- Caddy：增加 Admin API 监听地址检查。
- 伪装站：固定 release 版本，在上游发布或显式配置时校验 SHA256，校验归档路径，失败时保留原有站点。
- 权限：`/etc/caddy/trojan/passwd.txt` 设为 `600`，`/etc/caddy/trojan` 设为 `700`。
- systemd：增加 `NoNewPrivileges` / `CapabilityBoundingSet`；下载临时目录自动清理。
- 系统：sysctl 调优改为可选（opt-in）。
