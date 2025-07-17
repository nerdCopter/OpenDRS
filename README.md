# OpenDRS Scripts
**Version 1.0.0**

## 1. Project Purpose

This project provides a set of PowerShell scripts for analyzing and executing VMware vSphere Distributed Resource Scheduler (DRS) recommendations for compute resources. The scripts are designed to respect VMware's VM/Host Rules and Groups, focusing exclusively on VM-to-host migration logic. Datastore migration is not part of this toolset.

---

## 2. Architecture

The project consists of a modular, two-part system to separate analysis from execution:

*   **`Get-OpenDrsRecommendation.ps1`**: A read-only "engine" that analyzes cluster health and generates migration recommendations.
*   **`Invoke-OpenDrsMigration.ps1`**: An "executor" that consumes recommendations from the analysis engine and performs the actual VM migrations.

### 2.1. Important: Not a Direct VMware DRS Replacement

**This toolset is NOT a 1:1 equivalent of VMware's integrated DRS or PowerCLI's `Get-DrsRecommendation`/`Invoke-DrsRecommendation` cmdlets.** Key differences include:

*   **Real-time Analysis Only**: Uses current host utilization (`QuickStats`) rather than historical data or saved statistics that VMware DRS leverages for trend analysis.
*   **Custom Algorithm**: Implements independent load balancing logic based on standard deviation analysis, not VMware's proprietary DRS algorithms.
*   **VM Count-Based Balancing**: The `-Balance` parameter distributes VMs based on quantity (count) across hosts, prioritizing migration of smallest VMs first, rather than resource-weighted distribution.
*   **Potential Conflicts**: Since this operates independently of VMware DRS, recommendations may occasionally conflict with or counteract VMware's native DRS decisions, especially when both systems are active simultaneously.

### 2.2. Connection Management and Maintenance Mode Detection

Both scripts feature intelligent connection management - they detect existing vCenter connections and only connect/disconnect when necessary. This enables efficient chaining and variable assignment workflows.

The scripts automatically detect hosts in maintenance mode or entering maintenance mode and generate evacuation recommendations that take priority over normal DRS analysis. Maintenance mode evacuations bypass all rules and ensure rapid VM evacuation.

---

## 3. Script Roles and Behaviors

### 3.1. Get-OpenDrsRecommendation.ps1 (The Engine)

*   **Role:**  
    The primary analysis engine. It is strictly **read-only** and makes no changes to the vSphere environment.
*   **Behavior:**  
    Connects to vCenter, analyzes cluster health using standard deviation analysis, and generates migration recommendations while respecting VM/Host rules. Automatically detects maintenance mode hosts and generates evacuation recommendations.
*   **Parameters:**
    *   `-vCenterServer` (string, Required): FQDN or IP address of the vCenter Server.
    *   `-Clusters` (string[], Optional): Specify one or more cluster names to analyze. If not provided, all clusters are analyzed.
    *   `-MigrationThreshold` (integer, 1–5): Controls the aggressiveness of recommendations (1=conservative, 5=aggressive). Defaults to 3.
    *   `-Balance` (switch): Generates load balancing recommendations to evenly distribute VMs across hosts, even when hosts are not resource-constrained. Useful for clusters with uneven VM distribution. Excludes vCLS (vSphere Cluster Services) VMs from balancing calculations.
    *   `-BypassHostRulesAndGroups` (switch): If set, recommendations will ignore all VM/Host affinity and anti-affinity rules.
    *   `-ExportToCsv` (switch): Exports recommendations to a timestamped CSV file when recommendations exist.
    *   `-Quiet` (switch): Suppresses console output for variable assignment workflows.
    *   `-NoDisconnect` (switch): Internal parameter to prevent disconnecting from vCenter when called by other scripts.
*   **Output:**  
    Returns an array of `PSCustomObject`s representing migration recommendations. Displays complete cluster analysis including host utilization, cluster balance statistics, and recommendation tables.

### 3.2. Invoke-OpenDrsMigration.ps1 (The Executor)

*   **Role:**  
    Executes the VM migrations recommended by the analysis engine. This is the only script that performs **write operations**. Supports variable assignment for direct consumption of recommendations.
