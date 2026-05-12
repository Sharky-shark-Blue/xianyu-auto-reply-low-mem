# 轻量部署指南：103 Linux + 27 Windows + 云端数据库

> 目标架构：512MB 预算内跑完整系统。MySQL/Redis 使用云服务，Chromium 依赖（搜索/扫码）拆到 Windows 27 按需使用。
>
> 详细方案见 `CLAUDE.md` 与计划文件，本文档聚焦「如何操作」。

---

## 目录结构

```
deploy/
├── README.md                           # 本文档
├── dockerfiles/                        # 103 使用的精简 Dockerfile（无 Chromium）
│   ├── backend-web.Dockerfile.lite
│   ├── websocket.Dockerfile.lite
│   └── scheduler.Dockerfile.lite
├── linux-103/                          # 部署在 192.168.1.103
│   ├── docker-compose.yml
│   ├── env/
│   │   ├── backend-web.env.example
│   │   ├── websocket.env.example
│   │   └── scheduler.env.example
│   ├── nginx/
│   │   └── default.conf
│   └── stunnel/
│       └── xianyu.conf.example
└── windows-27/                         # 部署在 192.168.1.27
    ├── backend-web.env.example
    ├── start.bat
    └── stunnel.conf.example
```

---

## 阶段 1：云服务准备（一次性）

### 1.1 TiDB Cloud Serverless（MySQL 替代）

1. 访问 https://tidbcloud.com ，注册并登录
2. 创建 Cluster → 选择 **Serverless Tier**（免费）→ 区域建议 `Singapore` 或 `Tokyo`
3. 集群创建后进入「Connect」面板，记录：
   - `TIDB_HOST`（形如 `gateway01.ap-southeast-1.prod.aws.tidbcloud.com`）
   - `TIDB_PORT`（通常 `4000`）
   - `TIDB_USER`（形如 `xxxxxxxxxxx.root`）
   - `TIDB_PASSWORD`（控制台面板会显示）
4. 用 MySQL 客户端连上（Connect 面板有复制按钮）执行：
   ```sql
   CREATE DATABASE xianyu_data CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   ```
5. 如 TiDB 下发专用 CA，下载保存为 `tidb-ca.pem`；通常使用 Let's Encrypt，用系统 CA 即可

### 1.2 Upstash Redis

1. 访问 https://console.upstash.com ，注册并登录
2. 创建 Database → 区域与 TiDB 对齐（降低延迟）→ 免费 Plan
3. 进入 Details，记录：
   - `UPSTASH_HOST`（形如 `xxx-xxx.upstash.io`）
   - `UPSTASH_PORT`（`6379`，TLS）
   - `UPSTASH_PASSWORD`（Details 面板提供）

### 1.3 共享 JWT 密钥

```bash
openssl rand -hex 32
```

保存为 `SHARED_JWT_SECRET`，**两台机器都用同一个值**。

---

## 阶段 2：Linux 103 部署

### 2.1 安装基础依赖

```bash
# Ubuntu / Debian
sudo apt update
sudo apt install -y docker.io docker-compose-plugin stunnel4 mysql-client redis-tools
sudo usermod -aG docker $USER   # 免 sudo 使用 docker，需重新登录
```

### 2.2 配置 stunnel（系统服务）

```bash
# 复制 CA 证书（TiDB 专用 CA）
sudo cp tidb-ca.pem /etc/stunnel/tidb-ca.pem

# 从仓库复制配置模板
sudo cp deploy/linux-103/stunnel/xianyu.conf.example /etc/stunnel/xianyu.conf

# 编辑替换占位符 <TIDB_HOST>/<TIDB_PORT>/<UPSTASH_HOST>/<UPSTASH_PORT>
sudo nano /etc/stunnel/xianyu.conf

# 启用 stunnel4 默认服务
sudo sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4

# 启动
sudo systemctl enable --now stunnel4
sudo systemctl status stunnel4
```

**验证：**
```bash
mysql -h 127.0.0.1 -P 3306 -u <TIDB_USER> -p<TIDB_PASSWORD>     # 能进去即通
redis-cli -h 127.0.0.1 -p 6380 -a <UPSTASH_PASSWORD> PING        # 返回 PONG
```

### 2.3 准备项目代码

```bash
git clone <repo> ~/xianyu-auto-reply
cd ~/xianyu-auto-reply
```

### 2.4 构建前端产物

