<#
.SYNOPSIS
    A read-only script that analyzes VMware vSphere cluster balance and provides VM migration recommendations.
.DESCRIPTION
    This script connects to a vCenter Server to analyze cluster balance and displays    # Get all connected hosts in the current cluster, excluding those in maintenance mode or entering maintenance mode.
    $hostsInCluster = Get-VMHost -Location $cluster -State Connected | Where-Object { 
        $_.Name -notin $allMaintenanceHosts.Name 
    }
    if ($hostsInCluster.Count -lt 2) {
        Write-Warning "Cluster '$($cluster.Name)' has fewer than two hosts. DRS analysis is not applicable."
        
        # Still add any evacuation recommendations to the final results
        if ($clusterRecommendations.Count -gt 0) {
            Write-ConditionalHost "`n--- Recommendations for Cluster: $($cluster.Name) ---" -ForegroundColor Green
            Write-ConditionalHost "  Total Recommendations: $($clusterRecommendations.Count)" -ForegroundColor Cyan
            
            if (-not $Quiet) {
                $clusterRecommendations | Format-Table -AutoSize | Out-Host
            }
        }
        $allRecommendations += $clusterRecommendations
        continue
    } analysis details and recommendations to the console on a per-cluster basis.
    
    Automatically detects hosts in maintenance mode or entering maintenance mode and generates 
    critical evacuation recommendations that bypass all DRS rules and affinity groups.
    Both evacuation and normal DRS recommendations are combined in the output.
.PARAMETER vCenterServer
    The FQDN or IP address of the vCenter Server.
.PARAMETER ExportToCsv
    If specified, exports all migration recommendations to a single CSV file at the end.
.PARAMETER BypassHostRulesAndGroups
    If specified, will ignore all VM/Host affinity and anti-affinity rules.
.PARAMETER MigrationThreshold
    An integer from 1 to 5 that controls the aggressiveness of migration recommendations.
    1 is the most conservative, 5 is the most aggressive. Defaults to 3.
.PARAMETER Balance
    If specified, generates load balancing recommendations to evenly distribute VMs across hosts
    even when hosts are not resource-constrained. Useful for clusters with uneven VM distribution.
.OUTPUTS
    An array of PSCustomObjects, where each object represents a single VM migration recommendation.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter()]
    [string]$vCenterServer,
    [Parameter()]
    [switch]$ExportToCsv,
    [Parameter()]
    [switch]$BypassHostRulesAndGroups,
    [Parameter()]
    [ValidateSet(1, 2, 3, 4, 5)]
    [int]$MigrationThreshold = 3,
    [Parameter()]
    [switch]$Balance,  # Enable load balancing recommendations for VM distribution
    [Parameter()]
    [string[]]$Clusters,  # Optional cluster name(s) to analyze
    [Parameter()]
    [switch]$NoDisconnect,
    [Parameter()]
    [switch]$Quiet,  # Suppress console output for variable assignment workflows
    [Parameter()]
    [Alias('h', 'v', 'version')]
    [switch]$help
)

# --- Helper Functions ---

function Show-Usage {
    Write-Host "Usage: .\Get-OpenDrsRecommendation.ps1 -vCenterServer <server_name> [options]"
    Write-Host ""
    Write-Host "A read-only script that analyzes VMware vSphere cluster balance and provides VM migration recommendations."
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -vCenterServer <string>     (Required) The FQDN or IP address of the vCenter Server."
    Write-Host "  -Clusters <string[]>        Specify one or more cluster names to analyze (optional)."
    Write-Host "  -ExportToCsv                Export recommendations to a CSV file (only if recommendations exist)."
    Write-Host "  -BypassHostRulesAndGroups   Ignore VM/Host affinity rules."
    Write-Host "  -MigrationThreshold <1-5>   Set migration aggressiveness (1=conservative, 5=aggressive). Default is 3."
    Write-Host "  -Balance                    Generate load balancing recommendations for even VM distribution."
    Write-Host "  -Quiet                      Suppress console output for variable assignment workflows."
    Write-Host "  -Verbose                    Output detailed diagnostic information."
    Write-Host "  -help, -h, -version, -v     Show this help message."
}

if ($help -or ([string]::IsNullOrEmpty($vCenterServer))) {
    Show-Usage
    return
}

# Calculates the standard deviation of a given array of numbers.
function Get-StandardDeviation {
    param([double[]]$array)
    if ($array.Count -lt 2) { return 0 }
    $average = $array | Measure-Object -Average | Select-Object -ExpandProperty Average
    $sumOfSquares = ($array | ForEach-Object { [math]::Pow($_ - $average, 2) }) | Measure-Object -Sum | Select-Object -ExpandProperty Sum
    return [math]::Sqrt($sumOfSquares / ($array.Count - 1))
}

# Helper function to conditionally write to console unless in Quiet mode
function Write-ConditionalHost {
    param(
        [string]$Message,
        [System.ConsoleColor]$ForegroundColor
    )
    if (-not $Quiet) {
        if ($ForegroundColor) {
            Write-Host $Message -ForegroundColor $ForegroundColor
        } else {
            Write-Host $Message
        }
    }
}
# --- Main Script Body ---
# Track whether this script made the connection (and should disconnect later)
$shouldDisconnect = $false