*   **Behavior:**  
    1.  If used independently, calls `Get-OpenDrsRecommendation.ps1` internally.
    2.  If used with variable assignment, accepts recommendation objects directly from `Get-OpenDrsRecommendation.ps1`.
    3.  If CSV file is provided, loads recommendations from file instead of calling the analysis engine.
    4.  Executes `Move-VM` operations with high vMotion priority for each recommendation.
    5.  Logs the success or failure of each migration attempt.
*   **Parameters:**
    *   `-vCenterServer` (string): FQDN or IP address of the vCenter Server (required for independent use, optional for variable assignment workflows).
    *   `-Clusters` (string[], Optional): Specify one or more cluster names to analyze. Passthrough parameter for the analysis engine.
    *   `-CsvFile` (string): Path to a CSV file containing migration recommendations. When provided, the script loads recommendations from this file instead of calling the analysis engine.
    *   `-ExportToCsv` (switch): Passthrough parameter for the analysis engine.
    *   `-Balance` (switch): Passthrough parameter for the analysis engine.
    *   `-BypassHostRulesAndGroups` (switch): Passthrough parameter for the analysis engine.
    *   `-MigrationThreshold` (integer, 1–5): Passthrough parameter for the analysis engine.
    *   `-WhatIf`, `-Confirm`: Natively supported via `CmdletBinding` to allow users to preview actions before execution.
*   **Output:**  
    Displays migration execution status and results for each recommendation processed.

---

## 4. Usage Examples

### Analyze all clusters without making changes:
```powershell
.\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter.domain.com"
```

### Analyze specific cluster only:
```powershell
.\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Production Cluster"
```

### Analyze multiple specific clusters:
```powershell
.\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Production Cluster","Backup Cluster"
```

### Execute migrations for specific cluster with confirmation:
```powershell
.\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Production Cluster"
```

### Preview migrations for specific clusters without executing:
```powershell
.\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Cluster1","Cluster2" -WhatIf
```

### Aggressive analysis of specific cluster with CSV export:
```powershell
.\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Production Cluster" -MigrationThreshold 5 -ExportToCsv
```

### Load balancing for specific cluster:
```powershell
.\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Production Cluster" -Balance
```

### Execute load balancing migrations for specific cluster:
```powershell
.\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Production Cluster" -Balance
```

### Variable assignment workflow for efficient processing of specific clusters:
```powershell
$recommendations = .\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Production Cluster" -Quiet -NoDisconnect
if ($recommendations) { .\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Production Cluster" }
```

### Execute migrations from CSV file:
```powershell
.\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter.domain.com" -CsvFile "20250716-143022-drs_recommendations.csv"
```

### Preview migrations from CSV file:
```powershell
.\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter.domain.com" -CsvFile "recommendations.csv" -WhatIf
```

### Advanced cluster-specific workflows:
```powershell
# Generate recommendations for production clusters only, then execute with confirmation
.\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Prod-Cluster-01","Prod-Cluster-02" -MigrationThreshold 4 -ExportToCsv
.\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Prod-Cluster-01","Prod-Cluster-02" -Confirm

# Targeted load balancing for specific cluster with aggressive threshold
.\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Backup Cluster" -Balance -MigrationThreshold 5 -WhatIf
```

## 4.1. Invoke-OpenDrsMigration.ps1 Parameter Behavior

The `Invoke-OpenDrsMigration.ps1` script supports different execution modes through PowerShell's `ShouldProcess` framework:

| Parameters | Analysis | Recommendations | CSV Export | VM Migration | Prompts |
|------------|----------|----------------|------------|--------------|---------|
| `(none)` | ✅ Shows | ✅ Shows | ❌ N/A | ✅ Executes | ❌ No prompts |
| `-WhatIf` | ✅ Shows | ✅ Shows | ❌ N/A | ❌ Simulated | ❌ No prompts |
| `-Confirm` | ✅ Shows | ✅ Shows | ❌ N/A | ✅ Executes | ✅ **Prompts for each VM** |
| `-ExportToCsv` | ✅ Shows | ✅ Shows | ✅ Executes* | ✅ Executes | ❌ No prompts |
| `-ExportToCsv -WhatIf` | ✅ Shows | ✅ Shows | ✅ Executes* | ❌ Simulated | ❌ No prompts |
| `-ExportToCsv -Confirm` | ✅ Shows | ✅ Shows | ✅ Executes* | ✅ Executes | ✅ **Prompts for each VM** |
| `-ExportToCsv -Confirm -WhatIf` | ✅ Shows | ✅ Shows | ✅ Executes* | ❌ Simulated | ✅ **Prompts for each VM** |