```bash
cd frontend
npm install
npm run build
mkdir -p ../deploy/linux-103/frontend-dist
cp -r dist/* ../deploy/linux-103/frontend-dist/
cd ..
```

### 2.5 填写环境变量

```bash
cd deploy/linux-103

# 复制并编辑 3 个 .env
cp env/backend-web.env.example env/backend-web.env
cp env/websocket.env.example   env/websocket.env
cp env/scheduler.env.example   env/scheduler.env
chmod 600 env/*.env

# 将 <TIDB_USER>/<TIDB_PASSWORD>/<UPSTASH_PASSWORD>/<SHARED_JWT_SECRET> 全部替换为实际值
# 三个文件必须使用相同的凭据与 JWT 密钥
nano env/backend-web.env
nano env/websocket.env
nano env/scheduler.env
```

### 2.6 拉取镜像并启动

```bash
cd ~/xianyu-auto-reply/deploy/linux-103
docker compose pull                # 从阿里云镜像仓库拉取（支持 amd64 / arm64）
docker compose up -d
docker compose ps                  # 全部 running
docker compose logs -f backend-web # 确认连接 MySQL/Redis 成功（首次会自动建表）
```

> **镜像来源：** 默认使用作者在 `registry.cn-shanghai.aliyuncs.com/zhinian-software` 发布的多架构镜像，自动适配 x86_64 和 ARM64 宿主，无需本地编译。
>
> **x86_64 宿主可选自建精简版：** 如果想去掉镜像里的 Playwright Chromium（省 ~1.2GB 磁盘），把 `docker-compose.yml` 里三个服务的 `image:` 行换回 `build:` 块指向 `deploy/dockerfiles/*.Dockerfile.lite`，然后 `docker compose build`。ARM 宿主不要这么做（加密 `.so` 是 x86_64 编译，本地 build 出来的 ARM 镜像会 import 失败）。

### 2.7 确认端口与防火墙

- 9000 → 需对局域网开放（前端入口）
- 8089 → 必须允许 27 访问（nginx 分流会反向调用吗？**不会**；但若 27 未部署、直接访问 103 的后端，可用）
- 8090/8091 → 仅 127.0.0.1 内部使用，**不要对外暴露**

---

## 阶段 3：Windows 27 部署

### 3.1 安装前置工具

- Python 3.12.x（64 位）→ 勾选 Add to PATH
- Git for Windows
- stunnel：https://www.stunnel.org/downloads.html

### 3.2 配置 stunnel

1. 安装完成后进入 `C:\Program Files (x86)\stunnel\config\`
2. 将 `deploy/windows-27/stunnel.conf.example` 内容保存为 `stunnel.conf`，替换占位符
3. 如果 TiDB 使用专用 CA，将证书保存为同目录下的 `tidb-ca.pem`；否则把 Windows 根证书导出或复用 Let's Encrypt ISRG Root X1
4. 开始菜单 → stunnel → **Install stunnel service** → **Start stunnel service**

**验证：**
```powershell
Test-NetConnection 127.0.0.1 -Port 3306
Test-NetConnection 127.0.0.1 -Port 6380
```

### 3.3 克隆项目与安装依赖

```powershell
git clone <repo> F:\xianyu-search\xianyu-auto-reply
cd F:\xianyu-search\xianyu-auto-reply\backend-web
python -m venv .venv
.venv\Scripts\activate
pip install -e .
python -m playwright install chromium
```

### 3.4 配置环境变量

```powershell
# 复制模板
copy ..\deploy\windows-27\backend-web.env.example .env

# 编辑替换占位符
notepad .env
```

**关键确认：**
- `JWT_SECRET_KEY` 与 103 完全一致
- `WEBSOCKET_SERVICE_URL=http://192.168.1.103:8090`
- `SCHEDULER_SERVICE_URL=http://192.168.1.103:8091`
- `AUTO_START_CRAWL_JOBS=false`

### 3.5 启动脚本

```powershell
# 复制并按需修改路径
copy F:\新建文件夹 (2)\xianyu-auto-reply\deploy\windows-27\start.bat F:\xianyu-search\start.bat
```

双击 `F:\xianyu-search\start.bat` 启动。看到 `Uvicorn running on http://0.0.0.0:8089` 即成功。

**关闭：** 直接关闭命令行窗口即可。

---

## 阶段 4：功能验证

### 4.1 27 关机状态（日常态）

