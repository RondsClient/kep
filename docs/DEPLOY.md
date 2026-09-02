# KPE 生产部署指南

面向正式环境安装与升级。**客户交付前请先阅读 [RELEASE.md](./RELEASE.md)**（验收清单与发布包说明）。

## 系统要求

- Ubuntu 20.04+ / Debian 11+ / CentOS Stream 8+ / Rocky 8+ / Alma 8+
- 支持 KVM 的 x86_64 CPU
- root 权限安装
- Node.js 由安装程序自动安装（或自行准备 ≥ 18）

## 一键安装

```bash
# 1. 构建发布包（开发机 / CI，须先 pnpm run build 成功）
bash scripts/build-release.sh

# 2. 上传到目标服务器
scp release/kpe-linux-amd64.tar.gz release/kpe-install user@host:/tmp/

# 3. 安装
ssh user@host
sudo chmod +x /tmp/kpe-install
sudo /tmp/kpe-install -url file:///tmp/kpe-linux-amd64.tar.gz
```

安装完成后凭据保存在 `/opt/kpe/credentials.txt`。请立即修改默认管理员密码，并确认 `.env` 中 `KPE_JWT_SECRET` 已为随机值。

部署角色（安装向导或环境变量 `KPE_ROLE`）：

| 角色 | 说明 |
|------|------|
| `all` | Web 控制面 + 本机节点（默认） |
| `node` | 仅 KVM 节点（被控制面调用） |
| `web` | 仅 Web 控制面（NAT 须选远程节点） |

## systemd 服务

```bash
sudo systemctl status kpe
sudo systemctl restart kpe
journalctl -u kpe -f
```

配置文件：
- 服务：`/etc/systemd/system/kpe.service`
- 环境变量：`/opt/kpe/server/.env`（含 `KPE_JWT_SECRET`）
- 数据：`/opt/kpe/server/data/kpe.json`

## HTTPS（Nginx）

安装程序会在 `/opt/kpe/nginx/kpe.conf` 生成模板：

```bash
sudo apt install nginx certbot python3-certbot-nginx
sudo cp /opt/kpe/nginx/kpe.conf /etc/nginx/sites-available/kpe
sudo ln -s /etc/nginx/sites-available/kpe /etc/nginx/sites-enabled/
sudo certbot --nginx -d your-domain.com
sudo nginx -t && sudo systemctl reload nginx
```

**注意**：启用 HTTPS 后，在 `.env` 中设置 `KPE_COOKIE_SECURE=true` 并重启 kpe 服务。

## 防火墙

```bash
# UFW
sudo ufw allow 443/tcp
sudo ufw allow 8000/tcp   # 若直接访问 Node（不推荐）

# firewalld
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

## 安全入口

安装时可设置 `KPE_SECURE_PATH`，访问管理面板需先打开：

```
https://your-domain.com/{secure-path}/
```

## 升级

```bash
sudo systemctl stop kpe
# 备份数据
sudo cp -r /opt/kpe/server/data /opt/kpe/server/data.bak
# 解压新版本到 /opt/kpe（保留 data/ 和 .env）
sudo tar -xzf kpe-linux-amd64.tar.gz -C /opt/kpe
cd /opt/kpe/server && sudo npm install --omit=dev
sudo systemctl start kpe
```

## 监控

- 健康检查：`GET /health`
- Prometheus：`GET /metrics`
- 扩展健康：`GET /api/host/health`

## 故障排查

| 问题 | 处理 |
|------|------|
| libvirt 不可用 | `systemctl start libvirtd`，确认用户在 libvirt 组 |
| 登录失败（HTTPS） | 检查 `KPE_COOKIE_SECURE` 与协议一致 |
| VNC 无法连接 | 确认 VM 运行中，WebSocket 代理已配置 |
| ISO 上传失败 | 检查 `KPE_ISO_DIR` 目录权限 |

## 外部系统对接

IDC 控制面板、计费系统等通过 HTTP API 对接 KPE，请参阅 [API.md](./API.md)。
