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
- `/etc/caddy/trojan/hub/`
- `/usr/local/bin/easytrojan-hub`
- `/usr/local/share/easytrojan/lib/*.sh`
- `/usr/local/share/easytrojan/hub_server.py`
- `/etc/systemd/system/easytrojan-hub.service`
- `/etc/systemd/system/caddy.service`
- `/etc/systemd/system/caddy-renew.service`
- `/etc/systemd/system/caddy-renew.timer`
- `/etc/sysctl.d/99-easytrojan-bbr.conf`
- `/etc/sysctl.d/99-caddy-trojan.conf`
- `/etc/security/limits.d/caddy-trojan.conf`

## 密码安全

建议使用强随机密码：

```bash
openssl rand -base64 24
```

不建议通过命令行参数传入密码，因为密码可能会被 shell history 或进程列表记录。

`easytrojan status` 默认不输出分享链接；需要时使用 `easytrojan status --show-link`。用户列表只显示脱敏密码（长度 ≤ 8 的短密码整体隐藏）。

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

使用 `memory caddy` 混合 upstream 时，用户密钥会缓存在内存并落在 Caddy 本地
storage（前缀 `trojan/`）。`easytrojan user del` 会同时更新 passwd.txt、Caddyfile，
并调用 Admin API 删除内存与 storage 中的键。用户增删只有在 storage 操作成功后才会
更新内存状态；Caddyfile 校验使用独立临时 storage，不会以 root 身份创建运行时用户键。

节点与 Hub 之间的注册、注销、删除，以及删除 Caddy storage 用户等 API 调用，密码和令牌都通过 `0600` 临时文件传给 `curl`，不会作为命令行参数出现在进程列表（`ps auxww`）中。

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

Release 会提供 `SHA256SUMS` 和由 GitHub Actions OIDC 身份生成的
`SHA256SUMS.sigstore.json`。安装脚本先用固定版本、固定 SHA256 的 cosign
验证 manifest，再按 manifest 校验 Caddy 与 EasyTrojan bundle；签名缺失或签名者
身份不匹配时会 fail closed。签名身份固定为：

```text
https://github.com/zhongtait/caddy-trojan/.github/workflows/release.yml@refs/heads/main
```

手动校验时可使用 cosign（`v3.1.3` 或兼容版本）：

```bash
cosign verify-blob \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity 'https://github.com/zhongtait/caddy-trojan/.github/workflows/release.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  SHA256SUMS
sha256sum -c SHA256SUMS
```

Release tag 同时包含上游插件 SHA 与本仓库已测试源码 SHA，并显式指向该源码提交。
构建产物在只读权限 job 中执行和打包，OIDC 签名 job 无仓库写权限，发布 job 无
OIDC 权限且禁止覆盖已有 tag 的资产。

在引入 Sigstore 之前发布的旧 Release 可能没有签名资产。如确实需要兼容旧版本，
可显式设置 `EASYTROJAN_ALLOW_UNSIGNED_RELEASE=1` 后运行安装/更新；这只放宽
“签名文件不存在”的情况，签名存在但无效仍会拒绝。该开关会降低供应链保护，
不建议在公网自动化环境使用。

```bash
sudo env EASYTROJAN_ALLOW_UNSIGNED_RELEASE=1 \
  bash easytrojan.sh update --version '<legacy-release-tag>'
```

如果摘要或签名校验失败，请不要继续安装。

## 报告安全问题

如果你发现安全问题，请不要公开提交 issue。

建议通过以下方式报告：

- 如果仓库启用了 GitHub Security Advisories，请优先使用私密安全报告。
- 如果没有启用，请通过维护者提供的私密联系方式报告。
- 报告中建议包含影响范围、复现步骤、相关日志和修复建议。

## TLS 证书材料

- **auto**：证书与 ACME 账户材料位于 `/var/lib/caddy/certificates` 与 `/var/lib/caddy/acme`，属主应为 `caddy`，目录权限宜收紧；`/etc/caddy/Caddyfile` 与 Trojan 状态由 `root:caddy` 管理并只读给 Caddy。
- **origin**：私钥位于 `/etc/caddy/certs/origin.key`（600）。请勿把 Origin 私钥提交到公开仓库或聊天记录。
- 卸载脚本只删除带 EasyTrojan 管理标记的 Caddy 资源；检测不到标记时会保留现有 `/etc/caddy`、Caddy 服务和二进制。

## 第三方伪装站

默认伪装站使用 [CorentinTh/it-tools](https://github.com/CorentinTh/it-tools) 的固定 release 静态资源（GPL-3.0），并内置该固定 ZIP 的 SHA256。安装时会校验摘要和归档路径，再原子替换 `/etc/caddy/www`。自定义旧 release 未提供 digest 时，可通过 `IT_TOOLS_SHA256` 显式固定校验值。请遵守其许可证与上游安全公告。

仅下载 `easytrojan.sh` 入口时，脚本通过 GitHub API 解析当前 `main` 提交并下载不可变提交快照，避免入口脚本与旧 Release/本机残留模块混用。API 元数据或仓库快照不可用时会回退到带 SHA256 校验的 Release 包，不会执行可变的 `main` 分支归档；入口与 Release 归档还会拒绝符号链接条目。

## 节点聚合 Hub

启用 `easytrojan hub enable` 后：

- Hub 进程默认只监听 `127.0.0.1:2099`，不直接对公网暴露端口。
- 公网仅通过 Caddy 的 `/sub/<sub_token>` 与 `/api/*`（需 `X-Hub-Token: register_token`）访问。
- `register_token` 可注册/删除节点，**不要分享或写入公开仓库**。
- 订阅 URL 中的 `sub_token` 可拉取全部节点密码的 base64 订阅，**按密码同等保管**。
- `nodes.json` 含明文密码，目录权限应保持 `700`，文件 `600`。
- Hub 状态由 `hub_server.py --init` 统一初始化（原子写、损坏即 fail-closed）；`config.json`、`nodes.json` 原子替换并保留 `.bak`。
- Hub 对内部状态错误只返回通用信息 `hub state unavailable`（HTTP 503），不向未认证请求泄漏服务器文件路径；认证失败会记录到日志。
- 不需要聚合时请 `easytrojan hub disable` 或卸载。

### Hub membership 文件

- `hub join` 会把远端 Hub 的 URL 与 `register_token` 写入 `/etc/caddy/trojan/hub-client.json`（mode 600）。
- 该文件等同于注册凭证；泄露后他人可向你的 Hub 注册或注销节点。
- 不再使用远端聚合时执行 `easytrojan hub leave` 删除该文件。
- Hub 运行时需要 `python3 >= 3.8`。
- Hub 进程使用独立的 `easytrojan-hub` 系统用户；状态文件更新采用原子替换并保留 `.bak`。
