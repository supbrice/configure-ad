#Requires -Version 5.1
<#
.SYNOPSIS
    Identity hygiene report for the bricelab.local portfolio forest.

.DESCRIPTION
    Recursively lists privileged-group members, users with non-expiring
    passwords, stale enabled users/computers, and adminCount=1 accounts.

    Run on vm-dc01 or a domain-joined jump box that has the ActiveDirectory
    module (RSAT-AD-PowerShell).

    A clean new lab will still show labadmin and tier0.admin as Domain Admins.
    The point is the questions, not a red score.

.NOTES
    Author : Brice (github.com/supbrice)
#>
[CmdletBinding()]
param(
    [string] $DomainName = 'bricelab.local',
    [int] $StaleDays = 90,
    [string] $OutputCsv
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory -ErrorAction Stop

$null = Get-ADDomain -Identity $DomainName
$cutoff = (Get-Date).AddDays(-$StaleDays)
$findings = New-Object System.Collections.Generic.List[object]

function Add-LabFinding {
    param(
        [string] $Check,
        [string] $Identity,
        [string] $Severity,
        [string] $Detail
    )
    $findings.Add([pscustomobject]@{
            Check     = $Check
            Identity  = $Identity
            Severity  = $Severity
            Detail    = $Detail
            Collected = (Get-Date).ToString('s')
        })
}

$privileged = @(
    'Domain Admins',
    'Enterprise Admins',
    'Schema Admins',
    'Administrators',
    'Account Operators',
    'Backup Operators',
    'Server Operators'
)

Write-Host "=== Privileged group membership (recursive) ==="
foreach ($name in $privileged) {
    $group = Get-ADGroup -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue
    if (-not $group) { continue }
    $members = Get-ADGroupMember -Identity $group -Recursive -ErrorAction SilentlyContinue
    if (-not $members) {
        Write-Host ("{0,-22} (empty or no user/computer members)" -f $name)
        continue
    }
    foreach ($m in $members) {
        $sev = if ($name -in @('Domain Admins', 'Enterprise Admins', 'Schema Admins')) { 'High' } else { 'Medium' }
        Add-LabFinding -Check "PrivilegedGroup:$name" -Identity $m.SamAccountName -Severity $sev `
            -Detail "$($m.objectClass) in $name"
        Write-Host ("{0,-22} {1,-20} {2}" -f $name, $m.SamAccountName, $m.objectClass)
    }
}

Write-Host ''
Write-Host '=== PasswordNeverExpires (enabled users) ==='
$neverExpire = Get-ADUser -Filter { Enabled -eq $true -and PasswordNeverExpires -eq $true } `
    -Properties PasswordNeverExpires, PasswordLastSet, PasswordNotRequired
if (-not $neverExpire) {
    Write-Host 'None. Baseline users expire passwords (lab default).'
}
foreach ($u in $neverExpire) {
    Add-LabFinding -Check 'PasswordNeverExpires' -Identity $u.SamAccountName -Severity 'Medium' `
        -Detail "PasswordLastSet=$($u.PasswordLastSet); PasswordNotRequired=$($u.PasswordNotRequired)"
    Write-Host "$($u.SamAccountName)  PasswordLastSet=$($u.PasswordLastSet)"
}

Write-Host ''
Write-Host "=== Enabled users with LastLogonDate older than $StaleDays days (or never) ==="
$users = Get-ADUser -Filter { Enabled -eq $true } -Properties LastLogonDate, Created, PasswordLastSet
$staleUsers = $users | Where-Object {
    -not $_.LastLogonDate -or $_.LastLogonDate -lt $cutoff
}
if (-not $staleUsers) {
    Write-Host 'None.'
}
foreach ($u in $staleUsers) {
    $when = if ($u.LastLogonDate) { $u.LastLogonDate } else { 'never' }
    # Brand-new lab accounts have never logged on — note that so a hiring manager is not alarmed.
    $sev = if (-not $u.LastLogonDate -and $u.Created -gt (Get-Date).AddDays(-7)) { 'Info' } else { 'Low' }
    Add-LabFinding -Check 'StaleOrNeverLoggedOnUser' -Identity $u.SamAccountName -Severity $sev `
        -Detail "LastLogonDate=$when; Created=$($u.Created)"
    Write-Host "$($u.SamAccountName)  LastLogonDate=$when  Created=$($u.Created)  [$sev]"
}

Write-Host ''
Write-Host "=== Enabled computers with LastLogonDate older than $StaleDays days (or never) ==="
$computers = Get-ADComputer -Filter { Enabled -eq $true } -Properties LastLogonDate, Created, OperatingSystem
$staleComputers = $computers | Where-Object {
    -not $_.LastLogonDate -or $_.LastLogonDate -lt $cutoff
}
if (-not $staleComputers) {
    Write-Host 'None.'
}
foreach ($c in $staleComputers) {
    $when = if ($c.LastLogonDate) { $c.LastLogonDate } else { 'never' }
    $sev = if (-not $c.LastLogonDate -and $c.Created -gt (Get-Date).AddDays(-7)) { 'Info' } else { 'Low' }
    Add-LabFinding -Check 'StaleOrNeverLoggedOnComputer' -Identity $c.SamAccountName -Severity $sev `
        -Detail "LastLogonDate=$when; OS=$($c.OperatingSystem)"
    Write-Host "$($c.SamAccountName)  LastLogonDate=$when  OS=$($c.OperatingSystem)  [$sev]"
}

Write-Host ''
Write-Host '=== adminCount = 1 (AdminSDHolder / privileged SD) ==='
$adminCount = Get-ADUser -Filter { adminCount -eq 1 } -Properties adminCount, MemberOf
if (-not $adminCount) {
    Write-Host 'No user objects with adminCount=1 (unexpected on a DC lab).'
}
foreach ($u in $adminCount) {
    Add-LabFinding -Check 'AdminCount' -Identity $u.SamAccountName -Severity 'Info' `
        -Detail 'adminCount=1 — AdminSDHolder manages this ACL. Expected for real privileged users.'
    Write-Host $u.SamAccountName
}

Write-Host ''
Write-Host '=== Summary ==='
$findings |
    Group-Object Severity |
    Sort-Object Name |
    ForEach-Object { '{0,-8} {1}' -f $_.Name, $_.Count }

if ($OutputCsv) {
    $dir = Split-Path -Parent $OutputCsv
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $findings | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Wrote $($findings.Count) rows to $OutputCsv"
}

Write-Host ''
Write-Host 'Hybrid reminder: do not sync Domain Admins / tier0.admin to Entra ID. Filter OU=Corp and exclude Tier 0.'
