# OpenDRS Scripts
**Version 1.0.0**

## 1. Project Purpose

This project provides a set of PowerShell scripts for analyzing and executing VMware vSphere Distributed Resource Scheduler (DRS) recommendations for compute resources. The scripts are designed to respect VMware's VM/Host Rules and Groups, focusing exclusively on VM-to-host migration logic. Datastore migration is not part of this toolset.

---

## 2. Architecture

The project consists of a modular, two-part system to separate analysis from execution:

*   **`Get-OpenDrsRecommendation.ps1`**: A read-only "engine" that analyzes cluster health and generates migration recommendations.
*   **`Invoke-OpenDrsMigration.ps1`**: An "executor" that consumes recommendations from the engine and performs the actual VM migrations.

The engine script always displays full analysis output including per-cluster host utilization tables, cluster balance statistics, and recommendation tables. When executing migrations, `Invoke-OpenDrsMigration.ps1` directs the engine to leave the vCenter session open and manages disconnection after all operations complete.

All scripts automatically exclude hosts in maintenance mode from both analysis and migration targeting, ensuring that only operational hosts are considered for workload balancing.

---

## 3. Script Roles and Behaviors

### 3.1. Get-OpenDrsRecommendation.ps1 (The Engine)

*   **Role:**  
    The primary analysis engine. It is strictly **read-only** and makes no changes to the vSphere environment.
*   **Behavior:**  
    Connects to vCenter, gathers host and VM statistics for each cluster, calculates cluster balance using standard deviation analysis, and identifies over-utilized and under-utilized hosts. Generates migration recommendations while respecting VM/Host affinity rules and VM anti-affinity rules.
*   **Parameters:**
    *   `-vCenterServer` (string, Required): FQDN or IP address of the vCenter Server.
    *   `-MigrationThreshold` (integer, 1–5): Controls the aggressiveness of recommendations (1=conservative, 5=aggressive). Defaults to 3.
    *   `-BypassHostRulesAndGroups` (switch): If set, recommendations will ignore all VM/Host affinity and anti-affinity rules.
    *   `-ExportToCsv` (switch): Exports recommendations to a timestamped CSV file when recommendations exist.
    *   `-NoDisconnect` (switch): Internal parameter to prevent disconnecting from vCenter when called by other scripts.
*   **Output:**  
    Always displays complete cluster analysis including host utilization tables, cluster balance statistics, and recommendation tables. Returns an array of `PSCustomObject`s representing migration recommendations.

### 3.2. Invoke-OpenDrsMigration.ps1 (The Executor)

*   **Role:**  
    Executes the VM migrations recommended by the engine. This is the only script that performs **write operations**.
*   **Behavior:**  
    1.  Calls `Get-OpenDrsRecommendation.ps1` internally, displaying all analysis output to the user.
    2.  Uses `ShouldProcess` (`-WhatIf`/`-Confirm`) to show exactly what migrations would be performed.
    3.  Executes `Move-VM` operations with high vMotion priority for each recommendation.
    4.  Logs the success or failure of each migration attempt.
    5.  Manages the vCenter connection lifecycle, disconnecting only after all work is complete.
*   **Parameters:**
    *   `-vCenterServer` (string, Required): FQDN or IP address of the vCenter Server.
    *   `-ExportToCsv`, `-BypassHostRulesAndGroups`, `-MigrationThreshold`: Passthrough parameters for the analysis engine.
    *   `-WhatIf`, `-Confirm`: Natively supported via `CmdletBinding` to allow users to preview actions before execution.
*   **Output:**  
    Displays complete cluster analysis followed by migration execution status and results.

---

## 4. Usage Examples

### Analyze clusters without making changes:
```powershell
.\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter.domain.com"
```

### Execute migrations with confirmation:
```powershell
.\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter.domain.com"
```

### Preview migrations without executing:
```powershell
.\Invoke-OpenDrsMigration.ps1 -vCenterServer "vcenter.domain.com" -WhatIf
```

### Aggressive analysis with CSV export:
```powershell
.\Get-OpenDrsRecommendation.ps1 -vCenterServer "vcenter.domain.com" -MigrationThreshold 5 -ExportToCsv
```

## 4.1. Invoke-OpenDrsMigration.ps1 Parameter Behavior

The `Invoke-OpenDrsMigration.ps1` script supports different execution modes through PowerShell's `ShouldProcess` framework:

| Parameters | Analysis | Recommendations | CSV Export | VM Migration | Prompts |
|------------|----------|----------------|------------|--------------|---------|
| `(none)` | ✅ Shows | ✅ Shows | ❌ N/A | ✅ Executes | ❌ No prompts |
| `-WhatIf` | ✅ Shows | ✅ Shows | ❌ N/A | ❌ Simulated | ❌ No prompts |
| `-Confirm` | ✅ Shows | ✅ Shows | ❌ N/A | ✅ Executes | ✅ **Prompts for each VM** |
| `-ExportToCsv` | ✅ Shows | ✅ Shows | ✅ Executes | ✅ Executes | ❌ No prompts |
| `-ExportToCsv -WhatIf` | ✅ Shows | ✅ Shows | ❌ Simulated | ❌ Simulated | ❌ No prompts |
| `-ExportToCsv -Confirm` | ✅ Shows | ✅ Shows | ✅ Executes | ✅ Executes | ✅ **Prompts for CSV + each VM** |
| `-ExportToCsv -Confirm -WhatIf` | ✅ Shows | ✅ Shows | ✅ Executes | ❌ Simulated | ✅ **Prompts for CSV only** |

**Key Points:**
- **Analysis and Recommendations** always display regardless of parameters
- **CSV Export** only available when `-ExportToCsv` is specified
- **`-WhatIf`** simulates VM migrations but does NOT affect CSV export behavior
- **`-Confirm`** prompts separately for CSV export (if requested) and each VM migration
- **`-ExportToCsv -Confirm -WhatIf`** creates CSV file with confirmation but only simulates VM migrations

---

## 5. Requirements

*   **VMware PowerCLI**: Must be installed and available (VMware.PowerCLI or VCF.PowerCLI)
*   **vCenter Access**: Appropriate permissions for VM migration operations
*   **PowerShell**: Windows PowerShell 5.1 or later

---

## 6. Technical Details

### 6.1. Algorithm
The scripts use statistical analysis (standard deviation) to identify cluster imbalances:
- Calculate average CPU and memory utilization across cluster hosts
- Identify hosts exceeding threshold based on standard deviation multiplier
- Generate recommendations to move VMs from over-utilized to under-utilized hosts
- Respect all VM/Host affinity rules and VM anti-affinity rules unless bypassed
- Automatically exclude hosts in maintenance mode from all analysis and operations

### 6.2. Rule Compliance
- **VM/Host Affinity Rules**: VMs required to run on specific host groups are only migrated within those groups
- **VM/Host Anti-Affinity Rules**: VMs forbidden from specific host groups are never migrated to those hosts
- **VM Anti-Affinity Rules**: VMs marked to separate are never placed on the same host
- **Keep Together Rules**: VM groups marked for affinity are migrated as complete units

### 6.3. Safety Features
- Read-only analysis engine prevents accidental modifications
- WhatIf support allows previewing all operations
- Comprehensive rule validation before any migration
- High vMotion priority for reliable migrations
- Detailed logging of all operations and failures