# Check connection status and connect if needed
if ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected) {
    # Check if we're connected to the same server (handle FQDN vs hostname differences)
    $connectedServer = $global:DefaultVIServer.Name
    $targetServer = $vCenterServer
    
    # Compare servers - handle cases where one might be FQDN and other hostname
    $serversMatch = ($connectedServer -eq $targetServer) -or 
                   ($connectedServer.Split('.')[0] -eq $targetServer.Split('.')[0])
    
    if ($serversMatch) {
        Write-ConditionalHost "Already connected to vCenter Server: $connectedServer"
    }
    else {
        Write-ConditionalHost "Connecting to vCenter Server: $vCenterServer..."
        Write-ConditionalHost "Disconnecting existing vCenter session from $connectedServer."
        Disconnect-VIServer -Server $global:DefaultVIServer -Confirm:$false -Force -WhatIf:$false
        Connect-VIServer -Server $vCenterServer -ErrorAction Stop | Out-Null
        Write-ConditionalHost "Successfully connected to $vCenterServer."
        $shouldDisconnect = $true
    }
}
else {
    try {
        Write-ConditionalHost "Connecting to vCenter Server: $vCenterServer..."
        Connect-VIServer -Server $vCenterServer -ErrorAction Stop | Out-Null
        Write-ConditionalHost "Successfully connected to $vCenterServer."
        $shouldDisconnect = $true
    }
    catch {
        Write-Error "Failed to connect to vCenter Server '$vCenterServer'. Please check the server name and your network connection. `n$($_.Exception.Message)"
        exit 1
    }
}
Write-ConditionalHost "`nGathering cluster and host information..."
$allRecommendations = @()
if ($Clusters -and $Clusters.Count -gt 0) {
    try {
        # Simple workaround: if only one cluster, call it directly; if multiple, use splatting
        if ($Clusters.Count -eq 1) {
            $clusters = @(Get-Cluster -Name $Clusters[0] -ErrorAction Stop)
        } else {
            $clusters = Get-Cluster -Name $Clusters -ErrorAction Stop
        }
    }
    catch {
        Write-Error "Failed to retrieve specified clusters: $($_.Exception.Message)"
        if ($shouldDisconnect) {
            Write-ConditionalHost "Disconnecting from $vCenterServer (connection made by $($MyInvocation.MyCommand.Name))."
            Disconnect-VIServer -Confirm:$false -Force -WhatIf:$false
        }
        exit 1
    }
} else {
    $clusters = Get-Cluster
}
if (-not $clusters) {
    Write-Warning "No clusters found on $vCenterServer."
    if ($shouldDisconnect) {
        Write-ConditionalHost "Disconnecting from $vCenterServer (connection made by $($MyInvocation.MyCommand.Name))."
        Disconnect-VIServer -Confirm:$false -Force -WhatIf:$false
    }
    exit 0
}
# Iterate through each cluster found on the vCenter Server.
$clusterIndex = 0
foreach ($cluster in $clusters) {
    $clusterRecommendations = @()
    
    # Use the original cluster name from the input array if available, otherwise try cluster.Name
    $clusterName = if ($Clusters -and $clusterIndex -lt $Clusters.Count) { $Clusters[$clusterIndex] } else { $cluster.Name }
    $clusterIndex++
    
    Write-ConditionalHost "`n--- Analyzing Cluster: $clusterName ---"
    
    # Get ALL hosts in the cluster (including those entering maintenance mode)
    $allHostsInCluster = Get-VMHost -Location $cluster
    
    # Check for hosts in maintenance mode or entering maintenance mode
    $maintenanceModeHosts = $allHostsInCluster | Where-Object { 
        # Host is already in maintenance mode
        $_.ConnectionState -eq 'Maintenance'
    }
    
    # Also check for hosts currently entering maintenance mode (active tasks)
    $hostsEnteringMaintenance = foreach ($esxiHost in $allHostsInCluster) {
        $maintenanceTasks = Get-Task -Status Running | Where-Object { 
            $_.ObjectId -eq $esxiHost.Id -and 
            $_.Name -like "*EnterMaintenanceMode*"
        }
        if ($maintenanceTasks) {
            $esxiHost
        }
    }
    
    # Combine both sets
    $allMaintenanceHosts = @($maintenanceModeHosts) + @($hostsEnteringMaintenance) | Sort-Object Name | Get-Unique
    
    # Process maintenance mode evacuations first (highest priority)
    if ($allMaintenanceHosts.Count -gt 0) {
        Write-ConditionalHost "Found $($allMaintenanceHosts.Count) host(s) in or entering maintenance mode."
        
        foreach ($maintenanceHost in $allMaintenanceHosts) {
            Write-ConditionalHost "Processing evacuation for host: $($maintenanceHost.Name) (State: $($maintenanceHost.ConnectionState))"
            
            # Get all VMs on the maintenance mode host
            $vmsToEvacuate = Get-VM -Location $maintenanceHost | Where-Object { $_.PowerState -eq 'PoweredOn' -or $_.PowerState -eq 'PoweredOff' }
            
            if ($vmsToEvacuate.Count -gt 0) {
                Write-ConditionalHost "  Found $($vmsToEvacuate.Count) VM(s) requiring evacuation from $($maintenanceHost.Name)"
                
                # Get available destination hosts (connected and not in maintenance mode)
                $availableHosts = $allHostsInCluster | Where-Object { 
                    $_.ConnectionState -eq 'Connected' -and 
                    $_.Name -ne $maintenanceHost.Name -and
                    $_.Name -notin $allMaintenanceHosts.Name
                }
                
                if ($availableHosts.Count -eq 0) {
                    Write-Warning "No available destination hosts found for evacuation from $($maintenanceHost.Name)"
                    continue
                }
                
                # Distribute VMs across available hosts for load balancing
                $hostIndex = 0
                foreach ($vm in $vmsToEvacuate) {
                    $destinationHost = $availableHosts[$hostIndex % $availableHosts.Count]
                    
                    # Create evacuation recommendation (bypasses all rules for maintenance mode)
                    $recommendation = [PSCustomObject]@{
                        Cluster = $clusterName
                        VM_to_Move = $vm.Name
                        Reason = "Maintenance Evacuation"
                        Source_Host = $maintenanceHost.Name
                        Source_Host_CPU = "-"
                        Source_Host_Mem = "-"
                        Recommended_Destination_Host = $destinationHost.Name
                        Destination_Host_CPU = "-"
                        Destination_Host_Mem = "-"
                    }
                    
                    $clusterRecommendations += $recommendation
                    Write-ConditionalHost "    EVACUATION: '$($vm.Name)' -> '$($destinationHost.Name)' (Power: $($vm.PowerState))"
                    
                    $hostIndex++
                }
            }
        }
        
        Write-ConditionalHost "Maintenance mode evacuation analysis complete. Generated $($clusterRecommendations.Count) evacuation recommendations."
        
        # Continue with normal DRS analysis even if we have evacuation recommendations
        # Both evacuation and normal recommendations will be combined in the final output
    }
    
    # Get all connected hosts in the current cluster, excluding those in maintenance mode or entering maintenance mode.
    $hostsInCluster = Get-VMHost -Location $cluster -State Connected | Where-Object { 
        $_.Name -notin $allMaintenanceHosts.Name 
    }
    if ($hostsInCluster.Count -lt 2) {
        Write-Warning "Cluster '$clusterName' has fewer than two hosts. DRS analysis is not applicable."
        
        # Still display and add any evacuation recommendations to the final results
        if ($clusterRecommendations.Count -gt 0) {
            Write-ConditionalHost "`n--- Recommendations for Cluster: $clusterName ---" -ForegroundColor Green
            Write-ConditionalHost "  Total Recommendations: $($clusterRecommendations.Count)" -ForegroundColor Cyan
            
            if (-not $Quiet) {
                $clusterRecommendations | Format-Table -AutoSize | Out-Host
            }
        }
        else {
            Write-ConditionalHost "`n--- Recommendations for Cluster: $clusterName ---" -ForegroundColor Green
            Write-ConditionalHost "No migration recommendations for this cluster." -ForegroundColor Yellow
        }
        $allRecommendations += $clusterRecommendations
        continue
    }
    # Read all DRS rules and VM/Host groups for the current cluster, unless bypassed.
    $drsRules = $null
    $vmGroups = @{}
    $hostGroups = @{}
    if (-not $BypassHostRulesAndGroups) {
        Write-ConditionalHost "Reading DRS Rules and Groups for cluster '$clusterName'..."
        $drsRules = Get-DrsRule -Cluster $cluster -WarningAction SilentlyContinue
        
        # Note: VM/Host groups require Get-View which can have issues with cluster objects
        # For now, we'll focus on DRS rules (VM affinity/anti-affinity) which work reliably
        
        if ($PSBoundParameters['Verbose']) {
            Write-Verbose "Populated DRS Rules:"
            $drsRules | Format-List | Out-String | Write-Verbose
        }
    }

    # Calculate the current CPU and Memory utilization percentage for each host.
    $hostStats = foreach ($esxiHost in $hostsInCluster) {
        [PSCustomObject]@{
            Name            = $esxiHost.Name
            CpuUsagePercent = [math]::Round(($esxiHost.CpuUsageMhz / $esxiHost.CpuTotalMhz) * 100, 2)
            MemUsagePercent = [math]::Round(($esxiHost.MemoryUsageGB / $esxiHost.MemoryTotalGB) * 100, 2)
        }
    }
    Write-ConditionalHost "Host Utilization in Cluster '$clusterName':"
    if (-not $Quiet) {
        $hostStats | Format-Table -AutoSize | Out-Host
    }
    # Calculate the average and standard deviation for CPU and Memory usage across the cluster.
    $avgCpu = $hostStats.CpuUsagePercent | Measure-Object -Average | Select-Object -ExpandProperty Average
    $avgMem = $hostStats.MemUsagePercent | Measure-Object -Average | Select-Object -ExpandProperty Average
    $stdDevCpu = Get-StandardDeviation -array $hostStats.CpuUsagePercent
    $stdDevMem = Get-StandardDeviation -array $hostStats.MemUsagePercent
    Write-ConditionalHost "Cluster Balance Statistics:"
    Write-ConditionalHost "  Average CPU Utilization: $([math]::Round($avgCpu, 2))%"
    Write-ConditionalHost "  CPU Standard Deviation:  $([math]::Round($stdDevCpu, 2))"
    Write-ConditionalHost "  Average Memory Utilization: $([math]::Round($avgMem, 2))%"
    Write-ConditionalHost "  Memory Standard Deviation:  $([math]::Round($stdDevMem, 2))"
    # --- Generate Migration Recommendations ---
    $recommendationVerb = if ($BypassHostRulesAndGroups) { "bypassing" } else { "respecting" }
    Write-ConditionalHost "`nGenerating migration recommendations ($recommendationVerb DRS rules)..."
    # Map the user-defined threshold (1-5) to a standard deviation multiplier.
    # A more aggressive threshold (e.g., 5) results in a smaller multiplier, making the 
    # script more sensitive to imbalances.
    $stdDevMultiplier = switch ($MigrationThreshold) {
        1 { 1.5 }
        2 { 1.25 }
        3 { 1.0 }
        4 { 0.75 }
        5 { 0.5 }
        default { 1.0 }
    }
    Write-ConditionalHost "Migration threshold set to level $MigrationThreshold (StdDev Multiplier: $stdDevMultiplier)"
    # Determine the CPU and Memory thresholds for a host to be considered "over-utilized".
    $cpuThreshold = $avgCpu + ($stdDevCpu * $stdDevMultiplier)
    $memThreshold = $avgMem + ($stdDevMem * $stdDevMultiplier)
    # Identify over-utilized hosts (those exceeding either threshold) and under-utilized hosts.
    $overUtilizedHosts = $hostStats | Where-Object { $_.CpuUsagePercent -gt $cpuThreshold -or $_.MemUsagePercent -gt $memThreshold }
    $underUtilizedHosts = $hostStats | Where-Object { $_.CpuUsagePercent -lt $avgCpu -and $_.MemUsagePercent -lt $avgMem } | Sort-Object -Property CpuUsagePercent, MemUsagePercent
    # Proceed only if there are both over-utilized and under-utilized hosts.
    if ($overUtilizedHosts -and $underUtilizedHosts) {
        $allVMsInCluster = Get-VM -Location $cluster
        $availableDestinations = [System.Collections.Generic.List[pscustomobject]]($underUtilizedHosts)
        $vmsOnOverUtilizedHosts = $allVMsInCluster | Where-Object { $_.VMHost.Name -in $overUtilizedHosts.Name }
        # --- Step 1: Handle "Keep Together" VM Groups ---
        if (-not $BypassHostRulesAndGroups) {
            $keepTogetherRules = $drsRules | Where-Object { $_.Enabled -and $_.Type -eq 'VMAffinity' }
            foreach ($rule in $keepTogetherRules) {
                if (-not [string]::IsNullOrEmpty($rule.VMGroupName) -and $vmGroups.ContainsKey($rule.VMGroupName)) {
                    $groupVMNames = $vmGroups[$rule.VMGroupName]
                    $groupVMs = $vmsOnOverUtilizedHosts | Where-Object { $groupVMNames -contains $_.Name }
                    # If any VM in the group is on an over-utilized host, we must move the whole group.
                    if ($groupVMs.Count -gt 0) {
                        $allGroupVMs = $allVMsInCluster | Where-Object { $groupVMNames -contains $_.Name }
                        $groupCpuUsageMhz = ($allGroupVMs.ExtensionData.Summary.QuickStats.OverallCpuUsage | Measure-Object -Sum).Sum
                        $groupMemUsageGB = [math]::Round((($allGroupVMs.ExtensionData.Summary.QuickStats.GuestMemoryUsage | Measure-Object -Sum).Sum / 1024), 2)
                        # Find a single host that can fit the entire group.
                        $bestDestination = $null
                        foreach ($candidateHost in $availableDestinations) {
                            $hostView = Get-View -Id (Get-VMHost -Name $candidateHost.Name).Id
                            $hostCpuCapacityMhz = $hostView.Hardware.CpuInfo.NumCpuCores * $hostView.Hardware.CpuInfo.Hz / 1000000
                            $hostMemCapacityGB = [math]::Round($hostView.Hardware.MemorySize / 1024 / 1024 / 1024, 2)
                            # Predict post-move utilization
                            $predictedCpuUsage = (($candidateHost.CpuUsagePercent / 100 * $hostCpuCapacityMhz) + $groupCpuUsageMhz) / $hostCpuCapacityMhz * 100
                            $predictedMemUsage = (($candidateHost.MemUsagePercent / 100 * $hostMemCapacityGB) + $groupMemUsageGB) / $hostMemCapacityGB * 100
                            if ($predictedCpuUsage -lt $cpuThreshold -and $predictedMemUsage -lt $memThreshold) {
                                # This host has capacity, now check rules for the group.
                                $isHostValidForGroup = $true
                                if (-not $BypassHostRulesAndGroups) {
                                    # 1. Check VM-VM Anti-Affinity (Separate VMs) for the entire group
                                    $potentialVmsOnCandidateHostForGroup = New-Object System.Collections.Generic.HashSet[string]
                                    # Add all VMs in the current 'Keep Together' group being evaluated
                                    $allGroupVMs.Name | ForEach-Object { [void]$potentialVmsOnCandidateHostForGroup.Add($_) }

                                    # Add VMs currently on the candidate host
                                    ($allVMsInCluster | Where-Object { $_.VMHost.Name -eq $candidateHost.Name }).Name | ForEach-Object { [void]$potentialVmsOnCandidateHostForGroup.Add($_) }

                                    # Add VMs already recommended to move to this host
                                    ($clusterRecommendations | Where-Object { $_.Recommended_Destination_Host -eq $candidateHost.Name }).VM_to_Move | ForEach-Object { [void]$potentialVmsOnCandidateHostForGroup.Add($_) }

                                    # Iterate through all anti-affinity rules
                                    $antiAffinityRules = $drsRules | Where-Object { $_.Enabled -and $_.Type -eq 'VMAntiAffinity' }
                                    foreach ($rule in $antiAffinityRules) {
                                        $vmsInThisAntiAffinityGroup = @()
                                        if (-not [string]::IsNullOrEmpty($rule.VMGroupName) -and $vmGroups.ContainsKey($rule.VMGroupName)) {
                                            $vmsInThisAntiAffinityGroup = $vmGroups[$rule.VMGroupName]
                                        } elseif ($rule.VMIds) {
                                            $vmsInThisAntiAffinityGroup = $rule.VMIds | ForEach-Object { (Get-View $_).Name }
                                        }

                                        if ($vmsInThisAntiAffinityGroup.Count -gt 0) {
                                            if ($PSBoundParameters['Verbose']) {
                                                Write-Verbose "  Checking anti-affinity rule: $($rule.Name)"
                                                Write-Verbose "  VMs in this anti-affinity group: $($vmsInThisAntiAffinityGroup -join ', ')"
                                                Write-Verbose "  Potential VMs on candidate host ($($candidateHost.Name)): $($potentialVmsOnCandidateHostForGroup -join ', ')"
                                            }
                                            $membersOnCandidateHost = $potentialVmsOnCandidateHostForGroup | Where-Object { $vmsInThisAntiAffinityGroup -contains $_ } | Select-Object -Unique
                                            if ($PSBoundParameters['Verbose']) {
                                                Write-Verbose "  Members of anti-affinity group found on candidate host: $($membersOnCandidateHost -join ', ')"
                                            }
                                            if ($membersOnCandidateHost.Count -gt 1) {
                                                if ($PSBoundParameters['Verbose']) {
                                                    Write-Verbose "  Anti-affinity violation detected! Count: $($membersOnCandidateHost.Count)"
                                                }
                                                $isHostValidForGroup = $false
                                                break # Violation found, no need to check further rules for this candidate host
                                            }
                                        }
                                    }

                                    # 2. Check VM-Host rules for each VM in the group
                                    if ($isHostValidForGroup) {
                                        foreach ($vmInGroup in $allGroupVMs) {
                                            $requiredHosts = @(); $forbiddenHosts = @()
                                            $applicable_vh_rules = $drsRules | Where-Object {
                                                $_.Enabled -and (-not [string]::IsNullOrEmpty($_.HostGroupName)) -and ($hostGroups.ContainsKey($_.HostGroupName)) -and
                                                (-not [string]::IsNullOrEmpty($_.VMGroupName)) -and ($vmGroups.ContainsKey($_.VMGroupName)) -and
                                                ($vmGroups[$_.VMGroupName] -contains $vmInGroup.Name)
                                            }
                                            foreach ($rule in $applicable_vh_rules) {
                                                if ($rule.Affine) { $requiredHosts += $hostGroups[$rule.HostGroupName] }
                                                else { $forbiddenHosts += $hostGroups[$rule.HostGroupName] }
                                            }
                                            if (($forbiddenHosts | Select-Object -Unique) -contains $candidateHost.Name) { $isHostValidForGroup = $false; break }
                                            if (($requiredHosts.Count -gt 0) -and (($requiredHosts | Select-Object -Unique) -notcontains $candidateHost.Name)) { $isHostValidForGroup = $false; break }
                                        }
                                    }
                                }
                                if ($isHostValidForGroup) {
                                    $bestDestination = $candidateHost
                                    break
                                }
                            }
                        }
                        
                        if ($bestDestination) {
                            Write-Host "Found destination $($bestDestination.Name) for Keep Together group $($rule.VMGroupName)."
                            foreach ($vmToMove in $allGroupVMs) {
                                $recommendation = [PSCustomObject]@{
                                    Cluster = $cluster.Name; VM_to_Move = $vmToMove.Name; Reason = "Keep Together group migration"; Source_Host = $vmToMove.VMHost.Name;
                                    Source_Host_CPU = "-"; Source_Host_Mem = "-"; Recommended_Destination_Host = $bestDestination.Name;
                                    Destination_Host_CPU = "$($bestDestination.CpuUsagePercent)%"; Destination_Host_Mem = "$($bestDestination.MemUsagePercent)%"
                                }
                                $clusterRecommendations += $recommendation
                            }
                            # Remove the chosen destination and the VMs from this group from further processing.
                            $null = $availableDestinations.Remove($bestDestination)
                            $vmsOnOverUtilizedHosts = $vmsOnOverUtilizedHosts | Where-Object { $groupVMNames -notcontains $_.Name }
                        }
                        else {
                            Write-Warning "Could not find a suitable destination for the entire Keep Together group $($rule.VMGroupName)."
                        }
                    }
                }
            }
        }
        # --- Step 2: Handle all other VMs (including "Separate" VMs) ---
        $vmsToProcess = $vmsOnOverUtilizedHosts | Select-Object Name, Id, VMHost, @{N = "CpuUsageMhz"; E = { $_.ExtensionData.Summary.QuickStats.OverallCpuUsage } }, @{N = "MemoryUsageGB"; E = { [math]::Round($_.ExtensionData.Summary.QuickStats.GuestMemoryUsage / 1024, 2) } } | Sort-Object -Property CpuUsageMhz, MemoryUsageGB -Descending

        foreach ($vm in $vmsToProcess) {
            $overHost = $hostStats | Where-Object { $_.Name -eq $vm.VMHost.Name }
            $bestDestination = $null

            # Find the best valid destination from the remaining available hosts.
            foreach ($candidateHost in $availableDestinations) {
                $isHostValid = $true

                if (-not $BypassHostRulesAndGroups) {
                    # 1. Check VM-VM Anti-Affinity (Separate VMs)
                    $potentialVmsOnCandidateHost = New-Object System.Collections.Generic.HashSet[string]
                    # Add the VM currently being evaluated
                    [void]$potentialVmsOnCandidateHost.Add($vm.Name)

                    # Add VMs currently on the candidate host
                    ($allVMsInCluster | Where-Object { $_.VMHost.Name -eq $candidateHost.Name }).Name | ForEach-Object { [void]$potentialVmsOnCandidateHost.Add($_) }

                    # Add VMs already recommended to move to this host
                    ($clusterRecommendations | Where-Object { $_.Recommended_Destination_Host -eq $candidateHost.Name }).VM_to_Move | ForEach-Object { [void]$potentialVmsOnCandidateHost.Add($_) }

                    # Iterate through all anti-affinity rules
                    $antiAffinityRules = $drsRules | Where-Object { $_.Enabled -and $_.Type -eq 'VMAntiAffinity' }
                    foreach ($rule in $antiAffinityRules) {
                        $vmsInThisAntiAffinityGroup = @()
                        if (-not [string]::IsNullOrEmpty($rule.VMGroupName) -and $vmGroups.ContainsKey($rule.VMGroupName)) {
                            $vmsInThisAntiAffinityGroup = $vmGroups[$rule.VMGroupName]
                        } elseif ($rule.VMIds) {
                            $vmsInThisAntiAffinityGroup = $rule.VMIds | ForEach-Object { (Get-View $_).Name }
                        }

                        if ($vmsInThisAntiAffinityGroup.Count -gt 0) {
                            Write-Verbose "  Checking anti-affinity rule: $($rule.Name)"
                            Write-Verbose "  VMs in this anti-affinity group: $($vmsInThisAntiAffinityGroup -join ', ')"
                            Write-Verbose "  Potential VMs on candidate host ($($candidateHost.Name)): $($potentialVmsOnCandidateHost -join ', ')"
                            $membersOnCandidateHost = $potentialVmsOnCandidateHost | Where-Object { $vmsInThisAntiAffinityGroup -contains $_ } | Select-Object -Unique
                            Write-Verbose "  Members of anti-affinity group found on candidate host: $($membersOnCandidateHost -join ', ')"
                            if ($membersOnCandidateHost.Count -gt 1) {
                                Write-Verbose "  Anti-affinity violation detected! Count: $($membersOnCandidateHost.Count)"
                                $isHostValid = $false
                                break # Violation found, no need to check further rules for this candidate host
                            }
                        }
                    }
                }

                # If the host is still a valid candidate after rule checks, it's our best destination so far.
                if ($isHostValid) {
                    $bestDestination = $candidateHost
                    break # Found a suitable host, no need to check other under-utilized hosts for this VM.
                }
            }

            # --- Create Recommendation if a destination was found ---
            if ($bestDestination) {
                $recommendation = [PSCustomObject]@{
                    Cluster                      = $clusterName
                    VM_to_Move                   = $vm.Name
                    Reason                       = "High CPU/Mem on source"
                    Source_Host                  = $overHost.Name
                    Source_Host_CPU              = "$($overHost.CpuUsagePercent)%"
                    Source_Host_Mem              = "$($overHost.MemUsagePercent)%"
                    Recommended_Destination_Host = $bestDestination.Name
                    Destination_Host_CPU         = "$($bestDestination.CpuUsagePercent)%"
                    Destination_Host_Mem         = "$($bestDestination.MemUsagePercent)%"
                }
                $clusterRecommendations += $recommendation
                # This destination is now taken for this run, remove it from the pool.
                $null = $availableDestinations.Remove($bestDestination)
            }
            else {
                # Only warn if no suitable host was found AND rules were being enforced.
                if (-not $BypassHostRulesAndGroups) {
                    # Check if this VM is part of any DRS rules to provide a more specific warning.
                    $vmHasAnyDrsRules = $false
                    $tempPartnerVmNames = ($drsRules | Where-Object {
                            $_.Enabled -and $_.Type -eq 'VMAntiAffinity' -and
                            -not [string]::IsNullOrEmpty($_.VMGroupName) -and $vmGroups.ContainsKey($_.VMGroupName) -and
                            ($vmGroups[$_.VMGroupName] -contains $vm.Name)
                        } | ForEach-Object { $vmGroups[$_.VMGroupName] } | Select-Object -Unique | Where-Object { $_ -ne $vm.Name })

                    $tempApplicableVhRules = $drsRules | Where-Object {
                        $_.Enabled -and (-not [string]::IsNullOrEmpty($_.HostGroupName)) -and ($hostGroups.ContainsKey($_.HostGroupName)) -and
                        (-not [string]::IsNullOrEmpty($_.VMGroupName)) -and ($vmGroups.ContainsKey($_.VMGroupName)) -and
                        ($vmGroups[$_.VMGroupName] -contains $vm.Name)
                    }

                    if ($tempPartnerVmNames.Count -gt 0 -or $tempApplicableVhRules.Count -gt 0) {
                        $vmHasAnyDrsRules = $true
                    }

                    if ($vmHasAnyDrsRules) {
                        Write-Warning "Could not find a valid destination for $($vm.Name) from host $($overHost.Name) that satisfies all DRS rules."
                    }
                }
            }
        } # End of loop for VMs on over-utilized hosts
    } # End of check for over/under utilized hosts

    # --- Step 3: Load Balancing Logic (if -Balance parameter is specified) ---
    if ($Balance -and $hostsInCluster.Count -ge 2) {
        Write-ConditionalHost "`nProcessing load balancing recommendations..."
        
        # Get VM count per host (excluding hosts in maintenance mode and vCLS VMs)
        $hostVmCounts = @{}
        foreach ($esxiHost in $hostsInCluster) {
            # Exclude vCLS VMs (vSphere Cluster Services) from load balancing
            $vmsOnHost = Get-VM -Location $esxiHost | Where-Object { 
                $_.PowerState -eq 'PoweredOn' -and 
                $_.Name -notlike 'vCLS-*' 
            }
            $hostVmCounts[$esxiHost.Name] = $vmsOnHost.Count
        }
        
        # Calculate ideal distribution
        $totalVMs = ($hostVmCounts.Values | Measure-Object -Sum).Sum
        $idealVMsPerHost = [math]::Floor($totalVMs / $hostsInCluster.Count)
        $extraVMs = $totalVMs % $hostsInCluster.Count
        
        Write-ConditionalHost "Load Balancing Analysis:"
        Write-ConditionalHost "  Total VMs to distribute: $totalVMs"
        Write-ConditionalHost "  Ideal VMs per host: $idealVMsPerHost (with $extraVMs host(s) having +1 VM)"
        
        # Display current distribution
        foreach ($kvp in $hostVmCounts.GetEnumerator()) {
            Write-ConditionalHost "  Host '$($kvp.Key)': $($kvp.Value) VMs"
        }
        
        # Find hosts with too many VMs and hosts with capacity
        $sourceHosts = @()
        $targetHosts = @()
        
        foreach ($kvp in $hostVmCounts.GetEnumerator()) {
            $hostName = $kvp.Key
            $vmCount = $kvp.Value
            
            # For load balancing, we want a more aggressive approach than normal DRS
            # When perfect distribution is possible (no remainder), be more strict about balance
            if ($extraVMs -eq 0) {
                # Perfect balance is possible - all hosts should have exactly idealVMsPerHost
                $allowedMax = $idealVMsPerHost
                $allowedMin = $idealVMsPerHost
            } else {
                # Uneven distribution - allow some hosts to have +1
                $allowedMax = $idealVMsPerHost + 1
                $allowedMin = $idealVMsPerHost
            }
            
            Write-ConditionalHost "  Evaluating host '$hostName': $vmCount VMs (allowedMin: $allowedMin, allowedMax: $allowedMax)"
            
            if ($vmCount -gt $allowedMax) {
                $excessVMs = $vmCount - $allowedMax
                $sourceHosts += [PSCustomObject]@{
                    HostName = $hostName
                    CurrentVMs = $vmCount
                    ExcessVMs = $excessVMs
                }
                Write-ConditionalHost "    -> Source host (excess: $excessVMs VMs)"
            }
            elseif ($vmCount -lt $allowedMin) {
                $capacity = $allowedMin - $vmCount
                $targetHosts += [PSCustomObject]@{
                    HostName = $hostName
                    CurrentVMs = $vmCount
                    Capacity = $capacity
                }
                Write-ConditionalHost "    -> Target host (capacity: $capacity VMs)"
            }
            else {
                Write-ConditionalHost "    -> Balanced host (no action needed)"
            }
        }
        
        # Generate load balancing recommendations
        if ($sourceHosts.Count -gt 0 -and $targetHosts.Count -gt 0) {
            Write-ConditionalHost "Generating load balancing recommendations..."
            Write-ConditionalHost "  Source hosts (with excess VMs): $($sourceHosts.Count)"
            foreach ($sh in $sourceHosts) {
                Write-ConditionalHost "    $($sh.HostName): $($sh.CurrentVMs) VMs (excess: $($sh.ExcessVMs))"
            }
            Write-ConditionalHost "  Target hosts (with capacity): $($targetHosts.Count)"
            foreach ($th in $targetHosts) {
                Write-ConditionalHost "    $($th.HostName): $($th.CurrentVMs) VMs (capacity: $($th.Capacity))"
            }
            
            # Sort source hosts by excess VMs (highest first) and target hosts by capacity (highest first)
            $sourceHosts = $sourceHosts | Sort-Object ExcessVMs -Descending
            $targetHosts = $targetHosts | Sort-Object Capacity -Descending
            
            foreach ($sourceHost in $sourceHosts) {
                # Get VMs on this over-loaded host, sorted by resource usage (move smallest first for better distribution)
                # Exclude vCLS VMs from being moved
                $vmsToMove = Get-VM -Location (Get-VMHost -Name $sourceHost.HostName) | 
                    Where-Object { $_.PowerState -eq 'PoweredOn' -and $_.Name -notlike 'vCLS-*' } |
                    Select-Object Name, Id, VMHost, 
                        @{N = "CpuUsageMhz"; E = { $_.ExtensionData.Summary.QuickStats.OverallCpuUsage } }, 
                        @{N = "MemoryUsageGB"; E = { [math]::Round($_.ExtensionData.Summary.QuickStats.GuestMemoryUsage / 1024, 2) } } |
                    Sort-Object CpuUsageMhz, MemoryUsageGB
                
                Write-ConditionalHost "  Processing source host: $($sourceHost.HostName)"
                Write-ConditionalHost "  Found $($vmsToMove.Count) powered-on VMs to potentially move"
                if ($vmsToMove.Count -gt 0) {
                    Write-ConditionalHost "  VMs on $($sourceHost.HostName): $($vmsToMove.Name -join ', ')"
                }
                
                $vmsMovedFromThisHost = 0
                foreach ($vm in $vmsToMove) {
                    if ($vmsMovedFromThisHost -ge $sourceHost.ExcessVMs) {
                        break  # Moved enough VMs from this host
                    }
                    
                    # Find a suitable target host
                    $bestTarget = $null
                    foreach ($targetHost in $targetHosts) {
                        if ($targetHost.Capacity -gt 0) {
                            # Check if this move respects DRS rules (unless bypassed)
                            $isValidMove = $true
                            
                            if (-not $BypassHostRulesAndGroups) {
                                # Check VM-VM Anti-Affinity rules
                                $potentialVmsOnTarget = New-Object System.Collections.Generic.HashSet[string]
                                [void]$potentialVmsOnTarget.Add($vm.Name)
                                
                                # Add VMs currently on target host
                                $currentVMsOnTarget = Get-VM -Location (Get-VMHost -Name $targetHost.HostName)
                                $currentVMsOnTarget.Name | ForEach-Object { [void]$potentialVmsOnTarget.Add($_) }
                                
                                # Add VMs already recommended to move to this host
                                ($clusterRecommendations | Where-Object { $_.Recommended_Destination_Host -eq $targetHost.HostName }).VM_to_Move | 
                                    ForEach-Object { [void]$potentialVmsOnTarget.Add($_) }
                                
                                # Check anti-affinity rules
                                $antiAffinityRules = $drsRules | Where-Object { $_.Enabled -and $_.Type -eq 'VMAntiAffinity' }
                                foreach ($rule in $antiAffinityRules) {
                                    $vmsInThisAntiAffinityGroup = @()
                                    if (-not [string]::IsNullOrEmpty($rule.VMGroupName) -and $vmGroups.ContainsKey($rule.VMGroupName)) {
                                        $vmsInThisAntiAffinityGroup = $vmGroups[$rule.VMGroupName]
                                    } elseif ($rule.VMIds) {
                                        $vmsInThisAntiAffinityGroup = $rule.VMIds | ForEach-Object { (Get-View $_).Name }
                                    }
                                    
                                    if ($vmsInThisAntiAffinityGroup.Count -gt 0) {
                                        $membersOnTarget = $potentialVmsOnTarget | Where-Object { $vmsInThisAntiAffinityGroup -contains $_ } | Select-Object -Unique
                                        if ($membersOnTarget.Count -gt 1) {
                                            $isValidMove = $false
                                            break
                                        }
                                    }
                                }
                                
                                # Check VM-Host rules if move is still valid
                                if ($isValidMove) {
                                    $requiredHosts = @(); $forbiddenHosts = @()
                                    $applicable_vh_rules = $drsRules | Where-Object {
                                        $_.Enabled -and (-not [string]::IsNullOrEmpty($_.HostGroupName)) -and ($hostGroups.ContainsKey($_.HostGroupName)) -and
                                        (-not [string]::IsNullOrEmpty($_.VMGroupName)) -and ($vmGroups.ContainsKey($_.VMGroupName)) -and
                                        ($vmGroups[$_.VMGroupName] -contains $vm.Name)
                                    }
                                    foreach ($rule in $applicable_vh_rules) {
                                        if ($rule.Affine) { $requiredHosts += $hostGroups[$rule.HostGroupName] }
                                        else { $forbiddenHosts += $hostGroups[$rule.HostGroupName] }
                                    }
                                    if (($forbiddenHosts | Select-Object -Unique) -contains $targetHost.HostName) { $isValidMove = $false }
                                    if (($requiredHosts.Count -gt 0) -and (($requiredHosts | Select-Object -Unique) -notcontains $targetHost.HostName)) { $isValidMove = $false }
                                }
                            }
                            
                            if ($isValidMove) {
                                $bestTarget = $targetHost
                                break
                            }
                        }
                    }
                    
                    # Create load balancing recommendation if valid target found
                    if ($bestTarget) {
                        $recommendation = [PSCustomObject]@{
                            Cluster = $cluster.Name
                            VM_to_Move = $vm.Name
                            Reason = "Load Balancing"
                            Source_Host = $sourceHost.HostName
                            Source_Host_CPU = "-"
                            Source_Host_Mem = "-"
                            Recommended_Destination_Host = $bestTarget.HostName
                            Destination_Host_CPU = "-"
                            Destination_Host_Mem = "-"
                        }
                        $clusterRecommendations += $recommendation
                        Write-ConditionalHost "    BALANCE: '$($vm.Name)' -> '$($bestTarget.HostName)' (distributing load)"
                        
                        # Update counters
                        $vmsMovedFromThisHost++
                        $bestTarget.Capacity--
                        
                        # Remove target from list if it has no more capacity
                        if ($bestTarget.Capacity -eq 0) {
                            $targetHosts = $targetHosts | Where-Object { $_.HostName -ne $bestTarget.HostName }
                        }
                    }
                    else {
                        if (-not $BypassHostRulesAndGroups) {
                            Write-ConditionalHost "    Could not find valid target for '$($vm.Name)' due to DRS rules"
                        }
                    }
                }
            }
            
            if ($clusterRecommendations | Where-Object { $_.Reason -eq "Load Balancing" }) {
                $balanceRecommendations = ($clusterRecommendations | Where-Object { $_.Reason -eq "Load Balancing" }).Count
                Write-ConditionalHost "Load balancing analysis complete. Generated $balanceRecommendations load balancing recommendations."
            }
            else {
                Write-ConditionalHost "Load balancing analysis complete. No valid load balancing moves found."
            }
        }
        else {
            Write-ConditionalHost "Load balancing analysis: Cluster is already well-balanced."
        }
    }

    # Display recommendations for the current cluster.
    if ($clusterRecommendations.Count -gt 0) {
        Write-ConditionalHost "`n--- Recommendations for Cluster: $clusterName ---" -ForegroundColor Green
        Write-ConditionalHost "  Total Recommendations: $($clusterRecommendations.Count)" -ForegroundColor Cyan
        
        if (-not $Quiet) {
            $clusterRecommendations | Format-Table -AutoSize | Out-Host
        }
    }
    else {
        Write-ConditionalHost "`n--- Recommendations for Cluster: $clusterName ---" -ForegroundColor Green
        Write-ConditionalHost "No migration recommendations for this cluster." -ForegroundColor Yellow
    }
    $allRecommendations += $clusterRecommendations
}

