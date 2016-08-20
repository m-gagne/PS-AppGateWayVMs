# ENABLE GLOBAL DEBUG
$DebugPreference = "Continue"
$ErrorActionPreference = "Stop"

# VARIABLES
$envPrefix              = "pstest1"                                 # Used as prefix for naming (must be lowercase)
$resgroup               = $envPrefix + "RG"                         # Resource Group Name
$vmname                 = $envPrefix + "VM"                         # Virtual Machine Name (will have number postfixed)  
$storageAccName         = $envPrefix + "primarystorage"             # Default Storage Account Name (must be lowercase)
$gatewayIpName          = $envPrefix + "GatewayPIP"                 # Name of Application Gateway Public IP Address
$virtualNetName         = $envPrefix + "PrimaryNetwork"             # Name of default virtual network for the resource group
$publicIPName           = $envPrefix + "PublicIp"                   # VM Public IP Address name
$defaultSubnet          = $envPrefix + "Subnet"                     # Default Subnet for VMS
$nicName                = $envPrefix + "NIC"                        # Network Interface Card (NIC) name for VMs 
$availabilitySet        = $envPrefix + "AS"                         # Primary Availability Set for VMs
$gatewaySubnetName      = $envPrefix + "GatewaySubnet"              # Subnet for Application Gateway
$gatewayIPConfigName    = $envPrefix + "GatewayIPConfig"            # Configuration name for Application Gateway IP Config
$gatewayName            = $envPrefix + "AppGateway"                 # Name for Application Gateway
$gatewayPool            = "PrimaryPool"                             # Name for Application Gateway Pool
$gatewaySku             = "Standard_Small"                          # Gateway Size
$gatewayCapacity        = 1                                         # Gateway Capacity
$ipAllocationType       = "Dynamic"                                 # Static or Dynamic IP Allocation
$location               = "East US"                                 # Location for all resources
$vmsize                 = "Standard_A1"                             # Run Get-AzureRmVMSize -Location <Location> for sizes
$vmsInSet               = 2                                         # Number of VMs to create and assign to Application Gateway
$vnetBlock              = "10.0.0.0/16"                             # Virutal Network address block
$defaultSubnetBlock     = "10.0.0.0/24"                             # Default subnet block
$gatewaySubnetBlock     = "10.0.1.0/24"                             # Subnet block for Application Gateway

# CACHE
$poolIps = @() # Array of LB pool IPs
  
# Get credentials for creating the local account on Windows Server machines
$cred = Get-Credential
 
###############################################################################
# CREATE RESOURCE GROUP
###############################################################################
write-host "Creating Resource Group: " + $resgroup
New-AzureRmResourceGroup -Name $resgroup -location $location
 
###############################################################################
# CREATE STORAGE ACCOUNT
###############################################################################
write-host "Creating Storage Account: " + $storageAccName
$storageAccount = New-AzureRmStorageAccount -ResourceGroupName $resgroup -Name $storageAccName -SkuName "Standard_LRS" -Location $location
 
###############################################################################
# CREATE VIRTUAL NETWORK
###############################################################################
write-host "Creating Virtual Network: " + $virtualNetName
 
# Configuration for the default subnet
$subnet = New-AzureRmVirtualNetworkSubnetConfig -Name $defaultSubnet -AddressPrefix $defaultSubnetBlock
 
# Create the virtual network
$vnet = New-AzureRmVirtualNetwork -Name $virtualNetName -ResourceGroupName $resgroup -Location $location -AddressPrefix $vnetBlock -Subnet $subnet
 
# Update the subnet object reference to contain values updated during creation such as Id etc.
$subnet = $vnet.Subnets[0]
 
