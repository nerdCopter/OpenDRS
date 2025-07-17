<#
.SYNOPSIS
    Gets, displays, and executes VM migration recommendations for cluster balancing.

.DESCRIPTION
    This is the main user-facing script. It calls the 'Get-OpenDrsRecommendation.ps1' engine to
    generate a list of migrations. It then displays these recommendations and, after user
    confirmation, executes the migrations.
    
    Automatically handles maintenance mode evacuations with critical priority.
    Supports both powered-on (vMotion) and powered-off (cold migration) VMs during evacuation.

.PARAMETER vCenterServer
    The fully qualified domain name (FQDN) or IP address of the vCenter Server.

.PARAMETER WhatIf
    Shows what would happen if the cmdlet runs. The cmdlet is not run.

.PARAMETER Confirm
    Prompts you for confirmation before running the cmdlet.

.PARAMETER ExportToCsv
    Exports the migration recommendations to a CSV file.

.PARAMETER BypassHostRulesAndGroups
    Ignores VM/Host affinity rules and groups during migration.

.PARAMETER CsvFile
    Path to a CSV file containing migration recommendations. When provided, the script will
    load recommendations from this file instead of calling the analysis engine.

.PARAMETER MigrationThreshold
    Sets the migration aggressiveness level (1-5) for the analysis engine. Default is 3.

.PARAMETER Balance
    Enables load balancing recommendations to evenly distribute VMs across hosts,
    even when hosts are not resource-constrained.

.PARAMETER Clusters
    If specified, limits analysis to the specified cluster(s). Supports cluster names with spaces.
    Can accept a single cluster name or an array of cluster names.

.EXAMPLE
    .\Invoke-OpenDrsMigration.ps1 -vCenterServer 'vcenter.yourdomain.com'

    Gets and displays migration recommendations. Prompts for a final confirmation before
    executing the migrations.

.EXAMPLE
    .\Invoke-OpenDrsMigration.ps1 -vCenterServer 'vcenter.yourdomain.com' -WhatIf

    Gets and displays the migration recommendations that *would* be performed, but does not
    execute them.

.EXAMPLE
    .\Invoke-OpenDrsMigration.ps1 -vCenterServer 'vcenter.yourdomain.com' -ExportToCsv

    Gets migration recommendations and exports them to a CSV file.

.EXAMPLE
    .\Invoke-OpenDrsMigration.ps1 -vCenterServer 'vcenter.yourdomain.com' -CsvFile 'recommendations.csv'

    Loads migration recommendations from a CSV file and executes them.

.EXAMPLE
    .\Invoke-OpenDrsMigration.ps1 -vCenterServer 'vcenter.yourdomain.com' -Clusters 'Production R650 Cluster','Veeam Backup FC630 Cluster' -WhatIf

    Analyzes only the specified clusters and shows what migrations would be performed.

.NOTES
    Version:        1.0.0
    Creation Date:  July 2025
    License:        GNU Affero General Public License v3.0 (AGPL-3.0)
#>
[CmdletBinding(SupportsShouldProcess=$true, PositionalBinding=$false)]
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
    [switch]$Balance,  # Enable load balancing recommendations
    [Parameter()]
    [string]$CsvFile,  # Path to CSV file containing recommendations
    [Parameter()]
    [string[]]$Clusters,  # Optional cluster name(s) to analyze
    [Parameter()]
    [Alias('h', 'v', 'version')]
    [switch]$help
)

# Handle pipeline input by collecting all input objects
$pipelineInput = @()

# Read from pipeline if data is available
if ($input) {
    $pipelineInput = @($input | ForEach-Object { $_ })
}

