#requires -Version 5.1
<#
.SYNOPSIS
    Interactive, local Hyper-V manager restricted to existing LAB-* VMs.
.DESCRIPTION
    Run on the Hyper-V host in elevated Windows PowerShell 5.1 (powershell.exe).
    Select a VM, then an operation. Uses VM/checkpoint IDs, not name wildcards.
    Checkpoint changes and exports require the VM to be Off. Restores offer an
    optional safety checkpoint and never issue an automatic start/resume.
    No VM creation/deletion, guest provisioning, credential copying, or disk
    file deletion is implemented. This is an operator tool, not a security
    boundary against another administrator or an untrusted guest.
.PARAMETER ReadOnly
    Allows inventory, details and checkpoint listing; blocks all VM changes.
    A host-side audit log is still written.
.PARAMETER LogRoot
    Host log folder. Default: %LOCALAPPDATA%\LabVmManager\Logs.
.PARAMETER ExportRoot
    Optional existing local export folder, e.g. E:\HyperV-Exports.
    Each export goes into a new, unique subfolder. Otherwise prompts at export.
.PARAMETER TimeoutSeconds
    Maximum polling interval for VM start/shutdown state (default 180 seconds).
    Does not impose a timeout on Hyper-V checkpoint/export/merge operations.
.EXAMPLE
    powershell.exe -NoProfile -File .\Lab-VM.ps1 -ReadOnly
.EXAMPLE
    powershell.exe -NoProfile -File .\Lab-VM.ps1 -ExportRoot E:\HyperV-Exports
.NOTES
    Version: 1.0.0
    Written for Windows PowerShell 5.1. Does not change execution policy.
    Use only for disposable local lab VMs. See README.md and MANUAL-TESTS.md.
#>
[CmdletBinding()]
param(
    [switch]$ReadOnly,
    [string]$LogRoot = '',
    [string]$ExportRoot = '',
    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$script:LabVersion = '1.0.0'
$script:LabReadOnly = [bool]$ReadOnly
$script:LabLogFile = $null
$script:LabExportRoot = $ExportRoot
$script:LabTimeout = $TimeoutSeconds

function Test-LabVMName {
    param([AllowNull()][AllowEmptyString()][string]$Name)
    return (-not [string]::IsNullOrEmpty($Name) -and
        $Name.StartsWith('LAB-', [StringComparison]::OrdinalIgnoreCase))
}

function ConvertTo-LabMenuIndex {
    param([AllowEmptyString()][string]$Text, [int]$Count)
    $number = 0
    if ($Text -match '^\d+$' -and [int]::TryParse($Text, [ref]$number) -and
        $number -ge 1 -and $number -le $Count) { return ($number - 1) }
    return -1
}

function Get-LabProperty {
    param($Object, [string]$Name, $Default = '-')
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Read-LabText {
    param([string]$Prompt)
    $value = Read-Host $Prompt
    if ($null -eq $value) { throw [OperationCanceledException]::new('Input closed.') }
    return $value.Trim()
}

function Confirm-LabText {
    param([string]$Expected)
    Write-Host "Type exactly: $Expected"
    $answer = Read-LabText 'Confirmation (anything else cancels)'
    return [string]::Equals($answer, $Expected, [StringComparison]::Ordinal)
}

function Read-LabYesNoCancel {
    param([string]$Prompt)
    while ($true) {
        $answer = (Read-LabText "$Prompt [Y/n/cancel]").ToUpperInvariant()
        switch ($answer) {
            ''       { return 'Y' }
            'Y'      { return 'Y' }
            'YES'    { return 'Y' }
            'N'      { return 'N' }
            'NO'     { return 'N' }
            'C'      { return 'C' }
            'CANCEL' { return 'C' }
            default  { Write-Host 'Enter Y, N or C.' }
        }
    }
}

function Assert-LabHost {
    if ($env:OS -ne 'Windows_NT') { throw 'Run this script on your Windows Hyper-V host.' }
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Use Windows PowerShell 5.1: powershell.exe -NoProfile -File .\Lab-VM.ps1'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Open Windows PowerShell with Run as administrator, then run this script.'
        }
    } finally { $identity.Dispose() }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw 'Hyper-V PowerShell tools are missing. Enable/install the host management tools first.'
    }
    Import-Module Hyper-V -ErrorAction Stop
    $service = Get-Service -Name vmms -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        throw 'The Hyper-V Virtual Machine Management service (vmms) is not running.'
    }
}

