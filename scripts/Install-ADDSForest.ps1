#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Promotes this Windows Server to the first domain controller of bricelab.local.

.DESCRIPTION
    Installs the AD DS role and runs Install-ADDSForest. Intended for vm-dc01
    in Ngu Brice Che's hybrid identity portfolio lab.

    The server will reboot. After reboot, sign in as BRICELAB\<local-admin>
    and run New-LabIdentityBaseline.ps1.

    Portfolio lab only — a single DC is not a production forest.

.NOTES
    Author : Ngu Brice Che (github.com/supbrice)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $DomainName = 'bricelab.local',
    [string] $DomainNetbiosName = 'BRICELAB',
    [ValidateSet('WinThreshold', 'Win2016', 'Win2022')]
    [string] $FunctionalLevel = 'WinThreshold',
    [string] $DatabasePath = 'C:\Windows\NTDS',
    [string] $LogPath = 'C:\Windows\NTDS',
    [string] $SysvolPath = 'C:\Windows\SYSVOL',
    [switch] $NoReboot
)

$ErrorActionPreference = 'Stop'

if (Get-CimInstance -ClassName Win32_ComputerSystem | Where-Object { $_.PartOfDomain -and $_.Domain -eq $DomainName }) {
    Write-Host "This computer is already in $DomainName. Nothing to promote."
    return
}

if (Get-Service -Name NTDS -ErrorAction SilentlyContinue) {
    Write-Host 'NTDS is already present. This server looks like a domain controller.'
    return
}

Write-Host 'Installing AD-Domain-Services and management tools...'
$feature = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
if ($feature.RestartNeeded -eq 'Yes' -and -not $NoReboot) {
    Write-Warning 'A restart is required after the role install. Re-run this script after reboot.'
}

Import-Module ADDSDeployment -ErrorAction Stop

$dsrm = Read-Host -AsSecureString 'DSRM (Directory Services Restore Mode) password — store this; it is not your Azure labadmin password'

$forestParams = @{
    DomainName                    = $DomainName
    DomainNetbiosName             = $DomainNetbiosName
    ForestMode                    = $FunctionalLevel
    DomainMode                    = $FunctionalLevel
    InstallDns                    = $true
    CreateDnsDelegation           = $false
    DatabasePath                  = $DatabasePath
    LogPath                       = $LogPath
    SysvolPath                    = $SysvolPath
    SafeModeAdministratorPassword = $dsrm
    NoRebootOnCompletion          = [bool] $NoReboot
    Force                         = $true
}

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Create new AD DS forest $DomainName")) {
    Write-Host "Promoting $env:COMPUTERNAME as the first DC of $DomainName ($FunctionalLevel)..."
    Install-ADDSForest @forestParams
}
