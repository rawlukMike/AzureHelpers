<#
.SYNOPSIS
	Get Total Cost of Every Subscription in Service Principal Range

.DESCRIPTION
	This script gets all the cost of every subscription, and organize that one into nice Json
	Result file contain not only total cost per each subscription,
	but also grouping per cost center, and resource group.
	Result is written to execution directory as RESULT.JSON

	It assumes env are set: AppId, AppSecret, TenantId

.PARAMETER StartDate
	(Mandatory) Start date of costs.
	Format: day/month/year Sorry America this is better.
	WARNING: This is really heavy script. Run time 30min+ for 10 days.

.PARAMETER EndDate
	(Mandatory) End date of costs.
	Format: day/month/year Sorry America this is better.
	WARNING: This is really heavy script. Run time 30min+ for 10 days.

.EXAMPLE
    PS C:\> getTotalCost.ps1 -StartDate "29/07/2019" -EndDate "03/08/2019"
    
.NOTES
    Authors: Michal Rawluk (deprecated), Maciej Rawluk
    Last Edit: 2019-09-11
    Version 1.0 (First Release)
#>
[CmdletBinding()]
Param
(
	[Parameter(Mandatory=$True, 
	Position=2)]
	[string]$StartDate,

	[Parameter(Mandatory=$True,
	Position=3)]
	[string]$EndDate
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

function Get-ZFAzureCost
{
	Param(
		[string]$Start,
		[string]$End
	)
	# Holder for ALL Subs
	$SubDictionary=[ordered]@{}

	# Uncomment for testing
	#$AllSubs = @("ProviderCloud", "Openmatics Development")

	$AllSubs = Get-AzSubscription | Where State -ie "Enabled" | Select Name
	

	$TotalCount = $AllSubs.Count
	$Counter = 1

	foreach ($subName in $AllSubs)
	{
		# Comment next line out for testing 
		$subName = $subName.Name
		Write-Host "Subscription: " $subName "   " ([math]::Round(($Counter*100)/$TotalCount,1)) "%"
		$Counter = $Counter+1
		$OutputTable = @()
		$TotalCost = 0
		$NullOutput = Select-AzSubscription -SubscriptionName $subName

		try
		{
			# Create a dictionary with RG tags information
			$ResourceGroups = Get-AzResourceGroup | Select ResourceGroupName, Tags
			$RGTagsInfo = ArrayToHash($ResourceGroups)
		}
		catch
		{
			$SubDictionary[$subName] = @("ResourceGroup to cost center mapping problem.")
		}

		# Get All Cost Data for Subscription
		try{
			$SuperRaw = Get-AzConsumptionUsageDetail -StartDate $Start -EndDate $End -ErrorAction SilentlyContinue
			if(!$SuperRaw)
			{
				$SubDictionary[$subName] += "AzConsumptionUsageDetail failed."
				Continue
			}
			$LessRaw = $SuperRaw | Select-Object @{name="ResourceGroup";Expression={RGFromInstanceId($_.InstanceId)}}, PretaxCost
			$SubCostData = $LessRaw | Select-Object ResourceGroup, PretaxCost, @{name="CostCenter";Expression= {$RGTagsInfo[$_.ResourceGroup]["CostCenter"]}}
			$SubCostData = $SubCostData | Sort-Object ResourceGroup
			$SubCostData = $SubCostData | Group-Object ResourceGroup
	
			ForEach ($Row in $SubCostData) 
			{
				$Output = "" | Select-Object -Property SubscriptionName,ResourceGroupName,Cost,CostCenter 
				$Output.ResourceGroupName = $Row.Name
				$Output.SubscriptionName = $subName
				$Output.Cost = [decimal]($Row.Group | Measure-Object -Sum -Property PretaxCost).Sum
				$TotalCost += $Output.Cost
				if ($RGTagsInfo[$Row.Name]) 
				{
					if ($RGTagsInfo[$Row.Name]["CostCenter"]) {$Output.CostCenter = $RGTagsInfo[$Row.Name]["CostCenter"]}
					else {$Output.CostCenter = "None"}
				}
				else 
				{
					$Output.CostCenter = "None"
				}
				$OutputTable += $Output
			}
			$CostDictionary = @{}
			$ResourceGroupsDictionary = @{} 

			foreach($rg in $OutputTable)
			{
				$ResourceGroupsDictionary[$rg.ResourceGroupName] = @{"Cost"=$rg.Cost;"CostCenter"=$rg.CostCenter}
			}

			$SubDictionary[$subName] = @{ResourceGroups = $ResourceGroupsDictionary; TotalCost=$TotalCost}
			
			$OutputTable | Group-Object { $_.CostCenter } | ForEach-Object {
				$CostDictionary[$_.Name] = ($_.Group | Measure-Object Cost -Sum).Sum
			}
			$SubDictionary[$subName]["PerCostCenter"] = $CostDictionary
		}
		catch
		{
			$SubDictionary[$subName] += "Grouping Error"
			Continue
		}
	}
	$SubDictionary["StartDate"] = $Start
	$SubDictionary["EndDate"] = $End
	Return ConvertTo-Json -Depth 100 -Inputobject $SubDictionary
}

# SCRIPT START

# Checking if dates are correct
$TodayDate = Get-Date -UFormat "%d/%m/%Y"
$CastedStartDate = [datetime]::ParseExact("$StartDate", "dd/MM/yyyy", $CultureInfo.InvariantCulture)
$CastedEndDate = [datetime]::ParseExact("$EndDate", "dd/MM/yyyy", $CultureInfo.InvariantCulture)
$CastedTodayDate = [datetime]::ParseExact("$TodayDate", "dd/MM/yyyy", $CultureInfo.InvariantCulture)
if($CastedStartDate -gt $CastedTodayDate){
	Write-Host 'START DATE IS NEWER THAN TODAYS DATE'
	break;
}
if($CastedStartDate -gt $CastedEndDate){
	Write-Host 'START DATE IS NEWER THAN END DATE'
	break;
}


# Setting Up Auth
$userId = $env:AppId
$password = ConvertTo-SecureString $env:AppSecret -AsPlainText -Force
$cred = new-object -typename System.Management.Automation.PSCredential($userId, $password)
Connect-AzAccount -Credential $cred -ServicePrincipal -Tenant $env:TenantId -WarningAction silentlyContinue | Out-Null

Get-ZFAzureCost  -Start $StartDate -End $EndDate | Out-File "RESULT.JSON"
