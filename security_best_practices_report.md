# Hermes Secure 安全审计报告

审计对象：`/home/coder/workspace/Life/Hermes/hermes-secure`

依据：`/home/coder/workspace/Life/Hermes/Hermes 安全部署需求说明.md`

审计日期：2026-06-28

## 执行摘要

当前实现总体符合需求说明的核心安全模型：把 Hermes 视为可被攻陷、可牺牲的容器内执行区，同时通过 Docker Desktop/Linux 容器边界、非 root 用户、只读挂载、named volume、能力集裁剪、localhost 端口发布和 netguard 出站策略保护 Windows 宿主机、Docker 控制面、其他容器、局域网和用户原始输入文件。

本次源码审计未发现 `privileged`、Docker socket 挂载、host network、host PID/IPC、Windows 用户目录/系统盘挂载、Hermes root 运行、Hermes capability 保留、Dashboard 或 mihomo controller 暴露到局域网的证据。

需要优先处理的是一个网络策略细节：`netguard/entrypoint.sh` 当前存在 ownerless Docker DNS allow 规则。Hermes UID 本身仍被前置规则拒绝，不能直接使用 Docker DNS；但 tinyproxy UID 理论上仍可触达 Docker embedded DNS，这和“中间代理只能转发到 mihomo sidecar”的目标不完全一致，也给 tinyproxy 被利用后的 DNS 外带留下了窄通道。其余问题主要是审计覆盖和可重现性增强项。

## 审计范围与方法

使用了 `security-best-practices` 技能。该技能没有 Docker Compose、shell/PowerShell 或通用 Python CLI/container runtime 的专用参考文件；项目也不是 FastAPI、Flask、Django 等 Python Web 框架。因此本报告主要基于需求说明、通用容器隔离基线、Python 文件处理安全基线和当前源码静态审计。

重点检查文件：

- `compose.yaml`
- `Dockerfile.hermes`
- `netguard/entrypoint.sh`
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

当前工作树已有未提交改动：`netguard/entrypoint.sh`、`netguard/tinyproxy.conf` 被修改，旧的 `security_best_practices_report.md` 处于删除状态。本报告按当前工作树内容审计，未回滚这些改动。

## 已验证的强控制

### 容器权限和宿主机边界

- Hermes 以 `10000:10000` 运行，根文件系统只读，drop all capabilities，启用 `no-new-privileges`，并且没有单独发布端口。见 `compose.yaml:142-164`。
- Hermes 使用 `network_mode: "service:netguard"`，没有 host network。见 `compose.yaml:151`。
- Hermes 持久状态是 Docker named volume `/opt/data`，不是 Windows 用户目录 bind。见 `compose.yaml:184-185`。
- 输入目录 `./exchange/inbox` 只读挂载到 `/input`。见 `compose.yaml:186-191`。
- 密钥源文件 `./secrets/hermes.env` 只读挂载到 `/run/secrets/hermes.env`，启动时复制到 tmpfs 中的 `/run/hermes/hermes.env` 作为运行副本。见 `compose.yaml:179-180`、`compose.yaml:193-198` 和 `runtime/run-stack.sh:38-60`。
- Dockerfile 最终切换到非 root 用户，并移除常见 setuid/setgid 位。见 `Dockerfile.hermes:16-21`。
- 运行入口拒绝 root、检查 rootfs 不可写、检查 `/input` 不可写。见 `runtime/run-stack.sh:4-36`。

### 网络隔离