*CSV Export is handled by the analysis engine (`Get-OpenDrsRecommendation.ps1`)

**Key Points:**
- **Analysis and Recommendations** always display regardless of parameters
- **CSV Export** is handled by the analysis engine (`Get-OpenDrsRecommendation.ps1`) when `-ExportToCsv` is passed through
- **`-WhatIf`** simulates VM migrations but does NOT affect CSV export behavior (CSV is still created)
- **`-Confirm`** prompts separately for each VM migration (CSV export prompting is handled by the analysis engine)
- **`-ExportToCsv -Confirm -WhatIf`** creates CSV file and only simulates VM migrations

## 4.2. Maintenance Mode Evacuation

The scripts automatically detect hosts in maintenance mode or entering maintenance mode and generate evacuation recommendations that bypass all DRS rules and affinity groups.

### Detection Method
- **Hosts in Maintenance Mode**: `ConnectionState -eq 'Maintenance'`
- **Hosts Entering Maintenance Mode**: Uses `Get-Task -Status Running` to find active "EnterMaintenanceMode" tasks

### Evacuation Behavior
- **Processing Order**: Evacuation recommendations are processed first
- **Rule Bypassing**: All VM/Host affinity rules and groups are automatically bypassed for evacuations
- **VM Support**: Handles both powered-on (vMotion) and powered-off (cold migration) VMs
- **Load Balancing**: Distributes evacuated VMs across available hosts
- **Combined Analysis**: Both evacuation and normal DRS recommendations are generated and included in the output

### Examples
```powershell
# Check for maintenance mode evacuations in specific cluster
.\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Production Cluster" -Verbose

# Execute evacuations with preview for specific cluster
.\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Production Cluster" -WhatIf
```

### Output Format
Evacuation recommendations include:
- `Reason`: "Maintenance Evacuation"
- Console output displays evacuation recommendations clearly in tables
- Both evacuation and normal DRS recommendations are combined in the final output

## 4.3. CSV Export and Recommendation Types

When using `-ExportToCsv`, all recommendation types are exported to a single timestamped CSV file:

### Recommendation Types in CSV:
1. **Evacuation Recommendations**: `Reason` = "Maintenance Evacuation"
2. **Standard DRS Recommendations**: `Reason` = "High CPU/Mem on source"  
3. **Load Balancing Recommendations**: `Reason` = "Load Balancing"

### CSV File Format:
- **Filename**: `YYYYMMDD-HHMMSS-drs_recommendations.csv`
- **Location**: Same directory as the script
- **Contents**: All recommendation types combined in a single file
- **Columns**: Cluster, VM_to_Move, Reason, Source_Host, Source_Host_CPU, Source_Host_Mem, Recommended_Destination_Host, Destination_Host_CPU, Destination_Host_Mem

### Example:
```powershell
# Export all types of recommendations to CSV for specific cluster
.\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter.domain.com" -Clusters "Production Cluster" -Balance -ExportToCsv
```

---

## 5. Advanced Features

### 5.1. Cluster Filtering
Both scripts support targeted analysis by specifying specific clusters:

- **Default Behavior**: Analyze all clusters when no `-Clusters` parameter is specified
- **Single Cluster**: `-Clusters "Production Cluster"` to analyze only one cluster
- **Multiple Clusters**: `-Clusters "Cluster1","Cluster2"` to analyze specific clusters
- **Exact Matching**: Cluster names must match exactly (case-sensitive)
- **Error Handling**: Clear error messages when specified clusters are not found

**Benefits:**
- **Focused Analysis**: Target specific clusters without analyzing entire infrastructure
- **Reduced Scope**: Faster execution when working with large vCenter environments
- **Operational Safety**: Limit operations to specific clusters for controlled changes
- **Resource Efficiency**: Minimize vCenter API calls and processing time

