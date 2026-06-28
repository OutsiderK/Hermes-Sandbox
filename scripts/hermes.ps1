[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'help', 'init', 'start', 'stop', 'restart', 'status', 'open', 'logs',
        'shell', 'audit', 'export', 'outbox-list', 'outbox-clear',
        'secret-set', 'dashboard-password', 'proxy-subscription', 'proxy-secret',
        'proxy-ui', 'update', 'rebuild', 'reset', 'shortcut'
    )]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Name,

    [switch]$Open,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ComposeFile = Join-Path $ProjectRoot 'compose.yaml'
$DotEnvPath = Join-Path $ProjectRoot '.env'
$DotEnvExample = Join-Path $ProjectRoot '.env.example'
$SecretsPath = Join-Path $ProjectRoot 'secrets\hermes.env'
$SecretsExample = Join-Path $ProjectRoot 'secrets\hermes.env.example'
$MihomoConfigPath = Join-Path $ProjectRoot 'proxy\mihomo.yaml'
$MihomoConfigExample = Join-Path $ProjectRoot 'proxy\mihomo.yaml.example'
$DashboardUrl = 'http://127.0.0.1:9119'
$MihomoControllerUrl = 'http://127.0.0.1:9090'
$MihomoDashboardUrl = 'https://d.metacubex.one'
$GuardedHostPaths = @(
    'exchange\inbox',
    'exports',
    'secrets',
    'proxy',
    'secrets\hermes.env',
    'proxy\mihomo.yaml'
)

function Write-Info([string]$Message) {
    Write-Host "[Hermes Secure] $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Warning $Message
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function New-RandomHex([int]$Bytes = 32) {
    $secretBytes = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($secretBytes) } finally { $rng.Dispose() }
    return -join ($secretBytes | ForEach-Object { $_.ToString('x2') })
}

function Invoke-Docker([string[]]$Arguments, [switch]$Capture) {
    if ($Capture) {
        $output = & docker @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "docker $($Arguments -join ' ') failed:`n$($output | Out-String)"
        }
        return (($output | Out-String).Trim())
    }

    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-DockerWithRetry([string[]]$Arguments, [int]$Attempts = 4) {
    $lastOutput = ''
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $output = & docker @Arguments 2>&1
        $lastOutput = ($output | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($attempt -lt $Attempts) {
            $delay = [int][Math]::Min(30, [Math]::Pow(2, $attempt))
            Write-Warn "docker $($Arguments -join ' ') failed on attempt $attempt/$Attempts. Retrying in $delay seconds."
            if ($lastOutput) {
                Write-Warn $lastOutput
            }
            Start-Sleep -Seconds $delay
        }
    }

    throw "docker $($Arguments -join ' ') failed after $Attempts attempt(s). This is usually a network or registry download problem. Last output:`n$lastOutput"
}

function Invoke-Compose([string[]]$Arguments, [switch]$Capture) {
    $all = @('compose', '--file', $ComposeFile) + $Arguments
    return Invoke-Docker -Arguments $all -Capture:$Capture
}

function Ensure-Docker {
    try {
        $null = Invoke-Docker -Arguments @('version', '--format', '{{.Server.Version}}') -Capture
        $null = Invoke-Docker -Arguments @('compose', 'version', '--short') -Capture
    }
    catch {
        throw 'Docker Desktop is not running or docker compose is unavailable.'
    }
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

function Assert-SafeHostPath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required host path is missing: $Path"
    }

    $fullPath = Get-NormalizedFullPath $Path
    if (-not (Test-IsUnderProjectRoot $fullPath)) {
        throw "Host path escapes the project root: $Path"
    }

    $root = Get-NormalizedFullPath $ProjectRoot
    $current = $fullPath
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $attributes = [System.IO.File]::GetAttributes($current)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing reparse-point host path: $current"
            }
        }
        if ($current -eq $root) {
            break
        }
        $parent = [System.IO.Directory]::GetParent($current)
        if (-not $parent) {
            break
        }
        $current = Get-NormalizedFullPath $parent.FullName
        if (-not (Test-IsUnderProjectRoot $current)) {
            throw "Host path parent escapes the project root: $Path"
        }
    }
}

function Assert-HostPathLayout {
    foreach ($relative in $GuardedHostPaths) {
        Assert-SafeHostPath (Join-Path $ProjectRoot $relative)
    }
}

