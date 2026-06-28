[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ComposeFile = Join-Path $ProjectRoot 'compose.yaml'
$Failures = [System.Collections.Generic.List[string]]::new()
$Warnings = [System.Collections.Generic.List[string]]::new()
$GuardedHostPaths = @(
    'exchange\inbox',
    'exports',
    'secrets',
    'proxy',
    'secrets\hermes.env',
    'proxy\mihomo.yaml'
)

function Pass([string]$Message) { Write-Host "[PASS] $Message" -ForegroundColor Green }
function Fail([string]$Message) { $Failures.Add($Message); Write-Host "[FAIL] $Message" -ForegroundColor Red }
function Warn([string]$Message) { $Warnings.Add($Message); Write-Host "[WARN] $Message" -ForegroundColor Yellow }

function Docker-Capture([string[]]$Arguments) {
    $output = & docker @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output | Out-String) }
    return (($output | Out-String).Trim())
}

function Compose-Capture([string[]]$Arguments) {
    return Docker-Capture (@('compose', '--file', $ComposeFile) + $Arguments)
}

function Expect([bool]$Condition, [string]$Good, [string]$Bad) {
    if ($Condition) { Pass $Good } else { Fail $Bad }
}

function Normalize-CapabilityName([string]$Name) {
    $normalized = $Name.ToUpperInvariant()
    if ($normalized.StartsWith('CAP_')) {
        $normalized = $normalized.Substring(4)
    }
    return $normalized
}

