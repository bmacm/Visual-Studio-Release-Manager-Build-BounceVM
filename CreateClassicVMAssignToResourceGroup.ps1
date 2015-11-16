
#REQUIRES -Version 4.0 
#REQUIRES -Modules Azure
Function Create-BuildBounceVM{
<#
.SYNOPSIS
This script Creates a classic VM, disk and cloud service into a resource group. 

.DESCRIPTION
This Script created a Classic VM with disks and cloud service and moves all assets to a given ARM Resource group for ease of management. The script will wait on the VM booting
before connecting to the VM and configuring a remote PowerShell interface with authentication setup for the given Azure subscription. 
Note MAKE SURE YOU UPGRADE TO POWERSHELL 4.0 BEFORE RUNNING THIS, BUG IN v3 CAUSES AN ERROR.

To get the latest image for the given product do not enter the optional OSImageName, if you want a specific image at a given date specify the image name.

.EXAMPLE
Create-BuildBounceVM -AzureSubscriptionName "Development" -VMName "bldbounce" -Location "North Europe" -StorageAccountName "buildbouncedev" -VMSize "ExtraSmall" -OSName "Windows Server 2012 R2 Datacenter" -VMUserName "Ouradmin" -VMPassword "MyPasswordIs-01" -ResourceGroupName "BuildBounce"
always get the latest image

.EXAMPLE
Create-BuildBounceVM -AzureSubscriptionName "Development" -VMName "bldbounce" -Location "North Europe" -StorageAccountName "buildbouncedev" -VMSize "ExtraSmall" -OSName "Windows Server 2012 R2 Datacenter" -VMUserName "Ouradmin" -VMPassword "MyPasswordIs-01" -ResourceGroupName "BuildBounce"
use the exact image defined

#>
    [CmdletBinding()]
    Param 
    ( 
        [parameter(Mandatory=$true)] [String] $AzureSubscriptionName, 
        [parameter(Mandatory=$true)] [String] $VMName,
        [parameter(Mandatory=$true)] [String] $VMUserName,
        [parameter(Mandatory=$true)] [String] $VMPassword,
        [parameter(Mandatory=$true)] [String] $OSName,
        [parameter(Mandatory=$false)] [String] $OSImageName,
        [parameter(Mandatory=$true)] [String] $Location, 
        [parameter(Mandatory=$true)] [String] $StorageAccountName,
        [parameter(Mandatory=$true)] [String] $ResourceGroupName,
        [parameter(Mandatory=$false)] [String] $VMSize = "ExtraSmall"   
    )
        
        

        Switch-AzureMode AzureResourceManager

         
        Select-AzureSubscription -SubscriptionName $AzureSubscriptionName 
        $sub = Get-AzureSubscription -SubscriptionName $AzureSubscriptionName 
             
        Write-Output ("Checking if Resource Group '{0}' exists" -f $ResourceGroupName) 
        $newResourceGroup = Get-AzureResourceGroup -Name $ResourceGroupName

        if($newResourceGroup -eq $null){
            Write-Output ("Resource Group '{0}' does not exist, creating it..." -f $ResourceGroupName) 

            New-AzureResourceGroup -Name $ResourceGroupName -Location $Location -Force
            $newResourceGroup = Get-AzureResourceGroup -Name $ResourceGroupName

            Write-Output ("Resource Group '{0}' created" -f $ResourceGroupName)
        }

        Write-Output ("Checking whether VM '{0}' already exists.." -f $VMName) 
            
        Switch-AzureMode AzureServiceManagement
            
        $AzureVM = Get-AzureVM -Name $VMName -ServiceName $VMName
        if ($AzureVM -eq $null)
                                                                                                                                                                                                                                      { 
            Write-Output ("VM '{0}' does not exist. Will create it." -f $VMName) 
            Write-Output ("Getting the VM Image list for OS '{0}'.." -f $OSName) 
            
            # get OS Image list for $OSName 
            # then get the latest version of that OS image available. 
            $OSImages= $null
            
            if($OSImageName -eq $null){
                $OSImages = Get-AzureVMImage |
                         Where-Object {($_.Label -ne $null) -and ($_.Label.Contains($OSName)) -and ($_.PublisherName.Contains("Microsoft Windows Server Group"))} 
            }else{
                $OSImages = Get-AzureVMImage |
                         Where-Object {($_.Label -ne $null) -and ($_.Label.Contains($OSName)) -and ($_.PublisherName.Contains("Microsoft Windows Server Group")) -and ($_.ImageName.Contains($OSImageName))}
            }
            
            
            if ($OSImages -eq $null)  
            { 
                throw "'Get-AzureVMImage' activity: Could not get OS Images whose label contains OSName '{0}'" -f $OSName 
            }  
            Write-Output ("Got the VM Image list for OS '{0}'.." -f $OSName) 
             
            $OSImages = $OSImages | Sort-Object -Descending -Property PublishedDate  
            $OSImage = $OSImages |  Select-Object -First 1  
                                   
            if ($OSImage -eq $null)  
            { 
                throw " Could not get an OS Image whose label contains OSName '{0}'" -f $OSName 
            } 

            Write-Output ("The latest VM Image for OS '{0}' is '{1}'. Will use it for VM creation" -f $OSName, $OSImage.ImageName) 
            Write-Output "Creating Storage Account" 

            $result = New-AzureStorageAccount -StorageAccountName $StorageAccountName -Location $Location
                 
            if ($result -eq $null) 
            { 
                throw "Azure Storage Account '{0}' was not created successfully" -f $StorageAccountName 
            }  
            else 
            { 
                Write-Output ("Storage account '{0}' was created successfully, now moving it to the correct Resource Group" -f $StorageAccountName)
                MoveSingleAssetToNewResourceGroupDeleteOldResourceGroup -ResourceName $StorageAccountName -ResourceGroupToMoveTo $ResourceGroupName
            } 
    
            Set-AzureSubscription -SubscriptionName $AzureSubscriptionName -CurrentStorageAccountName $StorageAccountName 
             
            Write-Output ("Creating VM with service name  {0}, VM name {1}, image name {2}, Location {3}" -f $VMName, $VMName, $OSImage.ImageName, $Location) 
            Write-Output ("Grab a drink, this will take 10+ minutes, please wait...")

            # Create VM     
            if( $OSImage.OS -eq "Windows" ) 
            { 
                New-AzureQuickVM -Windows -ServiceName $VMName -Name $VMName -ImageName $OSImage.ImageName -Password $VMPassword -AdminUserName $VMUserName -Location $Location -InstanceSize $VMSize -WaitForBoot
            } 
     
            #check the VM was created and move it to the correct ResourceGroup
            $AzureVM = Get-AzureVM -ServiceName $VMName -Name $VMName 
            if ( ($AzureVM -ne $null) )  
            { 
                  Write-Output ("VM '{0}' with OS '{1}' was created successfully. " -f $VMName, $OSName)
                  Write-Output ("Now moving VM to the correct location")

                  MoveVMToNewResourceGroupDeleteOldResourceGroup -VMResourceName $VMName -ResourceGroupToMoveTo $ResourceGroupName  
                  
            } 
            else 
            { 
                throw "Could not retrieve info for VM '{0}'. VM was not created" -f $VMName 
            }  
         
        }
        else 
        { 
            Write-Output ("VM '{0}' already exists. Not creating it again" -f $VMName) 
        }
    }

