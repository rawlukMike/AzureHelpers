<#
.SYNOPSIS
	Get total / tag / resourcegroup cost in subscription range

.DESCRIPTION
	This script gets cost of subscription (with possible filter on RG and TAG),
	and return JSON with organized grouped data
	Result Written on Screen

	It assumes env are set: AppId, AppSecret, TenantId

.PARAMETER What
	(Mandatory) What should be filtered.
	Accepted values: Subscription, ResourceGroup, Tag

.PARAMETER WhatValue
	(Mandatory) Name of Subcription, Tag or ResourceGroup

.PARAMETER StartDate
	(Mandatory) Start date of costs.
	Format: day/month/year Sorry America this is better.
	WARNING: This is really heavy script. Run time 30min+ for 10 days.

.PARAMETER EndDate
	(Mandatory) End date of costs.
	Format: day/month/year Sorry America this is better.
	WARNING: This is really heavy script. Run time 30min+ for 10 days.

.PARAMETER WhatValue
	(Mandatory) Name of Subcription on which we apply script

.EXAMPLE
    PS C:\> getCost.ps1 -What "Subscription" -WhatValue "ExampleSubscription" -StartDate "29/07/2019" -EndDate "03/08/2019" -Subscription "ExampleSubscription"
	Will give output for ExampleSubscription with all RG

.EXAMPLE
    PS C:\> getCost.ps1 -What "Tag" -WhatValue "CostCenter=Mike" -StartDate "29/07/2019" -EndDate "03/08/2019" -Subscription "ExampleSubscription"
	Will give output for ExampleSubscription with resources taged with tag and value : CostCenter=Mike

.EXAMPLE
    PS C:\> getCost.ps1 -What "ResourceGroup" -WhatValue "SampleRG" -StartDate "29/07/2019" -EndDate "03/08/2019" -Subscription "ExampleSubscription"
	Will give output for ExampleSubscription with resources within "SampleRG" resource group
	
.NOTES
    Authors: Michal Rawluk (deprecated), Maciej Rawluk
    Last Edit: 2019-09-11
    Version 1.0 (First Release)
#>

[CmdletBinding()]
Param
(
	[Parameter(Mandatory=$True,
	Position=0)]
	[ValidateSet("Subscription", "ResourceGroup", "Tag")]
	[string]$What,

	[Parameter(Mandatory=$True,
	Position=1)]
	[string]$WhatValue,

	[Parameter(Mandatory=$True, 
	Position=2)]
	[string]$StartDate,

	[Parameter(Mandatory=$True,
	Position=3)]
	[string]$EndDate,

	[Parameter(Mandatory=$True,
	Position=4)]
	[string]$SubscriptionName
)
function ArrayToHash($a)
{
    $hash = [ordered]@{}
    $a | foreach { $hash[$_.ResourceGroupName] = $_.Tags }
    return $hash
}

function RGFromInstanceId ([string]$InstanceId)
{
	[regex]$regex = '(?i)resourcegroups\/(.*?)\/'
	$returnvalue = $regex.Match($InstanceId).Groups[1].Value.ToLower()
	if($returnvalue.Length -lt 2) 
	{
		return "Security-Costs"

	}
	if($returnvalue -eq '$system') 
	{
		return "None"
	}
    return $returnvalue
}

