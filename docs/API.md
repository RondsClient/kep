# KPE Open API 对接文档

> 版本：1.0.0  
> 适用对象：IDC 控制面板、计费系统、运维平台等需要对接 KVM 宿主机 KPE 的后端服务  
> 基础路径：所有业务接口前缀为 `/api`

---

## 1. 概述

KPE 是部署在 **单台 KVM 宿主机** 上的虚拟机管理 Agent。对接方通过 HTTP REST API 管理本机 libvirt/QEMU 虚拟机，通过 WebSocket 获取 VNC 控制台与实时监控数据。

| 项目 | 说明 |
|------|------|
| 协议 | HTTPS 推荐（生产环境经 Nginx 反代）；HTTP 仅用于内网调试 |
| 数据格式 | JSON，`Content-Type: application/json` |
| 字符编码 | UTF-8 |
| 默认端口 | `8000`（环境变量 `KPE_PORT`） |
| 宿主机要求 | Linux + KVM + libvirtd，`LIBVIRT_DEFAULT_URI=qemu:///system` |

---

## 2. 接入准备

### 2.1 获取连接信息

安装完成后，凭据与入口信息位于宿主机 `/opt/kpe/credentials.txt`（开发环境默认 `admin` / `admin`）。

| 环境变量 | 说明 |
|----------|------|
| `KPE_PORT` | API 监听端口 |
| `KPE_JWT_SECRET` | JWT 签名密钥（服务端配置，对接方无需持有） |
| `KPE_SECURE_PATH` | 安全入口路径（若启用，见 §3.3） |
| `KPE_CORS_ORIGIN` | 跨域白名单，逗号分隔 |

### 2.2 推荐架构

```
[IDC 控制面板] ──HTTPS──▶ [Nginx] ──▶ [KPE :8000] ──▶ [libvirt/KVM]
                              │
                         TLS 终结、IP 白名单
```

每台物理宿主机部署一个 KPE 实例；对接方维护「宿主机 IP / 域名 → KPE 实例」映射，按宿主机维度调用 API。

### 2.3 对接账号建议

| 角色 | 权限 | 适用场景 |
|------|------|----------|
| `admin` | 全部 | 平台初始化、用户管理 |
| `operator` | VM/存储/网络/控制台读写 | 日常开机关机、创建 VM |
| `viewer` | 只读 | 监控、状态查询 |

生产环境请为对接系统单独创建 `operator` 账号，勿共用 admin。

---

## 3. 认证与安全

### 3.1 登录获取 Token

**`POST /api/auth/login`**

无需鉴权。

请求体：

```json
{
  "username": "operator",
  "password": "your-password"
}
```

成功响应：

```json
{
  "code": 0,
  "data": {
    "username": "operator",
    "role": "operator",
    "roleId": "2",
    "permissions": ["vm.*", "storage.*", "network.*", "console.view", "host.read", "audit.read"],
    "expiresAt": 1735689600000,
    "sessionMaxAge": 28800
  }
}
```

同时服务端会设置 HttpOnly Cookie：

| Cookie | 说明 |
|--------|------|
| `kpe_token` | JWT，后续请求凭证 |
| `kpe_expires_at` | 过期时间戳（毫秒，非 HttpOnly） |

**对接推荐**：使用 **Bearer Token**，从登录响应的 `Set-Cookie: kpe_token=...` 中提取 JWT，或自行解析 Cookie。后续所有请求携带：

```http
Authorization: Bearer <JWT>
```

示例：

```bash
TOKEN=$(curl -s -X POST http://HOST:8000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"operator","password":"secret"}' \
  | jq -r '.data // empty')

# 实际 Token 在 Set-Cookie 中，可用 -c/-b 管理 Cookie，或从 Cookie 头解析 kpe_token
curl -s http://HOST:8000/api/vms \
  -H "Authorization: Bearer $TOKEN"
```

> 使用 `-c cookies.txt -b cookies.txt` 可自动管理 Cookie 会话，适合脚本调试。

### 3.2 会话校验

| 方法 | 路径 | 鉴权 | 说明 |
|------|------|------|------|
| GET | `/api/auth/session` | 否 | 检查 Cookie/Token 是否有效 |
| GET | `/api/auth/me` | 是 | 当前用户信息 |
| GET | `/api/auth/logout` | 是 | 登出并清除 Cookie |

`GET /api/auth/session` 响应示例：

```json
{
  "code": 0,
  "data": {
    "valid": true,
    "expiresAt": 1735689600000,
    "sessionMaxAge": 28800,
    "username": "operator",
    "role": "operator",
    "roleId": "2",
    "permissions": ["vm.*", "..."]
  }
}
```