打开浏览器访问 `http://192.168.1.103:9000`：

| 功能 | 预期 |
|------|------|
| 登录页 | 正常显示，能登录管理员账号 |
| 账号管理 / 消息 / 订单 | 正常 |
| 商品搜索（/items/search） | 约 3 秒超时，前端提示「网络错误 / 搜索失败」 |
| 扫码登录（添加新账号） | 同上，失败 |
| 其他功能 | 不受影响 |

### 4.2 27 开机（搜索态）

1. 在 27 上双击 `start.bat` 启动
2. 前端继续从 103 的 9000 端口访问（无需切换）
3. 点商品搜索 → 能返回结果
4. 添加新账号扫码 → QR 码在前端显示（由 27 生成），手机扫码后登录成功

### 4.3 数据一致性

- 在 27 上扫码登录的账号，关闭 27 后，103 的 websocket 服务应能继续接入该账号的闲鱼 IM（Cookie 已存 TiDB）
- 在 103 上设置的自动回复规则，27 开机后访问搜索页应能看到同样的账号列表

---

## 关键已知问题与应对

### ❗ stunnel TLS 配置若失败

TiDB/Upstash 的证书验证可能因 CA 文件路径差异报错。错误信息在 `/var/log/stunnel4/xianyu.log`（Linux）或 `stunnel.log`（Windows）。

**临时放宽验证（仅调试）：**
```ini
verifyChain = no
```
线上务必恢复 `verifyChain = yes`。

### ❗ Upstash 免费额度不够

默认每天 10,000 命令。若 Redis 限流/锁频繁使用导致超额，Upstash 会拒绝命令而不是静默丢弃——表现为 backend-web 日志报 Redis 连接异常。

**应对：** 升级 Upstash 付费计划（$0.2/10K 命令），或换为 Redis Cloud 30MB 免费套餐。

### ❗ TiDB Serverless 连接池限制

Serverless 单集群默认 256 最大连接。项目 3 个服务 × `pool_size=50, max_overflow=100` 理论最高 450，容易超。

**应对：** 在 Redis/MySQL 连接池不够时会超时，可手动在 `.env` 中降低（注：无此环境变量支持，需考虑是否改为付费 TiDB）。实际运行中连接数达不到峰值，先观察。

### ❗ QR 码回显

QR 扫码图片由 27 生成，通过 nginx 分流返回前端。图片流 URL 形如 `/api/v1/qr-login/<id>/image`，已被规则匹配，能正常代理。无需额外配置。

### ❗ 首次启动建表竞态

103 与 27 首次启动时都会尝试 `CREATE TABLE IF NOT EXISTS`。**先启动 103 等其完成启动（看到 "应用启动完成" 日志），再启动 27。**

---

## 常用命令速查

### Linux 103

```bash
# 查看服务状态
docker compose -f ~/xianyu-auto-reply/deploy/linux-103/docker-compose.yml ps

# 查看某个服务日志
docker compose logs -f backend-web
docker compose logs -f websocket

# 重启某个服务
docker compose restart backend-web

# 查看资源使用
docker stats --no-stream

# stunnel 状态
sudo systemctl status stunnel4
sudo tail -f /var/log/stunnel4/xianyu.log
```

### Windows 27

```powershell
# 查看 stunnel 服务
Get-Service stunnel

# 查看 Python 进程
Get-Process python

# 停止（PID 从 start.bat 窗口看到，或杀所有 python）
Stop-Process -Name python -Force
```

---

## 安全提醒

1. **所有 `.env` 文件禁止进 git**：仓库 `.gitignore` 已覆盖
2. **`chmod 600 env/*.env`**：防止其他用户读取
3. **防火墙**：
   - 103 对外开 9000（前端）
   - 103 的 8089 仅允许 27 访问（可用 `iptables -A INPUT -p tcp --dport 8089 -s 192.168.1.27 -j ACCEPT` 白名单）
   - 27 的 8089 仅允许 103 访问
4. **JWT_SECRET_KEY 泄露**：立即在所有 `.env` 更新并重启服务
5. **云凭据泄露**：TiDB/Upstash 控制台重置密码

---

## 后续优化方向

- 若 Chromium 使用频率高：把 27 改为常开，或考虑 103 升级内存
- 若 27 IP 变化：建议给 27 配置固定 IP 或用内网 DNS
- 监控：可接入 Uptime Kuma（10MB 内存）监测 103 和 27 的健康
