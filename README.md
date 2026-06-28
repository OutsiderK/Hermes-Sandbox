# Hermes Secure：Windows + Docker Desktop 安全部署

这是按照以下要求实现的 Hermes 项目骨架：

- Hermes、Dashboard、Gateway 以及 Hermes 启动的子进程始终使用 UID/GID `10000`，不使用 root。
- Windows 人工输入目录只读挂载为 `/input`。
- Hermes 只能写入 Docker named volume 中的 `/opt/data`。
- 输出先写入 `/opt/data/outbox`，再由显式命令导出到 Windows；Hermes 本身看不到宿主机输出目录。
- Web Dashboard 只发布到 `http://127.0.0.1:9119`，并强制使用用户名和密码。
- mihomo 控制器只发布到 `http://127.0.0.1:9090`，用于本机 GUI 切换节点和更新订阅。
- Hermes 没有 Docker socket、宿主机 namespace、Linux capabilities；根文件系统只读。
- HTTP/HTTPS 出站连接必须经过网络守卫代理和 mihomo；Hermes 不能直接连接宿主机、局域网或互联网。
- **不包含自动备份系统**。重要项目请在容器工作区内使用 Git，并推送到可信远端。

英文详细说明见 [`README.en.md`](README.en.md)。

## 哪些部分会使用 root？

**Hermes 容器内不会出现 root 进程。** 只有两个相互隔离、功能很小的辅助容器会使用受限 root 权限：

1. `state-init`：无网络，只能看到 Hermes named volume；负责把卷目录设为 UID 10000 后立即退出。
2. `netguard`：看不到 Hermes 文件、Windows 输入目录和 Docker socket；使用 `NET_ADMIN` 安装自己网络 namespace 内的防火墙规则，并通过 `setpriv` 用 `SETUID`/`SETGID` 将 tinyproxy 降权到 UID 10001，同时清空 tinyproxy 的 capability 集。

另有一个非 root 的 `mihomo` sidecar 使用 UID 10002，与 netguard 共享网络 namespace。Hermes 只与 netguard 共享网络 namespace，不共享文件系统、PID namespace 或用户身份；tinyproxy 只能把请求转发给本机 mihomo，mihomo 根据规则决定直连或走订阅节点。

## 第一次安装

需要：

- Windows 10/11；
- Docker Desktop，并使用 Linux containers；
- Windows PowerShell 5.1 或 PowerShell 7。

在项目目录打开 PowerShell：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\hermes.ps1 init
.\scripts\hermes.ps1 proxy-subscription
.\scripts\hermes.ps1 start -Open
```

`init` 会：

1. 创建本地 `.env` 和 `secrets/hermes.env`；
2. 拉取上游镜像；
3. 将可变 tag 解析并锁定为不可变的 `@sha256:` digest；
4. 创建本地 `proxy\mihomo.yaml` 并生成 mihomo controller secret；
5. 构建非 root Hermes runtime 和网络守卫；
6. 提示设置 Dashboard 用户名和密码，只保存 scrypt 哈希。

启动后访问：

```text
http://127.0.0.1:9119
```

## 日常启动

```powershell
.\scripts\hermes.ps1 start -Open
.\scripts\hermes.ps1 stop
.\scripts\hermes.ps1 status
.\scripts\hermes.ps1 logs
```

也可以直接双击：

```text
Start-Hermes.cmd
Stop-Hermes.cmd
```

创建桌面快捷方式：

```powershell
.\scripts\hermes.ps1 shortcut
```

## 向 Hermes 提供文件

把文件放入：

```text
exchange\inbox\
```

容器内路径是：

```text
/input
```

Docker 挂载参数、容器启动检查和运行时审计都会验证该目录不可写。不要放入不允许 Hermes 阅读或上传的内容。

## 工作区与 Git

Hermes 的默认工作区：

```text
/opt/data/workspace
```

Hermes 可以自由修改、删除其中内容。重要项目应在这里初始化 Git，并推送到可信远端。默认网络策略只支持经代理访问公共 HTTP/HTTPS，因此推荐使用 **Git over HTTPS**，并为 Hermes 配置仓库级、最小权限、可撤销且有限期的访问 token。普通 SSH 22 端口默认被阻断；不要把主账户通用凭据交给 Hermes。

本项目不会自动备份整个状态卷。

## 代理、直连规则和节点切换

Hermes 不能直接联网。实际路径是：

```text
Hermes -> tinyproxy -> mihomo -> DIRECT 或订阅节点
```

设置 Clash/mihomo 订阅 URL：

```powershell
.\scripts\hermes.ps1 proxy-subscription
```

打开 mihomo GUI：

```powershell
.\scripts\hermes.ps1 proxy-ui
```

脚本会显示本机 API 地址 `http://127.0.0.1:9090` 和 controller secret，并打开 `https://d.metacubex.one`。在 GUI 中添加该 API 后即可切换节点、触发 provider 更新。