### 3.3 安全入口（可选）

若配置了 `KPE_SECURE_PATH=abc123`，未持有入口 Cookie 的请求一律返回 **404**（含 API）。

**首次激活**：浏览器或脚本访问一次：

```http
GET https://HOST/abc123/
```

服务端写入 `kpe_entry=1` Cookie（有效期 7 天）。之后同会话可正常访问 `/api/*`。

健康检查 **`GET /health`**、**`GET /api/health`** 不受安全入口限制。

### 3.4 限流

全局限流：**100 次/分钟/IP**。超出返回 HTTP 429。

---

## 4. 通用约定

### 4.1 响应结构

```typescript
interface ApiResponse<T> {
  code: number      // 0 = 成功，非 0 = 失败
  data?: T          // 成功时业务数据
  message?: string  // 失败时错误描述
}
```

成功示例：

```json
{ "code": 0, "data": { "total": 2, "list": [] } }
```

失败示例：

```json
{ "code": 500, "message": "虚拟机未运行，请先启动" }
```

HTTP 状态码：

| HTTP | 场景 |
|------|------|
| 200 | 业务成功或业务失败（通过 `code` 区分） |
| 401 | 未登录 / Token 过期 |
| 403 | 权限不足 |
| 404 | 路径不存在或安全入口未激活 |
| 429 | 触发限流 |

### 4.2 VM 名称与 URL 编码

虚拟机 `name` 作为路径参数时需 **URL 编码**（如 `vm-01` → `vm-01`，含中文或空格必须编码）。

### 4.3 审计

所有写操作（创建/删除/电源/快照等）均写入审计日志，可通过 `GET /api/audit/logs` 查询。

---

## 5. API 参考

### 5.1 健康与监控

#### GET /health、GET /api/health

无需鉴权。负载均衡探活使用。

```json
{ "code": 0, "data": { "status": "ok", "version": "1.0.0" } }
```

#### GET /api/host/info

宿主机与 hypervisor 信息。需 `host.read`。

`libvirtAvailable: false` 时仅返回提示，无硬件详情。

```json
{
  "code": 0,
  "data": {
    "libvirtAvailable": true,
    "hypervisor": "libvirt",
    "qemuVersion": "8.2.0",
    "hostname": "kvm-node-01",
    "model": "x86_64",
    "cpus": 32,
    "cpuFrequency": "2400 MHz",
    "memoryKiB": 67108864,
    "freeMemoryKiB": 33554432
  }
}
```

#### GET /api/host/health

宿主机健康摘要。需 `host.read`。

```json
{
  "code": 0,
  "data": {
    "libvirt": true,
    "diskFreePercent": 45,
    "status": "ok"
  }
}
```

#### GET /metrics

Prometheus 文本格式，**无需 `/api` 前缀**，无需 JWT。

```
# HELP kpe_libvirt_up libvirt availability
# TYPE kpe_libvirt_up gauge
kpe_libvirt_up 1
# HELP kpe_vm_total total VMs
# TYPE kpe_vm_total gauge
kpe_vm_total 12
```

---

### 5.2 虚拟机

#### GET /api/vms

列表。需 `vm.read`。

```json
{
  "code": 0,
  "data": {
    "total": 1,
    "list": [
      {
        "id": "3",
        "name": "web-01",
        "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "state": "running",
        "cpu": 2,
        "memoryKiB": 2097152,
        "maxMemoryKiB": 4194304,
        "autostart": true
      }
    ]
  }
}
```

`state` 常见值：`running`、`shut off`、`paused`、`crashed` 等（与 virsh 一致）。

#### GET /api/vms/:name

单台 VM 详情。字段同列表项。

#### GET /api/vms/:name/xml

libvirt domain XML。

```json
{ "code": 0, "data": { "xml": "<domain type='kvm'>...</domain>" } }
```

#### GET /api/vms/:name/stats

运行监控。需 `vm.read`。

```json
{
  "code": 0,
  "data": {
    "name": "web-01",
    "state": "running",
    "cpuPercent": 12,
    "memoryKiB": 1800000,
    "maxMemoryKiB": 4194304
  }
}
```

#### POST /api/vms

创建 VM。需 `vm.*`。

请求体：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| name | string | 是 | 域名，唯一 |
| memoryMiB | number | 是 | 内存（MiB） |
| vcpus | number | 是 | vCPU 数 |
| diskSizeGiB | number | 是 | 系统盘大小（GiB） |
| network | string | 否 | libvirt 网络名，默认 `default` |
| isoPath | string | 否 | 宿主机 ISO 绝对路径 |
| bootOrder | string | 否 | `hd` 或 `cdrom`（挂载 ISO 时常用 `cdrom`） |