function Get-SubscriptionCost
{
	Param(
		[string]$What,
		[string]$WhatValue,
		[string]$Start,
		[string]$End
	)

	begin
	{
		$OutputTable = @()
		if($What -eq 'Subscription')
		{
			$Table = Get-AzConsumptionUsageDetail -StartDate $Start -EndDate $End | ` #-ErrorAction SilentlyContinue | `
			Select-Object @{name="ResourceGroup";Expression={RGFromInstanceId($_.InstanceId)}},PretaxCost | `
			Sort-Object ResourceGroup | Group-Object ResourceGroup
		}
		
		if($What -eq 'ResourceGroup')
		{
			$Table = Get-AzConsumptionUsageDetail -StartDate $Start -EndDate $End -ResourceGroup $WhatValue | ` #-ErrorAction SilentlyContinue | `
			Select-Object @{name="ResourceGroup";Expression={RGFromInstanceId($_.InstanceId)}},PretaxCost | `
			Sort-Object ResourceGroup | Group-Object ResourceGroup
		}
		
		if($What -eq 'Tag')
		{
			$hashedTag = ConvertFrom-StringData $WhatValue
			$TaggedResourceGroup = Get-AzResourceGroup -Tag $hashedTag
			$Table = @{}
			foreach ($ResourceGroups in $TaggedResourceGroup)
			{
				$tmpTable = Get-AzConsumptionUsageDetail -StartDate $Start -EndDate $End -ResourceGroup $ResourceGroups.ResourceGroupName | ` #-ErrorAction SilentlyContinue | `
				Select-Object @{name="ResourceGroup";Expression={$_.InstanceId.Split('/')[4]}},PretaxCost | `
				Sort-Object ResourceGroup | Group-Object ResourceGroup	
				$Table[$ResourceGroups.ResourceGroupName] = $tmpTable
			}
		}
	}
  
	process
	{
		# Formating result
		if($Table -is [Hashtable] )
		{
			foreach ($Data in $Table.Keys)
			{
				foreach ($Row in $Table[$Data])
				{
					$Output = "" | Select-Object -Property SubscriptionName,ResourceGroupName,Cost,Total 
					$Output.ResourceGroupName = $Row.Name
					$Output.Cost = [decimal]($Row.Group | Measure-Object -Sum -Property PretaxCost).Sum
					$TotalCost += $Output.Cost
					$OutputTable += $Output
				}
			}
		}
		else
		{
			ForEach ($Row in $Table) {
				$Output = "" | Select-Object -Property SubscriptionName,ResourceGroupName,Cost,Total 
				$Output.ResourceGroupName = $Row.Name
				$Output.Cost = [decimal]($Row.Group | Measure-Object -Sum -Property PretaxCost).Sum
				$TotalCost += $Output.Cost
				$OutputTable += $Output
			}
		}
	}
  
	end 
	{	
		# Create a dictionary with RG tags information
		$ResourceGroups = Get-AzResourceGroup | Select ResourceGroupName, Tags
		$RGTagsInfo = ArrayToHash($ResourceGroups)
		# Preparing Result JSON
		$SubJson = @{}
		$RGArray = [ordered]@{}
		foreach ($xxx in $OutputTable) 
		{
			if($RGTagsInfo[$xxx.ResourceGroupName] -and $RGTagsInfo[$xxx.ResourceGroupName]["CostCenter"])
			{
				$TempCostCenter = $RGTagsInfo[$xxx.ResourceGroupName]["CostCenter"]
			}
			else 
			{
				$TempCostCenter = "None"
			}
			$RGArray[$xxx.ResourceGroupName] = @{CostCenter=$TempCostCenter;Cost=$xxx.Cost}
		}
		$SubJson['SubscriptionName'] = $SubscriptionName
		$SubJson['TotalCost'] = $TotalCost
		$SubJson['Details'] = $RGArray

		$SubJson['StartDate'] = $Start
		$SubJson['EndDate'] = $End
		if ($What -eq "Tag")
		{
			$SubJson['Tag'] = $WhatValue
		}
		$ASDFG = ConvertTo-Json -Inputobject $SubJson
		Write-host $ASDFG
	}
}

# SCRIPT START

# Checking if dates are correct
$TodayDate = Get-Date -UFormat "%d/%m/%Y"
$CastedStartDate = [datetime]::ParseExact("$StartDate", "dd/MM/yyyy", $CultureInfo.InvariantCulture)
$CastedEndDate = [datetime]::ParseExact("$EndDate", "dd/MM/yyyy", $CultureInfo.InvariantCulture)
$CastedTodayDate = [datetime]::ParseExact("$TodayDate", "dd/MM/yyyy", $CultureInfo.InvariantCulture)
if($CastedStartDate -gt $CastedTodayDate){
	'START DATE IS NEWER THAN TODAYS DATE'
	break;
}
if($CastedEndDate -gt $CastedTodayDate){
	'END DATE IS NEWER THAN TODAYS DATE'
	break;
}
# Setting Up Auth
$userId = $env:AppId
$password = ConvertTo-SecureString $env:AppSecret -AsPlainText -Force
$cred = new-object -typename System.Management.Automation.PSCredential($userId, $password)
Connect-AzAccount -Credential $cred -ServicePrincipal -Tenant $env:TenantId -WarningAction silentlyContinue | Out-Null
$Subscription = Select-AzSubscription -SubscriptionName $SubscriptionName				
if(!$Subscription) 
{
	"`nSubscription not found"
	break;
}
Get-SubscriptionCost  -What $What -WhatValue $WhatValue -Start $StartDate -End $EndDate