function Initialize-LabLog {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Join-Path $env:LOCALAPPDATA 'LabVmManager\Logs'
    }
    $rootPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
    [void][IO.Directory]::CreateDirectory($rootPath)
    $sessionName = '{0}-{1}-{2}.jsonl' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID,
        ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $script:LabLogFile = Join-Path $rootPath $sessionName
    # Create the log now; if this fails, no VM operation has been attempted.
    [IO.File]::WriteAllText($script:LabLogFile, '', [Text.UTF8Encoding]::new($false))
}

function Write-LabAudit {
    param([string]$Action, [string]$Status, $VM = $null, [string]$Detail = '')
    if ([string]::IsNullOrWhiteSpace($script:LabLogFile)) { throw 'Audit log is not initialized.' }
    $record = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        hostName = $env:COMPUTERNAME
        operator = [Environment]::UserName
        processId = $PID
        scriptVersion = $script:LabVersion
        action = $Action
        status = $Status
        vmId = $(if ($null -eq $VM) { $null } else { [string]$VM.Id })
        vmName = $(if ($null -eq $VM) { $null } else { [string]$VM.Name })
        detail = $Detail
    }
    $line = ($record | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine
    [IO.File]::AppendAllText($script:LabLogFile, $line, [Text.UTF8Encoding]::new($false))
}

function Get-LabVM {
    param([Parameter(Mandatory)][guid]$VMId)
    $matches = @(Get-VM -Id $VMId -ErrorAction Stop)
    if ($matches.Count -ne 1) { throw "VM $VMId no longer resolves to exactly one local VM." }
    $vm = $matches[0]
    if (-not (Test-LabVMName $vm.Name)) {
        throw "Refusing VM '$($vm.Name)' [$VMId]: its current name does not start with LAB-."
    }
    return $vm
}

function Assert-LabVMOff {
    param([guid]$VMId)
    $vm = Get-LabVM $VMId
    if ([string]$vm.State -ne 'Off') {
        throw "'$($vm.Name)' is $($vm.State). This operation requires Off, not Saved/Paused. Start or resume it if needed, then shut down normally."
    }
    return $vm
}

function Wait-LabVMState {
    param([guid]$VMId, [string]$State)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $script:LabTimeout) {
        $vm = Get-LabVM $VMId
        if ([string]$vm.State -eq $State) { return $vm }
        Start-Sleep -Seconds 1
    }
    $vm = Get-LabVM $VMId
    throw "State wait timed out: '$($vm.Name)' is $($vm.State), expected $State. No forced fallback was attempted. The original request may still finish; inspect the VM before retrying."
}

function Get-LabSnapshots {
    param([guid]$VMId)
    $vm = Get-LabVM $VMId
    return @(Get-VMSnapshot -VM $vm -ErrorAction Stop | Sort-Object CreationTime, Id)
}

function Get-LabSnapshot {
    param([guid]$VMId, [guid]$SnapshotId)
    $matches = @(Get-LabSnapshots $VMId | Where-Object { [guid]$_.Id -eq $SnapshotId })
    if ($matches.Count -ne 1) { throw "Checkpoint $SnapshotId is no longer present on the selected VM." }
    if ([string]$matches[0].SnapshotType -ne 'Standard') {
        throw 'Recovery/backup checkpoints are not managed by this tool.'
    }
    return $matches[0]
}

function Show-LabCheckpoints {
    param([guid]$VMId)
    $items = @(Get-LabSnapshots $VMId)
    if ($items.Count -eq 0) { Write-Host 'No checkpoints found.'; return }
    $items | Select-Object Name, CreationTime, SnapshotType,
        @{n='Parent'; e={ Get-LabProperty $_ 'ParentSnapshotName' '(root)' }}, Id |
        Format-Table -AutoSize -Wrap | Out-Host
    Write-Host 'SnapshotType Standard identifies a user checkpoint, not necessarily its memory-capture policy.'
    Write-Host 'Recovery/backup checkpoints are displayed but cannot be selected for changes.'
}