function Show-Usage {
    Write-Host "Usage: .\Invoke-OpenDrsMigration.ps1 -vCenterServer <server_name> [options]"
    Write-Host ""
    Write-Host "Gets, displays, and executes VM migration recommendations for cluster balancing."
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -vCenterServer <string>     (Required) The FQDN or IP address of the vCenter Server."
    Write-Host "  -Clusters <string[]>        Optional cluster name(s) to analyze. Supports names with spaces."
    Write-Host "  -ExportToCsv                Export recommendations from the analysis engine to a CSV file (only if recommendations exist)."
    Write-Host "  -BypassHostRulesAndGroups   Tell the analysis engine to ignore VM/Host affinity rules."
    Write-Host "  -MigrationThreshold <1-5>   Set migration aggressiveness in the analysis engine (1=conservative, 5=aggressive). Default is 3."
    Write-Host "  -Balance                    Enable load balancing recommendations for even VM distribution across hosts."
    Write-Host "  -CsvFile <path>             Load recommendations from a CSV file instead of calling the analysis engine."
    Write-Host "  -Verbose                    Output detailed diagnostic information from the analysis engine."
    Write-Host "  -WhatIf                     Show what would happen if the cmdlet runs. The cmdlet is not run."
    Write-Host "  -Confirm                    Prompts you for confirmation before running the cmdlet."
    Write-Host "  -help, -h, -version, -v     Show this help message."
}

if ($help -or ([string]::IsNullOrEmpty($vCenterServer) -and [string]::IsNullOrEmpty($CsvFile))) {
    Show-Usage
    return
}

# --- Script Body ---

# Track whether this script made the connection (and should disconnect later)
$shouldDisconnect = $false
$allRecommendations = @()

# Check if we're already connected at the start
$wasConnectedAtStart = ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected)

# Handle pipeline input if provided
if ($pipelineInput.Count -gt 0) {
    $allRecommendations = @($pipelineInput)
}

# Handle CSV file input if provided
if ([string]::IsNullOrEmpty($CsvFile) -eq $false) {
    if (Test-Path $CsvFile) {
        try {
            Write-Host "Loading recommendations from CSV file: $CsvFile"
            $csvRecommendations = Import-Csv -Path $CsvFile
            
            # Validate required columns exist
            $requiredColumns = @('VM_to_Move', 'Recommended_Destination_Host')
            $csvColumns = $csvRecommendations[0].PSObject.Properties.Name
            $missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }
            
            if ($missingColumns.Count -gt 0) {
                Write-Error "CSV file is missing required columns: $($missingColumns -join ', '). Required columns are: $($requiredColumns -join ', ')"
                exit 1
            }
            
            $allRecommendations = @($csvRecommendations)
            Write-Host "Loaded $($allRecommendations.Count) recommendations from CSV file."
        }
        catch {
            Write-Error "Failed to load CSV file '$CsvFile'. Error: $($_.Exception.Message)"
            exit 1
        }
    }
    else {
        Write-Error "CSV file not found: $CsvFile"
        exit 1
    }
}

# Ensure PowerCLI module is available
if (-not (Get-Command Connect-VIServer -ErrorAction SilentlyContinue)) {
    try {
        Write-Host "Importing VMware PowerCLI module... (This may take a moment)"
        Import-Module VMware.PowerCLI -ErrorAction Stop
    }
    catch {
        Write-Error "VMware PowerCLI module not found or failed to import. Please install it using 'Install-Module VMware.PowerCLI'."
        exit 1
    }
}

