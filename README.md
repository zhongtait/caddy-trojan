# caddy-trojan

[![Build Status](https://github.com/zhongtait/caddy-trojan/actions/workflows/release.yml/badge.svg)](https://github.com/zhongtait/caddy-trojan/actions)
[![License](https://img.shields.io/github/license/zhongtait/caddy-trojan)](LICENSE)

一个轻量化、自动化的 Caddy + Trojan 一键部署脚本。

本项目基于 Caddy Server 构建，自动处理 HTTPS 证书申请与续期，支持 Trojan 协议，并集成了系统内核参数优化（BBR）与非侵入式配置管理。

## ✨ 功能特性

- **自动证书管理**：自动申请 Let's Encrypt 证书，到期自动续签。
- **高性能**：集成 BBR 拥塞控制与系统内核参数调优。
- **安全隐蔽**：标准 HTTPS (443端口) 伪装，通过 `nip.io` 提供免费动态域名支持。
- **非侵入式设计**：使用 `/etc/sysctl.d/` 管理内核参数，不破坏系统原生配置文件。
- **多架构支持**：自动适配 `amd64` (x86_64) 和 `arm64` (aarch64) 架构。

## 🚀 安装说明

### 1. 快速安装 (推荐)

执行以下命令即可开始安装。脚本将引导你输入密码；如果未提供域名，将自动生成专用域名。

```bash
curl -O https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/easytrojan.sh && chmod +x easytrojan.sh && bash easytrojan.sh
```

### 2. 高级模式 (自动化部署)

支持通过命令行参数直接传入配置，适合自动化脚本调用。

```bash
# 语法: bash easytrojan.sh <密码> [域名]

# 示例 1: 指定密码，使用默认 nip.io 域名
bash easytrojan.sh mypassword123

# 示例 2: 指定密码和自定义域名 (请确保域名已解析到本机IP)
bash easytrojan.sh mypassword123 example.com
```

## 🛡️ 端口放行

安装前或安装后，请务必在云服务商的安全组（防火墙）中放行 **TCP 80** 和 **TCP 443** 端口。

**系统内部防火墙放行命令参考：**

**RHEL / CentOS / AlmaLinux:**

```bash
firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp
firewall-cmd --reload
```

**Debian / Ubuntu:**

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

> **验证方法**：
> 安装完成后，直接在浏览器访问显示的域名（例如 `1.2.3.4.nip.io`）。如果网页显示 "Service Unavailable" 且地址栏有 HTTPS 小锁图标，说明服务运行正常且端口已通。

## 📂 文件路径与管理

  - **Caddyfile (主配置)**: `/etc/caddy/Caddyfile`
  - **密码文件**: `/etc/caddy/trojan/passwd.txt`
  - **服务管理**:
      - 启动: `systemctl start caddy`
      - 停止: `systemctl stop caddy`
      - 查看状态: `systemctl status caddy`
      - 重载配置: `systemctl reload caddy`

## 🗑️ 卸载

本项目提供了一键卸载脚本，可彻底清理安装的文件、服务及系统配置。

```bash
curl -O https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/uninstall.sh && chmod +x uninstall.sh && bash uninstall.sh
```

## ⚠️ 免责声明

1.  本项目仅供网络技术研究、学习及教育目的使用。
2.  请遵守您所在国家或地区的法律法规。
3.  作者不对使用本项目产生的任何后果负责。软件按“原样”提供，不包含任何明示或暗示的担保。

-----

[MIT License](https://www.google.com/search?q=MITLICENSE) © 2025 zhongtait