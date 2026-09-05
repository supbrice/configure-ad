#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates the OU, group, user, UPN, and sample GPO baseline for bricelab.local.

.DESCRIPTION
    Run on vm-dc01 after Install-ADDSForest completes and you can import
    the ActiveDirectory module. Prints one-time passwords to the console
    and does not write them to disk.

    Author : Brice (github.com/supbrice)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $DomainName = 'bricelab.local',
    [string] $UpnSuffix = 'bricelab.test',
    [string] $CorpOuName = 'Corp'
)

$ErrorActionPreference = 'Stop'

Import-Module ActiveDirectory -ErrorAction Stop
Import-Module GroupPolicy -ErrorAction SilentlyContinue

$domain = Get-ADDomain -Identity $DomainName
$dn = $domain.DistinguishedName

function New-LabPassword {
    # 20-char lab password: mixed case, digit, symbol. Not for production reuse.
    $chars = (48..57) + (65..90) + (97..122)
    $raw = -join ($chars | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    return ($raw + 'Aa1!')
}

function New-LabOu {
    param([string] $Name, [string] $Path)
    $existing = Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $Path -SearchScope OneLevel -ErrorAction SilentlyContinue
    if ($existing) { return $existing }
    return New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true -PassThru
}

function New-LabGroup {
    param([string] $Name, [string] $Path, [string] $Description)
    $existing = Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue
    if ($existing) { return $existing }
    return New-ADGroup -Name $Name -GroupScope Global -GroupCategory Security `
        -Path $Path -Description $Description -PassThru
}

function New-LabUser {
    param(
        [string] $Sam,
        [string] $Given,
        [string] $Sur,
        [string] $Path,
        [string] $Description
    )
    $existing = Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "User $Sam already exists; skipping create."
        return [pscustomobject]@{ Sam = $Sam; Password = '(unchanged)' }
    }
    $plain = New-LabPassword
    $secure = ConvertTo-SecureString $plain -AsPlainText -Force
    New-ADUser -Name "$Given $Sur" -GivenName $Given -Surname $Sur `
        -SamAccountName $Sam -UserPrincipalName "$Sam@$UpnSuffix" `
        -Path $Path -AccountPassword $secure -Enabled $true `
        -ChangePasswordAtLogon $false -PasswordNeverExpires $false `
        -Description $Description
    return [pscustomobject]@{ Sam = $Sam; Password = $plain }
}

Write-Host "Waiting for AD Web Services on $DomainName..."
for ($i = 0; $i -lt 12; $i++) {
    try {
        $null = Get-ADDomain -Identity $DomainName
        break
    }
    catch {
        Start-Sleep -Seconds 5
    }
}

$forest = Get-ADForest
if ($forest.UPNSuffixes -notcontains $UpnSuffix) {
    Write-Host "Adding UPN suffix $UpnSuffix (hybrid-friendly; do not sync *.local UPNs)."
    Set-ADForest -Identity $forest -UPNSuffixes @{ Add = $UpnSuffix }
}

$corp = New-LabOu -Name $CorpOuName -Path $dn
$ouUsers = New-LabOu -Name 'Users' -Path $corp.DistinguishedName
$ouWorkstations = New-LabOu -Name 'Workstations' -Path $corp.DistinguishedName
$ouServers = New-LabOu -Name 'Servers' -Path $corp.DistinguishedName
$ouGroups = New-LabOu -Name 'Groups' -Path $corp.DistinguishedName
$ouSvc = New-LabOu -Name 'ServiceAccounts' -Path $corp.DistinguishedName

$null = $ouWorkstations, $ouSvc

$ggHelpdesk = New-LabGroup -Name 'GG-Helpdesk' -Path $ouGroups.DistinguishedName `
    -Description 'Password reset and workstation join. Not Domain Admins.'
$ggOps = New-LabGroup -Name 'GG-ServerOperators' -Path $ouGroups.DistinguishedName `
    -Description 'Server operators for member servers. Not Domain Admins.'
$ggTier0 = New-LabGroup -Name 'GG-Tier0-Admins' -Path $ouGroups.DistinguishedName `
    -Description 'Lab privileged operators. Nested into Domain Admins for this lab only.'

$created = @()
$created += New-LabUser -Sam 'alice.user' -Given 'Alice' -Sur 'User' `
    -Path $ouUsers.DistinguishedName -Description 'Standard knowledge-worker account'
$created += New-LabUser -Sam 'bob.helpdesk' -Given 'Bob' -Sur 'Helpdesk' `
    -Path $ouUsers.DistinguishedName -Description 'Helpdesk role account'
$created += New-LabUser -Sam 'tier0.admin' -Given 'Tier0' -Sur 'Admin' `
    -Path $ouUsers.DistinguishedName -Description 'Dedicated privileged admin — lab Domain Admin'

Add-ADGroupMember -Identity $ggHelpdesk -Members 'bob.helpdesk' -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity $ggOps -Members 'bob.helpdesk' -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity $ggTier0 -Members 'tier0.admin' -ErrorAction SilentlyContinue

# Lab convenience: nest the Tier 0 group into Domain Admins so RDP-as-admin works
# without using the built-in Administrator. Do not copy this standing grant to production.
$da = Get-ADGroup 'Domain Admins'
$already = Get-ADGroupMember $da | Where-Object { $_.SamAccountName -eq 'GG-Tier0-Admins' }
if (-not $already) {
    Add-ADGroupMember -Identity $da -Members $ggTier0
}

# Grant helpdesk the right to join workstations via the default "Add workstations to domain"
# is already 10-computer for Authenticated Users. Document least privilege instead of
# granting SeEnableDelegationPrivilege here.

if (Get-Module GroupPolicy -ListAvailable) {
    Import-Module GroupPolicy
    $gpoName = 'Lab-LegalNotice'
    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $gpoName -Comment 'Portfolio lab logon banner — Brice'
        Set-GPRegistryValue -Name $gpoName `
            -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
            -ValueName 'LegalNoticeCaption' -Type String -Value 'bricelab.local portfolio lab'
        Set-GPRegistryValue -Name $gpoName `
            -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
            -ValueName 'LegalNoticeText' -Type String `
            -Value 'This is a personal AD DS lab for Brice. Not a production domain. Not affiliated with Microsoft or nVent.'
        New-GPLink -Name $gpoName -Target $corp.DistinguishedName -ErrorAction SilentlyContinue | Out-Null
    }
}
else {
    Write-Warning 'GroupPolicy module not present; skipped Lab-LegalNotice GPO.'
}

# Park the DC computer object where you would OU-filter Entra Connect later
$dcComp = Get-ADComputer -Identity $env:COMPUTERNAME -ErrorAction SilentlyContinue
if ($dcComp -and $dcComp.DistinguishedName -notlike "*OU=Servers,OU=$CorpOuName,*") {
    Write-Host "Leaving $env:COMPUTERNAME in its default OU (Domain Controllers). Member servers go under OU=Servers."
}

Write-Host ''
Write-Host '=== Identity baseline created ==='
Write-Host "Domain      : $DomainName"
Write-Host "UPN suffix  : $UpnSuffix"
Write-Host "Corp OU     : $($corp.DistinguishedName)"
Write-Host "Servers OU  : $($ouServers.DistinguishedName)"
Write-Host ''
Write-Host 'One-time passwords (not saved to disk):'
$created | Format-Table -AutoSize
Write-Host 'Sign in as BRICELAB\tier0.admin for day-to-day lab admin. Keep labadmin as Azure break-glass.'
Write-Host 'Next: set VNet DNS to 10.20.1.4, then domain-join vm-mgmt01.'