function Read-KeyValueFile([string]$Path) {
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }

    foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or -not $line.Contains('=')) {
            continue
        }
        $index = $line.IndexOf('=')
        $key = $line.Substring(0, $index).Trim()
        $value = $line.Substring($index + 1).Trim()
        if ($key) {
            $map[$key] = $value
        }
    }
    return $map
}

function Set-KeyValue([string]$Path, [string]$Key, [string]$Value) {
    if ($Key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Invalid environment key: $Key"
    }
    if ($Value.Contains("`n") -or $Value.Contains("`r") -or $Value.Contains([char]0)) {
        throw 'Secret/config values must be single-line and cannot contain NUL.'
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            $lines.Add($line)
        }
    }

    $replacement = "$Key=$Value"
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($Key))=") {
            $lines[$i] = $replacement
            $found = $true
            break
        }
    }
    if (-not $found) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') {
            $lines.Add('')
        }
        $lines.Add($replacement)
    }
    Write-Utf8NoBom -Path $Path -Text (($lines -join "`n") + "`n")
}

function Ensure-EnvDefaults {
    if (-not (Test-Path -LiteralPath $DotEnvPath) -or -not (Test-Path -LiteralPath $DotEnvExample)) {
        return
    }

    $current = Read-KeyValueFile $DotEnvPath
    $defaults = Read-KeyValueFile $DotEnvExample
    $missing = @($defaults.Keys | Where-Object { -not $current.Contains($_) })
    if ($missing.Count -eq 0) {
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($DotEnvPath)) {
        $lines.Add($line)
    }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') {
        $lines.Add('')
    }
    $lines.Add('# Added by hermes.ps1 for newer framework defaults.')
    foreach ($key in $missing) {
        $lines.Add("$key=$($defaults[$key])")
    }
    Write-Utf8NoBom -Path $DotEnvPath -Text (($lines -join "`n") + "`n")
    Write-Ok "Added missing .env default(s): $($missing -join ', ')"
}

function Initialize-Layout {
    foreach ($dir in @(
        (Join-Path $ProjectRoot 'exchange\inbox'),
        (Join-Path $ProjectRoot 'exports'),
        (Join-Path $ProjectRoot 'secrets'),
        (Join-Path $ProjectRoot 'proxy')
    )) {
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    }

    if (-not (Test-Path -LiteralPath $DotEnvPath)) {
        Copy-Item -LiteralPath $DotEnvExample -Destination $DotEnvPath
        Write-Ok 'Created .env from .env.example.'
    }
    Ensure-EnvDefaults
    if (-not (Test-Path -LiteralPath $SecretsPath)) {
        Copy-Item -LiteralPath $SecretsExample -Destination $SecretsPath
        Write-Ok 'Created secrets/hermes.env from its example.'
    }
    if (-not (Test-Path -LiteralPath $MihomoConfigPath)) {
        $mihomo = [System.IO.File]::ReadAllText($MihomoConfigExample)
        $mihomo = $mihomo.Replace('__MIHOMO_CONTROLLER_SECRET__', (New-RandomHex 32))
        Write-Utf8NoBom -Path $MihomoConfigPath -Text $mihomo
        Write-Ok 'Created proxy/mihomo.yaml from its example. Run proxy-subscription to add your Clash subscription URL.'
    }
    Assert-HostPathLayout
}

function Test-ImageDigestRef([string]$ImageRef) {
    return $ImageRef -match '@sha256:[0-9a-f]{64}$'
}

function Get-LocalImageDigest([string]$SourceImage) {
    try {
        $digest = Invoke-Docker -Arguments @('image', 'inspect', '--format', '{{index .RepoDigests 0}}', $SourceImage) -Capture
        if (Test-ImageDigestRef $digest) {
            return $digest
        }
    }
    catch {
        return ''
    }
    return ''
}

