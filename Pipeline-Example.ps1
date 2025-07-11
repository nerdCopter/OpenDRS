<#
.SYNOPSIS
    Example demonstrating usage patterns for Get-OpenDrsRecommendation and Invoke-OpenDrsMigration.

.DESCRIPTION
    This example demonstrates different approaches for using the OpenDRS scripts:
    1. Traditional separate execution with full output
    2. Efficient chaining with quiet analysis mode
    3. Connection management best practices

.PARAMETER vCenterServer
    The fully qualified domain name (FQDN) or IP address of the vCenter Server.

.PARAMETER MigrationThreshold
    Optional migration aggressiveness level (1-5). Default is 3.

.PARAMETER WhatIf
    Shows what migrations would be performed without executing them.

.EXAMPLE
    .\Pipeline-Example.ps1 -vCenterServer 'vcenter.yourdomain.com'

    Demonstrates both traditional and efficient usage patterns.

.EXAMPLE
    .\Pipeline-Example.ps1 -vCenterServer 'vcenter.yourdomain.com' -MigrationThreshold 5 -WhatIf

    Uses aggressive threshold and shows what would happen without executing.

.NOTES
    Version:        1.0.0
    Author:         OpenDRS Project
    Creation Date:  July 11, 2025
    License:        GNU Affero General Public License v3.0 (AGPL-3.0)
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$vCenterServer = 'vcenter',
    [ValidateSet(1, 2, 3, 4, 5)]
    [int]$MigrationThreshold = 3
)

Write-Host "=== OpenDRS Usage Example ===" -ForegroundColor Cyan
Write-Host "Demonstrating different usage patterns for OpenDRS scripts"
Write-Host "vCenter Server: $vCenterServer"
Write-Host "Migration Threshold: $MigrationThreshold"
Write-Host "Mode: Preview only (WhatIf enforced for safety)" -ForegroundColor Yellow
Write-Host ""

# Method 1: Traditional approach - separate execution with full analysis output
Write-Host "Method 1: Traditional Separate Execution" -ForegroundColor Green
Write-Host "This shows the complete analysis process with full console output."
Write-Host ""

Write-Host "Step 1: Getting recommendations with full analysis output..." -ForegroundColor Yellow
$getArgs = @{
    vCenterServer = $vCenterServer
    MigrationThreshold = $MigrationThreshold
    NoDisconnect = $true
}
$recommendations = & "$PSScriptRoot\Get-OpenDrsRecommendation.ps1" @getArgs

if ($recommendations -and $recommendations.Count -gt 0) {
    Write-Host ""
    Write-Host "Step 2: Executing migrations (WhatIf only) based on $($recommendations.Count) recommendations..." -ForegroundColor Yellow
    $invokeArgs = @{
        vCenterServer = $vCenterServer
        MigrationThreshold = $MigrationThreshold
        WhatIf = $true  # Always use WhatIf for safety
    }
    
    & "$PSScriptRoot\Invoke-OpenDrsMigration.ps1" @invokeArgs
} else {
    Write-Host "No recommendations found to execute." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Method 2: Efficient chaining approach
Write-Host "Method 2: Efficient Chaining with Quiet Analysis" -ForegroundColor Green
Write-Host "This approach minimizes output while preserving all functionality."
Write-Host ""

try {
    Write-Host "Getting recommendations quietly..." -ForegroundColor Yellow
    # Get recommendations with quiet mode to suppress console output
    $quietArgs = @{
        vCenterServer = $vCenterServer
        MigrationThreshold = $MigrationThreshold
        Quiet = $true
        NoDisconnect = $true
    }
    $quietRecommendations = & "$PSScriptRoot\Get-OpenDrsRecommendation.ps1" @quietArgs
    
    if ($quietRecommendations -and $quietRecommendations.Count -gt 0) {
        Write-Host "Retrieved $($quietRecommendations.Count) recommendations quietly" -ForegroundColor Green
        
        Write-Host "Processing recommendations (WhatIf only)..." -ForegroundColor Yellow
        # Process recommendations - always using WhatIf for safety in this example
        foreach ($rec in $quietRecommendations) {
            Write-Host "  Would migrate VM: $($rec.VM_to_Move) from $($rec.Source_Host) to $($rec.Recommended_Destination_Host)" -ForegroundColor Cyan
        }
        
        Write-Host "Efficient chaining completed successfully!" -ForegroundColor Green
    } else {
        Write-Host "No recommendations found to process" -ForegroundColor Yellow
    }
} catch {
    Write-Error "Efficient chaining failed: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "=== Usage Summary ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Best Practices:" -ForegroundColor Green
Write-Host "• Use Method 1 for interactive analysis and troubleshooting"
Write-Host "• Use Method 2 for automation and scripted workflows"
Write-Host "• Always use -WhatIf first to preview actions"
Write-Host "• The -Quiet parameter suppresses output while preserving return objects"
Write-Host "• Connection management is handled automatically between scripts"
Write-Host ""
Write-Host "Advanced Usage:" -ForegroundColor Green
Write-Host "• Add -ExportToCsv to save recommendations to CSV files"
Write-Host "• Use -BypassHostRulesAndGroups to ignore DRS rules"
Write-Host "• Adjust -MigrationThreshold (1-5) to control aggressiveness"
Write-Host ""

# Final cleanup - disconnect from vCenter
Write-Host "=== Cleanup ===" -ForegroundColor Cyan
if ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected) {
    Write-Host "Disconnecting from vCenter Server..." -ForegroundColor Yellow
    Disconnect-VIServer -Confirm:$false -Force -WhatIf:$false
    Write-Host "Successfully disconnected from vCenter." -ForegroundColor Green
} else {
    Write-Host "No active vCenter connection to disconnect." -ForegroundColor Yellow
}
Write-Host ""

Write-Host "=== Example Complete ===" -ForegroundColor Cyan