function Select-LabCheckpoint {
    param([guid]$VMId)
    while ($true) {
        $items = @(Get-LabSnapshots $VMId | Where-Object { [string]$_.SnapshotType -eq 'Standard' })
        if ($items.Count -eq 0) { Write-Host 'No user checkpoints available.'; return $null }
        $rows = for ($i = 0; $i -lt $items.Count; $i++) {
            [pscustomobject]@{ No = $i + 1; Name = $items[$i].Name;
                Created = $items[$i].CreationTime; Id = $items[$i].Id }
        }
        $rows | Format-Table -AutoSize -Wrap | Out-Host
        $answer = Read-LabText 'Checkpoint number; R refresh; B cancel'
        if ($answer -ieq 'B' -or $answer -eq '') { return $null }
        if ($answer -ieq 'R') { continue }
        $index = ConvertTo-LabMenuIndex $answer $items.Count
        if ($index -ge 0) { return Get-LabSnapshot $VMId ([guid]$items[$index].Id) }
        Write-Host 'Choose a listed number, R or B.'
    }
}

function Select-LabVM {
    while ($true) {
        Clear-Host
        Write-Host "`n=== LAB VM Manager | $env:COMPUTERNAME | read-only: $script:LabReadOnly ==="
        $items = @(Get-VM -ErrorAction Stop | Where-Object { Test-LabVMName $_.Name } |
            Sort-Object Name, Id)
        if ($items.Count -eq 0) {
            Write-Host 'No local VMs whose names begin with LAB- were found. No VMs will be created or renamed.'
        } else {
            $rows = for ($i = 0; $i -lt $items.Count; $i++) {
                $vm = $items[$i]
                [pscustomobject]@{ No = $i + 1; Name = $vm.Name; State = $vm.State;
                    CPUs = $vm.ProcessorCount; RAM_GiB = [math]::Round($vm.MemoryAssigned / 1GB, 1);
                    Id = $vm.Id }
            }
            $rows | Format-Table -AutoSize -Wrap | Out-Host
        }
        $answer = Read-LabText 'VM number; R refresh; Q quit'
        if ($answer -ieq 'Q') { return $null }
        if ($answer -ieq 'R') { continue }
        $index = ConvertTo-LabMenuIndex $answer $items.Count
        if ($index -ge 0) { return Get-LabVM ([guid]$items[$index].Id) }
        Write-Host 'Choose a listed number, R or Q.'
    }
}

function Show-LabVMDetails {
    param([guid]$VMId)
    $vm = Get-LabVM $VMId
    $vm | Select-Object Name, Id, State, Status, Generation, Version, ProcessorCount,
        MemoryStartup, MemoryAssigned, DynamicMemoryEnabled, CheckpointType,
        AutomaticCheckpointsEnabled, Path, SnapshotFileLocation |
        Format-List | Out-Host
    Write-Host '--- Virtual disks (do not edit checkpoint disk files manually) ---'
    Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
        Select-Object ControllerType, ControllerNumber, ControllerLocation, Path, DiskNumber |
        Format-Table -AutoSize -Wrap | Out-Host
    Write-Host '--- Network adapters ---'
    Get-VMNetworkAdapter -VM $vm -ErrorAction Stop |
        Select-Object Name, SwitchName, MacAddress, IPAddresses |
        Format-Table -AutoSize -Wrap | Out-Host
    Write-Host '--- Integration services ---'
    Get-VMIntegrationService -VM $vm -ErrorAction Stop |
        Select-Object Name, Enabled, PrimaryStatusDescription |
        Format-Table -AutoSize -Wrap | Out-Host
}