```json
{
  "name": "cust-10086",
  "memoryMiB": 2048,
  "vcpus": 2,
  "diskSizeGiB": 40,
  "network": "default",
  "isoPath": "/var/lib/libvirt/boot/ubuntu-22.04.iso",
  "bootOrder": "cdrom"
}
```

响应：

```json
{
  "code": 0,
  "data": {
    "name": "cust-10086",
    "diskPath": "/var/lib/libvirt/images/cust-10086.qcow2"
  }
}
```

#### PATCH /api/vms/:name

更新 VM。需 `vm.*`。

```json
{
  "autostart": true,
  "isoPath": "/var/lib/libvirt/boot/win.iso"
}
```

| 字段 | 说明 |
|------|------|
| autostart | 是否开机自启 |
| isoPath | 挂载 ISO；传 `null` 卸载 ISO |

#### POST /api/vms/:name/power

电源操作。需 `vm.*`。

```json
{ "action": "start" }
```

| action | 说明 |
|--------|------|
| start | 启动 |
| shutdown | ACPI 优雅关机 |
| reboot | 重启 |
| destroy | 强制断电 |

#### DELETE /api/vms/:name

删除 VM。需 `vm.*`。

Query：`removeStorage=true` 同时删除磁盘。

```bash
curl -X DELETE "http://HOST:8000/api/vms/cust-10086?removeStorage=true" \
  -H "Authorization: Bearer $TOKEN"
```

---

### 5.3 网卡

#### GET /api/vms/:name/interfaces

```json
{
  "code": 0,
  "data": [
    { "mac": "52:54:00:xx:xx:xx", "network": "default", "type": "network" }
  ]
}
```

#### POST /api/vms/:name/interfaces

添加网卡。VM 需处于 shut off 状态（libvirt 限制）。

```json
{ "network": "default" }
```

#### DELETE /api/vms/:name/interfaces/:mac

移除网卡。`:mac` 需 URL 编码（如 `52%3A54%3A00%3Axx%3Axx%3Axx`）。

---

### 5.4 快照

#### GET /api/vms/:name/snapshots

```json
{
  "code": 0,
  "data": [
    { "name": "snap1", "creationTime": "2026-01-01 12:00:00 +0800", "state": "running" }
  ]
}
```

#### POST /api/vms/:name/snapshots

```json
{
  "snapName": "before-update",
  "description": "系统升级前",
  "quiesce": false
}
```

`quiesce: true` 需要 guest agent 支持。

#### POST /api/vms/:name/snapshots/:snapName/revert

回滚到指定快照。

#### DELETE /api/vms/:name/snapshots/:snapName

删除快照。

---

### 5.5 控制台（VNC）

KPE 将 libvirt VNC 通过 WebSocket 代理暴露给前端；对接方可用于自建控制台或 iframe 集成。

#### GET /api/vms/:name/console

获取短期 Token。需 `console.view`。VM 必须 **running**。

```json
{
  "code": 0,
  "data": {
    "host": "127.0.0.1",
    "port": 5900,
    "token": "a1b2c3d4...",
    "wsPath": "/api/vms/web-01/console/ws"
  }
}
```

| 字段 | 说明 |
|------|------|
| token | 一次性凭证，**120 秒**有效，单次 WebSocket 连接消耗 |
| port | libvirt VNC 端口（宿主机本地） |
| wsPath | WebSocket 相对路径 |

#### WebSocket /api/vms/:name/console/ws

```
wss://HOST/api/vms/web-01/console/ws?token=<token>
```

- 子协议：二进制 RFB（noVNC 使用 `wsProtocols: ['binary']`）
- 连接前须完成 JWT 鉴权（与 REST 相同，Bearer 或 Cookie）
- Token 无效返回关闭码 `4001`

**对接 noVNC 示例流程**：

