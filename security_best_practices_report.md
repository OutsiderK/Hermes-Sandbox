# Hermes Secure 安全审计报告

审计对象：`/home/coder/workspace/Life/Hermes/hermes-secure`

依据：`/home/coder/workspace/Life/Hermes/Hermes 安全部署需求说明.md`

审计时间：2026-06-28

## 执行摘要

当前实现整体符合需求说明的核心安全目标：Hermes 被设计为可牺牲、可攻陷的容器内执行区，而宿主机文件、Docker 控制面、其他容器、局域网和管理接口均通过 Compose 运行策略、只读挂载、named volume、非 root 用户、能力集裁剪和 netguard 出站防火墙隔离。

本次源码审计未发现以下高危配置：`--privileged`、Docker socket 挂载、host network、host PID/IPC、完整 Windows 用户目录挂载、宿主机敏感目录挂载、Hermes root 运行、Hermes capability 保留、Dashboard 或 mihomo controller 绑定到局域网地址。

旧报告中提到的几项问题在当前代码里已经修复：宿主机路径 reparse-point 检查已加入 PowerShell 启动/导出路径；Hermes UID 的 loopback 访问已收紧为端口 allowlist；exporter 已加入条目数、目录深度、路径长度和 Windows 文件名限制。

剩余问题主要是验证覆盖不足，而不是已经观察到的隔离失效：运行时审计对 mihomo 私网拒绝规则只抽查了 link-local/metadata 网段；netguard 降权后的有效 capability 没有被审计脚本显式检查；当前 Linux 审计环境缺少 Docker Desktop/PowerShell，因此无法替代目标 Windows 宿主机上的真实运行态验证。

## 审计方法与适用指导

使用了 `security-best-practices` 技能。该技能的参考目录没有 Docker Compose、shell/PowerShell 或通用 Python CLI/container runtime 专用指导；项目也不是 FastAPI、Flask、Django 等 Python Web 框架。因此本报告基于需求说明、通用容器隔离安全基线、Python 文件处理安全基线和当前源码静态审计。

已检查的主要资产和入口：

- `compose.yaml`
- `Dockerfile.hermes`
- `netguard/entrypoint.sh`
- `netguard/healthcheck.sh`
- `netguard/tinyproxy.conf`
- `proxy/mihomo.yaml.example`
- `runtime/run-stack.sh`
- `runtime/supervisor.py`
- `runtime/healthcheck.py`
- `runtime/export_outbox.py`
- `scripts/hermes.ps1`
- `scripts/audit.ps1`
- `.dockerignore`
- `.gitignore`
- `README.md`
- `docs/SECURITY.md`

## 已验证的强控制

### 容器权限和宿主机边界

- Hermes 以 `10000:10000` 运行，根文件系统只读，drop all capabilities，启用 `no-new-privileges`，且没有独立发布端口。见 `compose.yaml:142-164`。
- Hermes 使用 `network_mode: "service:netguard"`，没有 host network。见 `compose.yaml:151`。
- Hermes 持久状态是 Docker named volume `/opt/data`，不是 Windows 用户目录 bind。见 `compose.yaml:184-185`。
- 输入目录 `./exchange/inbox` 只读挂载到 `/input`。见 `compose.yaml:186-191`。
- 密钥文件 `./secrets/hermes.env` 只读挂载到 `/opt/data/.env`。见 `compose.yaml:192-197`。
- Dockerfile 最终切换到非 root 用户，并去除基础镜像内常见 setuid/setgid 位。见 `Dockerfile.hermes:16-21`。
- 运行入口拒绝 root、检查根文件系统不可写、检查 `/input` 不可写。见 `runtime/run-stack.sh:4-36`。

### 网络隔离

- 只有 netguard 发布端口，Dashboard 和 mihomo controller 都绑定宿主机 `127.0.0.1`。见 `compose.yaml:76-78`。
- netguard 启动时将 OUTPUT 默认策略设为 DROP。见 `netguard/entrypoint.sh:18-19`。
- Hermes UID 不能直接访问 Docker DNS，并且只允许访问 loopback allowlist 端口，之后拒绝该 UID 的其他出站。见 `netguard/entrypoint.sh:26-29`。
- tinyproxy UID 只能连接本地 mihomo 代理端口 `7890`。见 `netguard/entrypoint.sh:31-34`。
- mihomo UID 被阻断访问 host/LAN/link-local/metadata/multicast/reserved IPv4 网段，只允许配置的公网 TCP 端口。见 `netguard/entrypoint.sh:40-64`。
- IPv6 在共享网络 namespace 中关闭。见 `compose.yaml:82-84` 和 `scripts/audit.ps1:143-144`。
- mihomo 模板显式拒绝私网、metadata、`host.docker.internal` 和 `gateway.docker.internal`，再应用直连/代理规则。见 `proxy/mihomo.yaml.example:39-92`。

### 启动、更新和防绕过

- `start` 会先检查初始化、Dashboard 认证、host path 布局和 Compose 配置，再启动服务。见 `scripts/hermes.ps1:500-504`。
- 启动后自动运行 `scripts/audit.ps1`，失败则停止 Hermes/mihomo/netguard。见 `scripts/hermes.ps1:521-535`。
- `.env.example` 中的可变镜像 tag 会在 `init` / `update` 中锁定为不可变 digest。见 `scripts/hermes.ps1:265-293`。
- 本地密钥、mihomo 配置、输入和导出目录不会进入 Docker build context。见 `.dockerignore:1-8`。
- 本地密钥、mihomo 配置、输入和导出内容被 Git 忽略。见 `.gitignore:1-7`。

### Host bind path 防护