function Start-LabVM {
    param([guid]$VMId)
    $vm = Get-LabVM $VMId
    switch ([string]$vm.State) {
        'Running' { Write-Host 'Already running.'; return 'NO_CHANGE' }
        'Off'     { Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
        'Saved'   { Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
        'Paused'  { Resume-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
        default   { throw "Cannot start/resume from state $($vm.State). Inspect it in Hyper-V Manager." }
    }
    $vm = Wait-LabVMState $VMId 'Running'
    Write-Host "'$($vm.Name)' is Running. This does not prove the OS, SSH or agent CLIs are ready."
    return 'COMPLETED'
}

function Stop-LabVMGracefully {
    param([guid]$VMId)
    $vm = Get-LabVM $VMId
    if ([string]$vm.State -eq 'Off') { Write-Host 'Already off.'; return 'NO_CHANGE' }
    if ([string]$vm.State -ne 'Running') { throw 'Graceful shutdown requires Running. Start/resume the VM first.' }
    Write-Warning 'Save your work in the guest before requesting shutdown.'
    if (-not (Confirm-LabText "SHUTDOWN $($vm.Name)")) { return 'CANCELLED' }
    $vm = Get-LabVM $VMId
    if ([string]$vm.State -ne 'Running') { throw 'VM state changed; no shutdown request was sent.' }
    # Explicit non-forced integration-service request, avoiding a Stop-VM fallback prompt.
    $system = @(Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName Msvm_ComputerSystem `
        -Filter ("Name='{0}'" -f $VMId) -OperationTimeoutSec 30 -ErrorAction Stop)
    if ($system.Count -ne 1) { throw 'Cannot resolve the selected VM through the Hyper-V CIM provider.' }
    $component = @(Get-CimAssociatedInstance -InputObject $system[0] `
        -ResultClassName Msvm_ShutdownComponent -OperationTimeoutSec 30 -ErrorAction Stop)
    if ($component.Count -ne 1) { throw 'Guest shutdown integration component unavailable. Shut down inside the guest.' }
    $result = Invoke-CimMethod -InputObject $component[0] -MethodName InitiateShutdown `
        -Arguments @{ Force = $false; Reason = 'LAB VM Manager: operator requested graceful shutdown' } `
        -OperationTimeoutSec 30 -ErrorAction Stop
    if ($null -eq $result.ReturnValue) { throw 'Shutdown request returned no status; inspect the guest.' }
    $code = [uint32]$result.ReturnValue
    if ($code -notin @(0, 4096, 32782)) {
        throw "Guest rejected shutdown (Hyper-V code $code). It may have unsaved work, be locked, or lack shutdown integration. No forced fallback. Use the guest console."
    }
    Write-Host 'Shutdown requested without forcing applications closed. Waiting for Off...'
    $null = Wait-LabVMState $VMId 'Off'
    Write-Host 'VM is Off.'
    return 'COMPLETED'
}

function Test-LabCheckpointName {
    param([AllowEmptyString()][string]$Name)
    return (-not [string]::IsNullOrWhiteSpace($Name) -and $Name.Length -le 100 -and
        $Name -eq $Name.Trim() -and $Name -notmatch '[\\/:*?"<>|\x00-\x1F]')
}

function New-LabCheckpointCore {
    param([guid]$VMId, [string]$Name)
    if (-not (Test-LabCheckpointName $Name)) {
        throw 'Use a checkpoint name of 1-100 characters without path/wildcard/control characters.'
    }
    $vm = Assert-LabVMOff $VMId
    if ([string]$vm.CheckpointType -ne 'Standard') {
        throw 'This lab tool requires Standard checkpoint policy for creation. Choose operation 10 explicitly first.'
    }
    if (@(Get-LabSnapshots $VMId | Where-Object { $_.Name -ieq $Name }).Count -gt 0) {
        throw "A checkpoint named '$Name' already exists. Choose another name; nothing is overwritten."
    }
    Write-LabAudit 'create-checkpoint' 'STARTED' $vm $Name
    $vm = Assert-LabVMOff $VMId
    Checkpoint-VM -VM $vm -SnapshotName $Name -Confirm:$false -ErrorAction Stop | Out-Null
    # Hyper-V's snapshot inventory can briefly lag right after Checkpoint-VM returns; retry before declaring it unconfirmed.
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $matches = @(Get-LabSnapshots $VMId | Where-Object { $_.Name -ieq $Name })
        if ($matches.Count -eq 1) { break }
        Start-Sleep -Milliseconds 500
    } while ($watch.Elapsed.TotalSeconds -lt 5)
    if ($matches.Count -ne 1) { throw 'Checkpoint creation could not be verified unambiguously. Inspect the VM; do not assume it failed without changes.' }
    Write-LabAudit 'create-checkpoint' 'COMPLETED' $vm ("{0} [{1}]" -f $Name, $matches[0].Id)
    return $matches[0]
}

function New-LabCheckpoint {
    param([guid]$VMId)
    $vm = Assert-LabVMOff $VMId
    Write-Host 'Examples: 00-os-clean, 10-toolchain-v1, 20-live-ready-private-v1'
    Write-Warning 'Off alone does not prove a clean shutdown. Finish guest updates/reboots and shut down normally first.'
    $name = Read-LabText 'New checkpoint name (blank cancels)'
    if ($name -eq '') { return 'CANCELLED' }
    if (-not (Confirm-LabText "CHECKPOINT $($vm.Name) $name")) { return 'CANCELLED' }
    $snapshot = New-LabCheckpointCore $VMId $name
    Write-Host "Created '$($snapshot.Name)' [$($snapshot.Id)]."
    return 'COMPLETED'
}

function Restore-LabCheckpoint {
    param([guid]$VMId)
    $vm = Assert-LabVMOff $VMId
    $snapshot = Select-LabCheckpoint $VMId
    if ($null -eq $snapshot) { return 'CANCELLED' }
    $snapshotId = [guid]$snapshot.Id
    Write-Warning "RESTORE '$($snapshot.Name)' [$snapshotId], created $($snapshot.CreationTime)."
    Write-Warning 'This replaces the current VM disk/configuration state. Preserve source changes and collect guest logs externally first.'
    Write-Host 'A checkpoint is not an independent backup. External files/services are not rolled back.'
    Write-Host 'A checkpoint captured while running may contain saved execution state. This tool will not automatically start/resume it.'
    $safety = Read-LabYesNoCancel 'Create a safety checkpoint of the current OFF state first?'
    if ($safety -eq 'C') { return 'CANCELLED' }
    if (-not (Confirm-LabText "RESTORE $($vm.Name) $($snapshotId.ToString().Substring(0, 8))")) {
        return 'CANCELLED'
    }
    if ($safety -eq 'Y') {
        $safetyName = 'safety-before-restore-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'),
            ([guid]::NewGuid().ToString('N').Substring(0, 8))
        # Any creation/verification error aborts before Restore-VMSnapshot is called.
        $saved = New-LabCheckpointCore $VMId $safetyName
        Write-Host "Safety checkpoint retained: '$($saved.Name)' [$($saved.Id)]."
    }
    $vm = Assert-LabVMOff $VMId
    $snapshot = Get-LabSnapshot $VMId $snapshotId
    Write-LabAudit 'restore-checkpoint' 'STARTED' $vm ("{0} [{1}]" -f $snapshot.Name, $snapshotId)
    Restore-VMSnapshot -VMSnapshot $snapshot -Confirm:$false -ErrorAction Stop | Out-Null
    $vm = Get-LabVM $VMId
    Write-Host "Hyper-V completed restore. Observed VM state: $($vm.State). No start/resume command was issued."
    Write-Host 'Check VM settings before starting: checkpoint restore can also restore configuration.'
    Write-LabAudit 'restore-checkpoint' 'COMPLETED' $vm ("Checkpoint {0}; state {1}" -f $snapshotId, $vm.State)
    return 'COMPLETED'
}

function Rename-LabCheckpoint {
    param([guid]$VMId)
    $vm = Assert-LabVMOff $VMId
    $snapshot = Select-LabCheckpoint $VMId
    if ($null -eq $snapshot) { return 'CANCELLED' }
    $name = Read-LabText 'New name (blank cancels)'
    if ($name -eq '') { return 'CANCELLED' }
    if (-not (Test-LabCheckpointName $name)) { throw 'Invalid name; use 1-100 characters without path/wildcard/control characters.' }
    if (@(Get-LabSnapshots $VMId | Where-Object { $_.Name -ieq $name -and $_.Id -ne $snapshot.Id }).Count -gt 0) {
        throw 'Another checkpoint already has that name.'
    }
    if (-not (Confirm-LabText "RENAME $($vm.Name) $($snapshot.Id.ToString().Substring(0, 8))")) { return 'CANCELLED' }
    $vm = Assert-LabVMOff $VMId
    $snapshot = Get-LabSnapshot $VMId ([guid]$snapshot.Id)
    Write-LabAudit 'rename-checkpoint' 'STARTED' $vm ("{0} -> {1}; ID {2}" -f $snapshot.Name, $name, $snapshot.Id)
    Rename-VMSnapshot -VMSnapshot $snapshot -NewName $name -Confirm:$false -ErrorAction Stop | Out-Null
    $updated = Get-LabSnapshot $VMId ([guid]$snapshot.Id)
    if ($updated.Name -cne $name) { throw 'Rename verification did not match the requested name.' }
    Write-Host "Renamed checkpoint to '$name'."
    return 'COMPLETED'
}

function Remove-LabCheckpoint {
    param([guid]$VMId)
    $vm = Assert-LabVMOff $VMId
    $snapshot = Select-LabCheckpoint $VMId
    if ($null -eq $snapshot) { return 'CANCELLED' }
    Write-Warning "Delete only '$($snapshot.Name)' [$($snapshot.Id)]? This removes a return point; it does NOT roll back the VM."
    Write-Host 'Hyper-V manages disk merging. Never manually delete AVHDX/VHDX files.'
    $word = 'DELETE'
    if ($snapshot.Name -match '^(00-|10-|20-)') {
        Write-Warning 'This checkpoint name looks like a baseline.'
        $word = 'DELETE BASELINE'
    }
    if (-not (Confirm-LabText "$word $($vm.Name) $($snapshot.Id.ToString().Substring(0, 8))")) { return 'CANCELLED' }
    $vm = Assert-LabVMOff $VMId
    $snapshot = Get-LabSnapshot $VMId ([guid]$snapshot.Id)
    $snapshotId = [guid]$snapshot.Id
    Write-LabAudit 'delete-checkpoint' 'STARTED' $vm ("{0} [{1}]" -f $snapshot.Name, $snapshotId)
    Remove-VMSnapshot -VMSnapshot $snapshot -Confirm:$false -ErrorAction Stop | Out-Null
    if (@(Get-LabSnapshots $VMId | Where-Object { [guid]$_.Id -eq $snapshotId }).Count -ne 0) {
        throw 'Checkpoint still appears in inventory. Inspect Hyper-V before retrying.'
    }
    Write-Host 'Checkpoint removed from inventory. No subtree-delete option was used.'
    Write-Host 'Hyper-V may still need to finish storage work; do not manipulate its disk files.'
    return 'COMPLETED'
}

function Export-LabVM {
    param([guid]$VMId)
    $vm = Assert-LabVMOff $VMId
    $root = $script:LabExportRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Read-LabText 'Existing local export folder, e.g. E:\HyperV-Exports (blank cancels)'
    }
    if ([string]::IsNullOrWhiteSpace($root)) { return 'CANCELLED' }
    # Deliberately local filesystem only: no UNC/mapped-share credential handling.
    if ($root -notmatch '^[A-Za-z]:\\') { throw 'Use an absolute local drive path, e.g. E:\HyperV-Exports.' }
    $directory = Get-Item -LiteralPath $root -ErrorAction Stop
    if (-not $directory.PSIsContainer -or $directory.PSProvider.Name -ne 'FileSystem') {
        throw 'Export root must be an existing filesystem directory.'
    }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($directory.FullName))
    if ($drive.DriveType -eq [IO.DriveType]::Network) { throw 'Mapped network exports are outside this tool; use a local disk.' }
    $folderName = '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $VMId,
        ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $destination = Join-Path $directory.FullName $folderName
    Write-Host "Destination: $destination"
    Write-Host ('Available on destination drive: {0:N1} GiB (not an export-size estimate).' -f ($drive.AvailableFreeSpace / 1GB))
    Write-Warning 'A full export includes VM disks and checkpoints, potentially containing credentials and private source. Protect the export folder.'
    Write-Host 'Use separate storage for an independent backup; the same disk is not disk-failure protection.'
    if (-not (Confirm-LabText "EXPORT $($vm.Name)")) { return 'CANCELLED' }
    $vm = Assert-LabVMOff $VMId
    if (Test-Path -LiteralPath $destination) { throw 'Export destination already exists; refusing to overwrite.' }
    [void][IO.Directory]::CreateDirectory($destination)
    $manifestPath = Join-Path $destination 'export-manifest.json'
    $manifest = [ordered]@{
        Status = 'IN_PROGRESS'; StartedUtc = [DateTime]::UtcNow.ToString('o'); FinishedUtc = $null
        ScriptVersion = $script:LabVersion; HostName = $env:COMPUTERNAME
        VMName = $vm.Name; VMId = [string]$VMId; VMState = [string]$vm.State
        Destination = $destination; Error = $null
        Checkpoints = @(Get-LabSnapshots $VMId | Select-Object Name, Id, CreationTime, SnapshotType)
    }
    try {
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop
        Write-LabAudit 'export-vm' 'STARTED' $vm $destination
        Export-VM -VM $vm -Path $destination -Confirm:$false -ErrorAction Stop | Out-Null
        $configs = @(Get-ChildItem -LiteralPath $destination -Filter '*.vmcx' -Recurse -File -ErrorAction Stop)
        if ($configs.Count -eq 0) { throw 'Hyper-V returned, but no VMCX configuration was found. Inspect the export.' }
        $manifest.Status = 'COMPLETE'
        $manifest.FinishedUtc = [DateTime]::UtcNow.ToString('o')
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop
        Write-Host "Export completed: $destination"
        Write-Host 'Completion is not a restore test. Import-test a copy before relying on it for recovery.'
    } catch {
        $manifest.Status = 'INCOMPLETE'
        $manifest.Error = $_.Exception.Message
        $manifest.FinishedUtc = [DateTime]::UtcNow.ToString('o')
        try { $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop }
        catch { Write-Warning 'Could not update the export manifest.' }
        Write-Warning "Export is incomplete/unverified; files were retained at: $destination"
        throw
    }
    return 'COMPLETED'
}