1. `POST /api/auth/login` 获取 JWT  
2. `GET /api/vms/:name/console` 获取 `token`  
3. 建立 WebSocket：`wss://HOST/api/vms/:name/console/ws?token=...`，Header 带 `Authorization: Bearer ...`  
4. 使用 [noVNC RFB](https://github.com/novnc/noVNC) 客户端渲染  

---

### 5.5.0 KVM 节点管理

KPE 支持 **Web + 节点**（`KPE_ROLE=all`）、**仅节点**（`KPE_ROLE=node`）、**仅 Web 控制面**（`KPE_ROLE=web`）三种部署模式。NAT 小鸡须在已安装 NAT 转发的 KVM 节点上创建。

| 环境变量 | 说明 |
|----------|------|
| `KPE_ROLE` | `all` / `node` / `web`，默认 `all` |

#### GET /api/nodes

列出已注册节点（不含 SSH 密码、API Key 明文）。

#### POST /api/nodes

注册远程节点。需管理员权限。

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| name | string | 是 | 节点名称 |
| url | string | 是 | 节点 API 地址，如 `http://192.168.1.10:8000` |
| sshHost / sshPort / sshUser / sshPassword | | 否 | SSH 凭据，用于远程安装 NAT 转发 |
| apiKey | string | 否 | 节点 API Key，留空自动生成（仅响应中显示一次） |

安装程序选择 **Web + 节点** 时会自动注册本地节点（`http://127.0.0.1:PORT`）。

#### POST /api/nodes/:id/install-nat

通过 SSH 在节点上安装 NAT 转发（开启 `ip_forward`、标记 `/etc/kpe/nat-forwarding-enabled`）。本地节点在 `all`/`node` 模式下可直接本地执行。

#### POST /api/nodes/:id/test-ssh

测试 SSH 连接。

#### POST /api/nodes/:id/ping

检测节点 API 是否在线。

---

### 5.5.0 云镜像库

内置 qcow2 云镜像目录（**仅收录官方镜像站可直链下载**的 qcow2 / cloud img），用于 NAT 小鸡与 cloud-init 快速开 VM。未收录的系统可通过上传自定义 qcow2 添加。

#### GET /api/cloud-images

列出云镜像。响应字段含 `os_family`、`downloaded`（是否已就绪）。**Windows 镜像保留在数据库中，但不在此接口返回**（仅隐藏展示）。

**内置镜像系列（列表可见 32 项）**：

| os_family | 发行版 | slug 示例 |
|-----------|--------|-----------|
| ubuntu | Ubuntu 18.04–26.04 | ubuntu-18.04 … ubuntu-26.04 |
| debian | Debian 10–13 | debian-10 … debian-13 |
| centos | CentOS Stream 8/9、AlmaLinux 8/9/10、Rocky 8/9/10、Oracle Linux 8/9 | centos-stream-9, almalinux-10, rocky-10, oracle-linux-9 |
| fedora | Fedora 41–43 Cloud | fedora-41 … fedora-43 |
| suse | openSUSE Leap 15.5/15.6、Tumbleweed | opensuse-leap-15.6, opensuse-tumbleweed |
| alpine | Alpine 3.20–3.22 Cloud | alpine-3.22 |
| arch | Arch Linux Cloud | archlinux |
| anolis | Anolis OS 8.9/8.10 | anolis-8.10 |

另有 Windows Server 2016/2019/2022、Windows 11 内置目录项（`visible: false`），可通过 `POST /api/cloud-images/:id/upload` 绑定 qcow2，不出现在列表中。

#### POST /api/cloud-images/:id/download

异步拉取远程镜像（写入 `KPE_CLOUD_IMAGE_DIR`）。

#### POST /api/cloud-images/upload

上传自定义 qcow2，新建镜像记录。

#### POST /api/cloud-images/:id/upload

将 qcow2 绑定到已有目录项。

#### DELETE /api/cloud-images/:id

删除非内置镜像。

---

NAT 小鸡 = 云镜像 + cloud-init + libvirt NAT 网络 + **iptables DNAT** 端口映射。无独立公网 IP，通过宿主机端口访问 VM 内服务。

#### POST /api/vms/nat-chick

创建 NAT 小鸡。需 `vm.*`。

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| name | string | 是 | VM 名称 |
| cloudImageId | number | 是 | 云镜像库 ID（需已拉取） |
| memoryMiB / vcpus / diskSizeGiB | number | 是 | 规格 |
| network | string | 否 | NAT 网络，默认 `default` |
| **nodeId** | number | 条件 | KVM 节点 ID；`web` 模式必填，`all`/`node` 可省略（默认本地节点） |
| natPortQuota | number | 否 | **NAT 端口配额总数，默认 `1`** |
| password / sshPublicKey | string | 否 | cloud-init 初始化 |
| portForwards | array | 否 | 除 SSH 外的额外映射 |

**端口配额规则**：

| natPortQuota | 效果 |
|--------------|------|
| `1`（默认） | 仅分配 **1 个端口**给默认 SSH（Guest:22 → 随机宿主机端口） |
| `5` | SSH 占 1 个 + **4 个预留槽**（已分配宿主机端口，Guest 端口待绑定） |
| 含 portForwards | 额外映射计入配额；总数不得超过 `natPortQuota` |

上限由环境变量 `KPE_NAT_PORT_QUOTA_MAX` 控制（默认 32）。

**前置条件**：目标节点须 `nat_installed=true`（通过 `POST /api/nodes/:id/install-nat` 完成）。

请求示例：

```json
{
  "name": "chick-001",
  "cloudImageId": 1,
  "nodeId": 1,
  "memoryMiB": 512,
  "vcpus": 1,
  "diskSizeGiB": 10,
  "natPortQuota": 5,
  "password": "YourPass123"
}
```

响应示例：

```json
{
  "code": 0,
  "data": {
    "name": "chick-001",
    "natPortQuota": 5,
    "portQuota": {
      "quota": 5,
      "used": 5,
      "mapped": 1,
      "reservedSlots": 4,
      "ssh": { "host_port": 10023, "guest_port": 22, "label": "ssh" }
    },
    "sshCommand": "ssh -p 10023 root@<宿主机IP>"
  }
}
```

#### GET /api/vms/:name/port-forwards

返回配额摘要与端口列表：

```json
{
  "code": 0,
  "data": {
    "quota": 5,
    "summary": { "quota": 5, "used": 5, "mapped": 2, "reservedSlots": 3 },
    "list": [
      { "id": 1, "host_port": 10023, "guest_port": 22, "label": "ssh", "reserved": false },
      { "id": 2, "host_port": 10024, "guest_port": 0, "label": "reserved", "reserved": true }
    ]
  }
}
```

#### POST /api/vms/:name/port-forwards

添加映射。默认 **优先占用预留槽**（`useReservedSlot: true`）。配额已满且无余槽时返回错误。

#### PATCH /api/vms/:name/port-forwards/:id

将**预留槽**绑定到 Guest 端口并立即应用 DNAT：

```json
{ "guestPort": 8080, "protocol": "tcp" }
```

#### DELETE /api/vms/:name/port-forwards/:id

删除映射或释放预留槽（SSH 默认连接建议保留）。

---

### 5.6 凭据（Guest 登录 / VNC 密码）

用于自动化注入密码、noVNC 粘贴密码等场景。**敏感接口，调用会记审计。**

#### GET /api/vms/:name/credentials

需 `vm.read`。

密码来源（`sources` 数组）：

| 来源标识 | 说明 |
|----------|------|
| vnc-xml | libvirt XML `<graphics passwd>` |
| description-cloud-config | domain `<description>` 内 cloud-config |
| cloud-init-iso | cloud-init seed ISO 的 user-data |
| xml-metadata | XML 自定义元数据 |
| kpe-store | 通过 PATCH 接口手动保存 |

```json
{
  "code": 0,
  "data": {
    "vncPassword": "vnc123",
    "loginPassword": "GuestPass!",
    "loginUser": "root",
    "sources": ["kpe-store", "cloud-init-iso"],
    "hasVncPassword": true,
    "hasLoginPassword": true
  }
}
```

> Hypervisor **不会**自动知晓 Guest OS 密码；若未配置 cloud-init / 手动保存，则 `loginPassword` 为 `null`。

#### PATCH /api/vms/:name/credentials

保存 Guest 登录凭据。需 `vm.*`。

```json
{
  "loginUser": "root",
  "loginPassword": "MySecurePass123"
}
```

---

### 5.7 存储

#### GET /api/storage/pools

```json
{
  "code": 0,
  "data": [
    {
      "name": "default",
      "state": "running",
      "autostart": true,
      "capacity": "500.00 GiB",
      "allocation": "120.00 GiB",
      "available": "380.00 GiB",
      "path": "/var/lib/libvirt/images"
    }
  ]
}
```

#### POST /api/storage/pools

```json
{ "name": "data", "path": "/data/kvm" }
```

#### DELETE /api/storage/pools/:name

#### GET /api/storage/pools/:pool/volumes

#### POST /api/storage/volumes

```json
{ "pool": "default", "name": "data-01.qcow2", "sizeGiB": 100 }
```

#### POST /api/storage/volumes/resize

```json
{ "pool": "default", "name": "cust-10086.qcow2", "sizeGiB": 80 }
```

#### DELETE /api/storage/volumes?pool=default&name=xxx.qcow2

---

### 5.8 ISO 镜像

#### GET /api/images

```json
{
  "code": 0,
  "data": {
    "dir": "/var/lib/libvirt/boot",
    "list": [
      {
        "name": "ubuntu-22.04.iso",
        "path": "/var/lib/libvirt/boot/ubuntu-22.04.iso",
        "size": 2136926208,
        "sizeHuman": "1.99 GiB"
      }
    ]
  }
}
```

#### POST /api/images/upload

`multipart/form-data`，字段名 `file`，仅 `.iso`，单文件最大 **10 GiB**。

```bash
curl -X POST http://HOST:8000/api/images/upload \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@./ubuntu-22.04.iso"
```

#### DELETE /api/images?path=/var/lib/libvirt/boot/old.iso

只能删除 ISO 目录内的文件。

---

### 5.9 网络

#### GET /api/networks

```json
{
  "code": 0,
  "data": [
    {
      "name": "default",
      "uuid": "...",
      "active": true,
      "persistent": true,
      "autostart": true
    }
  ]
}
```

#### POST /api/networks

```json
{ "name": "nat100", "ipRange": "192.168.100.0/24" }
```

`ipRange` 可选，默认由 KPE 分配 NAT 网段。

#### DELETE /api/networks/:name

#### POST /api/networks/:name/power

```json
{ "action": "start" }
```

`action`：`start` | `stop`

---

### 5.9.1 IP 地址池（IPv4 / IPv6）

IPv4 与 IPv6 使用**同一套 API**，通过 `family` 区分。IPv4 池创建时从 CIDR 导入全部可用单 IP；IPv6 池按需分配 `/64`（或自定义 `allocPrefix`）子网。

#### GET /api/ip-pools?family=ipv4|ipv6

#### POST /api/ip-pools

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| name | string | 是 | 池名称 |
| family | string | 是 | `ipv4` 或 `ipv6` |
| cidr | string | 是 | 如 `203.0.113.0/24` 或 `2001:db8:1000::/48` |
| gateway | string | 是 | 网关地址 |
| dnsServers | string[] | 否 | DNS 列表；省略时 IPv4 默认 `223.5.5.5,223.6.6.6`，IPv6 默认 `2400:3200::1,2400:3200:baba::1`（阿里云公共 DNS） |
| allocPrefix | number | 否 | IPv6 分配前缀，默认 64；IPv4 固定 32 |

IPv4 示例：

```json
{
  "name": "public-v4-hk",
  "family": "ipv4",
  "cidr": "203.0.113.0/24",
  "gateway": "203.0.113.1",
  "dnsServers": ["223.5.5.5", "223.6.6.6"]
}
```

IPv6 示例：

```json
{
  "name": "public-v6-hk",
  "family": "ipv6",
  "cidr": "2001:db8:1000::/48",
  "gateway": "2001:db8:1000::1",
  "dnsServers": ["2400:3200::1", "2400:3200:baba::1"],
  "allocPrefix": 64
}
```

#### DELETE /api/ip-pools/:id

#### GET /api/ip-pools/:id/addresses?status=free|used|reserved

#### POST /api/ip-pools/:id/allocate

```json
{ "vmName": "web-01", "address": "203.0.113.10" }
```

`address` 可选；省略时 IPv4 自动取第一个空闲 IP，IPv6 自动分配下一个 `/64`。

#### POST /api/ip-pools/:id/release

```json
{ "address": "203.0.113.10" }
```

#### POST /api/ip-pools/:id/reserve

```json
{ "address": "203.0.113.254", "note": "网关预留" }
```

删除 VM 时关联 IP 会自动释放。

---

### 5.10 模板与异步任务

模板导出、从模板克隆为 **异步任务**，返回 `jobId` 后轮询。

#### GET /api/templates

#### GET /api/templates/:id

#### POST /api/templates

从现有 VM 导出模板。

```json
{
  "vmName": "golden-ubuntu",
  "name": "tpl-ubuntu-22",
  "description": "标准 Ubuntu 22.04"
}
```

响应：`{ "code": 0, "data": { "jobId": 1 } }`

#### DELETE /api/templates/:id

#### POST /api/vms/from-template

从模板克隆 VM。

```json
{ "templateId": 1, "name": "cust-new-001" }
```

响应：`{ "code": 0, "data": { "jobId": 2, "name": "cust-new-001" } }`

#### GET /api/jobs

#### GET /api/jobs/:id

```json
{
  "code": 0,
  "data": {
    "id": 2,
    "type": "clone_template",
    "payload": "{\"templateId\":1,\"name\":\"cust-new-001\"}",
    "status": "completed",
    "progress": 100,
    "error": null,
    "result": "{\"name\":\"cust-new-001\",\"diskPath\":\"...\"}",
    "created_at": "2026-09-02T04:00:00.000Z",
    "updated_at": "2026-09-02T04:01:30.000Z"
  }
}
```

| status | 说明 |
|--------|------|
| pending | 排队中 |
| running | 执行中 |
| completed | 成功 |
| failed | 失败，见 `error` |

**轮询建议**：间隔 2–5 秒，超时 30 分钟。

---

### 5.11 用户与系统设置

> 通常仅 `admin` 使用。

#### GET /api/users

#### POST /api/users

```json
{ "username": "idc-bot", "password": "...", "role": "operator" }
```

角色：`admin` | `operator` | `viewer`

#### PATCH /api/users/:id

```json
{ "role": "viewer", "password": "new-pass" }
```

#### DELETE /api/users/:id

#### POST /api/auth/change-password

当前用户改密。

```json
{ "oldPassword": "...", "newPassword": "..." }
```

#### GET /api/settings

```json
{
  "code": 0,
  "data": {
    "sessionMaxAge": 28800,
    "isoDir": "/var/lib/libvirt/boot",
    "libvirtUri": "qemu:///system"
  }
}
```

#### PATCH /api/settings

```json
{
  "sessionMaxAge": 86400,
  "isoDir": "/data/iso",
  "libvirtUri": "qemu:///system"
}
```

---

### 5.12 审计日志

#### GET /api/audit/logs

需 `audit.read`。默认返回最近 100 条。

```json
{
  "code": 0,
  "data": [
    {
      "id": 1,
      "username": "operator",
      "action": "vm.create",
      "target": "cust-10086",
      "detail": "{\"memoryMiB\":2048,...}",
      "created_at": "2026-09-02T04:00:00.000Z"
    }
  ]
}
```

常见 `action`：`login`、`vm.create`、`vm.start`、`vm.delete`、`vm.credentials.read`、`image.upload` 等。

---

## 6. WebSocket 实时事件

#### GET /api/ws/events（WebSocket）

需 JWT 鉴权。每 **5 秒**推送一次宿主机与全部 VM 监控快照。

消息格式：

```json
{
  "type": "stats",
  "vms": [
    {
      "name": "web-01",
      "state": "running",
      "cpuPercent": 8,
      "memoryKiB": 1800000,
      "maxMemoryKiB": 4194304
    }
  ],
  "host": {
    "cpus": 32,
    "memoryKiB": 67108864,
    "freeMemoryKiB": 33554432,
    "memoryUsagePercent": 50
  },
  "vmStates": [ /* 同 GET /api/vms list 项 */ ]
}
```

错误时：

```json
{ "type": "error", "message": "stats unavailable" }
```

连接示例（websocat）：

```bash
websocat -H="Authorization: Bearer $TOKEN" \
  ws://HOST:8000/api/ws/events
```

---

## 7. RBAC 权限矩阵

| 权限标识 | admin | operator | viewer |
|----------|:-----:|:--------:|:------:|
| `*.*.*` | ✓ | | |
| `vm.*`（创建/删除/电源/快照/改凭据） | ✓ | ✓ | |
| `vm.read`（列表/详情/监控/凭据读） | ✓ | ✓ | ✓ |
| `storage.*` | ✓ | ✓ | |
| `network.*` | ✓ | ✓ | |
| `console.view` | ✓ | ✓ | |
| `host.read` | ✓ | ✓ | ✓ |
| `audit.read` | ✓ | ✓ | ✓ |

权限不足返回：

```json
{ "code": 403, "message": "权限不足" }
```

---

## 8. 典型对接流程

### 8.1 开通一台 VM（ISO 安装）

```
1. POST /api/auth/login
2. GET  /api/images                    → 选择 isoPath
3. GET  /api/networks                  → 选择 network
4. POST /api/vms                       → 创建 VM
5. POST /api/vms/:name/power           → { "action": "start" }
6. GET  /api/vms/:name/console         → 获取 VNC token（可选，给客户控制台）
7. PATCH /api/vms/:name/credentials    → 保存初始 root 密码（可选）
```

### 8.2 从模板快速开 VM

```
1. POST /api/vms/from-template         → jobId
2. GET  /api/jobs/:id                  → 轮询至 completed
3. POST /api/vms/:name/power           → start
```

### 8.3 停机回收

```
1. POST /api/vms/:name/power           → { "action": "shutdown" }
   （或 destroy 强制）
2. 轮询 GET /api/vms/:name             → state == "shut off"
3. DELETE /api/vms/:name?removeStorage=true
```

### 8.4 IDC 监控采集

```
方案 A：定时 GET /api/vms + GET /api/vms/:name/stats（简单）
方案 B：长连 /api/ws/events（实时性更好）
方案 C：Prometheus 抓取 GET /metrics（宿主机级别）
```

---

## 9. 错误处理建议

| message 关键词 | 处理建议 |
|----------------|----------|
| 登录已过期 | 重新 `POST /api/auth/login` |
| libvirt 不可用 | 检查宿主机 libvirtd、KPE 进程 |
| 虚拟机未运行 | 先 `power.start` 再取 console |
| 权限不足 | 换 operator/admin 账号或调整角色 |
| Invalid token（WS） | 重新获取 console token（120s 过期） |

对接方应：

1. 对 `code !== 0` 统一记录 `message`  
2. Token 在 `expiresAt` 前主动刷新（重新登录）  
3. 写操作实现幂等或业务侧去重（如 VM 名唯一）  
4. 敏感接口（credentials）日志脱敏  

---

## 10. 附录：接口速查表

| 方法 | 路径 | 权限 |
|------|------|------|
| POST | /api/auth/login | 公开 |
| GET | /api/auth/session | 公开 |
| GET | /api/auth/me | 已登录 |
| GET | /api/auth/logout | 已登录 |
| POST | /api/auth/change-password | 已登录 |
| GET | /api/health | 公开 |
| GET | /health | 公开 |
| GET | /metrics | 公开 |
| GET | /api/host/info | host.read |
| GET | /api/host/health | host.read |
| GET | /api/vms | vm.read |
| POST | /api/vms | vm.* |
| GET | /api/vms/:name | vm.read |
| PATCH | /api/vms/:name | vm.* |
| DELETE | /api/vms/:name | vm.* |
| POST | /api/vms/:name/power | vm.* |
| GET | /api/vms/:name/xml | vm.read |
| GET | /api/vms/:name/stats | vm.read |
| GET | /api/vms/:name/interfaces | vm.read |
| POST | /api/vms/:name/interfaces | vm.* |
| DELETE | /api/vms/:name/interfaces/:mac | vm.* |
| GET | /api/vms/:name/snapshots | vm.read |
| POST | /api/vms/:name/snapshots | vm.* |
| POST | /api/vms/:name/snapshots/:snap/revert | vm.* |
| DELETE | /api/vms/:name/snapshots/:snap | vm.* |
| GET | /api/vms/:name/console | console.view |
| WS | /api/vms/:name/console/ws | console.view + token |
| GET | /api/vms/:name/credentials | vm.read |
| PATCH | /api/vms/:name/credentials | vm.* |
| GET | /api/storage/pools | storage.* / vm.read |
| POST | /api/storage/pools | storage.* |
| DELETE | /api/storage/pools/:name | storage.* |
| GET | /api/storage/pools/:pool/volumes | storage.* |
| POST | /api/storage/volumes | storage.* |
| POST | /api/storage/volumes/resize | storage.* |
| DELETE | /api/storage/volumes | storage.* |
| GET | /api/images | storage.* |
| POST | /api/images/upload | storage.* |
| DELETE | /api/images | storage.* |
| GET | /api/networks | network.* |
| POST | /api/networks | network.* |
| DELETE | /api/networks/:name | network.* |
| POST | /api/networks/:name/power | network.* |
| GET | /api/ip-pools | network.* |
| POST | /api/ip-pools | network.* |
| DELETE | /api/ip-pools/:id | network.* |
| GET | /api/ip-pools/:id/addresses | network.* |
| POST | /api/ip-pools/:id/allocate | network.* |
| POST | /api/ip-pools/:id/release | network.* |
| POST | /api/ip-pools/:id/reserve | network.* |
| GET | /api/templates | vm.read |
| GET | /api/templates/:id | vm.read |
| POST | /api/templates | vm.* |
| DELETE | /api/templates/:id | vm.* |
| POST | /api/vms/from-template | vm.* |
| GET | /api/jobs | vm.read |
| GET | /api/jobs/:id | vm.read |
| GET | /api/users | admin |
| POST | /api/users | admin |
| PATCH | /api/users/:id | admin |
| DELETE | /api/users/:id | admin |
| GET | /api/settings | 已登录 |
| PATCH | /api/settings | admin |
| GET | /api/audit/logs | audit.read |
| WS | /api/ws/events | 已登录 |

---

## 11. 版本与变更

| 版本 | 日期 | 说明 |
|------|------|------|
| 1.0.0 | 2026-09 | 初始 Open API 文档 |

如有接口变更，以宿主机 `/opt/kpe/server` 部署版本为准。部署说明见 [DEPLOY.md](./DEPLOY.md)。
