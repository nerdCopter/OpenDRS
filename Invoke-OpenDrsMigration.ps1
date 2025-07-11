<#
.SYNOPSIS
    Gets, displays, and executes VM migration recommendations for cluster balancing.

.DESCRIPTION
    This is the main user-facing script. It calls the 'Get-OpenDrsRecommendation.ps1' engine to
    generate a list of migrations. It then displays these recommendations and, after user
    confirmation, executes the migrations.

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
    Sets the migration aggressiveness level (1-5) for the engine. Default is 3.

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

.NOTES
    Version:        0.9.0
    Author:         NJD
    Creation Date:  July 9, 2025
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
    [string]$CsvFile,  # Path to CSV file containing recommendations
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
    Write-Host "  -ExportToCsv                Export recommendations from the engine to a CSV file (only if recommendations exist)."
    Write-Host "  -BypassHostRulesAndGroups   Tell the engine to ignore VM/Host affinity rules."
    Write-Host "  -MigrationThreshold <1-5>   Set migration aggressiveness in the engine (1=conservative, 5=aggressive). Default is 3."
    Write-Host "  -CsvFile <path>             Load recommendations from a CSV file instead of calling the analysis engine."
    Write-Host "  -Verbose                    Output detailed diagnostic information from the recommendation engine."
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

# If no recommendations found yet, get them from the engine script
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
    $allRecommendations = & "$PSScriptRoot\Get-OpenDrsRecommendation.ps1" @engineArgs
}

# Connect for migration operations if we have recommendations to execute
if ($allRecommendations -and $allRecommendations.Count -gt 0) {
    if ([string]::IsNullOrEmpty($vCenterServer)) {
        Write-Error "vCenterServer parameter is required for VM migrations."
        exit 1
    }

    # Connect to vCenter for migration operations
    if ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected) {
        # Check if we're connected to the same server (handle FQDN vs hostname differences)
        $connectedServer = $global:DefaultVIServer.Name
        $targetServer = $vCenterServer
        
        # Compare servers - handle cases where one might be FQDN and other hostname
        $serversMatch = ($connectedServer -eq $targetServer) -or 
                       ($connectedServer.Split('.')[0] -eq $targetServer.Split('.')[0])
        
        if ($serversMatch) {
            Write-Verbose "Using existing vCenter Server connection: $connectedServer"
            # We're using an existing connection, so don't disconnect unless we started disconnected
            $shouldDisconnect = -not $wasConnectedAtStart
        }
        else {
            Write-Host "Connecting to vCenter Server: $vCenterServer..."
            Write-Host "Disconnecting existing vCenter session from $connectedServer."
            Disconnect-VIServer -Server $global:DefaultVIServer -Confirm:$false -Force -WhatIf:$false
            Connect-VIServer -Server $vCenterServer -ErrorAction Stop | Out-Null
            Write-Host "Successfully connected to $vCenterServer."
            $shouldDisconnect = $true
        }
    }
    else {
        try {
            Write-Host "Connecting to vCenter Server: $vCenterServer..."
            Connect-VIServer -Server $vCenterServer -ErrorAction Stop | Out-Null
            Write-Host "Successfully connected to $vCenterServer."
            $shouldDisconnect = $true
        }
        catch {
            Write-Error "Failed to connect to vCenter Server '$vCenterServer'. Please check the server name and your network connection. `n$($_.Exception.Message)"
            exit 1
        }
    }
}

# Execute migrations with confirmation
if ($allRecommendations -and $allRecommendations.Count -gt 0) {
    Write-Host "`nStarting migration process..."
    foreach ($rec in $allRecommendations) {
        try {
            if ($PSCmdlet.ShouldProcess("Target: '$($rec.VM_to_Move)' -> '$($rec.Recommended_Destination_Host)'", "Migrate VM")) {
                Write-Verbose "Executing migration for VM '$($rec.VM_to_Move)'..."
                $vmToMove = Get-VM -Name $rec.VM_to_Move
                $destinationHost = Get-VMHost -Name $rec.Recommended_Destination_Host
                Move-VM -VM $vmToMove -Destination $destinationHost -VMotionPriority High -ErrorAction Stop
            }
        }
        catch {
            Write-Error "Failed to migrate VM '$($rec.VM_to_Move)'. Error: $($_.Exception.Message)"
        }
    }
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