# If no recommendations found yet, get them from the analysis engine script
if ($allRecommendations.Count -eq 0) {
    if ([string]::IsNullOrEmpty($vCenterServer)) {
        Write-Error "vCenterServer parameter is required to get recommendations from the analysis engine."
        exit 1
    }
    
    Write-Verbose "Getting DRS recommendations from vCenter: $vCenterServer..."
    $engineArgs = @{
        vCenterServer = $vCenterServer
    }
    if ($PSBoundParameters['Verbose']) {
        $engineArgs['Verbose'] = $true
    }
    if ($PSBoundParameters['ExportToCsv']) {
        $engineArgs['ExportToCsv'] = $true
    }
    if ($PSBoundParameters['BypassHostRulesAndGroups']) {
        $engineArgs['BypassHostRulesAndGroups'] = $true
    }
    if ($PSBoundParameters.ContainsKey('MigrationThreshold')) {
        $engineArgs['MigrationThreshold'] = $MigrationThreshold
    }
    if ($PSBoundParameters['Balance']) {
        $engineArgs['Balance'] = $true
    }
    if ($PSBoundParameters['Clusters']) {
        $engineArgs['Clusters'] = $Clusters
    }
    
    # Capture the recommendations from the analysis engine script
    $allRecommendations = @(& "$PSScriptRoot\Get-OpenDrsRecommendation.ps1" @engineArgs)
    
    # Debug: Show what we received from the analysis engine
    Write-Host "`nReceived $($allRecommendations.Count) recommendations from engine."
    if ($allRecommendations.Count -gt 0) {
        # Separate evacuation from normal recommendations
        $evacuationRecs = $allRecommendations | Where-Object { $_.Reason -eq "MAINTENANCE_MODE_EVACUATION" }
        $normalRecs = $allRecommendations | Where-Object { $_.Reason -ne "MAINTENANCE_MODE_EVACUATION" }
        
        if ($evacuationRecs.Count -gt 0) {
            Write-Host "`n*** CRITICAL: $($evacuationRecs.Count) MAINTENANCE MODE EVACUATION(S) ***" -ForegroundColor Red
            foreach ($rec in $evacuationRecs) {
                Write-Host "[EVACUATION] VM '$($rec.VM_to_Move)' -> Host '$($rec.Recommended_Destination_Host)' (Power: $($rec.Power_State))" -ForegroundColor Yellow
            }
        }
        
        if ($normalRecs.Count -gt 0) {
            Write-Host "`nNormal DRS Recommendations:" -ForegroundColor Cyan
            foreach ($rec in $normalRecs) {
                Write-Host "VM '$($rec.VM_to_Move)' -> Host '$($rec.Recommended_Destination_Host)'"
            }
        }
    }
}

# Connect for migration operations if we have recommendations to execute
if ($allRecommendations -and $allRecommendations.Count -gt 0) {
    if ([string]::IsNullOrEmpty($vCenterServer)) {
        Write-Error "vCenterServer parameter is required for VM migrations."
        exit 1
    }

    # Check if we're already connected to the target vCenter
    $existingConnection = $null
    
    # First check if we have a default connection that matches
    if ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected) {
        if ($global:DefaultVIServer.Name -eq $vCenterServer -or 
            $global:DefaultVIServer.Name -like "*$vCenterServer*" -or 
            $vCenterServer -like "*$($global:DefaultVIServer.Name)*") {
            $existingConnection = $global:DefaultVIServer
        }
    }
    
    # If not found in default, check all existing connections
    if (-not $existingConnection) {
        # Use $global:DefaultVIServers array to get all connections instead of Get-VIServer
        $allConnections = @()
        if ($global:DefaultVIServers) {
            $allConnections = @($global:DefaultVIServers)
        }
        $existingConnection = $allConnections | Where-Object { 
            $_.IsConnected -and (
                $_.Name -eq $vCenterServer -or 
                $_.Name -like "*$vCenterServer*" -or 
                $vCenterServer -like "*$($_.Name)*"
            )
        } | Select-Object -First 1
    }
    
    if ($existingConnection -and $existingConnection.IsConnected) {
        Write-Host "`nUsing existing connection to $($existingConnection.Name)."
        $shouldDisconnect = $false
    }
    else {
        # Need to connect to vCenter for migrations
        try {
            Write-Host "`nConnecting to vCenter Server for migrations: '$vCenterServer'..."
            
            # Use hashtable splatting for reliable parameter binding across all PowerShell versions
            $connectParams = @{
                Server = $vCenterServer
                ErrorAction = 'Stop'
            }
            $connection = Connect-VIServer @connectParams
            
            if ($connection) {
                Write-Host "Successfully connected to $($connection.Name)."
                $shouldDisconnect = $true
            }
        }
        catch {
            Write-Error "Failed to connect to vCenter Server '$vCenterServer'. Please check the server name and your network connection. `n$($_.Exception.Message)"
            exit 1
        }
    }
}