### 5.2. Smart Connection Management
Both scripts intelligently manage vCenter connections:
- **Reuse existing connections** when already connected to the target server
- **Only connect when necessary**, avoiding unnecessary disconnection/reconnection cycles  
- **Independent operation** - each script manages its own connection lifecycle
- **Clear status messages** indicating connection decisions

### 5.3. Variable Assignment Support
The scripts support efficient chaining using PowerShell variable assignment:
```powershell
# Efficient chaining with quiet analysis output for all clusters
$recommendations = .\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter" -Quiet -NoDisconnect
if ($recommendations) { .\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter" }

# Efficient chaining for specific clusters
$recommendations = .\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter" -Clusters "Production Cluster" -Quiet -NoDisconnect
if ($recommendations) { .\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter" }

# Traditional separate execution (shows full analysis output)
.\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter" -Clusters "Production Cluster"
.\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter" -Clusters "Production Cluster"
```

The `-Quiet` parameter suppresses console output from the analysis engine while preserving all returned recommendation objects. Both scripts share vCenter connections efficiently, avoiding unnecessary reconnections.

---

## 6. Requirements

*   **VMware PowerCLI**: Must be installed and available (VMware.PowerCLI or VCF.PowerCLI)
*   **vCenter Access**: Appropriate permissions for VM migration operations
*   **PowerShell**: Windows PowerShell 5.1 or later

---

## 7. Technical Details

### 7.1. Algorithm Implementation

**Important**: These scripts implement a custom DRS-like algorithm that is **not equivalent** to VMware's native DRS engine. Key technical differences:

**Data Source:**
- Uses real-time vSphere `QuickStats` data (current CPU/memory utilization)
- Does NOT use historical performance data or saved statistics that VMware DRS leverages
- No trend analysis or predictive modeling capabilities

**Analysis Methods:**

**Cluster Filtering:**
- Analyze all clusters when no `-Clusters` parameter is specified (default behavior)
- Analyze only specified clusters when `-Clusters` parameter is provided with one or more cluster names
- Supports exact cluster name matching for precise targeting

**Standard DRS Analysis:**
- Calculate average CPU and memory utilization across cluster hosts using standard deviation analysis
- Identify hosts exceeding threshold based on standard deviation multiplier (configurable via `-MigrationThreshold`)
- Generate recommendations to move VMs from over-utilized to under-utilized hosts
- Moves largest VMs first during standard DRS analysis

**Load Balancing Analysis (when `-Balance` is specified):**
- Count VMs per host, excluding vCLS (vSphere Cluster Services) VMs
- Calculate ideal distribution for even VM **count** (not resource-weighted) across hosts
- Generate recommendations to achieve balanced VM distribution regardless of resource utilization
- **Moves smallest VMs first** to optimize distribution efficiency
- May conflict with resource-based recommendations from VMware's native DRS

**Rule Compliance:**
- Respect all VM/Host affinity rules and VM anti-affinity rules unless bypassed
- Automatically exclude hosts in maintenance mode from all analysis and operations

**Coexistence Considerations:**
- When VMware DRS is enabled and set to automatic mode, recommendations from this toolset may occasionally conflict with VMware's native DRS decisions
- Both systems operate independently and may attempt to optimize for different criteria simultaneously
- Consider VMware DRS automation level and cluster configuration when using this toolset

### 7.2. Rule Compliance
- **VM/Host Affinity Rules**: VMs required to run on specific host groups are only migrated within those groups
- **VM/Host Anti-Affinity Rules**: VMs forbidden from specific host groups are never migrated to those hosts
- **VM Anti-Affinity Rules**: VMs marked to separate are never placed on the same host
- **Keep Together Rules**: VM groups marked for affinity are migrated as complete units

### 7.3. Safety Features
- Read-only analysis engine prevents accidental modifications
- WhatIf support allows previewing all operations
- Comprehensive rule validation before any migration
- High vMotion priority for reliable migrations
- Detailed logging of all operations and failures

### 7.4. Tested Versions
- **PowerShell 7.5.2** (Primary testing platform)
- **PowerShell 5.1.26100.4652** (Windows PowerShell compatibility)  
- **VMware PowerCLI 13.3.0** (build 24145083)
- **VMware vCenter Server 8.0.3.00500**
- **VMware ESXi 8.0.3** (build 24674464)
- **VMware ESXi 7.0.3** (build 24723872)
