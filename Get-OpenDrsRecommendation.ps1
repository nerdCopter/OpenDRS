<#
.SYNOPSIS
    A read-only script that analyzes VMware vSphere cluster balance and provides VM migration recommendations.
.DESCRIPTION
    This script connects to a vCenter Server to analyze cluster balance and displays
    all analysis details and recommendations to the console on a per-cluster basis.
.PARAMETER vCenterServer
    The FQDN or IP address of the vCenter Server. Defaults to 'vcenter.nicholls.edu'.
.PARAMETER ExportToCsv
    If specified, exports all migration recommendations to a single CSV file at the end.
.PARAMETER BypassHostRulesAndGroups
    If specified, will ignore all VM/Host affinity and anti-affinity rules.
.PARAMETER MigrationThreshold
    An integer from 1 to 5 that controls the aggressiveness of migration recommendations.
    1 is the most conservative, 5 is the most aggressive. Defaults to 3.
.OUTPUTS
    An array of PSCustomObjects, where each object represents a single VM migration recommendation.
#>
[CmdletBinding()]
param(
    [string]$vCenterServer,
    [switch]$ExportToCsv,
    [switch]$BypassHostRulesAndGroups,
    [ValidateSet(1, 2, 3, 4, 5)]
    [int]$MigrationThreshold = 3,
    [switch]$NoDisconnect,
    [Alias('h', 'v', 'version')]
    [switch]$help
)

# --- Helper Functions ---