function Set-LabCheckpointPolicy {
    param([guid]$VMId)
    $vm = Assert-LabVMOff $VMId
    Write-Host "Current: $($vm.CheckpointType); automatic checkpoints: $($vm.AutomaticCheckpointsEnabled)"
    Write-Host 'Requested: Standard checkpoints; automatic checkpoints disabled. Existing checkpoints are retained.'
    if (-not (Confirm-LabText "CONFIGURE $($vm.Name)")) { return 'CANCELLED' }
    $vm = Assert-LabVMOff $VMId
    Set-VM -VM $vm -CheckpointType Standard -AutomaticCheckpointsEnabled $false -Confirm:$false -ErrorAction Stop
    $vm = Get-LabVM $VMId
    if ([string]$vm.CheckpointType -ne 'Standard' -or $vm.AutomaticCheckpointsEnabled) {
        throw 'Checkpoint policy verification failed.'
    }
    Write-Host 'Verified: Standard checkpoints; automatic checkpoints disabled.'
    return 'COMPLETED'
}

function Stop-LabVMPower {
    param([guid]$VMId)
    $vm = Get-LabVM $VMId
    if ([string]$vm.State -eq 'Off') { Write-Host 'Already off.'; return 'NO_CHANGE' }
    if ([string]$vm.State -notin @('Running', 'Paused')) {
        throw 'Emergency power-off is offered only for Running/Paused VMs. Inspect other states in Hyper-V Manager.'
    }
    Write-Warning 'EMERGENCY POWER-OFF: equivalent to disconnecting power. Unsaved data can be lost and guest files can be corrupted.'
    if (-not (Confirm-LabText "POWER OFF $($vm.Name) $($VMId.ToString().Substring(0, 8))")) { return 'CANCELLED' }
    $vm = Get-LabVM $VMId
    if ([string]$vm.State -notin @('Running', 'Paused')) { throw 'VM state changed; no power-off command was sent.' }
    Stop-VM -VM $vm -TurnOff -Confirm:$false -ErrorAction Stop | Out-Null
    $null = Wait-LabVMState $VMId 'Off'
    Write-Warning 'VM is Off after a hard power-off. Boot and repair/recover as needed before making a clean baseline.'
    return 'COMPLETED'
}

