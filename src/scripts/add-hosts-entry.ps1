# Add "127.0.0.1 <fqdn>" to the Windows hosts file (asks for admin via UAC).
# Usage: powershell -ExecutionPolicy Bypass -File src\scripts\add-hosts-entry.ps1 ping-local.test.bbl
param([Parameter(Mandatory = $true)][string]$Fqdn)

$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$pattern = "^\s*127\.0\.0\.1\s+(.*\s)?$([regex]::Escape($Fqdn))(\s|$)"

if (Select-String -Path $hosts -Pattern $pattern -Quiet) {
    Write-Host "Already present: 127.0.0.1 $Fqdn"
    exit 0
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting administrator rights to edit $hosts ..."
    $p = Start-Process -FilePath "powershell" -Verb RunAs -Wait -PassThru -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", $Fqdn)
    exit $p.ExitCode
}

Add-Content -Path $hosts -Value "`r`n127.0.0.1 $Fqdn  # ping-platform on-premise (k8s ingress)" -Encoding ascii
ipconfig /flushdns | Out-Null
Write-Host "Added: 127.0.0.1 $Fqdn"