function Show-Usage {
    Write-Host "Usage: .\Get-DrsRecommendation.ps1 -vCenterServer <server_name> [options]"
    Write-Host ""
    Write-Host "A read-only script that analyzes VMware vSphere cluster balance and provides VM migration recommendations."
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -vCenterServer <string>     (Required) The FQDN or IP address of the vCenter Server."
    Write-Host "  -ExportToCsv                Export recommendations to a CSV file (only if recommendations exist)."
    Write-Host "  -BypassHostRulesAndGroups   Ignore VM/Host affinity rules."
    Write-Host "  -MigrationThreshold <1-5>   Set migration aggressiveness (1=conservative, 5=aggressive). Default is 3."
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
# --- Main Script Body ---
# Connect to the specified vCenter Server. If a session already exists to a different
# vCenter, it will be disconnected first.
try {
    Write-Host "Attempting to connect to vCenter Server: $vCenterServer..."
    if ($global:DefaultVIServer.Name -ne $vCenterServer) {
        if ($global:DefaultVIServer) {
            Write-Host "Disconnecting existing vCenter session."
            Disconnect-VIServer -Server $global:DefaultVIServer -Confirm:$false -Force
        }
        Connect-VIServer -Server $vCenterServer -ErrorAction Stop | Out-Null
    }
    Write-Host "Successfully connected to $vCenterServer."
}
catch {
    Write-Error "Failed to connect to vCenter Server '$vCenterServer'. Please check the server name and your network connection. `n$($_.Exception.Message)"
    exit 1
}
Write-Host "`nGathering cluster and host information..."
$allRecommendations = @()
$clusters = Get-Cluster
if (-not $clusters) {
    Write-Warning "No clusters found on $vCenterServer."
    Disconnect-VIServer -Confirm:$false -Force
    exit 0
}
# Iterate through each cluster found on the vCenter Server.
foreach ($cluster in $clusters) {
    $clusterRecommendations = @()
    Write-Host "`n--- Analyzing Cluster: $($cluster.Name) ---"
    # Get all connected hosts in the current cluster, excluding those in maintenance mode.
    $hostsInCluster = Get-VMHost -Location $cluster -State Connected
    if ($hostsInCluster.Count -lt 2) {
        Write-Warning "Cluster '$($cluster.Name)' has fewer than two hosts. DRS analysis is not applicable."
        continue
    }
    # Read all DRS rules and VM/Host groups for the current cluster, unless bypassed.
    $drsRules = $null
    $vmGroups = @{}
    $hostGroups = @{}
    if (-not $BypassHostRulesAndGroups) {
        Write-Host "Reading DRS Rules and Groups for cluster '$($cluster.Name)'..."
        $drsRules = Get-DrsRule -Cluster $cluster -WarningAction SilentlyContinue
        $clusterView = Get-View -Id $cluster.Id
        if ($clusterView.Configuration.Group) {
            foreach ($group in $clusterView.Configuration.Group) {
                if ($group.Host) {
                    # It's a host group
                    $hostsInGroup = $group.Host | ForEach-Object { (Get-View $_).Name }
                    $hostGroups[$group.Name] = $hostsInGroup
                }
                elseif ($group.Vm) {
                    # It's a VM group
                    $vmsInGroup = $group.Vm | ForEach-Object { (Get-View $_).Name }
                    $vmGroups[$group.Name] = $vmsInGroup
                }
            }
        }
        if ($PSBoundParameters['Verbose']) {
            Write-Verbose "Populated DRS Rules:"
            $drsRules | Format-List | Out-String | Write-Verbose
            Write-Verbose "Populated VM Groups:"
            $vmGroups.GetEnumerator() | ForEach-Object { Write-Verbose "  $($_.Name): $($_.Value -join ', ')" }
            Write-Verbose "Populated Host Groups:"
            $hostGroups.GetEnumerator() | ForEach-Object { Write-Verbose "  $($_.Name): $($_.Value -join ', ')" }
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
    Write-Host "Host Utilization in Cluster '$($cluster.Name)':"
    $hostStats | Format-Table -AutoSize | Out-Host
    # Calculate the average and standard deviation for CPU and Memory usage across the cluster.
    $avgCpu = $hostStats.CpuUsagePercent | Measure-Object -Average | Select-Object -ExpandProperty Average
    $avgMem = $hostStats.MemUsagePercent | Measure-Object -Average | Select-Object -ExpandProperty Average
    $stdDevCpu = Get-StandardDeviation -array $hostStats.CpuUsagePercent
    $stdDevMem = Get-StandardDeviation -array $hostStats.MemUsagePercent
    Write-Host "Cluster Balance Statistics:"
    Write-Host "  Average CPU Utilization: $([math]::Round($avgCpu, 2))%"
    Write-Host "  CPU Standard Deviation:  $([math]::Round($stdDevCpu, 2))"
    Write-Host "  Average Memory Utilization: $([math]::Round($avgMem, 2))%"
    Write-Host "  Memory Standard Deviation:  $([math]::Round($stdDevMem, 2))"
    # --- Generate Migration Recommendations ---
    $recommendationVerb = if ($BypassHostRulesAndGroups) { "bypassing" } else { "respecting" }
    Write-Host "`nGenerating migration recommendations ($recommendationVerb DRS rules)..."
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
    Write-Host "Migration threshold set to level $MigrationThreshold (StdDev Multiplier: $stdDevMultiplier)"
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
                    Cluster                      = $cluster.Name
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

    # Display recommendations for the current cluster.
    if ($clusterRecommendations.Count -gt 0) {
        Write-Host "`n--- Recommendations for Cluster: $($cluster.Name) ---" -ForegroundColor Green
        $clusterRecommendations | Format-Table -AutoSize | Out-Host
    }
    else {
        Write-Host "`n--- Recommendations for Cluster: $($cluster.Name) ---" -ForegroundColor Green
        Write-Host "No migration recommendations for this cluster." -ForegroundColor Yellow
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
        Write-Host "`nAll recommendations have been exported to: $filePath"
    }
    catch { Write-Error "Failed to export recommendations to CSV. `n$($_.Exception.Message)" }
}
# Disconnect from the vCenter Server, unless specifically told not to.
if (-not $NoDisconnect) {
    Write-Host "`nAnalysis complete. Disconnecting from $vCenterServer."
    Disconnect-VIServer -Confirm:$false -Force
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