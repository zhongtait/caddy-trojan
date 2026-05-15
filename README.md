# caddy-trojan

一键部署 Caddy + Trojan 代理服务。基于 [imgk/caddy-trojan](https://github.com/imgk/caddy-trojan) 模块构建。

支持系统：CentOS/RedHat 7+、Debian 9+、Ubuntu 16+  
支持架构：x86_64 (amd64)、aarch64 (arm64)

## 特性

- 一键安装，自动申请 SSL 证书
- 支持 WebSocket 传输 + CONNECT 方法
- 伪装站点（file_server），比 503 更隐蔽
- 自动启用 BBR 拥塞控制
- 系统内核参数优化
- 每日自动检查上游更新并构建最新版本

## 快速安装

将 `password` 替换为你的密码：

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/easytrojan.sh -o easytrojan.sh && chmod +x easytrojan.sh && bash easytrojan.sh password
```

使用自定义域名（需提前将域名 A 记录指向服务器 IP）：

```bash
bash easytrojan.sh password yourdomain.com
```

安装成功后会显示连接参数：
```
Address  : 1.2.3.4.nip.io
Port     : 443
Password : your_password
ALPN     : h2,http/1.1
Transport: websocket
```

## 放行端口

如果服务器开启了防火墙，需放行 TCP 80 与 443 端口：

```bash
# RHEL 系列 (CentOS, AlmaLinux, RockyLinux)
firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp && firewall-cmd --reload

# Debian / Ubuntu
sudo ufw allow proto tcp from any to any port 80,443
```

验证：浏览器访问 `https://你的IP.nip.io`，如果显示 "It works!" 页面，说明安装成功。

## 管理命令

```bash
# 查看状态
systemctl status caddy

# 重启服务
systemctl restart caddy

# 查看日志
journalctl -u caddy --no-pager -n 50

# 添加用户
curl -X POST -H "Content-Type: application/json" -d '{"password": "newpass"}' http://127.0.0.1:2019/trojan/users/add

# 配置文件
cat /etc/caddy/Caddyfile
```

## 重新安装

```bash
systemctl stop caddy
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/easytrojan.sh -o easytrojan.sh && chmod +x easytrojan.sh && bash easytrojan.sh password
```

## 完全卸载

```bash
curl -fsSL https://raw.githubusercontent.com/zhongtait/caddy-trojan/main/uninstall.sh -o uninstall.sh && chmod +x uninstall.sh && bash uninstall.sh
```

## 项目结构

| 文件 | 说明 |
|------|------|
| `easytrojan.sh` | 安装脚本 |
| `uninstall.sh` | 卸载脚本 |
| `sha` | 上游 commit hash，变更时触发自动构建 |
| `.github/workflows/release.yml` | 自动构建 Caddy-Trojan 二进制 |
| `.github/workflows/test.yml` | 每日检查上游更新 |

## 客户端配置

| 参数 | 值 |
|------|------|
| 协议 | trojan |
| 地址 | 安装时显示的域名 |
| 端口 | 443 |
| 密码 | 安装时设置的密码 |
| TLS | 开启 |
| ALPN | h2,http/1.1 |
| 传输 | websocket |

## 致谢

- [caddyserver/caddy](https://github.com/caddyserver/caddy)
- [imgk/caddy-trojan](https://github.com/imgk/caddy-trojan)
- [xcaddy](https://github.com/caddyserver/xcaddy)