# Execute migrations with confirmation
if ($allRecommendations -and $allRecommendations.Count -gt 0) {
    Write-Host "`nFound $($allRecommendations.Count) migration recommendation(s) to execute."
    Write-Host "Starting migration process..."
    
    $successCount = 0
    $failureCount = 0
    
    foreach ($rec in $allRecommendations) {
        try {
            # Check if this is a maintenance mode evacuation
            $isEvacuation = $rec.Reason -eq "MAINTENANCE_MODE_EVACUATION"
            $evacuationPrefix = if ($isEvacuation) { "[EVACUATION] " } else { "" }
            
            if ($PSCmdlet.ShouldProcess("VM '$($rec.VM_to_Move)' from '$($rec.Source_Host)' to '$($rec.Recommended_Destination_Host)'", "Migrate VM")) {
                Write-Host "${evacuationPrefix}Migrating VM '$($rec.VM_to_Move)' to '$($rec.Recommended_Destination_Host)'..."
                
                $vmToMove = Get-VM -Name $rec.VM_to_Move -ErrorAction Stop
                $destinationHost = Get-VMHost -Name $rec.Recommended_Destination_Host -ErrorAction Stop
                
                # Handle both powered-on and powered-off VMs
                if ($vmToMove.PowerState -eq 'PoweredOn') {
                    # Use vMotion for powered-on VMs
                    Move-VM -VM $vmToMove -Destination $destinationHost -VMotionPriority High -ErrorAction Stop
                    Write-Host "✓ ${evacuationPrefix}Successfully migrated VM '$($rec.VM_to_Move)' (vMotion)" -ForegroundColor Green
                } elseif ($vmToMove.PowerState -eq 'PoweredOff') {
                    # Use storage migration for powered-off VMs
                    Move-VM -VM $vmToMove -Destination $destinationHost -ErrorAction Stop
                    Write-Host "✓ ${evacuationPrefix}Successfully migrated VM '$($rec.VM_to_Move)' (cold migration)" -ForegroundColor Green
                } else {
                    Write-Warning "${evacuationPrefix}VM '$($rec.VM_to_Move)' is in '$($vmToMove.PowerState)' state. Skipping migration."
                    continue
                }
                
                $successCount++
            }
        }
        catch {
            Write-Error "${evacuationPrefix}Failed to migrate VM '$($rec.VM_to_Move)'. Error: $($_.Exception.Message)"
            $failureCount++
        }
    }
    
    # Provide detailed summary
    $evacuationCount = ($allRecommendations | Where-Object { $_.Reason -eq "MAINTENANCE_MODE_EVACUATION" }).Count
    $normalCount = ($allRecommendations | Where-Object { $_.Reason -ne "MAINTENANCE_MODE_EVACUATION" }).Count
    
    Write-Host "`nMigration Summary:"
    if ($evacuationCount -gt 0) {
        Write-Host "  Maintenance Mode Evacuations: $evacuationCount processed" -ForegroundColor Yellow
    }
    if ($normalCount -gt 0) {
        Write-Host "  Normal DRS Migrations: $normalCount processed" -ForegroundColor Cyan
    }
    Write-Host "  Total: $successCount successful, $failureCount failed" -ForegroundColor $(if ($failureCount -eq 0) { 'Green' } else { 'Red' })
}
else {
    Write-Host "`nNo migration recommendations to process."
}

# Disconnect only if this script made the connection
if ($shouldDisconnect) {
    Write-Host "`nAll tasks complete. Disconnecting from $vCenterServer (connection made by $($MyInvocation.MyCommand.Name))."
    Disconnect-VIServer -Confirm:$false -Force -WhatIf:$false
}
else {
    Write-Host "`nAll tasks complete. Leaving existing vCenter connection open."
}