function Resolve-ImageDigest([string]$SourceImage, [string]$ExistingRef = '', [switch]$ForcePull) {
    if (-not $ForcePull -and (Test-ImageDigestRef $ExistingRef)) {
        Write-Ok "Using existing locked digest for $SourceImage"
        return $ExistingRef
    }

    if (-not $ForcePull) {
        $localDigest = Get-LocalImageDigest $SourceImage
        if ($localDigest) {
            Write-Ok "Using locally cached digest for $SourceImage"
            return $localDigest
        }
    }

    Write-Info "Pulling and locking $SourceImage"
    Invoke-DockerWithRetry -Arguments @('pull', $SourceImage)
    $digest = Invoke-Docker -Arguments @('image', 'inspect', '--format', '{{index .RepoDigests 0}}', $SourceImage) -Capture
    if (-not (Test-ImageDigestRef $digest)) {
        throw "Docker did not return an immutable RepoDigest for ${SourceImage}: $digest"
    }
    return $digest
}

function Lock-Images([switch]$ForcePull) {
    Initialize-Layout
    $envMap = Read-KeyValueFile $DotEnvPath
    foreach ($required in @('HERMES_SOURCE_IMAGE', 'NETGUARD_SOURCE_IMAGE', 'STATE_INIT_SOURCE_IMAGE', 'MIHOMO_SOURCE_IMAGE')) {
        if (-not $envMap.Contains($required) -or -not $envMap[$required]) {
            throw "$required is missing from .env"
        }
    }

    foreach ($pair in @(
        @('HERMES_SOURCE_IMAGE', 'HERMES_IMAGE_REF'),
        @('NETGUARD_SOURCE_IMAGE', 'NETGUARD_IMAGE_REF'),
        @('STATE_INIT_SOURCE_IMAGE', 'STATE_INIT_IMAGE_REF'),
        @('MIHOMO_SOURCE_IMAGE', 'MIHOMO_IMAGE_REF')
    )) {
        $sourceKey = $pair[0]
        $refKey = $pair[1]
        $existingRef = ''
        if ($envMap.Contains($refKey)) {
            $existingRef = $envMap[$refKey]
        }
        $ref = Resolve-ImageDigest -SourceImage $envMap[$sourceKey] -ExistingRef $existingRef -ForcePull:$ForcePull
        Set-KeyValue $DotEnvPath $refKey $ref
        $envMap[$refKey] = $ref
    }

    if ($ForcePull) {
        Write-Ok 'Image references were refreshed and locked to immutable SHA-256 digests.'
    }
    else {
        Write-Ok 'Image references are locked to immutable SHA-256 digests.'
    }
}

function Assert-Initialized {
    Initialize-Layout
    $envMap = Read-KeyValueFile $DotEnvPath
    foreach ($key in @('HERMES_IMAGE_REF', 'NETGUARD_IMAGE_REF', 'STATE_INIT_IMAGE_REF', 'MIHOMO_IMAGE_REF')) {
        if (-not $envMap.Contains($key) -or $envMap[$key] -notmatch '@sha256:[0-9a-f]{64}$') {
            throw "Images are not locked. Run: .\scripts\hermes.ps1 init"
        }
    }
}

function Validate-Compose {
    Write-Info 'Validating the effective Compose configuration.'
    Invoke-Compose -Arguments @('config', '--quiet')
    Write-Ok 'Compose configuration is valid.'
}

function Build-Images {
    Validate-Compose
    Write-Info 'Building the non-root Hermes runtime and network guard.'
    Invoke-Compose -Arguments @('build', '--pull', 'netguard', 'hermes')
    Write-Ok 'Images built.'
}

function Convert-SecureStringToPlain([Security.SecureString]$Secure) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-RuntimeImageName {
    $envMap = Read-KeyValueFile $DotEnvPath
    if ($envMap.Contains('HERMES_RUNTIME_IMAGE') -and $envMap['HERMES_RUNTIME_IMAGE']) {
        return $envMap['HERMES_RUNTIME_IMAGE']
    }
    return 'hermes-secure-runtime:local'
}