Function MoveSingleAssetToNewResourceGroupDeleteOldResourceGroup{
    
    Param 
    ( 
        [parameter(Mandatory=$true)] [String] $ResourceName, 
        [parameter(Mandatory=$true)] [String] $ResourceGroupToMoveTo 
    )

    Switch-AzureMode AzureResourceManager

    #first find out what resource group the asset is in just now...
    $currentResource = Get-AzureResource -ResourceName $ResourceName
    
    if($currentResource -eq $null)
    {
         throw "Could not retrieve info for resource name '{0}'. Resource was not moved to the correct resource group." -f $ResourceName 
    }
    else{

        Write-Output ("RG name '{0}' found. Now moving the assets to '{1}'" -f $currentResource.ResourceGroupName, $ResourceGroupToMoveTo) 
       
        Move-AzureResource -DestinationResourceGroupName $ResourceGroupToMoveTo -ResourceId $currentResource.ResourceId -force

        #check if the original resource group has 0 assets left in it, if so delete it. Else print warning
        $rgAfterMove = Get-AzureResource -ResourceGroupName $currentResource.ResourceGroupName;

        if ($rgAfterMove -eq $null)
        {
            Remove-AzureResourceGroup -Name $currentResource.ResourceGroupName -Force
        }
        else
        {
            Write-Warning ("WARNING : RG name '{0}' has assets remaining. This will not be deleted, please review manually" -f $currentResource.ResourceGroupName) 
        }
    }

    Switch-AzureMode AzureServiceManagement
}

Function MoveVMToNewResourceGroupDeleteOldResourceGroup{
    
     Param 
    ( 
        [parameter(Mandatory=$true)] [String] $VMResourceName,
        [parameter(Mandatory=$true)] [String] $ResourceGroupToMoveTo 
    )

    Switch-AzureMode AzureResourceManager

    #first find out what resource group the VM is in. Note VM and Cloud Service will always be in the same resource group.
    $currentResource = Get-AzureResource -ResourceName $VMResourceName | Where-Object {$_.ResourceType -eq "Microsoft.ClassicCompute/virtualMachines"}
    $currentCloudServiceResource = Get-AzureResource -ResourceName $VMResourceName
    
    if(($currentResource -eq $null) -or ($currentCloudServiceResource -eq $null ))
    {
         throw "Could not retrieve info for VM. Resource was not moved to the correct resource group."
    }
    else{
        
        Write-Output ("RG name '{0}' found. Now moving the assets to '{1}'" -f $currentResource.ResourceGroupName, $ResourceGroupToMoveTo) 
         
        Get-AzureResource |?{$_.Name -eq $VMResourceName } | Move-AzureResource -DestinationResourceGroupName $ResourceGroupToMoveTo -force
            
        #check if the original resource group has 0 assets left in it, if so delete it. Else print warning
        $rgAfterMove = Get-AzureResource -ResourceGroupName $currentResource.ResourceGroupName;

        if ($rgAfterMove -eq $null)
        {
             Remove-AzureResourceGroup -Name $currentResource.ResourceGroupName -Force
             Write-Output ("All Done...")
        }
        else
        {
             Write-Warning ("WARNING : RG name '{0}' has assets remaining. This will not be deleted, please review manually" -f $currentResource.ResourceGroupName) 
        }    
    }

    Switch-AzureMode AzureServiceManagement
}