- 只有 netguard 发布端口，Dashboard 和 mihomo controller 都绑定宿主机 `127.0.0.1`。见 `compose.yaml:76-78`。
- netguard 启动时将 OUTPUT 默认策略设为 DROP。见 `netguard/entrypoint.sh:18-19`。
- Hermes UID 不能直接访问 Docker DNS，并且只允许访问 loopback allowlist 端口，之后拒绝该 UID 的其他出站。见 `netguard/entrypoint.sh:26-29`。
- tinyproxy UID 只能连接本地 mihomo 代理端口 `7890`，但 DNS 例外见 M-1。见 `netguard/entrypoint.sh:39-40`。
- mihomo UID 被阻断访问 host/LAN/link-local/metadata/multicast/reserved IPv4 网段，只允许配置的公网 TCP 端口。见 `netguard/entrypoint.sh:67-89`。
- IPv6 在共享网络 namespace 中关闭。见 `compose.yaml:82-84`。
- mihomo 模板显式拒绝私网、metadata、`host.docker.internal` 和 `gateway.docker.internal`，再应用直连/代理规则。见 `proxy/mihomo.yaml.example:39-92`。

### 启动、更新和防绕过

- `start` 会先检查初始化、Dashboard 认证、host path 布局和 Compose 配置，再启动服务。见 `scripts/hermes.ps1:564-589`。
- 启动后自动运行 `scripts/audit.ps1`，失败则停止 Hermes/mihomo/netguard。见 `scripts/hermes.ps1:591-599`。
- `.env.example` 中的可变镜像 tag 会在 `init` / `update` 中锁定为不可变 digest。见 `scripts/hermes.ps1:286-357`。
- 本地密钥、mihomo 配置、输入和导出目录不会进入 Docker build context。见 `.dockerignore:1-8`。
- 本地 `.env`、`secrets/hermes.env`、`proxy/mihomo.yaml` 被 Git 忽略，且当前未被 Git 跟踪。见 `.gitignore:1-3`。

### Host bind path 防护

- PowerShell 侧确认 guarded host path 存在、位于项目根目录下，并拒绝 reparse point。见 `scripts/hermes.ps1:117-175`。
- `start` 和 `export` 均调用 host path 布局检查。见 `scripts/hermes.ps1:564-568` 和 `scripts/hermes.ps1:648-650`。
- `audit.ps1` 也包含相同的本地路径和 reparse-point 检查。见 `scripts/audit.ps1:45-102`。

### 输出导出

- exporter 使用独立 tools profile，无网络，非 root，根文件系统只读；Hermes state volume 在 exporter 中只读，只有 `/export` 可写。见 `compose.yaml:213-238`。
- exporter 拒绝危险 Windows 文件名、符号链接、硬链接、特殊文件，并限制单文件大小、总大小、条目数、深度、相对路径长度和路径组件长度。见 `runtime/export_outbox.py:20-32`、`runtime/export_outbox.py:35-64`、`runtime/export_outbox.py:73-108`。
- export 前会短暂停止 Hermes，使只读源稳定；导出后重新启动并复跑审计。见 `scripts/hermes.ps1:648-674`。

## Critical

未发现。

## High

未发现。

## Medium

### M-1. netguard 的 ownerless Docker DNS allow 规则给 tinyproxy UID 留下 DNS 外带通道

Rule ID: HERMES-NET-001

Severity: Medium

Location: `netguard/entrypoint.sh:31-40`

Evidence:

```sh
iptables -w -A OUTPUT -d 127.0.0.11/32 -p udp --dport 53 -j ACCEPT
iptables -w -A OUTPUT -d 127.0.0.11/32 -p tcp --dport 53 -j ACCEPT
iptables -w -A OUTPUT -m owner --uid-owner "$PROXY_UID" -o lo -p tcp --dport 7890 -j ACCEPT
iptables -w -A OUTPUT -m owner --uid-owner "$PROXY_UID" -j REJECT --reject-with icmp-port-unreachable
```

Impact: Hermes UID 的 DNS 已被前置规则拒绝，但上述 ownerless DNS allow 位于 tinyproxy UID 的 reject 之前，因此 tinyproxy UID 仍可访问 Docker embedded DNS。正常配置下 tinyproxy upstream 是 `127.0.0.1:7890`，不需要解析目标域名；但若 tinyproxy 或 netguard 内进程被利用，该 DNS 通道可能绕过“tinyproxy 只能转发到 mihomo”的代理链路，向 Docker DNS/宿主 DNS 外带少量数据。