function Invoke-LabAction {
    param([guid]$VMId, [string]$Name, [scriptblock]$Action)
    if ($script:LabReadOnly) { Write-Warning 'Read-only mode: VM-changing operations are disabled.'; return }
    $mutex = [Threading.Mutex]::new($false, "Global\LabVmManager-$VMId")
    $held = $false
    $vm = $null
    try {
        try { $held = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Another copy of this script is operating on this VM. No operation was started here.' }
        # Re-resolve after acquiring the lock; names can change after menu selection.
        $vm = Get-LabVM $VMId
        Write-LabAudit $Name 'STARTED' $vm
        $status = & $Action $VMId
        if ($status -notin @('COMPLETED', 'CANCELLED', 'NO_CHANGE')) {
            throw 'Operation returned an unexpected status; inspect the VM before retrying.'
        }
        Write-LabAudit $Name $status (Get-LabVM $VMId)
        if ($status -eq 'CANCELLED') { Write-Host 'Cancelled.' }
    } catch [Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $message = $_.Exception.Message
        try { Write-LabAudit $Name 'FAILED_OR_UNCONFIRMED' $vm $message }
        catch { Write-Warning 'Audit logging also failed. Inspect VM state; do not assume nothing changed.' }
        Write-Warning "Operation failed or completion is unconfirmed: $message"
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Show-LabVMMenu {
    param([guid]$VMId)
    :vmMenu while ($true) {
        Clear-Host
        try { $vm = Get-LabVM $VMId }
        catch { Write-Warning $_.Exception.Message; return 'BACK' }
        Write-Host "`n=== $($vm.Name) | $($vm.Id) | $($vm.State) ==="
        Write-Host "Policy: $($vm.CheckpointType); automatic checkpoints: $($vm.AutomaticCheckpointsEnabled)"
        if ($script:LabReadOnly) {
            Write-Host @'
  1  Inspect VM: configuration, disks, network, integration services
  4  List checkpoints
  R  Refresh
  B  Choose another VM
  Q  Quit
READ-ONLY: VM-changing operations are disabled.
'@
        } else {
            Write-Host @'
  1  Inspect VM: configuration, disks, network, integration services
  2  Start / resume VM
  3  Request graceful shutdown (no forced fallback)
  4  List checkpoints
  5  Create checkpoint                         [requires Off]
  6  Restore checkpoint; offer safety copy     [requires Off]
  7  Rename checkpoint                         [requires Off]
  8  Delete ONE checkpoint                     [requires Off]
  9  Export full VM to a new folder            [requires Off]
 10  Configure lab checkpoint policy           [requires Off]
  X  EMERGENCY power-off                       [risk of data loss]
  R  Refresh
  B  Choose another VM
  Q  Quit
'@
        }
        $choice = (Read-LabText 'Operation').ToUpperInvariant()
        try {
            switch ($choice) {
                '1'  { Show-LabVMDetails $VMId }
                '2'  { Invoke-LabAction $VMId 'start-resume' { param($id) Start-LabVM $id } }
                '3'  { Invoke-LabAction $VMId 'graceful-shutdown' { param($id) Stop-LabVMGracefully $id } }
                '4'  { Show-LabCheckpoints $VMId }
                '5'  { Invoke-LabAction $VMId 'create-checkpoint-menu' { param($id) New-LabCheckpoint $id } }
                '6'  { Invoke-LabAction $VMId 'restore-checkpoint-menu' { param($id) Restore-LabCheckpoint $id } }
                '7'  { Invoke-LabAction $VMId 'rename-checkpoint-menu' { param($id) Rename-LabCheckpoint $id } }
                '8'  { Invoke-LabAction $VMId 'delete-checkpoint-menu' { param($id) Remove-LabCheckpoint $id } }
                '9'  { Invoke-LabAction $VMId 'export-vm-menu' { param($id) Export-LabVM $id } }
                '10' { Invoke-LabAction $VMId 'configure-policy' { param($id) Set-LabCheckpointPolicy $id } }
                'X'  { Invoke-LabAction $VMId 'emergency-power-off' { param($id) Stop-LabVMPower $id } }
                'R'  { continue vmMenu }
                'B'  { return 'BACK' }
                'Q'  { return 'QUIT' }
                default { Write-Host 'Choose a listed operation.'; continue vmMenu }
            }
        } catch [Management.Automation.PipelineStoppedException] { throw }
        catch { Write-Warning $_.Exception.Message }
        $null = Read-LabText 'Press Enter to continue'
    }
}

function Start-LabVMManager {
    param([string]$RequestedLogRoot)
    $ErrorActionPreference = 'Stop'
    Assert-LabHost
    Initialize-LabLog $RequestedLogRoot
    Write-LabAudit 'session' 'STARTED' $null ("ReadOnly={0}" -f $script:LabReadOnly)
    Write-Host "Host audit log: $script:LabLogFile"
    Write-Host 'This tool does not collect files from guests. Save code and copy guest results out before restoring.'
    Write-Host 'Do not concurrently modify the selected VM using Hyper-V Manager or another tool.'
    try {
        while ($true) {
            $vm = Select-LabVM
            if ($null -eq $vm) { break }
            $outcome = Show-LabVMMenu ([guid]$vm.Id)
            if ($outcome -eq 'QUIT') { break }
        }
    } finally {
        try { Write-LabAudit 'session' 'ENDED' }
        catch { Write-Warning 'Could not write the final audit entry.' }
        Write-Host "Audit log: $script:LabLogFile"
    }
}

# Dot-sourcing loads functions without launching the UI; normal invocation runs it.
if ($MyInvocation.InvocationName -ne '.') {
    try { Start-LabVMManager -RequestedLogRoot $LogRoot }
    catch {
        Write-Error -Message $_.Exception.Message -ErrorAction Continue
        exit 1
    }
}
