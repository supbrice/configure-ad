#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys Ngu Brice Che's hybrid AD DS lab landing zone in Azure.

.DESCRIPTION
    Creates rg-bricelab-hybridid, a single VNet/subnet, an NSG that allows RDP
    only from the operator public IP, and two Windows Server 2022 VMs with
    static private IPs:

      vm-dc01    10.20.1.4   future domain controller
      vm-mgmt01  10.20.1.5   domain-join jump box

    Run this from your workstation after Connect-AzAccount. Do not run it
    inside the VMs.

    This is a portfolio lab, not a production landing zone.

.NOTES
    Author : Ngu Brice Che (github.com/supbrice)
    Lab    : bricelab.local hybrid identity
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ResourceGroupName = 'rg-bricelab-hybridid',
    [string] $Location = 'eastus',
    [string] $VnetName = 'vnet-bricelab',
    [string] $VnetPrefix = '10.20.0.0/16',
    [string] $SubnetName = 'snet-identity',
    [string] $SubnetPrefix = '10.20.1.0/24',
    [string] $NsgName = 'nsg-identity',
    [string] $DcName = 'vm-dc01',
    [string] $DcPrivateIp = '10.20.1.4',
    [string] $MgmtName = 'vm-mgmt01',
    [string] $MgmtPrivateIp = '10.20.1.5',
    [string] $VmSize = 'Standard_B2ms',
    [string] $AdminUsername = 'labadmin',
    [Parameter(Mandatory)]
    [SecureString] $AdminPassword,
    [string] $OperatorPublicIp,
    [string] $ImageSku = '2022-datacenter-g2'
)

$ErrorActionPreference = 'Stop'

function Get-LabOperatorIp {
    if ($script:OperatorPublicIp) { return $script:OperatorPublicIp.Trim() }
    Write-Host 'OperatorPublicIp not supplied; detecting via api.ipify.org...'
    $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 15).ip
    if (-not $ip) { throw 'Could not detect a public IP. Pass -OperatorPublicIp x.x.x.x/32' }
    return $ip
}

function Test-LabAzModule {
    foreach ($name in @('Az.Accounts', 'Az.Resources', 'Az.Network', 'Az.Compute')) {
        if (-not (Get-Module -ListAvailable -Name $name)) {
            throw "Missing PowerShell module $name. Install-Module Az -Scope CurrentUser"
        }
        Import-Module $name -ErrorAction Stop
    }
    if (-not (Get-AzContext)) {
        throw 'No Az context. Run Connect-AzAccount and select the lab subscription.'
    }
}

function New-LabWindowsVm {
    param(
        [string] $Name,
        [string] $PrivateIp,
        $VirtualNetwork,
        $Nsg,
        [pscredential] $Credential
    )

    $pip = Get-AzPublicIpAddress -Name "pip-$Name" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $pip) {
        $pip = New-AzPublicIpAddress -Name "pip-$Name" -ResourceGroupName $ResourceGroupName `
            -Location $Location -Sku Standard -AllocationMethod Static -IpAddressVersion IPv4
    }

    $nic = Get-AzNetworkInterface -Name "nic-$Name" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $nic) {
        $nic = New-AzNetworkInterface -Name "nic-$Name" -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -SubnetId $VirtualNetwork.Subnets[0].Id `
            -PublicIpAddressId $pip.Id `
            -NetworkSecurityGroupId $Nsg.Id `
            -PrivateIpAddress $PrivateIp
    }

    $existing = Get-AzVM -Name $Name -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "VM $Name already exists; skipping create."
        return $existing
    }

    $vmConfigParams = @{ VMName = $Name; VMSize = $VmSize }
    if ((Get-Command New-AzVMConfig).Parameters.ContainsKey('SecurityType')) {
        $vmConfigParams.SecurityType = 'Standard'
    }
    $vmConfig = New-AzVMConfig @vmConfigParams |
        Set-AzVMOperatingSystem -Windows -ComputerName $Name -Credential $Credential -ProvisionVMAgent -EnableAutoUpdate |
        Set-AzVMSourceImage -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Skus $ImageSku -Version 'latest' |
        Add-AzVMNetworkInterface -Id $nic.Id |
        Set-AzVMOSDisk -Name "osdisk-$Name" -CreateOption FromImage -StorageAccountType 'StandardSSD_LRS' -DiskSizeInGB 127 |
        Set-AzVMBootDiagnostic -Disable

    Write-Host "Creating VM $Name ($VmSize, $ImageSku, private $PrivateIp)..."
    return New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig
}

Test-LabAzModule

$operatorIp = Get-LabOperatorIp
if ($operatorIp -notmatch '/') { $operatorIp = "$operatorIp/32" }
Write-Host "RDP will be allowed from $operatorIp only."

$credential = [pscredential]::new($AdminUsername, $AdminPassword)

if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Create hybrid AD lab landing zone')) {
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{
            project    = 'bricelab-hybridid'
            owner      = 'supbrice'
            purpose    = 'portfolio-lab'
        }
    }

    $rdpRule = New-AzNetworkSecurityRuleConfig -Name 'Allow-RDP-Operator' `
        -Description 'Lab RDP from the operator public IP. Not a production pattern.' `
        -Protocol Tcp -Direction Inbound -Priority 1000 `
        -SourceAddressPrefix $operatorIp -SourcePortRange '*' `
        -DestinationAddressPrefix '*' -DestinationPortRange 3389 -Access Allow

    $nsg = Get-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $nsg) {
        $nsg = New-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $ResourceGroupName `
            -Location $Location -SecurityRules $rdpRule
    }
    else {
        Write-Host "NSG $NsgName already exists; not rewriting rules. Update Allow-RDP-Operator if your public IP changed."
    }

    $vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $vnet) {
        $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetPrefix -NetworkSecurityGroup $nsg
        $vnet = New-AzVirtualNetwork -Name $VnetName -ResourceGroupName $ResourceGroupName `
            -Location $Location -AddressPrefix $VnetPrefix -Subnet $subnetConfig
    }
    else {
        $vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $ResourceGroupName
    }

    $dcVm = New-LabWindowsVm -Name $DcName -PrivateIp $DcPrivateIp -VirtualNetwork $vnet -Nsg $nsg -Credential $credential
    $mgmtVm = New-LabWindowsVm -Name $MgmtName -PrivateIp $MgmtPrivateIp -VirtualNetwork $vnet -Nsg $nsg -Credential $credential

    $dcPip = (Get-AzPublicIpAddress -Name "pip-$DcName" -ResourceGroupName $ResourceGroupName).IpAddress
    $mgmtPip = (Get-AzPublicIpAddress -Name "pip-$MgmtName" -ResourceGroupName $ResourceGroupName).IpAddress

    [pscustomobject]@{
        ResourceGroup     = $rg.ResourceGroupName
        DomainController  = $DcName
        DcPrivateIp       = $DcPrivateIp
        DcPublicIp        = $dcPip
        ManagementVm      = $MgmtName
        MgmtPrivateIp     = $MgmtPrivateIp
        MgmtPublicIp      = $mgmtPip
        RdpSourcePrefix   = $operatorIp
        NextStep          = "RDP to $dcPip as $AdminUsername and run scripts/Install-ADDSForest.ps1"
    } | Format-List
}