Fix: 优先把 Docker DNS allow 规则改成只允许 mihomo UID。如果确实需要解决 Docker DNS DNAT 后 owner match 不稳定的问题，建议把例外限制到 mihomo UID 的 loopback rewritten DNS 规则，并用运行态测试证明 mihomo 可解析、PROXY_UID 不可解析。

Mitigation: 在 `scripts/audit.ps1` 中增加 PROXY_UID 负向测试，例如在 netguard 容器内以 UID 10001 尝试连接 `127.0.0.11:53`，期望失败；同时确认 tinyproxy 仍可通过 `127.0.0.1:7890` 转发。

False positive notes: 如果 Docker Desktop/iptables 在目标环境中确实无法用 owner match 限制 rewritten DNS，需要保留某种 DNS 例外；但该例外应有注释解释具体内核/Docker 行为，并由审计脚本验证不会扩展成通用出站能力。

## Low

### L-1. 运行时审计未逐条覆盖所有 mihomo 私网/保留网段拒绝规则

Rule ID: HERMES-AUDIT-001

Severity: Low

Location: `netguard/entrypoint.sh:67-89`, `scripts/audit.ps1:178-179`, `scripts/audit.ps1:226-237`

Evidence:

```sh
for cidr in \
  0.0.0.0/8 \
  10.0.0.0/8 \
  ...
  192.168.0.0/16 \
  ...
  240.0.0.0/4; do
  iptables -w -A OUTPUT -m owner --uid-owner "$MIHOMO_UID" -d "$cidr" -j REJECT --reject-with icmp-port-unreachable
done
```

`audit.ps1` 当前只显式 `iptables -C` 检查 `169.254.0.0/16`，代理负向探针也只覆盖 `169.254.169.254`。