function Get-NormalizedFullPath([string]$Path) {
    $trimChars = @(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    return [System.IO.Path]::GetFullPath($Path).TrimEnd($trimChars)
}

function Test-IsUnderProjectRoot([string]$FullPath) {
    $root = Get-NormalizedFullPath $ProjectRoot
    if ($FullPath -eq $root) {
        return $true
    }
    foreach ($separator in @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) {
        if ($FullPath.StartsWith($root + $separator, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-SafeHostPath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $fullPath = Get-NormalizedFullPath $Path
    if (-not (Test-IsUnderProjectRoot $fullPath)) {
        return $false
    }

    $root = Get-NormalizedFullPath $ProjectRoot
    $current = $fullPath
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $attributes = [System.IO.File]::GetAttributes($current)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $false
            }
        }
        if ($current -eq $root) {
            return $true
        }
        $parent = [System.IO.Directory]::GetParent($current)
        if (-not $parent) {
            return $false
        }
        $current = Get-NormalizedFullPath $parent.FullName
        if (-not (Test-IsUnderProjectRoot $current)) {
            return $false
        }
    }
}

foreach ($relative in $GuardedHostPaths) {
    $path = Join-Path $ProjectRoot $relative
    Expect (Test-SafeHostPath $path) "Host path is local and not a reparse point: $relative" "Host path is missing, outside the project, or a reparse point: $relative"
}

try {
    $hermes = (Docker-Capture @('inspect', 'hermes-secure-hermes') | ConvertFrom-Json)[0]
    $netguard = (Docker-Capture @('inspect', 'hermes-secure-netguard') | ConvertFrom-Json)[0]
    $mihomo = (Docker-Capture @('inspect', 'hermes-secure-mihomo') | ConvertFrom-Json)[0]
}
catch {
    Write-Host '[FAIL] Hermes containers are not running or inspectable.' -ForegroundColor Red
    exit 1
}

Expect ($hermes.Config.User -eq '10000:10000') 'Hermes container user is UID/GID 10000.' "Unexpected Hermes user: $($hermes.Config.User)"
Expect (-not $hermes.HostConfig.Privileged) 'Hermes is not privileged.' 'Hermes is privileged.'
Expect ($hermes.HostConfig.ReadonlyRootfs) 'Hermes root filesystem is read-only.' 'Hermes root filesystem is writable.'
Expect (($hermes.HostConfig.CapDrop -contains 'ALL') -and (-not $hermes.HostConfig.CapAdd)) 'All Hermes Linux capabilities are dropped.' 'Hermes capabilities are not fully dropped.'
Expect (($hermes.HostConfig.SecurityOpt -contains 'no-new-privileges:true') -or ($hermes.HostConfig.SecurityOpt -contains 'no-new-privileges')) 'no-new-privileges is active.' 'no-new-privileges is missing.'
Expect ($hermes.HostConfig.NetworkMode -like 'container:*') 'Hermes shares only the netguard network namespace.' "Unexpected network mode: $($hermes.HostConfig.NetworkMode)"
Expect (-not $hermes.HostConfig.PidMode) 'Hermes does not share the host PID namespace.' 'Hermes uses a shared PID namespace.'
Expect (-not $hermes.HostConfig.IpcMode -or $hermes.HostConfig.IpcMode -eq 'private') 'Hermes does not share host IPC.' "Unexpected IPC mode: $($hermes.HostConfig.IpcMode)"

$mountMap = @{}
foreach ($mount in $hermes.Mounts) { $mountMap[$mount.Destination] = $mount }
Expect ($mountMap.ContainsKey('/opt/data') -and $mountMap['/opt/data'].RW -and $mountMap['/opt/data'].Type -eq 'volume') 'State is a writable Docker volume at /opt/data.' '/opt/data state volume is missing, not a volume, or read-only.'
Expect ($mountMap.ContainsKey('/input') -and -not $mountMap['/input'].RW -and $mountMap['/input'].Type -eq 'bind') '/input is a read-only bind mount.' '/input is not a read-only bind mount.'
Expect ($mountMap.ContainsKey('/run/secrets/hermes.env') -and -not $mountMap['/run/secrets/hermes.env'].RW -and $mountMap['/run/secrets/hermes.env'].Type -eq 'bind') 'Secret source is a read-only bind mount.' 'Secret source is missing, writable, or not a bind mount.'

$allowedMounts = @('/opt/data', '/input', '/run/secrets/hermes.env')
$unexpectedMounts = @($mountMap.Keys | Where-Object { $_ -notin $allowedMounts })
Expect ($unexpectedMounts.Count -eq 0) 'Hermes has only the approved state, input and secret-source mounts.' "Unexpected Hermes mount destinations: $($unexpectedMounts -join ', ')"

$dangerPattern = '(?i)(docker[._-]?sock|docker_engine|DockerDesktop|\.ssh(?:[/\\]|$)|\.gnupg(?:[/\\]|$)|[/\\]Windows(?:[/\\]|$))'
$dangerousSources = @($hermes.Mounts | Where-Object { [string]$_.Source -match $dangerPattern } | ForEach-Object { [string]$_.Source })
Expect ($dangerousSources.Count -eq 0) 'No Docker control, SSH, GPG, or Windows system source is mounted.' "Dangerous mount source detected: $($dangerousSources -join ', ')"
Expect (-not $hermes.HostConfig.Devices -or $hermes.HostConfig.Devices.Count -eq 0) 'No host device is passed to Hermes.' 'Hermes has host device passthrough.'

$bindings = $netguard.HostConfig.PortBindings.'9119/tcp'
$portOk = $bindings -and $bindings.Count -eq 1 -and $bindings[0].HostIp -eq '127.0.0.1'
Expect $portOk 'Dashboard is published only on host loopback.' 'Dashboard is not restricted to 127.0.0.1.'
$controllerBindings = $netguard.HostConfig.PortBindings.'9090/tcp'
$controllerPortOk = $controllerBindings -and $controllerBindings.Count -eq 1 -and $controllerBindings[0].HostIp -eq '127.0.0.1'
Expect $controllerPortOk 'mihomo controller is published only on host loopback.' 'mihomo controller is not restricted to 127.0.0.1.'
$expectedNetguardCaps = @('NET_ADMIN', 'SETGID', 'SETUID') | Sort-Object
$actualNetguardCaps = @($netguard.HostConfig.CapAdd | ForEach-Object { Normalize-CapabilityName ([string]$_) } | Sort-Object)
$actualNetguardDrops = @($netguard.HostConfig.CapDrop | ForEach-Object { Normalize-CapabilityName ([string]$_) })
$netguardCapsOk = @(Compare-Object $expectedNetguardCaps $actualNetguardCaps).Count -eq 0 -and ($actualNetguardDrops -contains 'ALL')
Expect $netguardCapsOk 'Netguard has only NET_ADMIN plus temporary UID/GID drop capabilities.' "Netguard capability set is unexpected. CapAdd=$($actualNetguardCaps -join ',') CapDrop=$($actualNetguardDrops -join ',')"
Expect (-not $netguard.Mounts -or $netguard.Mounts.Count -eq 0) 'Netguard has no filesystem mounts.' 'Netguard unexpectedly has filesystem mounts.'
Expect (-not $netguard.HostConfig.Devices -or $netguard.HostConfig.Devices.Count -eq 0) 'Netguard has no host device passthrough.' 'Netguard has host device passthrough.'
$netguardPidOneUid = Docker-Capture @('exec', 'hermes-secure-netguard', 'sh', '-c', "awk '/^Uid:/ {print `$2}' /proc/1/status")
Expect ($netguardPidOneUid -eq '10001') 'Netguard PID 1 dropped to proxy UID 10001.' "Netguard PID 1 UID is $netguardPidOneUid"
$ipv6Disabled = Docker-Capture @('exec', 'hermes-secure-netguard', 'cat', '/proc/sys/net/ipv6/conf/all/disable_ipv6')
Expect ($ipv6Disabled -eq '1') 'IPv6 is disabled in the shared network namespace.' "IPv6 disable flag is $ipv6Disabled"

Expect ($mihomo.Config.User -eq '10002:10002') 'mihomo container user is UID/GID 10002.' "Unexpected mihomo user: $($mihomo.Config.User)"
Expect ($mihomo.HostConfig.ReadonlyRootfs) 'mihomo root filesystem is read-only.' 'mihomo root filesystem is writable.'
Expect (-not $mihomo.HostConfig.Privileged) 'mihomo is not privileged.' 'mihomo is privileged.'
Expect (($mihomo.HostConfig.CapDrop -contains 'ALL') -and (-not $mihomo.HostConfig.CapAdd)) 'mihomo has no Linux capabilities.' 'mihomo capabilities are not fully dropped.'
Expect (($mihomo.HostConfig.SecurityOpt -contains 'no-new-privileges:true') -or ($mihomo.HostConfig.SecurityOpt -contains 'no-new-privileges')) 'mihomo has no-new-privileges.' 'mihomo no-new-privileges is missing.'
Expect ($mihomo.HostConfig.NetworkMode -like 'container:*') 'mihomo shares only the netguard network namespace.' "Unexpected mihomo network mode: $($mihomo.HostConfig.NetworkMode)"
Expect (-not $mihomo.HostConfig.Devices -or $mihomo.HostConfig.Devices.Count -eq 0) 'mihomo has no host device passthrough.' 'mihomo has host device passthrough.'
$mihomoMountMap = @{}
foreach ($mount in $mihomo.Mounts) { $mihomoMountMap[$mount.Destination] = $mount }
Expect ($mihomoMountMap.ContainsKey('/etc/mihomo/config.yaml') -and -not $mihomoMountMap['/etc/mihomo/config.yaml'].RW -and $mihomoMountMap['/etc/mihomo/config.yaml'].Type -eq 'bind') 'mihomo config is a read-only bind mount.' 'mihomo config is missing, writable, or not a bind mount.'
Expect ($mihomoMountMap.ContainsKey('/var/lib/mihomo') -and $mihomoMountMap['/var/lib/mihomo'].RW -and $mihomoMountMap['/var/lib/mihomo'].Type -eq 'volume') 'mihomo state is a writable Docker volume.' 'mihomo state volume is missing, not a volume, or read-only.'
$mihomoDangerousSources = @($mihomo.Mounts | Where-Object { [string]$_.Source -match $dangerPattern } | ForEach-Object { [string]$_.Source })
Expect ($mihomoDangerousSources.Count -eq 0) 'mihomo has no dangerous host mount sources.' "Dangerous mihomo mount source detected: $($mihomoDangerousSources -join ', ')"

$hermesLoopbackRule = Docker-Capture @('exec', 'hermes-secure-netguard', 'sh', '-c', 'iptables -w -C OUTPUT -m owner --uid-owner 10000 -o lo -p tcp -m multiport --dports "$HERMES_LOOPBACK_TCP_PORTS" -j ACCEPT && echo ok')
Expect ($hermesLoopbackRule -eq 'ok') 'Hermes UID has only the audited local TCP port allowlist.' 'Hermes loopback TCP allowlist rule is missing.'
$dockerDnsRule = Docker-Capture @('exec', 'hermes-secure-netguard', 'sh', '-c', 'iptables -w -C OUTPUT -d 127.0.0.11/32 -p udp --dport 53 -j ACCEPT && iptables -w -C OUTPUT -d 127.0.0.11/32 -p tcp --dport 53 -j ACCEPT && echo ok')
Expect ($dockerDnsRule -eq 'ok') 'Docker embedded DNS is available for sidecar bootstrap only.' 'Docker embedded DNS bootstrap rule is missing.'
$tinyproxyRule = Docker-Capture @('exec', 'hermes-secure-netguard', 'sh', '-c', 'iptables -w -C OUTPUT -m owner --uid-owner 10001 -o lo -p tcp --dport 7890 -j ACCEPT && echo ok')
Expect ($tinyproxyRule -eq 'ok') 'tinyproxy UID can only reach local mihomo proxy port.' 'tinyproxy-to-mihomo firewall rule is missing.'
$mihomoPublicRule = Docker-Capture @('exec', 'hermes-secure-netguard', 'sh', '-c', 'iptables -w -C OUTPUT -m owner --uid-owner 10002 -p tcp -m multiport --dports "$MIHOMO_TCP_PORTS" -j ACCEPT && echo ok')
Expect ($mihomoPublicRule -eq 'ok') 'mihomo UID has the audited public TCP allowlist.' 'mihomo public TCP allowlist rule is missing.'
$mihomoPrivateRule = Docker-Capture @('exec', 'hermes-secure-netguard', 'sh', '-c', 'iptables -w -C OUTPUT -m owner --uid-owner 10002 -d 169.254.0.0/16 -j REJECT --reject-with icmp-port-unreachable && echo ok')
Expect ($mihomoPrivateRule -eq 'ok') 'mihomo UID is blocked from link-local metadata addresses.' 'mihomo metadata block rule is missing.'

$uid = Docker-Capture @('exec', 'hermes-secure-hermes', 'id', '-u')
Expect ($uid -eq '10000') 'Hermes runtime UID is non-root.' "Hermes runtime UID is $uid"

$rootProcesses = Docker-Capture @('exec', 'hermes-secure-hermes', 'sh', '-c', "ps -eo uid=,comm= | awk '`$1 == 0 {print}'")
Expect (-not $rootProcesses) 'No UID 0 process exists in the Hermes container.' "Root process detected:`n$rootProcesses"

& docker exec hermes-secure-hermes sh -c 'touch /input/.__audit_write 2>/dev/null'
if ($LASTEXITCODE -eq 0) {
    & docker exec hermes-secure-hermes rm -f /input/.__audit_write | Out-Null
    Fail '/input accepted a write.'
} else { Pass '/input rejects writes.' }

& docker exec hermes-secure-hermes sh -c 'touch /.__audit_root 2>/dev/null'
if ($LASTEXITCODE -eq 0) {
    & docker exec hermes-secure-hermes rm -f /.__audit_root | Out-Null
    Fail 'Container root filesystem accepted a write.'
} else { Pass 'Container root filesystem rejects writes.' }

& docker exec hermes-secure-hermes sh -c 'touch /opt/data/workspace/.__audit_state && rm /opt/data/workspace/.__audit_state'
if ($LASTEXITCODE -eq 0) { Pass 'Hermes workspace remains writable.' } else { Fail 'Hermes workspace is not writable.' }

& docker exec hermes-secure-hermes sh -c 'test -r /run/secrets/hermes.env && ! test -w /run/secrets/hermes.env'
if ($LASTEXITCODE -eq 0) { Pass 'Secret source is readable but not writable in the container.' } else { Fail 'Secret source is missing or writable in the container.' }

& docker exec hermes-secure-hermes sh -c 'test -f /run/hermes/hermes.env && test -w /run/hermes/hermes.env && test "$(stat -c %a /run/hermes/hermes.env)" = 600'
if ($LASTEXITCODE -eq 0) { Pass 'Effective secret copy is writable, temporary, and mode 0600.' } else { Fail 'Effective secret copy is missing, not writable, or has unsafe permissions.' }

$directTest = @'
import socket
try:
    socket.create_connection(("1.1.1.1", 443), 2)
except OSError:
    raise SystemExit(0)
raise SystemExit(1)
'@
$directTest | & docker exec -i hermes-secure-hermes python -
if ($LASTEXITCODE -eq 0) { Pass 'Direct Internet egress by Hermes UID is blocked.' } else { Fail 'Hermes bypassed the local proxy for direct egress.' }

$sidecarLoopbackTest = @'
import socket
for port in (7890, 9090):
    try:
        socket.create_connection(("127.0.0.1", port), 2).close()
    except OSError:
        continue
    raise SystemExit(port)
raise SystemExit(0)
'@
$sidecarLoopbackTest | & docker exec -i hermes-secure-hermes python -
if ($LASTEXITCODE -eq 0) { Pass 'Hermes UID cannot connect directly to mihomo sidecar loopback ports.' } else { Fail "Hermes reached a forbidden sidecar loopback port: $LASTEXITCODE" }

$privateProxyTest = @'
import urllib.request
proxy = urllib.request.ProxyHandler({"http": "http://127.0.0.1:3128"})
opener = urllib.request.build_opener(proxy)
try:
    opener.open("http://169.254.169.254/", timeout=3)
except Exception:
    raise SystemExit(0)
raise SystemExit(1)
'@
$privateProxyTest | & docker exec -i hermes-secure-hermes python -
if ($LASTEXITCODE -eq 0) { Pass 'Proxy rejects link-local metadata destinations.' } else { Fail 'Proxy allowed a link-local metadata destination.' }

$health = Docker-Capture @('inspect', '--format', '{{.State.Health.Status}}', 'hermes-secure-hermes')
Expect ($health -eq 'healthy') 'Hermes healthcheck reports healthy with Dashboard auth active.' "Hermes health is $health"

if ($Warnings.Count -gt 0) {
    Write-Host "`nWarnings: $($Warnings.Count)" -ForegroundColor Yellow
}
if ($Failures.Count -gt 0) {
    Write-Host "`nSecurity audit failed with $($Failures.Count) issue(s)." -ForegroundColor Red
    exit 1
}
Write-Host "`nSecurity audit passed." -ForegroundColor Green
exit 0