# If requested, export all recommendations to a CSV file.
if ($ExportToCsv -and $allRecommendations) {
    try {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $fileName = "$timestamp-drs_recommendations.csv"
        $filePath = Join-Path -Path $PSScriptRoot -ChildPath $fileName
        $allRecommendations | Export-Csv -Path $filePath -NoTypeInformation -Force -WhatIf:$false
        Write-ConditionalHost "`nAll recommendations have been exported to: $filePath"
    }
    catch { Write-Error "Failed to export recommendations to CSV. `n$($_.Exception.Message)" }
}
# Disconnect from the vCenter Server only if this script made the connection
# or if explicitly told not to disconnect via NoDisconnect parameter
if (-not $NoDisconnect -and $shouldDisconnect) {
    Write-ConditionalHost "`nAnalysis complete. Disconnecting from $vCenterServer (connection made by $($MyInvocation.MyCommand.Name))."
    Disconnect-VIServer -Confirm:$false -Force -WhatIf:$false
}
elseif (-not $NoDisconnect -and -not $shouldDisconnect) {
    Write-ConditionalHost "`nAnalysis complete. Leaving existing vCenter connection open."
}
elseif ($NoDisconnect) {
    Write-ConditionalHost "`nAnalysis complete. Leaving vCenter connection open as requested."
}
# Return all recommendation objects, making them available to any calling script.
# Filter out any invalid recommendations before returning
$validRecommendations = $allRecommendations | Where-Object { 
    $_ -and 
    $_.VM_to_Move -and 
    $_.Recommended_Destination_Host -and
    ![string]::IsNullOrWhiteSpace($_.VM_to_Move) -and
    ![string]::IsNullOrWhiteSpace($_.Recommended_Destination_Host)
}
return $validRecommendations