- PowerShell 侧会确认 guarded host path 存在、位于项目根目录下，并拒绝 reparse point。见 `scripts/hermes.ps1:96-154`。
- `start` 和 `export` 均调用 host path 布局检查。见 `scripts/hermes.ps1:500-504` 和 `scripts/hermes.ps1:584-587`。
- `audit.ps1` 也包含相同的本地路径和 reparse-point 检查。见 `scripts/audit.ps1:37-94`。

### 输出导出

- exporter 使用独立工具 profile，无网络，非 root，根文件系统只读；Hermes state volume 在 exporter 中只读，只有 `/export` 可写。见 `compose.yaml:213-238`。
- exporter 拒绝危险 Windows 文件名、符号链接、硬链接、特殊文件，并限制单文件大小、总大小、条目数、深度、相对路径长度和路径组件长度。见 `runtime/export_outbox.py:20-32`、`runtime/export_outbox.py:35-64`、`runtime/export_outbox.py:73-108`。
- export 前会短暂停止 Hermes，使只读源稳定；导出后重新启动并复跑审计。见 `scripts/hermes.ps1:584-609`。

## 高危发现

未发现。

## 中危发现

未发现。

## 低风险发现

### L-1. 运行时审计未逐条覆盖所有 mihomo 私网/保留网段拒绝规则

影响：`netguard/entrypoint.sh` 已阻断多组私网、link-local、metadata、multicast 和 reserved IPv4 网段，但 `scripts/audit.ps1` 只显式 `iptables -C` 检查了 `169.254.0.0/16`，代理负向探针也只访问 `169.254.169.254`。如果后续维护误删 `10.0.0.0/8`、`172.16.0.0/12` 或 `192.168.0.0/16` 等规则，当前审计可能不能第一时间发现。

证据：

- 完整拒绝列表位于 `netguard/entrypoint.sh:42-59`。
- 审计脚本只显式检查 `169.254.0.0/16` 规则。见 `scripts/audit.ps1:166-167`。
- 代理负向测试只覆盖 metadata 地址。见 `scripts/audit.ps1:214-225`。

建议：

- 在 `audit.ps1` 中维护同一组拒绝 CIDR，并逐条 `iptables -C`。
- 增加经代理访问 `10.0.0.1`、`172.16.0.1`、`192.168.0.1`、`host.docker.internal`、`gateway.docker.internal` 的负向探针。
- 长期更优做法是把拒绝 CIDR 列表集中到一个可生成 netguard 与 audit 检查的源文件，减少配置漂移。

### L-2. netguard 降权后的有效 capability 未被运行时审计显式验证

影响：Compose 层必须给 netguard `NET_ADMIN` 来安装网络 namespace 防火墙，然后 `entrypoint.sh` 使用 `setpriv` 将 PID 1 降到 UID 10001 并清空 capability 集。当前 `audit.ps1` 会验证 netguard 容器的声明 capability 和 PID 1 UID，但没有读取 `/proc/1/status` 中的 `CapEff` / `CapBnd` 确认 tinyproxy 进程确实没有保留能力。若未来 `setpriv` 参数被误改，审计覆盖会偏弱。

证据：

- netguard Compose 声明 `NET_ADMIN`、`SETUID`、`SETGID`。见 `compose.yaml:66-75`。
- netguard 用 `setpriv --reuid=10001 --regid=10001 --clear-groups --no-new-privs --inh-caps=-all --ambient-caps=-all --bounding-set=-all` 启动 tinyproxy。见 `netguard/entrypoint.sh:75`。
- 审计脚本验证 capability 声明和 PID 1 UID，但没有验证 `CapEff`。见 `scripts/audit.ps1:136-142`。

建议：

- 在 `audit.ps1` 中读取 `awk '/^CapEff:/ {print $2}' /proc/1/status`，要求为全零。
- 可同时检查 `CapBnd` 为全零或符合预期，以确保 tinyproxy 运行态无法重新获得网络管理能力。

## 运行态验证缺口

当前审计环境没有 Docker、PowerShell 和 ShellCheck，因此未能执行以下目标环境验证：

```powershell
.\scripts\hermes.ps1 init
.\scripts\hermes.ps1 start -Open
.\scripts\hermes.ps1 audit
```

也未能执行：

```text
docker compose --file compose.yaml config --quiet
shellcheck runtime/run-stack.sh netguard/entrypoint.sh netguard/healthcheck.sh
```

这不是源码中已发现的漏洞，但它意味着本报告不能替代 Windows + Docker Desktop 上的真实运行态审计。尤其需要在目标宿主机确认端口绑定、Docker mount 解析、Windows reparse-point 检测、iptables owner 规则、IPv6 sysctl 和容器 healthcheck 均按预期生效。

## 测试结果

已在当前环境执行并通过：

```text
python3 tests/static_check.py
python3 tests/test_runtime.py
python3 -m py_compile runtime/*.py tests/*.py
```

结果：

```text
STATIC CHECK PASSED
RUNTIME TESTS PASSED
```

未执行的运行态测试原因：当前环境没有 `docker`、`pwsh` / `powershell`、`shellcheck`。

## 总体结论

以需求说明的优先级衡量，当前 `hermes-secure` 已经较好实现了第一优先级“保护宿主机”、第二优先级“输入文件不可修改”、第三优先级“容器内高自主权限”和第四优先级“启动简单且不易误配置”。当前没有发现需要立即阻断使用的高危或中危问题。

建议后续优先把两个低风险项补进 `scripts/audit.ps1`，然后在目标 Windows 宿主机跑一次完整 `init/start/audit`，保存通过输出作为后续更新基线。
