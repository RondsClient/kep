# KPE 客户交付与发布清单

面向正式给客户使用的发布步骤与验收标准。开发机（Windows）仅用于构建；**正式环境必须是 Linux KVM 宿主机**。

## 1. 能不能给客户用？

**可以**，前提是：

| 条件 | 说明 |
|------|------|
| 运行环境 | Ubuntu 20.04+ / Debian 11+ / Rocky、Alma、CentOS Stream 8+，已启用 KVM |
| 交付物 | `kpe-linux-amd64.tar.gz` + `kpe-install`（由 `scripts/build-release.sh` 产出） |
| 部署验证 | 在真实 Linux 节点完成下方「上线验收」全部打勾 |
| 已知边界 | Windows 云镜像不在列表展示（可 API 上传）；NAT 小鸡仅支持 Linux cloud-init；多节点需配置 SSH/API Key |

当前版本适合作为 **KVM 面板 / NAT 小鸡 / IDC API 对接** 的正式交付；不适合承诺「全平台 Windows 虚拟机一键开箱」类能力。

## 2. 构建发布包（开发机）

要求：Node.js ≥ 18、pnpm、（可选）Go 用于编译安装器。

```bash
# 仓库根目录
pnpm install
pnpm run build                 # 必须成功：前端 dist-pro + 后端 dist
bash scripts/build-release.sh  # Linux/macOS/Git Bash；产出 release/
```

产出目录 `release/`：

| 文件 | 用途 |
|------|------|
| `kpe-linux-amd64.tar.gz` | 应用包（server + web） |
| `kpe-linux-amd64.tar.gz.sha256` | 校验和 |
| `kpe-install` | 一键安装程序（Linux amd64） |

Windows 上若无 bash/Go，可在 Linux CI 或 WSL 中执行 `build-release.sh`；至少保证 `pnpm run build` 通过后再打包。

## 3. 客户机安装

```bash
scp release/kpe-linux-amd64.tar.gz release/kpe-install root@客户机:/tmp/
ssh root@客户机
chmod +x /tmp/kpe-install
/tmp/kpe-install -url file:///tmp/kpe-linux-amd64.tar.gz
```

安装程序会：检测系统、安装 KVM/依赖（可 `--skip-kvm`）、解压到 `/opt/kpe`、写入管理员与 JWT、注册 systemd、可选生成 Nginx 模板。

凭据：`/opt/kpe/credentials.txt`  
环境变量：`/opt/kpe/server/.env`（务必修改默认密钥类配置）  
服务：`systemctl status kpe`

多节点：安装时选择 **Web + 节点** 或 **仅节点**；控制面通过「节点管理」注册远端并安装 NAT。

## 4. 上线前必改配置

| 项 | 建议 |
|----|------|
| `KPE_JWT_SECRET` | 随机长密钥，勿用开发默认值 |
| 管理员密码 | 首次登录后立即修改；勿使用 `admin/admin` |
| `KPE_COOKIE_SECURE` | HTTPS 时设为 `true` |
| `KPE_SECURE_PATH` | 建议开启安全入口路径 |
| 防火墙 | 仅开放 443（或约定管理端口）；NAT 端口池按需放行 |
| HTTPS | 按 [DEPLOY.md](./DEPLOY.md) 配置 Nginx + Certbot |
| 备份 | 定期备份 `/opt/kpe/server/data/` |

## 5. 上线验收清单（客户机）

在 **Linux KVM 节点** 上逐项确认：

- [ ] `systemctl is-active kpe` 为 active，`GET /health` 正常
- [ ] 浏览器登录管理台（含安全入口时路径正确）
- [ ] Dashboard / 虚拟机列表可打开
- [ ] 云镜像库可见 Linux 镜像；「拉取」至少成功一项（或已上传 qcow2）
- [ ] 创建 NAT 小鸡成功，SSH 端口映射可连
- [ ] VNC 控制台可连已运行的 VM
- [ ] 存储池 / 网络 / 模板 / 任务页无白屏
- [ ] 用户、API Key、Webhook、租户、节点页可打开且 API 正常
- [ ] IP 池（IPv4，可选 IPv6）可创建与分配
- [ ] （多节点）注册节点、安装 NAT、`ping`/`test-ssh` 成功
- [ ] HTTPS + Cookie 登录无循环跳转
- [ ] 审计日志有操作记录

任一项失败，**不要**作为正式交付版本发出。

## 6. 给客户的交付物建议

1. `kpe-linux-amd64.tar.gz` + `.sha256` + `kpe-install`
2. [DEPLOY.md](./DEPLOY.md)（部署与升级）
3. [API.md](./API.md)（IDC / 控制面板对接）
4. 本清单中的「已知边界」与验收结果截图或记录
5. 初始管理员账号说明（建议当面交付，勿明文长期存放）

## 7. 升级

见 [DEPLOY.md](./DEPLOY.md)「升级」：停服务 → 备份 `data/` 与 `.env` → 解压新包 → `npm install --omit=dev` → 启服务。

## 8. 版本与责任边界（建议写进合同/说明书）

- 支持：Linux 云镜像开 VM、NAT 小鸡、存储/网络/模板、RBAC、租户与 Open API、多节点代理
- 不保证：官方 Windows 云镜像直链拉取；Windows 客户机上运行完整 KVM 能力；任意公有云厂商专有镜像格式
- 依赖：宿主机 KVM/libvirt、磁盘与网络容量由客户运维负责