###############################################################################
# CREATE AVAILBILITY SET
###############################################################################
write-host "Creating Availability Set: " + $availabilitySet
$as = New-AzureRmAvailabilitySet -ResourceGroupName $resgroup -Name $availabilitySet -Location $location
 
 
###############################################################################
# CREATE THE VIRTUAL MACHINES
###############################################################################
For ($i = 0; $i -lt $vmsInSet; $i++) {
    # Create a 3 digit padded number e.g. 001, 002 etc. to make VM names unique
    $number = "{0:D3}" -f ($i+1)
    
    # Define VM config
    $uniqueVmName = ($vmname + $number)
    write-host "Creating VM: " + $uniqueVmName

    $vm = New-AzureRmVMConfig -VMName $uniqueVmName -VMSize $vmsize 
    $vm = Set-AzureRmVMOperatingSystem -VM $vm -Windows -ComputerName $uniqueVmName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
    $vm = Set-AzureRmVMSourceImage -VM $vm -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus 2012-R2-Datacenter -Version "latest"   
    
    # Create a public IP per VM
    $pip = New-AzureRmPublicIpAddress -Name ($publicIPName + $number) -ResourceGroupName $resgroup -Location $location -AllocationMethod $ipAllocationType

    # Create a network interface for the VM
    $nic = New-AzureRmNetworkInterface -Name ($nicName + $number)  -ResourceGroupName $resgroup -Location $location -SubnetId $subnet.Id -PublicIpAddressId $pip.Id
    
    # Add the NIC to the Virtual Network
    $vm = Add-AzureRmVMNetworkInterface -VM $vm -Id $nic.Id
    
    # Define OS disk detaails
    $osDiskName = $uniqueVmName + "osDisk.vhd"
    $osDiskUri = $storageAccount.PrimaryEndpoints.Blob.ToString() + "vhds/" + $osDiskName 
    Set-AzureRmVMOSDisk -VM $vm -Name $osDiskName -VhdUri $osDiskUri -CreateOption fromImage

    # Configigure availability set
    $asRef = New-Object Microsoft.Azure.Management.Compute.Models.SubResource 
    $asRef.Id = $as.Id 
    $vm.AvailabilitySetReference = $asRef
 
    # Create the VM
    $vm = New-AzureRmVM -ResourceGroupName $resgroup -Location $location -VM $vm

    # Get the VM details (properties are updated after creation)
    $vm = Get-AzureRmVM -ResourceGroupName $resgroup -Name $uniqueVmName
    $nic = Get-AzureRmNetworkInterface -ResourceGroupName $resgroup -Name ($nicName + $number)
    $pip = Get-AzureRmPublicIpAddress -ResourceGroupName $resgroup -Name ($publicIPName + $number)

    # Cache the list of public IP addresses for the VMs, used later for the Application Gateway load balancing
    $poolIps += $pip.IpAddress
}
 
###############################################################################
# CREATE THE APPLICATION GATEWAY
###############################################################################
write-host "Creating Application Gateway: " + $gatewayName
 
# Create subnet for Gateway
$vnet = Add-AzureRmVirtualNetworkSubnetConfig -AddressPrefix $gatewaySubnetBlock -Name $gatewaySubnetName -VirtualNetwork $vnet
 
# Apply subnet config to vnet:
$vnet = Set-AzureRmVirtualNetwork -VirtualNetwork $vnet

# Update subnet reference
$gatewaySubnet = $vnet.Subnets[-1]

# Create a pulic IP for the gateway
$gatewayPublicIp = New-AzureRmPublicIpAddress -ResourceGroupName $resgroup -name $gatewayIpName -location $location -AllocationMethod $ipAllocationType

# Define config
$gipconfig = New-AzureRmApplicationGatewayIPConfiguration -Name $gatewayIPConfigName -Subnet $gatewaySubnet
 
# Define backend pool
$pool = New-AzureRmApplicationGatewayBackendAddressPool -Name $gatewayPool -BackendIPAddresses $poolIps
 
$poolSetting = New-AzureRmApplicationGatewayBackendHttpSettings -Name "HTTP" -Port 80 -Protocol Http -CookieBasedAffinity Enabled

# Define front end port 80
 
$fp = New-AzureRmApplicationGatewayFrontendPort -Name ($gatewayName + "HTTP")  -Port 80
 
$fipconfig = New-AzureRmApplicationGatewayFrontendIPConfig -Name ($gatewayIPConfigName + "FE") -PublicIPAddress $gatewayPublicIp

# Create the listener
$listener = New-AzureRmApplicationGatewayHttpListener -Name ($gatewayName + "Listener") -Protocol Http -FrontendIPConfiguration $fipconfig -FrontendPort $fp
 
# Gatway rule
$rule = New-AzureRmApplicationGatewayRequestRoutingRule -Name rule01 -RuleType Basic -BackendHttpSettings $poolSetting -HttpListener $listener -BackendAddressPool $pool

# Define the sku
$sku = New-AzureRmApplicationGatewaySku -Name $gatewaySku -Tier Standard -Capacity $gatewayCapacity
 
# Create the actual application gateway
$appgw = New-AzureRmApplicationGateway -Name $gatewayName -ResourceGroupName $resgroup -Location $location -BackendAddressPools $pool -BackendHttpSettingsCollection $poolSetting -FrontendIpConfigurations $fipconfig  -GatewayIpConfigurations $gipconfig -FrontendPorts $fp -HttpListeners $listener -RequestRoutingRules $rule -Sku $sku