function Set-DashboardPassword {
    Assert-Initialized
    $runtimeImage = Get-RuntimeImageName
    $null = Invoke-Docker -Arguments @('image', 'inspect', $runtimeImage) -Capture

    $username = Read-Host 'Dashboard username [admin]'
    if (-not $username) { $username = 'admin' }
    if ($username -notmatch '^[A-Za-z0-9._-]{1,64}$') {
        throw 'Dashboard username may contain only letters, digits, dot, underscore and hyphen.'
    }

    $passwordOne = Read-Host 'Dashboard password' -AsSecureString
    $passwordTwo = Read-Host 'Confirm dashboard password' -AsSecureString
    $plainOne = Convert-SecureStringToPlain $passwordOne
    $plainTwo = Convert-SecureStringToPlain $passwordTwo
    try {
        if ($plainOne -cne $plainTwo) { throw 'Passwords do not match.' }
        if ($plainOne.Length -lt 14) { throw 'Use a dashboard password of at least 14 characters.' }

        $hashOutput = $plainOne | & docker run --rm -i --user 10000:10000 --entrypoint python $runtimeImage -c "import sys; from plugins.dashboard_auth.basic import hash_password; print(hash_password(sys.stdin.read().rstrip('\r\n')))" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not hash the dashboard password:`n$($hashOutput | Out-String)"
        }
        $hash = (($hashOutput | Out-String).Trim())
        if (-not $hash.StartsWith('scrypt$')) {
            throw "Unexpected password hash format: $hash"
        }
    }
    finally {
        $plainOne = $null
        $plainTwo = $null
    }

    $sessionSecret = New-RandomHex 32

    Set-KeyValue $SecretsPath 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME' $username
    Set-KeyValue $SecretsPath 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH' $hash
    Set-KeyValue $SecretsPath 'HERMES_DASHBOARD_BASIC_AUTH_SECRET' $sessionSecret
    Write-Ok 'Dashboard password hash and signing secret updated.'
}

function Assert-DashboardConfigured {
    $map = Read-KeyValueFile $SecretsPath
    foreach ($key in @(
        'HERMES_DASHBOARD_BASIC_AUTH_USERNAME',
        'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH',
        'HERMES_DASHBOARD_BASIC_AUTH_SECRET'
    )) {
        if (-not $map.Contains($key) -or -not $map[$key]) {
            throw "Dashboard authentication is incomplete. Run: .\scripts\hermes.ps1 dashboard-password"
        }
    }
    if (-not $map['HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH'].StartsWith('scrypt$')) {
        throw 'Dashboard password is not stored as a scrypt hash.'
    }
}

function Get-MihomoControllerSecret {
    Initialize-Layout
    $text = [System.IO.File]::ReadAllText($MihomoConfigPath)
    $match = [regex]::Match($text, '(?m)^\s*secret:\s*"?([^"`#\r\n]+)"?\s*$')
    if (-not $match.Success -or -not $match.Groups[1].Value -or $match.Groups[1].Value -eq '__MIHOMO_CONTROLLER_SECRET__') {
        throw 'mihomo controller secret is missing. Run: .\scripts\hermes.ps1 proxy-secret'
    }
    return $match.Groups[1].Value.Trim()
}

function Set-MihomoControllerSecret {
    Initialize-Layout
    $text = [System.IO.File]::ReadAllText($MihomoConfigPath)
    $secret = New-RandomHex 32
    if ($text -match '(?m)^\s*secret:\s*') {
        $text = [regex]::Replace($text, '(?m)^(\s*secret:\s*).+$', "`$1`"$secret`"", 1)
    }
    else {
        $text += "`nsecret: `"$secret`"`n"
    }
    Write-Utf8NoBom -Path $MihomoConfigPath -Text $text
    Write-Ok 'mihomo controller secret rotated.'
    if (Get-ContainerRunning 'hermes-secure-mihomo') {
        Invoke-Compose -Arguments @('restart', 'mihomo')
    }
}

function Set-MihomoSubscription {
    Initialize-Layout
    $secure = Read-Host 'Clash subscription URL for mihomo' -AsSecureString
    $url = Convert-SecureStringToPlain $secure
    try {
        if (-not $url -or $url -notmatch '^https?://') {
            throw 'Subscription URL must start with http:// or https://.'
        }
        if ($url.Contains("`n") -or $url.Contains("`r") -or $url.Contains([char]0)) {
            throw 'Subscription URL must be a single line.'
        }

        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in [System.IO.File]::ReadAllLines($MihomoConfigPath)) {
            $lines.Add($line)
        }

        $inProvider = $false
        $updated = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s{2}my-sub:\s*$') {
                $inProvider = $true
                continue
            }
            if ($inProvider -and $lines[$i] -match '^\s{2}\S') {
                break
            }
            if ($inProvider -and $lines[$i] -match '^\s{4}url:\s*') {
                $escaped = $url.Replace('\', '\\').Replace('"', '\"')
                $lines[$i] = "    url: `"$escaped`""
                $updated = $true
                break
            }
        }
        if (-not $updated) {
            throw 'Could not find proxy-providers.my-sub.url in proxy/mihomo.yaml.'
        }

        Write-Utf8NoBom -Path $MihomoConfigPath -Text (($lines -join "`n") + "`n")
        Write-Ok 'mihomo subscription URL updated. The URL is stored only in ignored proxy/mihomo.yaml.'
        if (Get-ContainerRunning 'hermes-secure-mihomo') {
            Invoke-Compose -Arguments @('restart', 'mihomo')
        }
    }
    finally {
        $url = $null
    }
}

function Open-MihomoDashboard {
    $secret = Get-MihomoControllerSecret
    Write-Host "mihomo API:    $MihomoControllerUrl"
    Write-Host "Secret:        $secret"
    Write-Host "Dashboard:     $MihomoDashboardUrl"
    Write-Host 'In the dashboard, add the API above and paste the secret when prompted.'
    Start-Process $MihomoDashboardUrl
}

function Wait-ForHealthy([string]$ContainerName, [int]$Seconds = 120) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        Start-Sleep -Seconds 2
        try {
            $status = Invoke-Docker -Arguments @('inspect', '--format', '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}', $ContainerName) -Capture
        }
        catch {
            $status = 'missing'
        }
        if ($status -eq 'healthy' -or $status -eq 'running') {
            return
        }
        if ($status -eq 'unhealthy' -or $status -eq 'exited' -or $status -eq 'dead') {
            throw "$ContainerName entered state '$status'. Run .\scripts\hermes.ps1 logs"
        }
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for $ContainerName to become healthy."
}

function Start-Stack([switch]$LaunchBrowser) {
    Assert-Initialized
    Assert-DashboardConfigured
    Assert-HostPathLayout
    Validate-Compose

    try {
        Write-Info 'Preparing the named state volume.'
        Invoke-Compose -Arguments @('up', '--detach', '--force-recreate', 'state-init')
        $initDeadline = (Get-Date).AddSeconds(60)
        $initState = 'missing'
        do {
            Start-Sleep -Milliseconds 500
            $initState = Invoke-Docker -Arguments @('inspect', '--format', '{{.State.Status}}:{{.State.ExitCode}}', 'hermes-secure-state-init') -Capture
            if ($initState -eq 'exited:0') { break }
            if ($initState -like 'exited:*' -and $initState -ne 'exited:0') {
                throw "The state-init container failed ($initState)."
            }
        } while ((Get-Date) -lt $initDeadline)
        if ($initState -ne 'exited:0') { throw 'Timed out waiting for state-init.' }

        Write-Info 'Starting netguard, mihomo and Hermes.'
        Invoke-Compose -Arguments @('up', '--detach', 'netguard', 'mihomo', 'hermes')
        Wait-ForHealthy 'hermes-secure-netguard' 90
        Wait-ForHealthy 'hermes-secure-mihomo' 90
        Wait-ForHealthy 'hermes-secure-hermes' 150

        & (Join-Path $PSScriptRoot 'audit.ps1')
        if ($LASTEXITCODE -ne 0) {
            throw 'Security audit failed; Hermes will be stopped.'
        }
    }
    catch {
        Write-Warn "Startup failed: $($_.Exception.Message)"
        try { Invoke-Compose -Arguments @('stop', 'hermes', 'mihomo', 'netguard') } catch { Write-Warn $_.Exception.Message }
        throw
    }

    Write-Ok "Dashboard is ready at $DashboardUrl"
    if ($LaunchBrowser) {
        Start-Process $DashboardUrl
    }
}

function Stop-Stack {
    Invoke-Compose -Arguments @('stop', 'hermes', 'mihomo', 'netguard')
    Write-Ok 'Hermes, mihomo and netguard stopped.'
}

function Get-ContainerRunning([string]$ContainerName) {
    try {
        return (Invoke-Docker -Arguments @('inspect', '--format', '{{.State.Running}}', $ContainerName) -Capture) -eq 'true'
    }
    catch {
        return $false
    }
}

function Set-SecretValue([string]$Key) {
    if (-not $Key) { throw 'Usage: hermes.ps1 secret-set VARIABLE_NAME' }
    if ($Key -notmatch '^[A-Z][A-Z0-9_]*$') {
        throw 'Secret names must use uppercase letters, digits and underscores.'
    }
    $secure = Read-Host "Value for $Key" -AsSecureString
    $plain = Convert-SecureStringToPlain $secure
    try {
        if (-not $plain) { throw 'Secret value cannot be empty.' }
        Set-KeyValue $SecretsPath $Key $plain
    }
    finally {
        $plain = $null
    }
    Write-Ok "$Key updated. Restarting Hermes applies it."
    if (Get-ContainerRunning 'hermes-secure-hermes') {
        Invoke-Compose -Arguments @('restart', 'hermes')
        Wait-ForHealthy 'hermes-secure-hermes' 150
        & (Join-Path $PSScriptRoot 'audit.ps1')
        if ($LASTEXITCODE -ne 0) {
            Stop-Stack
            throw 'Security audit failed after applying the secret.'
        }
    }
}

function Export-Outbox {
    Assert-Initialized
    Assert-HostPathLayout
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $exportName = "hermes_$timestamp"
    $wasRunning = Get-ContainerRunning 'hermes-secure-hermes'

    if ($wasRunning) {
        Write-Info 'Stopping Hermes to make the outbox export consistent.'
        Invoke-Compose -Arguments @('stop', 'hermes')
    }

    try {
        Invoke-Compose -Arguments @('--profile', 'tools', 'run', '--rm', '--no-deps', '-e', "EXPORT_NAME=$exportName", 'exporter')
        Write-Ok "Outbox exported to exports\$exportName"
    }
    finally {
        if ($wasRunning) {
            Invoke-Compose -Arguments @('up', '--detach', 'hermes')
            Wait-ForHealthy 'hermes-secure-hermes' 150
            & (Join-Path $PSScriptRoot 'audit.ps1')
            if ($LASTEXITCODE -ne 0) {
                Stop-Stack
                throw 'Security audit failed after export restart; Hermes was stopped.'
            }
        }
    }
}

function Clear-Outbox {
    if (-not $Force) {
        $answer = Read-Host 'Delete every item currently in the container outbox? Type DELETE'
        if ($answer -cne 'DELETE') {
            Write-Info 'Cancelled.'
            return
        }
    }
    Invoke-Compose -Arguments @('exec', '--user', '10000:10000', 'hermes', 'sh', '-ec', 'find /opt/data/outbox -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +')
    Write-Ok 'Outbox cleared.'
}

function Reset-Environment {
    if (-not $Force) {
        $answer = Read-Host 'Delete the Hermes state volume, including workspace Git working trees? Pushed remote repositories are unaffected. Type RESET'
        if ($answer -cne 'RESET') {
            Write-Info 'Cancelled.'
            return
        }
    }
    try { Invoke-Compose -Arguments @('down', '--remove-orphans') } catch { Write-Warn $_.Exception.Message }
    $envMap = Read-KeyValueFile $DotEnvPath
    $volume = 'hermes-secure-data'
    if ($envMap.Contains('HERMES_DATA_VOLUME') -and $envMap['HERMES_DATA_VOLUME']) {
        $volume = $envMap['HERMES_DATA_VOLUME']
    }
    try { Invoke-Docker -Arguments @('volume', 'rm', $volume) } catch { Write-Warn $_.Exception.Message }
    $mihomoVolume = 'hermes-secure-mihomo-data'
    if ($envMap.Contains('MIHOMO_DATA_VOLUME') -and $envMap['MIHOMO_DATA_VOLUME']) {
        $mihomoVolume = $envMap['MIHOMO_DATA_VOLUME']
    }
    try { Invoke-Docker -Arguments @('volume', 'rm', $mihomoVolume) } catch { Write-Warn $_.Exception.Message }
    Write-Ok 'Hermes runtime state was reset. Input, exports and secrets were not deleted.'
}

function Create-Shortcut {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktop 'Hermes Secure.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = (Get-Command powershell.exe).Source
    $scriptPath = Join-Path $PSScriptRoot 'hermes.ps1'
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" start -Open"
    $shortcut.WorkingDirectory = $ProjectRoot
    $shortcut.Description = 'Start the isolated Hermes Dashboard'
    $shortcut.Save()
    Write-Ok "Created $shortcutPath"
}

function Show-Help {
    @"
Hermes Secure commands

  init                 Create local files, lock image digests, build, set password
  start [-Open]        Start and audit Hermes; optionally open the Dashboard
  stop                 Stop Hermes and the network guard
  restart [-Open]      Restart, audit and optionally open the Dashboard
  status               Show compose state and one-shot resource usage
  open                 Open http://127.0.0.1:9119
  logs                 Follow Hermes and netguard logs
  shell                Enter a non-root shell in the Hermes container
  audit                Re-run runtime security checks
  export               Stop Hermes briefly and explicitly export only outbox/
  outbox-list          List files waiting in /opt/data/outbox
  outbox-clear [-Force] Delete outbox contents after confirmation
  secret-set NAME      Securely set an API key/token in secrets/hermes.env
  dashboard-password   Rotate the Dashboard password and signing secret
  proxy-subscription   Store/update the local Clash subscription URL for mihomo
  proxy-secret         Rotate the local mihomo controller secret
  proxy-ui             Open the mihomo/Clash GUI for node switching
  update               Re-lock upstream tags, rebuild, restart and audit
  rebuild              Rebuild local images without changing locked digests
  reset [-Force]       Delete the Hermes state volume; no backup is made
  shortcut             Create a Windows desktop shortcut

Important: there is deliberately no automatic state-volume backup. Keep important
projects in Git, and use `export` only for files placed in /opt/data/outbox.
"@ | Write-Host
}

Push-Location $ProjectRoot
try {
    if ($Command -ne 'help') { Ensure-Docker }

    switch ($Command) {
        'help' { Show-Help }
        'init' {
            Initialize-Layout
            Lock-Images
            Build-Images
            Set-DashboardPassword
            Write-Ok 'Initialization complete. Run: .\scripts\hermes.ps1 proxy-subscription, then .\scripts\hermes.ps1 start -Open'
        }
        'start' { Start-Stack -LaunchBrowser:$Open }
        'stop' { Stop-Stack }
        'restart' {
            Stop-Stack
            Start-Stack -LaunchBrowser:$Open
        }
        'status' {
            Invoke-Compose -Arguments @('ps')
            try { Invoke-Docker -Arguments @('stats', '--no-stream', 'hermes-secure-hermes', 'hermes-secure-mihomo', 'hermes-secure-netguard') } catch { Write-Warn $_.Exception.Message }
        }
        'open' { Start-Process $DashboardUrl }
        'logs' { Invoke-Compose -Arguments @('logs', '--follow', '--tail', '200', 'hermes', 'mihomo', 'netguard') }
        'shell' { Invoke-Compose -Arguments @('exec', '--user', '10000:10000', 'hermes', 'bash') }
        'audit' { & (Join-Path $PSScriptRoot 'audit.ps1'); exit $LASTEXITCODE }
        'export' { Export-Outbox }
        'outbox-list' { Invoke-Compose -Arguments @('exec', '--user', '10000:10000', 'hermes', 'find', '/opt/data/outbox', '-mindepth', '1', '-maxdepth', '3', '-printf', '%y %s %p\n') }
        'outbox-clear' { Clear-Outbox }
        'secret-set' { Set-SecretValue $Name }
        'proxy-subscription' { Set-MihomoSubscription }
        'proxy-secret' { Set-MihomoControllerSecret }
        'proxy-ui' { Open-MihomoDashboard }
        'dashboard-password' {
            Set-DashboardPassword
            if (Get-ContainerRunning 'hermes-secure-hermes') {
                Invoke-Compose -Arguments @('restart', 'hermes')
                Wait-ForHealthy 'hermes-secure-hermes' 150
                & (Join-Path $PSScriptRoot 'audit.ps1')
                if ($LASTEXITCODE -ne 0) {
                    Stop-Stack
                    throw 'Security audit failed after rotating the Dashboard password.'
                }
            }
        }
        'update' {
            Lock-Images -ForcePull
            Build-Images
            if (Get-ContainerRunning 'hermes-secure-hermes') {
                Stop-Stack
                Start-Stack -LaunchBrowser:$Open
            }
            Write-Ok 'Update completed. No state-volume backup was created.'
        }
        'rebuild' {
            Assert-Initialized
            Build-Images
            if (Get-ContainerRunning 'hermes-secure-hermes') {
                Stop-Stack
                Start-Stack -LaunchBrowser:$Open
            }
        }
        'reset' { Reset-Environment }
        'shortcut' { Create-Shortcut }
    }
}
finally {
    Pop-Location
}