Impact: 如果后续维护误删 `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 等拒绝规则，当前运行时审计可能不能第一时间发现。

Fix: 在 `audit.ps1` 中维护与 netguard 相同的拒绝 CIDR 列表，并逐条 `iptables -C`。再增加经代理访问 `10.0.0.1`、`172.16.0.1`、`192.168.0.1`、`host.docker.internal`、`gateway.docker.internal` 的负向探针。

Mitigation: 把拒绝 CIDR 列表集中到单一源文件或生成脚本，减少 netguard 与 audit 漂移。

False positive notes: 当前源码中的拒绝规则本身是完整的；问题是验证覆盖不足。

### L-2. netguard 降权后的有效 capability 未被运行时审计显式验证

Rule ID: HERMES-AUDIT-002

Severity: Low

Location: `compose.yaml:66-75`, `netguard/entrypoint.sh:102`, `scripts/audit.ps1:144-152`

Evidence:

```sh
exec setpriv --reuid=10001 --regid=10001 --clear-groups --no-new-privs --inh-caps=-all --ambient-caps=-all --bounding-set=-all tinyproxy -d -c /etc/tinyproxy/secure.conf
```

`audit.ps1` 验证了 netguard 容器声明的 capability 和 PID 1 UID，但没有读取 `/proc/1/status` 中的 `CapEff` / `CapBnd`。

Impact: 如果未来 `setpriv` 参数被误改，审计脚本可能只看到 PID 1 已降到 UID 10001，却没有发现 tinyproxy 仍保留 capability。

Fix: 在 `audit.ps1` 中读取 `awk '/^CapEff:/ {print $2}' /proc/1/status`，要求为全零；可同时检查 `CapBnd` 为全零。

Mitigation: 在 `tests/static_check.py` 中也加入对 `--bounding-set=-all`、`--ambient-caps=-all`、`--inh-caps=-all` 的静态断言。

False positive notes: 当前 `entrypoint.sh` 的 `setpriv` 参数看起来是正确的；问题是运行态审计覆盖不足。

### L-3. netguard 镜像构建中的 apt 包未锁定到快照或版本

Rule ID: HERMES-SUPPLY-001

Severity: Low

Location: `netguard/Dockerfile:4-7`

Evidence:

```dockerfile
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         ca-certificates iptables tinyproxy procps util-linux \
    && rm -rf /var/lib/apt/lists/*
```

Impact: `.env.example` 和脚本会把基础镜像锁到 digest，但 `apt-get update && apt-get install` 仍会随 Debian 仓库状态漂移。同一个源码和同一个基础镜像 digest 在不同日期重建，可能获得不同 tinyproxy/iptables/util-linux 包版本，降低更新 diff 可审计性和可重现性。

Fix: 对安全优先部署，可以使用 Debian snapshot 仓库、记录并审核 `apt-cache policy` / SBOM，或在更新流程中输出 netguard 包版本 diff。

Mitigation: 在 `scripts/hermes.ps1 update` 后追加 `docker run --rm hermes-secure-netguard:local dpkg-query -W ...` 的版本摘要，作为人工审核材料。

False positive notes: 不锁 apt 包有利于拿到安全更新；这里不是立即漏洞，而是与需求中的“更新前后可 diff 审核、可重现性”存在张力。

## Operational Notes

### 本地 mihomo 配置含敏感值，但当前未被 Git 跟踪

`proxy/mihomo.yaml` 是本地实际配置，包含 mihomo controller secret 和 Clash subscription URL/token。该文件被 `.gitignore:3` 和 `.dockerignore:4` 忽略，当前 `git ls-files .env secrets/hermes.env proxy/mihomo.yaml` 为空，说明未被 Git 跟踪。

报告中未复述任何 secret/token。后续注意不要把 `proxy/mihomo.yaml` 贴到 issue、聊天记录或导出目录中。

### Dashboard 容器内绑定 0.0.0.0 是当前架构需要

`runtime/supervisor.py:136-139` 将 Dashboard 绑定到容器共享网络 namespace 的 `0.0.0.0:9119`。这不是宿主机 LAN 暴露，因为宿主机端口发布由 `compose.yaml:76-78` 限制为 `127.0.0.1`。运行态仍应通过 `scripts/audit.ps1` 验证 Docker 实际 PortBindings。

### 被攻陷容器可以控制它暴露给本机浏览器的内容

需求已假设 Hermes 容器可被完全攻陷。若 Hermes/Dashboard 进程被攻陷，本机浏览器访问 `http://127.0.0.1:9119` 时看到的页面也不应被视为可信管理界面。当前设计主要保护宿主机文件和 Docker 控制面，不等同于对浏览器零风险。建议日常只在可信浏览器配置中使用该 localhost UI，不在其中输入宿主机主账户密码或高价值凭据。

## 运行态验证缺口

当前审计环境没有 `docker`、`powershell`/`pwsh` 和 `shellcheck`，因此未能执行目标 Windows + Docker Desktop 上的完整运行态检查：

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

这不是源码中已发现的漏洞，但意味着本报告不能替代目标宿主机上的真实运行态审计。尤其需要在 Windows Docker Desktop 上确认端口绑定、bind mount 只读、reparse-point 检测、iptables owner 规则、IPv6 sysctl 和 healthcheck 均按预期生效。

## 已执行测试

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

## 总体结论

以需求说明的优先级衡量，当前 `hermes-secure` 已较好实现“保护宿主机”“输入文件不可修改”“容器内高自主权限”和“启动简单且不易误配置”。当前没有发现需要立即阻断使用的 Critical/High 问题。

建议下一步优先修复 M-1，确保 tinyproxy UID 不能访问 Docker DNS；随后把 L-1/L-2 补进 `scripts/audit.ps1`，并在目标 Windows 宿主机跑一次完整 `init/start/audit`，把通过结果作为后续更新基线。