`proxy\mihomo.yaml` 不提交 Git，也不进入 Docker build context。默认模板采用“大陆域名和大陆 IP 直连，其他走代理节点”的策略，并额外显式保留 Cambridge、Oxford Learners、Gigya、Coursera、Overleaf、NJU box/CMS、DeepSeek、Kimi、Aliyun、Cowtransfer 等你指定的直连域名，方便通过 diff 审核。即使规则写错或 DNS 被污染，netguard 仍会阻断 mihomo 访问私网、宿主机、link-local 和 metadata 地址。

如果你的订阅节点使用非常规 TCP 端口，在 `.env` 里把端口加入 `MIHOMO_TCP_PORTS` 后重新 `restart` 或 `rebuild`。

## API Key 和 Token

宿主机 `secrets\hermes.env` 以只读方式挂载到 `/run/secrets/hermes.env`。容器启动时会把它复制到 tmpfs 中的 `/run/hermes/hermes.env` 作为本次运行副本，Hermes 和 Dashboard 实际读取这个副本。

这意味着容器内进程即使修改运行副本，也只影响当前容器生命周期；下次重启会重新用宿主机原文件覆盖。持久修改仍应从宿主机执行：

例如设置 DeepSeek Key：

```powershell
.\scripts\hermes.ps1 secret-set DEEPSEEK_API_KEY
```

然后在 Dashboard 中选择 provider 和 model。其他常见变量包括：

```text
OPENROUTER_API_KEY
ANTHROPIC_API_KEY
OPENAI_API_KEY
TELEGRAM_BOT_TOKEN
```

请使用专用、最小权限、可撤销并设置额度限制的凭据。

Dashboard 的密钥管理页面不应作为正式持久写入入口；如果它能修改运行副本，该修改也会在容器重启后丢失。更换 Dashboard 密码：

```powershell
.\scripts\hermes.ps1 dashboard-password
```

## 输出方案 A

让 Hermes 把交付文件写到：

```text
/opt/data/outbox
```

显式导出：

```powershell
.\scripts\hermes.ps1 export
```

导出时会短暂停止 Hermes，再启动一个独立的导出容器。该容器：

- UID 10000；
- 无网络；
- 只读挂载 Hermes 状态卷；
- 只有它能写宿主机 `exports\`；
- 拒绝符号链接、硬链接、设备文件、socket、FIFO、不安全 Windows 文件名及超限数据；
- 为导出结果生成 `MANIFEST.sha256`。

导出不会自动删除 outbox。确认结果后执行：

```powershell
.\scripts\hermes.ps1 outbox-clear
```

## 更新

```powershell
.\scripts\hermes.ps1 update
```

该命令会重新锁定上游 digest、重建、重启并执行安全审计，**不会创建状态卷备份**。更新前请先提交并推送重要 Git 项目。

只按当前锁定版本重建：

```powershell
.\scripts\hermes.ps1 rebuild
```

## 重置

```powershell
.\scripts\hermes.ps1 reset
```

这会删除 Hermes named volume，但不会删除：

- `exchange\inbox`；
- `exports`；
- `secrets\hermes.env`；
- 已经推送到外部远端的 Git 仓库。

重置前不会自动备份。

## 安全审计

每次成功启动都会自动执行：

```powershell
.\scripts\hermes.ps1 audit
```

审计会检查实际生效的 Docker 配置，并测试：

- Hermes UID 是否为 10000；
- Hermes 容器中是否存在 UID 0 进程；
- rootfs 和 `/input` 是否不可写；
- `/opt/data/workspace` 是否可写；
- Docker socket、特权模式和危险挂载是否不存在；
- Dashboard 是否只发布到 Windows loopback；
- mihomo controller 是否只发布到 Windows loopback；
- Hermes 是否无法绕过代理直接出站；
- 代理是否拒绝链路本地/metadata 地址；
- tinyproxy 是否只能连接本机 mihomo 端口；
- mihomo 是否非 root、只读 rootfs、仅有受限公网 TCP 出站；
- Dashboard 认证是否实际启用。

审计失败时，启动脚本不会自动打开 Dashboard。

## 功能取舍

- Hermes 不能在运行时执行 `apt install`。需要新的系统包时，应修改 `Dockerfile.hermes`、审核差异并重建。
- 仍可在 `/opt/data` 中使用 Python virtualenv、用户级 pip 包、NPM 项目依赖和独立二进制文件。
- 不遵守标准代理环境变量的程序无法联网；此时应增加用途明确的 sidecar，而不是让 Hermes 接入普通 Docker 网络。
- Hermes 可以读取并上传 `/input`、`/opt/data` 以及你主动交给它的凭据。
- mihomo 订阅链接等价于代理凭据；不要把 `proxy\mihomo.yaml` 提交或导出给 Hermes。
- Docker Desktop、Linux 内核和容器运行时仍属于可信计算基；该设计显著缩小攻击面，但不能保证不存在未知容器逃逸漏洞。

完整设计见：

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/SECURITY.md`](docs/SECURITY.md)
- [`docs/UPDATE.md`](docs/UPDATE.md)
- [`docs/VALIDATION.md`](docs/VALIDATION.md)
