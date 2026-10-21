#requires -Version 5.1
<#
.SYNOPSIS
    Interactive, local Hyper-V manager restricted to VMs whose names begin with LAB-.
.DESCRIPTION
    Run on the Hyper-V host in elevated Windows PowerShell 5.1 (powershell.exe).
    Select a VM, then an operation. Uses VM/checkpoint IDs, not name wildcards.
    Checkpoint changes and exports require the VM to be Off. Restores offer an
    optional safety checkpoint and never issue an automatic start/resume.
    LAB-* VMs can be created, have settings edited, and be deleted (virtual
    disks are retained). File transfer to/from a Running VM is available
    both from the interactive menu and, via -CopyToVM/-CopyFromVM and their
    related parameters below, as a non-interactive parameter-mode CLI
    surface that runs one transfer and exits; see README.md ("Parameter
    mode: file transfer") for the full parameter list and examples. A new
    LAB- VM can also be created with Windows 11 installed unattended (menu W,
    or -ProvisionWindowsVM). Other guest provisioning, credential copying, and
    disk file deletion are not implemented. This is an operator tool, not a security boundary against
    another administrator or an untrusted guest.

    Copying files into a guest's .ssh directory is an ordinary file/directory
    transfer, governed by the same path/conflict/permission rules as any
    other transfer; it never edits authorized_keys as a side effect, and it
    is a separate concern from the key this manager itself uses to
    authenticate to the guest. See README.md ("SSH key roles") for the full
    explanation, and ("Future work: optional no-SSH bootstrap with
    Copy-VMFile") for a bounded, unimplemented design note.
.PARAMETER ReadOnly
    Allows inventory, details and checkpoint listing; blocks all VM changes.
    A host-side audit log is still written.
.PARAMETER LogRoot
    Host log folder. Default: %LOCALAPPDATA%\LabVmManager\Logs.
.PARAMETER ExportRoot
    Optional existing local export folder, e.g. E:\HyperV-Exports.
    Each export goes into a new, unique subfolder. Otherwise prompts at export.
.PARAMETER IsoRoot
    Local ISO library folder to scan for installer media, e.g. E:\ISO.
    Default: E:\ISO. Scanned recursively via Get-LabIsoCandidates, read-only,
    when menu option M (installation media) asks you to pick an ISO.
.PARAMETER TimeoutSeconds
    Maximum polling interval for VM start/shutdown state (default 180 seconds).
    Does not impose a timeout on Hyper-V checkpoint/export/merge operations.
.PARAMETER CopyToVM
    Parameter mode: copy a file/directory from this host to the VM, then exit.
    Mutually exclusive with -CopyFromVM; requires exactly one of -VMName/-VMId.
.PARAMETER CopyFromVM
    Parameter mode: copy a file/directory from the VM to this host, then exit.
    Mutually exclusive with -CopyToVM; requires exactly one of -VMName/-VMId.
.PARAMETER VMName
    Exact, case-insensitive VM name for parameter-mode transfer. Mutually
    exclusive with -VMId; exactly one of the two is required.
.PARAMETER VMId
    VM id for parameter-mode transfer. Mutually exclusive with -VMName.
.PARAMETER SourcePath
    Parameter-mode transfer source path, on the side -CopyToVM/-CopyFromVM implies.
.PARAMETER DestinationPath
    Parameter-mode transfer destination path, on the side -CopyToVM/-CopyFromVM implies.
.PARAMETER Recurse
    Copy a directory source's contents recursively (parameter mode).
.PARAMETER OnConflict
    Destination conflict policy for parameter mode: Error (default), Skip, or Overwrite.
.PARAMETER DryRun
    Parameter mode: report what would be copied without changing any files.
.PARAMETER NonInteractive
    Parameter mode: never prompt; -Credential must be supplied when it is needed.
.PARAMETER VerifyHash
    Parameter mode: verify a SHA-256 hash of each copied file after the copy.
.PARAMETER PermissionProfile
    Parameter mode: Default (no permission change) or PrivateFiles, which restricts each
    finalized item to the receiving account only (Windows ACLs, or chmod 600/700 on a
    Linux/SFTP guest; see README.md for the Linux directory-contents limitation).
.PARAMETER Credential
    Guest Windows credential for parameter-mode transfer. Only pass an existing
    PSCredential object built in the calling elevated Windows PowerShell 5.1
    session, invoking the script normally with the call operator (see the last
    example) -- never a plaintext password on the command line. Do not
    dot-source the script for this: dot-sourcing only loads its functions and
    runs no transfer at all. powershell.exe -File cannot receive a PSCredential
    object; without -Credential (and without -NonInteractive) it prompts instead.
    The transfer-only parameters above (-VMName through -Credential) are
    rejected with an error, rather than ignored, when neither -CopyToVM nor
    -CopyFromVM is supplied; the menu is not opened in that case.
.PARAMETER ConfigureSsh
    Parameter mode: save an SSH connection setting (host/port/user/identity file) for a VM,
    then exit, instead of launching the menu. Requires exactly one of -VMName/-VMId plus
    -SshHost and -SshUser; never prompts. Mutually exclusive with -CopyToVM/-CopyFromVM.
.PARAMETER SshHost
    Parameter mode: the SSH hostname or IP address to save, with -ConfigureSsh.
.PARAMETER SshPort
    Parameter mode: the SSH port to save, with -ConfigureSsh (default 22; 1-65535).
.PARAMETER SshUser
    Parameter mode: the SSH username to save, with -ConfigureSsh.
.PARAMETER SshIdentityFile
    Parameter mode: an optional identity-file path to save, with -ConfigureSsh. Omit it to
    save password authentication instead.
.PARAMETER ProvisionWindowsVM
    Parameter mode: create a new LAB- VM and install Windows 11 on it unattended (menu option W does
    the same with all defaults), then exit. Shows one combined preview and asks once before creating
    anything; with -NonInteractive it never prompts and requires -NewVMName, -WindowsIsoPath and
    -Credential. Mutually exclusive with -ConfigureSsh/-CopyToVM/-CopyFromVM. The parameters
    -NewVMName through -ProvisioningTimeoutSeconds are rejected, rather than ignored, without it.
.PARAMETER NewVMName
    Name of the VM to CREATE with -ProvisionWindowsVM (must start with LAB- and be unique). Distinct
    from -VMName, which always names an existing VM. Prompted for when omitted (unless -NonInteractive).
.PARAMETER WindowsIsoPath
    Windows 11 installer ISO for -ProvisionWindowsVM. When omitted, pick one from -IsoRoot interactively.
.PARAMETER ComputerName
    Guest computer name (1-15 letters, digits or hyphens). Default: 'lab-agent-test', independent of
    -NewVMName.
.PARAMETER Locale
    Guest input/system/UI/user locale, e.g. en-US (default en-US). Must be a language the ISO contains.
.PARAMETER TimeZone
    Guest Windows time zone ID, e.g. 'Pacific Standard Time' (see tzutil /l). Default: 'Central
    America Standard Time'.
.PARAMETER OsEdition
    Windows 11 edition on the ISO, by full image name ('Windows 11 Pro') or short name ('Pro').
    Default: a picker preselecting Pro; with -NonInteractive, Pro (or the ISO's only edition).
.PARAMETER ProductKey
    Windows product key, as five groups of five letters/digits separated by dashes (e.g.
    'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'). Default: '' (no product key, no activation). Optional; supply a
    real key, or Microsoft's own "generic" edition-matching key (e.g. 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
    for Home, 'VK7JG-NPHTM-C97JM-9MPGT-3V66T' for Pro; must match -OsEdition) to suppress a
    product-key prompt on some multi-edition ISOs without activating anything. An all-zero placeholder
    does NOT work: real Windows keys never contain the digit 0, so Setup's own key field refuses it
    outright -- confirmed live.
.PARAMETER VhdxSizeGB
    New dynamic VHDX maximum size in GB (default 150; 64-65536).
.PARAMETER VCpuCount
    New VM's vCPU count (default 2, capped to this host's logical processor count).
.PARAMETER MemoryMinimumGB
    Dynamic memory minimum in GB (default 2).
.PARAMETER MemoryStartupGB
    Dynamic memory startup in GB (default 4).
.PARAMETER MemoryMaximumGB
    Dynamic memory maximum in GB (default 8).
.PARAMETER SwitchName
    Virtual switch for the new VM's network adapter (default: 'Default Switch', Hyper-V's built-in
    NAT switch -- PowerShell Direct itself needs no network, but a real network is useful for the
    finished VM). Supply '' explicitly to leave the adapter Disconnected instead.
.PARAMETER VmStorageRoot
    Existing local folder that receives the new VM's own folder (default: the Hyper-V host default).
.PARAMETER VhdxStorageRoot
    Existing local folder that receives the new VHDX's own folder (default: the Hyper-V host default).
.PARAMETER ProvisioningTimeoutSeconds
    How long to wait for each PowerShell Direct sign-in proving Windows is installed/boots cleanly
    (default 1800; 300-7200). Separate from -TimeoutSeconds, which bounds short VM state changes.
.EXAMPLE
    powershell.exe -NoProfile -File .\Lab-VM.ps1 -ReadOnly
.EXAMPLE
    powershell.exe -NoProfile -File .\Lab-VM.ps1 -ExportRoot E:\HyperV-Exports
.EXAMPLE
    $cred = Get-Credential
    & .\Lab-VM.ps1 -CopyToVM -VMName LAB-dev -SourcePath C:\keys\id_ed25519 -DestinationPath C:\Users\dev\.ssh\id_ed25519 -PermissionProfile PrivateFiles -NonInteractive -Credential $cred
.EXAMPLE
    powershell.exe -NoProfile -File .\Lab-VM.ps1 -ConfigureSsh -VMName LAB-linux -SshHost 192.168.1.50 -SshUser dev -SshIdentityFile C:\keys\id_ed25519
.EXAMPLE
    $cred = Get-Credential
    & .\Lab-VM.ps1 -ProvisionWindowsVM -NewVMName LAB-win11 -WindowsIsoPath E:\ISO\Win11_24H2_English_x64.iso -OsEdition Pro -NonInteractive -Credential $cred
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
    [string]$IsoRoot = 'E:\ISO',
    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 180,
    [switch]$CopyToVM,
    [switch]$CopyFromVM,
    [string]$VMName,
    [Nullable[guid]]$VMId,
    [string]$SourcePath,
    [string]$DestinationPath,
    [switch]$Recurse,
    [ValidateSet('Error', 'Skip', 'Overwrite')]
    [string]$OnConflict = 'Error',
    [switch]$DryRun,
    [switch]$NonInteractive,
    [switch]$VerifyHash,
    [ValidateSet('Default', 'PrivateFiles')]
    [string]$PermissionProfile = 'Default',
    [PSCredential]$Credential,
    [switch]$ConfigureSsh,
    [string]$SshHost,
    [ValidateRange(1, 65535)]
    [int]$SshPort = 22,
    [string]$SshUser,
    [string]$SshIdentityFile,
    [switch]$ProvisionWindowsVM,
    [string]$NewVMName,
    [string]$WindowsIsoPath,
    [string]$ComputerName = 'lab-agent-test',
    [string]$Locale,
    [string]$TimeZone = 'Central America Standard Time',
    [string]$OsEdition,
    [string]$ProductKey = '',
    [ValidateRange(64, 65536)]
    [int]$VhdxSizeGB = 150,
    [ValidateRange(1, 1024)]
    [int]$VCpuCount = 2,
    [ValidateRange(1, 4096)]
    [int]$MemoryMinimumGB = 2,
    [ValidateRange(1, 4096)]
    [int]$MemoryStartupGB = 4,
    [ValidateRange(1, 4096)]
    [int]$MemoryMaximumGB = 8,
    [string]$SwitchName = '',
    [string]$VmStorageRoot = '',
    [string]$VhdxStorageRoot = '',
    [ValidateRange(300, 7200)]
    [int]$ProvisioningTimeoutSeconds = 1800
)

Set-StrictMode -Version Latest
$script:LabVersion = '1.0.0'
$script:LabReadOnly = [bool]$ReadOnly
$script:LabLogFile = $null
$script:LabExportRoot = $ExportRoot
$script:LabIsoRoot = $IsoRoot
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

function Resolve-LabVMByNameOrId {
    param([AllowEmptyString()][string]$VMName, [Nullable[guid]]$VMId)
    $hasName = -not [string]::IsNullOrEmpty($VMName)
    $hasId = $null -ne $VMId
    if ($hasName -eq $hasId) { throw 'Supply exactly one of -VMName or -VMId.' }
    if ($hasId) { return [guid]$VMId }
    # Exact, case-insensitive match only; no wildcard expansion of operator-supplied text.
    $matches = @(Get-VM -ErrorAction Stop | Where-Object { $_.Name -ieq $VMName })
    if ($matches.Count -eq 0) { throw "No matching VM named '$VMName'." }
    if ($matches.Count -gt 1) { throw "Ambiguous VM name '$VMName' matches $($matches.Count) VMs; use -VMId instead." }
    return [guid]$matches[0].Id
}

function Get-LabHostDefaults {
    $vmHost = Get-VMHost -ErrorAction Stop
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    return [pscustomobject]@{
        VirtualMachinePath = [string]$vmHost.VirtualMachinePath
        VirtualHardDiskPath = [string]$vmHost.VirtualHardDiskPath
        LogicalProcessorCount = [int]$computer.NumberOfLogicalProcessors
        TotalPhysicalMemoryBytes = [long]$computer.TotalPhysicalMemory
    }
}

function Get-LabSwitchNames {
    return @(Get-VMSwitch -ErrorAction Stop | ForEach-Object { [string]$_.Name })
}

function Get-LabSshToolingInfo {
    $sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
    $sftpCommand = Get-Command sftp.exe -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Available = [bool]($sshCommand -and $sftpCommand)
        SshPath = if ($sshCommand) { [string]$sshCommand.Source } else { $null }
        SftpPath = if ($sftpCommand) { [string]$sftpCommand.Source } else { $null }
        Version = if ($sshCommand) { $sshCommand.Version } else { $null }
    }
}

function Test-LabNewVMName {
    param([AllowNull()][AllowEmptyString()][string]$Name, [AllowNull()][AllowEmptyCollection()][string[]]$ExistingNames)
    if (-not (Test-LabVMName $Name)) { return $false }
    # The name becomes a folder/file name under the storage roots: same character and length rules
    # as Test-LabCheckpointName, so it cannot escape the root or act as a wildcard.
    if ($Name.Length -gt 100 -or $Name -ne $Name.Trim() -or $Name -match '[\\/:*?"<>|\x00-\x1F]') { return $false }
    foreach ($existing in $ExistingNames) {
        if ([string]::Equals($existing, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Test-LabVCpuCount {
    param([int]$Count, [int]$MaxLogicalProcessors)
    return ($Count -ge 1 -and $Count -le $MaxLogicalProcessors)
}

function Test-LabMemorySpec {
    param([long]$MinimumBytes, [long]$StartupBytes, [long]$MaximumBytes, [bool]$IsDynamic)
    $unit = 2MB
    if (-not $IsDynamic) {
        return ($StartupBytes -gt 0 -and ($StartupBytes % $unit) -eq 0)
    }
    return ($MinimumBytes -gt 0 -and $StartupBytes -gt 0 -and $MaximumBytes -gt 0 -and
        ($MinimumBytes % $unit) -eq 0 -and ($StartupBytes % $unit) -eq 0 -and ($MaximumBytes % $unit) -eq 0 -and
        $MinimumBytes -le $StartupBytes -and $StartupBytes -le $MaximumBytes)
}

function Get-LabTransferConflictKind {
    param([bool]$SourceIsDirectory, [bool]$DestinationExists, [bool]$DestinationIsDirectory)
    if (-not $DestinationExists) { return 'None' }
    if ($SourceIsDirectory -ne $DestinationIsDirectory) { return 'TypeMismatch' }
    return 'Exists'
}

function Resolve-LabConflictAction {
    param([string]$ConflictKind, [string]$OnConflict)
    switch ($ConflictKind) {
        'None'         { return 'Proceed' }
        'TypeMismatch' { return 'Error' }
        'Exists'       { return $OnConflict }
    }
}

function Assert-LabVMOff {
    param([guid]$VMId)
    $vm = Get-LabVM $VMId
    if ([string]$vm.State -ne 'Off') {
        throw "'$($vm.Name)' is $($vm.State). This operation requires Off, not Saved/Paused. Start or resume it if needed, then shut down normally."
    }
    return $vm
}

function Assert-LabVMRunning {
    param([guid]$VMId)
    $vm = Get-LabVM $VMId
    if ([string]$vm.State -ne 'Running') {
        throw "'$($vm.Name)' is $($vm.State). This operation requires Running. Start it first."
    }
    return $vm
}

function Get-LabSshConnectionSettingsPath {
    param([guid]$VMId)
    return Join-Path $env:LOCALAPPDATA "LabVmManager\SshConnections\$VMId.json"
}

# The host and user values reach ssh.exe/sftp.exe inside one positional "user@host" argument. A value
# starting with '-' could be read as a command-line option, and whitespace, control characters (or an
# '@' in the host) would change how that argument is split, so such values are refused, not escaped.
function Test-LabSshHostName {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    return (-not [string]::IsNullOrEmpty($Value) -and -not $Value.StartsWith('-') -and $Value -notmatch '[\s\x00-\x1F\x7F@]')
}

function Test-LabSshUserName {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    return (-not [string]::IsNullOrEmpty($Value) -and -not $Value.StartsWith('-') -and $Value -notmatch '[\s\x00-\x1F\x7F]')
}

function Get-LabSshConnectionSettings {
    param([guid]$VMId)
    $path = Get-LabSshConnectionSettingsPath $VMId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    # A settings file that exists but cannot be used fails loudly. Returning $null here would make the VM
    # look unconfigured, and adapter selection would then silently fall back to PowerShell Direct (and its
    # Windows credential prompt) for a VM the operator explicitly configured for SSH.
    $problem = $null
    $settings = $null
    try {
        $saved = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $saved) { $problem = 'the file is empty' }
        else {
            $settings = [pscustomobject]@{
                HostNameOrAddress = [string]$saved.HostNameOrAddress
                Port = [int]$saved.Port
                UserName = [string]$saved.UserName
                IdentityFilePath = [string]$saved.IdentityFilePath
            }
            if (-not (Test-LabSshHostName $settings.HostNameOrAddress)) { $problem = 'the saved host name or address is missing or invalid' }
            elseif (-not (Test-LabSshUserName $settings.UserName)) { $problem = 'the saved username is missing or invalid' }
            elseif ($settings.Port -lt 1 -or $settings.Port -gt 65535) { $problem = 'the saved port is not between 1 and 65535' }
        }
    } catch {
        $problem = $_.Exception.Message
    }
    if ($null -ne $problem) {
        throw "The saved SSH connection settings for VM $VMId cannot be used ($problem). File: $path. Save new settings (option C or -ConfigureSsh) to replace it, or delete the file to return this VM to PowerShell Direct."
    }
    return $settings
}

function Set-LabSshConnectionSettings {
    param(
        [guid]$VMId,
        [string]$HostNameOrAddress,
        [int]$Port,
        [string]$UserName,
        # A path reference to a private key file, not the key/secret contents themselves.
        [AllowNull()][AllowEmptyString()][string]$IdentityFilePath
    )
    if (-not (Test-LabSshHostName $HostNameOrAddress)) {
        throw "Invalid SSH host name or address '$HostNameOrAddress': it must not be empty, start with '-', or contain whitespace, control characters or '@'."
    }
    if (-not (Test-LabSshUserName $UserName)) {
        throw "Invalid SSH username '$UserName': it must not be empty, start with '-', or contain whitespace or control characters."
    }
    if ($Port -lt 1 -or $Port -gt 65535) { throw "Invalid SSH port ${Port}: it must be between 1 and 65535." }
    $path = Get-LabSshConnectionSettingsPath $VMId
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    $settings = [ordered]@{
        HostNameOrAddress = $HostNameOrAddress
        Port = $Port
        UserName = $UserName
        IdentityFilePath = $IdentityFilePath
    }
    ($settings | ConvertTo-Json) | Set-Content -LiteralPath $path
}

function Get-LabGuestAddressCandidates {
    param([guid]$VMId)
    $addresses = @(Get-VMNetworkAdapter -VM (Get-LabVM $VMId) -ErrorAction Stop |
        Select-Object -ExpandProperty IPAddresses)
    return @($addresses | Where-Object { $_ -notmatch '^169\.254\.' -and $_ -notmatch '^fe80:' })
}

function Resolve-LabWindowsCredential {
    param([AllowNull()][PSCredential]$Credential, [bool]$NonInteractive)
    if ($null -ne $Credential) { return $Credential }
    if ($NonInteractive) { throw 'Guest Windows credentials are required in non-interactive mode. Supply -Credential.' }
    $Credential = Get-Credential -Message 'Guest Windows credentials for PowerShell Direct'
    if ($null -eq $Credential) { throw 'Credential prompt was cancelled. Guest Windows credentials are required.' }
    return $Credential
}

function New-LabPSDirectSession {
    param([guid]$VMId, [PSCredential]$Credential)
    $null = Assert-LabVMRunning $VMId
    return New-PSSession -VMId $VMId -Credential $Credential -ErrorAction Stop
}

function Test-LabTransferConnection {
    param([guid]$VMId)
    $session = $null
    try {
        $credential = Resolve-LabWindowsCredential $null $false
        $session = New-LabPSDirectSession $VMId $credential
        $osVersion = Invoke-Command -Session $session { [Environment]::OSVersion.VersionString }
        Write-Host "Connection succeeded. Guest OS version: $osVersion"
    } catch {
        Write-Warning "Connection test failed: $($_.Exception.Message)"
    } finally {
        if ($session) { Remove-PSSession $session }
    }
}

function Resolve-LabSshAuthMode {
    param([AllowNull()][AllowEmptyString()][string]$IdentityFilePath, [bool]$NonInteractive)
    if (-not [string]::IsNullOrEmpty($IdentityFilePath)) { return 'KeyAgent' }
    if ($NonInteractive) {
        throw 'An SSH identity file is required in non-interactive mode (the SSH equivalent of -Credential). Supply an identity file.'
    }
    return 'InteractivePassword'
}

function Invoke-LabSftpCommand {
    param(
        [string]$HostNameOrAddress,
        [int]$Port,
        [string]$UserName,
        [AllowNull()][AllowEmptyString()][string]$IdentityFilePath,
        [string]$BatchFilePath,
        [string]$AuthMode
    )
    # Local override only (does not leak to the caller): callers such as Start-LabVMManager run
    # with $ErrorActionPreference = 'Stop', under which any captured native stderr line -- a plain
    # connection/auth failure, not a PowerShell error -- would otherwise be promoted to a
    # terminating exception instead of flowing into Output alongside ExitCode below.
    $ErrorActionPreference = 'Continue'
    $tooling = Get-LabSshToolingInfo
    if (-not $tooling.Available) {
        throw 'ssh.exe/sftp.exe (Windows OpenSSH Client) were not found. Install the OpenSSH Client optional feature on this host.'
    }
    $target = "$UserName@$HostNameOrAddress"
    switch ($AuthMode) {
        'KeyAgent' {
            $arguments = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-P', $Port)
            if (-not [string]::IsNullOrEmpty($IdentityFilePath)) { $arguments += @('-i', $IdentityFilePath) }
            $arguments += @('-b', $BatchFilePath, $target)
            $raw = & sftp.exe @arguments 2>&1
            $exitCode = $LASTEXITCODE
            $output = [string[]]@($raw | ForEach-Object { [string]$_ })
        }
        'InteractivePassword' {
            # sftp's own -b silently hands its ssh child '-oBatchMode yes' (upstream sftp.c does this, and the
            # bundled sftp.exe contains that string), which would switch password authentication off. sftp
            # passes -o options on in command-line order and ssh keeps the first value it sees for an option,
            # so BatchMode=no must come BEFORE -b. Order is load-bearing; test_static.py pins it.
            $arguments = @('-o', 'BatchMode=no', '-o', 'StrictHostKeyChecking=yes', '-P', $Port, '-b', $BatchFilePath, $target)
            # No stdin/stderr redirection here: OpenSSH's own password prompt must reach the operator's real
            # console unmodified, so a future reader should not "fix" this branch to match the batch-mode one
            # above. Out-Host only keeps sftp's stdout (its batch echo, e.g. "sftp> pwd") out of this
            # function's return value -- inside a function, PowerShell would otherwise capture that stdout into
            # the returned array, and callers reading .ExitCode would fail under StrictMode.
            & sftp.exe @arguments | Out-Host
            $exitCode = $LASTEXITCODE
            $output = [string[]]@()
        }
        default { throw "Unknown SSH auth mode '$AuthMode'." }
    }
    return [pscustomobject]@{ ExitCode = [int]$exitCode; Output = $output }
}

function Invoke-LabSshCommand {
    param(
        [string]$HostNameOrAddress,
        [int]$Port,
        [string]$UserName,
        [AllowNull()][AllowEmptyString()][string]$IdentityFilePath,
        [string]$AuthMode,
        [string]$RemoteCommand
    )
    # The ssh.exe counterpart of Invoke-LabSftpCommand, for the few guest-side checks sftp's batch
    # vocabulary cannot express (SHA-256, and the password-mode existence/size checks). Same flag rules,
    # driven by the same AuthMode: StrictHostKeyChecking=yes always, BatchMode=yes only for KeyAgent.
    # Each call is its own connection (no connection sharing, see README), so in InteractivePassword mode
    # every call asks for the password again.
    $ErrorActionPreference = 'Continue'
    $tooling = Get-LabSshToolingInfo
    if (-not $tooling.Available) {
        throw 'ssh.exe/sftp.exe (Windows OpenSSH Client) were not found. Install the OpenSSH Client optional feature on this host.'
    }
    # Windows PowerShell 5.1 does not escape an embedded double quote when it builds a native command
    # line, so a remote command containing one would reach the guest's shell altered.
    if ($RemoteCommand.Contains('"')) { throw 'Remote SSH commands built by this script must not contain a double quote.' }
    $target = "$UserName@$HostNameOrAddress"
    switch ($AuthMode) {
        'KeyAgent' {
            # -n: redirect ssh's stdin from /dev/null so a BatchMode=yes call never reads from (or hangs
            # on) this process's own stdin, which belongs to whatever unrelated stream launched it.
            $arguments = @('-n', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-p', $Port)
            if (-not [string]::IsNullOrEmpty($IdentityFilePath)) { $arguments += @('-i', $IdentityFilePath) }
            $arguments += @($target, $RemoteCommand)
            $raw = & ssh.exe @arguments 2>&1
            $exitCode = $LASTEXITCODE
            $output = [string[]]@($raw | ForEach-Object { [string]$_ })
        }
        'InteractivePassword' {
            $arguments = @('-o', 'StrictHostKeyChecking=yes', '-p', $Port, $target, $RemoteCommand)
            # No -o BatchMode=yes and no stderr redirection: OpenSSH's own password prompt must reach the
            # operator's console unmodified. (StrictHostKeyChecking=yes never prompts about host keys; first
            # trust is the separate Add-LabSshKnownHost action.) Out-Host only keeps any remote stdout
            # (the commands used here print none) out of this function's return value -- inside a
            # function, PowerShell would otherwise capture that stdout into the returned array.
            & ssh.exe @arguments | Out-Host
            $exitCode = $LASTEXITCODE
            $output = [string[]]@()
        }
        default { throw "Unknown SSH auth mode '$AuthMode'." }
    }
    return [pscustomobject]@{ ExitCode = [int]$exitCode; Output = $output }
}

function Test-LabSshConnection {
    param([guid]$VMId)
    $settings = Get-LabSshConnectionSettings $VMId
    if ($null -eq $settings) {
        Write-Host 'SSH connection is not configured for this VM. Use Configure SSH connection first.'
        return
    }
    $batchPath = $null
    try {
        $null = Assert-LabVMRunning $VMId
        $batchPath = Join-Path ([IO.Path]::GetTempPath()) ('labssh-' + [guid]::NewGuid().ToString('N') + '.batch')
        [IO.File]::WriteAllText($batchPath, "pwd`n")
        $authMode = Resolve-LabSshAuthMode $settings.IdentityFilePath $false
        $result = Invoke-LabSftpCommand $settings.HostNameOrAddress $settings.Port $settings.UserName `
            $settings.IdentityFilePath $batchPath $authMode
        if ($result.ExitCode -eq 0) {
            Write-Host "Connection succeeded ($authMode)."
        } else {
            # KeyAgent mode captures sftp's own messages ("Host key verification failed.", "Permission denied
            # (publickey).", "Connection refused"); show their tail instead of a bare exit code. In password mode
            # OpenSSH already printed its reason straight to the console.
            $reason = @($result.Output | Where-Object { $_ -and $_ -notmatch '^sftp>' } | Select-Object -Last 3) -join ' '
            if ($reason) { Write-Warning "Connection test failed (sftp exit code $($result.ExitCode)): $reason" }
            else { Write-Warning "Connection test failed (sftp exit code $($result.ExitCode)); OpenSSH's own message, if any, is shown above." }
            if ($result.ExitCode -eq 255) {
                Write-Warning 'Exit 255 is a connection-level failure: guest unreachable, authentication refused, or an unknown or changed host key. For a guest never connected to before, trust its key with option K; after its key changed, clear the old entry with option U.'
            }
        }
    } catch {
        Write-Warning "Connection test failed: $($_.Exception.Message)"
    } finally {
        if ($batchPath -and [IO.File]::Exists($batchPath)) { [IO.File]::Delete($batchPath) }
    }
}

function Update-LabSshKnownHost {
    param([string]$HostNameOrAddress, [int]$Port)
    # ssh-keygen's own bracket notation marks a non-default port; port 22 stays unbracketed.
    $target = if ($Port -eq 22) { $HostNameOrAddress } else { "[$HostNameOrAddress]:$Port" }
    Write-Host "This clears the known_hosts entry for $target so a changed host key can be re-trusted."
    if (-not (Confirm-LabText "UPDATE KNOWN HOST $HostNameOrAddress")) { return }
    & ssh-keygen.exe -R $target
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Known-hosts entry for $target removed."
    } else {
        Write-Warning "ssh-keygen -R exited with code $LASTEXITCODE; known_hosts may be unchanged."
    }
}

function Add-LabSshKnownHost {
    param([guid]$VMId)
    # Explicit first-connection trust for a guest whose host key is not in known_hosts yet. Every other
    # connection this script makes (each transfer, the connection test, every probe) keeps
    # StrictHostKeyChecking=yes and refuses an unknown or changed key outright; this is the only call that
    # uses StrictHostKeyChecking=ask, and only after the operator's typed confirmation below. The trust
    # decision itself is the operator's own "yes" to OpenSSH's native fingerprint prompt: OpenSSH writes
    # known_hosts, never this script, and this script never reads, echoes or answers that prompt.
    # Interactive by design, so it is checked by source review (test_static.py), never run by a test.
    $ErrorActionPreference = 'Continue'
    $settings = Get-LabSshConnectionSettings $VMId
    if ($null -eq $settings) {
        Write-Host 'SSH connection is not configured for this VM. Use Configure SSH connection first.'
        return
    }
    $null = Assert-LabVMRunning $VMId
    $tooling = Get-LabSshToolingInfo
    if (-not $tooling.Available) {
        throw 'ssh.exe/sftp.exe (Windows OpenSSH Client) were not found. Install the OpenSSH Client optional feature on this host.'
    }
    $target = "$($settings.UserName)@$($settings.HostNameOrAddress)"
    Write-Host "This connects once to $target (port $($settings.Port)) and lets OpenSSH itself ask whether to trust the guest's host key."
    Write-Host 'Before you answer OpenSSH, compare the fingerprint it prints with the one the guest reports on its own console:'
    Write-Host '    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'
    Write-Host "Answer 'yes' to OpenSSH only if the two match; OpenSSH then adds the key to your known_hosts file."
    Write-Host 'A host whose saved key has CHANGED is still refused here: clear the old entry with option U first.'
    if (-not (Confirm-LabText "TRUST HOST KEY $($settings.HostNameOrAddress)")) {
        Write-Host 'Cancelled. No connection was made and known_hosts was not changed.'
        return
    }
    $arguments = @('-o', 'StrictHostKeyChecking=ask', '-o', 'BatchMode=no', '-p', $settings.Port)
    if (-not [string]::IsNullOrEmpty($settings.IdentityFilePath)) { $arguments += @('-i', $settings.IdentityFilePath) }
    # 'exit' is the remote command: a harmless no-op once the login succeeds.
    $arguments += @($target, 'exit')
    # Console passthrough: stdin and stderr are not redirected, so OpenSSH's fingerprint prompt, the
    # operator's answer and any password prompt pass directly between OpenSSH and the console. Out-Host only
    # keeps remote stdout (none is expected from 'exit') off this function's return value, the same pattern
    # as Invoke-LabSshCommand's password branch.
    & ssh.exe @arguments | Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        Write-Host "Connected to $target; its host key is now trusted. Use T to run the SFTP connection test."
    } else {
        Write-Warning "ssh exited with code $exitCode. If you answered 'yes' to OpenSSH, the key may already be saved even though the login itself failed; run T to check. If you answered 'no', known_hosts is unchanged."
    }
}

function Configure-LabSshConnectionInteractive {
    param([guid]$VMId)
    $vm = Get-LabVM $VMId
    # An unreadable saved file is reported, not fatal here: saving new settings below is one way to fix it.
    $existing = $null
    try { $existing = Get-LabSshConnectionSettings $VMId }
    catch { Write-Warning "$($_.Exception.Message) Saving below replaces that file." }
    if ($null -ne $existing) {
        $existingAuth = $(if ([string]::IsNullOrEmpty($existing.IdentityFilePath)) { 'password' } else { "identity file: $($existing.IdentityFilePath)" })
        Write-Host "Current saved settings: $($existing.UserName)@$($existing.HostNameOrAddress):$($existing.Port) ($existingAuth)"
    } else {
        Write-Host 'No SSH connection is saved for this VM yet.'
    }

    # Suggestions only: never auto-selected. The operator must type or explicitly pick one.
    $candidates = @(Get-LabGuestAddressCandidates $VMId)
    if ($candidates.Count -gt 0) {
        Write-Host 'Guest address candidates (type one of these, or any other address):'
        for ($i = 0; $i -lt $candidates.Count; $i++) { Write-Host ("  {0}  {1}" -f ($i + 1), $candidates[$i]) }
    } else {
        Write-Host 'No guest address candidates were found for this VM.'
    }

    $hostNameOrAddress = ''
    while ($hostNameOrAddress -eq '') {
        $hostAnswer = Read-LabText 'Hostname or IP address for SSH (blank re-prompts; a listed number also works)'
        $candidateIndex = ConvertTo-LabMenuIndex $hostAnswer $candidates.Count
        if ($candidateIndex -ge 0) { $hostNameOrAddress = $candidates[$candidateIndex] }
        elseif ($hostAnswer -eq '') { Write-Host 'Enter a hostname or address.' }
        elseif (-not (Test-LabSshHostName $hostAnswer)) {
            Write-Host "A hostname or address must not start with '-' or contain spaces, control characters or '@'."
        }
        else { $hostNameOrAddress = $hostAnswer }
    }

    $port = 22
    $portAnswer = Read-LabText 'SSH port [22]'
    if ($portAnswer -ne '') {
        $parsedPort = 0
        while (-not ([int]::TryParse($portAnswer, [ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535)) {
            Write-Host 'Enter a valid port number (1-65535), or blank for 22.'
            $portAnswer = Read-LabText 'SSH port [22]'
            if ($portAnswer -eq '') { break }
        }
        if ($portAnswer -ne '') { $port = $parsedPort }
    }

    $userName = ''
    while ($userName -eq '') {
        $userAnswer = Read-LabText 'SSH username (blank re-prompts)'
        if ($userAnswer -eq '') { Write-Host 'Enter a username.' }
        elseif (-not (Test-LabSshUserName $userAnswer)) {
            Write-Host "A username must not start with '-' or contain spaces or control characters."
        }
        else { $userName = $userAnswer }
    }

    $identityFilePath = Read-LabText 'Identity-file path (blank = password authentication)'

    Write-Host "`n=== SSH connection preview ==="
    [pscustomobject]@{
        VMName = $vm.Name
        VMId = $vm.Id
        HostNameOrAddress = $hostNameOrAddress
        Port = $port
        UserName = $userName
        AuthMode = $(if ($identityFilePath -eq '') { 'Password (prompted at connection time)' } else { "Key file: $identityFilePath" })
    } | Format-List | Out-Host

    $confirmAnswer = Read-LabYesNoCancel 'Save these SSH connection settings for this VM?'
    if ($confirmAnswer -ne 'Y') { Write-Host 'Cancelled. No settings were changed.'; return }

    Set-LabSshConnectionSettings -VMId $VMId -HostNameOrAddress $hostNameOrAddress -Port $port -UserName $userName -IdentityFilePath $identityFilePath
    Write-Host 'SSH connection settings saved.'
}

function Wait-LabVMState {
    # -TimeoutSeconds overrides the general -TimeoutSeconds ($script:LabTimeout) for one wait only;
    # omitted (0), the general value applies, as it always has for every other caller.
    param([guid]$VMId, [string]$State, [int]$TimeoutSeconds = 0)
    $limit = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } else { $script:LabTimeout }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $limit) {
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
            if (-not $script:LabReadOnly) {
                Write-Host 'No local VMs whose names begin with LAB- were found. Choose N to create one, or W to provision a Windows 11 VM unattended.'
            } else {
                Write-Host 'No local VMs whose names begin with LAB- were found. Read-only mode: VM creation is disabled.'
            }
        } else {
            $rows = for ($i = 0; $i -lt $items.Count; $i++) {
                $vm = $items[$i]
                [pscustomobject]@{ No = $i + 1; Name = $vm.Name; State = $vm.State;
                    CPUs = $vm.ProcessorCount; RAM_GiB = [math]::Round($vm.MemoryAssigned / 1GB, 1);
                    Id = $vm.Id }
            }
            $rows | Format-Table -AutoSize -Wrap | Out-Host
        }
        if (-not $script:LabReadOnly) {
            $answer = Read-LabText 'VM number; N create VM; W provision Windows 11 VM (unattended); R refresh; Q quit'
        } else {
            $answer = Read-LabText 'VM number; R refresh; Q quit'
        }
        if ($answer -ieq 'Q') { return $null }
        if ($answer -ieq 'R') { continue }
        # New-LabVM returns a status string; discard it so it cannot leak into Select-LabVM's output.
        if ($answer -ieq 'N' -and -not $script:LabReadOnly) { $null = New-LabVM; continue }
        if ($answer -ieq 'W' -and -not $script:LabReadOnly) {
            # Same status-string discard as N. Unlike New-LabVM this throws on failure (its CLI wrapper
            # needs that for the exit code), so the error -- which names the steps already applied and
            # the kept workspace -- is shown here and held on screen before the list is redrawn.
            try { $null = Start-LabWindowsVMProvisioning @{} }
            catch [Management.Automation.PipelineStoppedException] { throw }
            catch { Write-Warning $_.Exception.Message }
            $null = Read-LabText 'Press Enter to continue'
            continue
        }
        $index = ConvertTo-LabMenuIndex $answer $items.Count
        if ($index -ge 0) { return Get-LabVM ([guid]$items[$index].Id) }
        if (-not $script:LabReadOnly) { Write-Host 'Choose a listed number, N, W, R or Q.' }
        else { Write-Host 'Choose a listed number, R or Q.' }
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
    Request-LabVMGuestShutdown $VMId
    Write-Host 'Shutdown requested without forcing applications closed. Waiting for Off...'
    $null = Wait-LabVMState $VMId 'Off'
    Write-Host 'VM is Off.'
    return 'COMPLETED'
}

function Request-LabVMGuestShutdown {
    param([guid]$VMId, [string]$Reason = 'LAB VM Manager: operator requested graceful shutdown')
    # Sends the request only; no confirmation and no wait (callers decide both). Shared by
    # Stop-LabVMGracefully and the Windows provisioning orchestrator's post-install shutdown.
    # Explicit non-forced integration-service request, avoiding a Stop-VM fallback prompt.
    $system = @(Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName Msvm_ComputerSystem `
        -Filter ("Name='{0}'" -f $VMId) -OperationTimeoutSec 30 -ErrorAction Stop)
    if ($system.Count -ne 1) { throw 'Cannot resolve the selected VM through the Hyper-V CIM provider.' }
    $component = @(Get-CimAssociatedInstance -InputObject $system[0] `
        -ResultClassName Msvm_ShutdownComponent -OperationTimeoutSec 30 -ErrorAction Stop)
    if ($component.Count -ne 1) { throw 'Guest shutdown integration component unavailable. Shut down inside the guest.' }
    $result = Invoke-CimMethod -InputObject $component[0] -MethodName InitiateShutdown `
        -Arguments @{ Force = $false; Reason = $Reason } `
        -OperationTimeoutSec 30 -ErrorAction Stop
    if ($null -eq $result.ReturnValue) { throw 'Shutdown request returned no status; inspect the guest.' }
    $code = [uint32]$result.ReturnValue
    if ($code -notin @(0, 4096, 32782)) {
        throw "Guest rejected shutdown (Hyper-V code $code). It may have unsaved work, be locked, or lack shutdown integration. No forced fallback. Use the guest console."
    }
}

function New-LabVMCore {
    param(
        [string]$Name,
        [string]$VmStoragePath,
        [int]$VCpuCount,
        [long]$MinimumBytes,
        [long]$StartupBytes,
        [long]$MaximumBytes,
        [bool]$IsDynamic,
        [string]$VhdxPath,
        [long]$VhdxMaximumBytes,
        [AllowNull()][AllowEmptyString()][string]$SwitchName
    )
    if (@(Get-VM -ErrorAction Stop | Where-Object { $_.Name -ieq $Name }).Count -gt 0) {
        throw "A VM named '$Name' already exists."
    }
    if (Test-Path -LiteralPath $VmStoragePath) {
        throw "VM storage path already exists: $VmStoragePath"
    }
    $vhdxDirectory = Split-Path -Path $VhdxPath -Parent
    if (Test-Path -LiteralPath $vhdxDirectory) {
        throw "VHDX directory already exists: $vhdxDirectory"
    }
    if (-not [string]::IsNullOrEmpty($SwitchName) -and (Get-LabSwitchNames) -notcontains $SwitchName) {
        throw "Virtual switch '$SwitchName' is no longer available. Choose another switch."
    }
    if ([string]::IsNullOrEmpty($SwitchName)) {
        $vm = New-VM -Name $Name -Generation 2 -Path $VmStoragePath -NoVHD `
            -MemoryStartupBytes $StartupBytes -Confirm:$false -ErrorAction Stop
    } else {
        $vm = New-VM -Name $Name -Generation 2 -Path $VmStoragePath -NoVHD `
            -MemoryStartupBytes $StartupBytes -SwitchName $SwitchName -Confirm:$false -ErrorAction Stop
    }
    # New-VHD does not create missing parent folders; create the dedicated (verified-absent) VHDX folder.
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $VhdxPath))
    New-VHD -Path $VhdxPath -Dynamic -SizeBytes $VhdxMaximumBytes -Confirm:$false -ErrorAction Stop | Out-Null
    Add-VMHardDiskDrive -VM $vm -Path $VhdxPath -Confirm:$false -ErrorAction Stop
    Set-VMProcessor -VM $vm -Count $VCpuCount -Confirm:$false -ErrorAction Stop
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $IsDynamic -MinimumBytes $MinimumBytes `
        -StartupBytes $StartupBytes -MaximumBytes $MaximumBytes -Confirm:$false -ErrorAction Stop
    # Same policy as Set-LabCheckpointPolicy; applied directly here since there is no prior VM to re-fetch under Assert-LabVMOff.
    Set-VM -VM $vm -CheckpointType Standard -AutomaticCheckpointsEnabled $false -Confirm:$false -ErrorAction Stop
    return (Get-LabVM $vm.Id)
}

function New-LabVM {
    if ($script:LabReadOnly) { Write-Warning 'Read-only mode: VM creation is disabled.'; return 'CANCELLED' }
    $defaults = Get-LabHostDefaults
    $existingNames = @((Get-VM -ErrorAction Stop).Name)
    while ($true) {
        $name = Read-LabText 'New VM name, must start with LAB- and be unique (blank cancels)'
        if ($name -eq '') { return 'CANCELLED' }
        if (Test-LabNewVMName $name $existingNames) { break }
        Write-Host 'Name must start with LAB- (case-insensitive), be unique, be at most 100 characters, and contain no path, wildcard or control characters.'
    }

    while ($true) {
        $storageInput = Read-LabText "VM storage root [$($defaults.VirtualMachinePath)] (blank = default; C cancels)"
        if ($storageInput -ieq 'C') { return 'CANCELLED' }
        $storageRoot = $(if ($storageInput -eq '') { $defaults.VirtualMachinePath } else { $storageInput })
        Write-Host 'An ISO/installer media folder such as E:\ISO is not valid VM storage.'
        # Same local-only rule as Export-LabVM: absolute local drive path, no UNC/mapped network drive.
        if ($storageRoot -notmatch '^[A-Za-z]:\\') { Write-Host 'Use an absolute local drive path, e.g. D:\Hyper-V, or C to cancel.'; continue }
        if (-not (Test-Path -LiteralPath $storageRoot -PathType Container)) { Write-Host 'Enter an existing directory, or C to cancel.'; continue }
        if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($storageRoot)).DriveType -eq [IO.DriveType]::Network) {
            Write-Host 'Mapped network drives are outside this tool; use a local disk, or C to cancel.'; continue
        }
        break
    }
    $vmStoragePath = Join-Path $storageRoot $name

    while ($true) {
        $vCpuText = Read-LabText "vCPU count, 1-$($defaults.LogicalProcessorCount) (blank cancels)"
        if ($vCpuText -eq '') { return 'CANCELLED' }
        $vCpuCount = 0
        if ([int]::TryParse($vCpuText, [ref]$vCpuCount) -and (Test-LabVCpuCount $vCpuCount $defaults.LogicalProcessorCount)) { break }
        Write-Host "Enter a whole number from 1 to $($defaults.LogicalProcessorCount)."
    }

    $dynamicAnswer = Read-LabYesNoCancel 'Use dynamic memory?'
    if ($dynamicAnswer -eq 'C') { return 'CANCELLED' }
    $isDynamic = ($dynamicAnswer -eq 'Y')
    if ($isDynamic) {
        while ($true) {
            $minText = Read-LabText 'Minimum memory bytes, e.g. 536870912 for 512MB (blank cancels)'
            if ($minText -eq '') { return 'CANCELLED' }
            $startupText = Read-LabText 'Startup memory bytes, e.g. 1073741824 for 1GB (blank cancels)'
            if ($startupText -eq '') { return 'CANCELLED' }
            $maxText = Read-LabText 'Maximum memory bytes, e.g. 4294967296 for 4GB (blank cancels)'
            if ($maxText -eq '') { return 'CANCELLED' }
            $minimumBytes = 0L; $startupBytes = 0L; $maximumBytes = 0L
            if ([long]::TryParse($minText, [ref]$minimumBytes) -and [long]::TryParse($startupText, [ref]$startupBytes) -and
                [long]::TryParse($maxText, [ref]$maximumBytes) -and
                (Test-LabMemorySpec $minimumBytes $startupBytes $maximumBytes $true)) { break }
            Write-Host 'Enter whole-byte values, multiples of 2MB, with minimum <= startup <= maximum.'
        }
    } else {
        while ($true) {
            $startupText = Read-LabText 'Startup (static) memory bytes, e.g. 2147483648 for 2GB (blank cancels)'
            if ($startupText -eq '') { return 'CANCELLED' }
            $startupBytes = 0L
            if ([long]::TryParse($startupText, [ref]$startupBytes) -and (Test-LabMemorySpec 0 $startupBytes 0 $false)) { break }
            Write-Host 'Enter a whole-byte value that is a multiple of 2MB.'
        }
        $minimumBytes = $startupBytes
        $maximumBytes = $startupBytes
    }

    while ($true) {
        $vhdxRootInput = Read-LabText "VHDX storage root [$($defaults.VirtualHardDiskPath)] (blank = default; C cancels)"
        if ($vhdxRootInput -ieq 'C') { return 'CANCELLED' }
        $vhdxRoot = $(if ($vhdxRootInput -eq '') { $defaults.VirtualHardDiskPath } else { $vhdxRootInput })
        # Same local-only rule as Export-LabVM: absolute local drive path, no UNC/mapped network drive.
        if ($vhdxRoot -notmatch '^[A-Za-z]:\\') { Write-Host 'Use an absolute local drive path, e.g. D:\Hyper-V, or C to cancel.'; continue }
        if (-not (Test-Path -LiteralPath $vhdxRoot -PathType Container)) { Write-Host 'Enter an existing directory, or C to cancel.'; continue }
        if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($vhdxRoot)).DriveType -eq [IO.DriveType]::Network) {
            Write-Host 'Mapped network drives are outside this tool; use a local disk, or C to cancel.'; continue
        }
        break
    }
    $vhdxPath = Join-Path (Join-Path $vhdxRoot $name) "$name.vhdx"

    while ($true) {
        $vhdxSizeText = Read-LabText 'VHDX maximum capacity in bytes, e.g. 68719476736 for 64GB (blank cancels)'
        if ($vhdxSizeText -eq '') { return 'CANCELLED' }
        $vhdxMaximumBytes = 0L
        if ([long]::TryParse($vhdxSizeText, [ref]$vhdxMaximumBytes) -and $vhdxMaximumBytes -gt 0) { break }
        Write-Host 'Enter a whole-byte value greater than zero.'
    }

    $switchNames = @(Get-LabSwitchNames)
    $switchName = $null
    if ($switchNames.Count -eq 0) {
        Write-Host 'No virtual switches found; the network adapter will be Disconnected.'
    } else {
        $rows = for ($i = 0; $i -lt $switchNames.Count; $i++) {
            [pscustomobject]@{ No = $i + 1; Switch = $switchNames[$i] }
        }
        $rows += [pscustomobject]@{ No = $switchNames.Count + 1; Switch = 'Disconnected' }
        $rows | Format-Table -AutoSize | Out-Host
        while ($true) {
            $switchAnswer = Read-LabText 'Switch number (blank cancels)'
            if ($switchAnswer -eq '') { return 'CANCELLED' }
            $switchIndex = ConvertTo-LabMenuIndex $switchAnswer $rows.Count
            if ($switchIndex -ge 0) {
                $switchName = $(if ($switchIndex -eq $switchNames.Count) { $null } else { $switchNames[$switchIndex] })
                break
            }
            Write-Host 'Choose a listed number.'
        }
    }

    Write-Host "`n=== Create VM preview ==="
    [pscustomobject]@{
        Name = $name
        VMStoragePath = $vmStoragePath
        VhdxPath = $vhdxPath
        VhdxMaximumBytesGiB = [math]::Round($vhdxMaximumBytes / 1GB, 1)
        VCpuCount = $vCpuCount
        DynamicMemory = $isDynamic
        MinimumMemoryMiB = [math]::Round($minimumBytes / 1MB, 0)
        StartupMemoryMiB = [math]::Round($startupBytes / 1MB, 0)
        MaximumMemoryMiB = [math]::Round($maximumBytes / 1MB, 0)
        Switch = $(if ([string]::IsNullOrEmpty($switchName)) { 'Disconnected' } else { $switchName })
        Generation = 2
        CheckpointPolicy = 'Standard; automatic checkpoints disabled'
    } | Format-List | Out-Host
    if (-not (Confirm-LabText "CREATE $name")) { return 'CANCELLED' }

    $mutex = [Threading.Mutex]::new($false, "Global\LabVmManager-Create-$($name.ToUpperInvariant())")
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Another copy of this script is already creating a VM with this name. No operation was started here.' }
        Write-LabAudit 'create-vm' 'STARTED' $null $name
        $vm = New-LabVMCore -Name $name -VmStoragePath $vmStoragePath -VCpuCount $vCpuCount `
            -MinimumBytes $minimumBytes -StartupBytes $startupBytes -MaximumBytes $maximumBytes `
            -IsDynamic $isDynamic -VhdxPath $vhdxPath -VhdxMaximumBytes $vhdxMaximumBytes -SwitchName $switchName
        Write-LabAudit 'create-vm' 'COMPLETED' $vm
        Write-Host "Created '$($vm.Name)' [$($vm.Id)]."
        return 'COMPLETED'
    } catch [Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $message = $_.Exception.Message
        try { Write-LabAudit 'create-vm' 'FAILED_OR_UNCONFIRMED' $null "$name`: $message" }
        catch { Write-Warning 'Audit logging also failed. Inspect Hyper-V inventory; do not assume nothing was created.' }
        Write-Warning "Create VM failed or completion is unconfirmed: $message"
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
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

# Recursively lists .iso files under $IsoRoot. A manual stack walk (not -Recurse) so a
# mid-tree permission error is recorded and skipped rather than aborting the whole scan,
# and so a reparse-point directory is never descended into (avoids loops/escaping the root).
# Incomplete is $true whenever Errors is non-empty, including a missing/inaccessible root --
# callers can then tell "nothing found" from "couldn't look everywhere".
function Get-LabIsoCandidates {
    param([string]$IsoRoot)
    $files = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $IsoRoot -PathType Container)) {
        $errors.Add("ISO root not found or not a directory: $IsoRoot")
        return [pscustomobject]@{ Files = @(); Incomplete = $true; Errors = @($errors) }
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($IsoRoot)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try {
            $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
        } catch {
            $errors.Add("${directory}: $($_.Exception.Message)")
            continue
        }
        foreach ($child in $children) {
            $isReparse = [bool]($child.Attributes -band [IO.FileAttributes]::ReparsePoint)
            if ($child.PSIsContainer) {
                # Never descend into a link: it can loop or lead outside the chosen root.
                if (-not $isReparse) { $pending.Push($child.FullName) }
                continue
            }
            if ($child.Extension -ieq '.iso') {
                $files.Add([pscustomobject]@{ FullName = $child.FullName; Length = $child.Length; LastWriteTime = $child.LastWriteTime })
            }
        }
    }
    [pscustomobject]@{ Files = @($files); Incomplete = [bool]($errors.Count -gt 0); Errors = @($errors) }
}

function Select-LabIsoPath {
    param([string]$IsoRoot)
    $allItems = @()
    $items = @()
    $needsScan = $true
    while ($true) {
        if ($needsScan) {
            $scan = Get-LabIsoCandidates $IsoRoot
            $allItems = @($scan.Files)
            $items = $allItems
            if ($scan.Incomplete) {
                Write-Host "ISO scan under '$IsoRoot' did not finish; the list below may be missing files."
                foreach ($scanError in $scan.Errors) { Write-Host "  $scanError" }
            }
            $needsScan = $false
        }
        Write-Host "`n=== Select an ISO ($($items.Count) found under $IsoRoot) ==="
        if ($items.Count -eq 0) {
            Write-Host 'No ISO files match. Choose R to refresh or B to go back.'
        } else {
            $rows = for ($i = 0; $i -lt $items.Count; $i++) {
                $iso = $items[$i]
                [pscustomobject]@{
                    No           = $i + 1
                    Name         = Split-Path -Leaf $iso.FullName
                    FullName     = $iso.FullName
                    SizeMB       = [math]::Round($iso.Length / 1MB, 1)
                    LastWriteTime = $iso.LastWriteTime
                }
            }
            $rows | Format-Table -AutoSize -Wrap | Out-Host
        }
        $answer = Read-LabText 'ISO number; text to filter the list above; R refresh; B back'
        if ($answer -ieq 'B') { return $null }
        if ($answer -ieq 'R') { $needsScan = $true; continue }
        $index = ConvertTo-LabMenuIndex $answer $items.Count
        if ($index -ge 0) {
            $chosen = $items[$index].FullName
            if (-not (Test-Path -LiteralPath $chosen -PathType Leaf)) {
                Write-Host "Cannot select '$chosen': it no longer exists. Pick again or R to refresh."
                continue
            }
            try {
                $stream = [IO.File]::OpenRead($chosen)
                try { $size = $stream.Length } finally { $stream.Close() }
            } catch {
                Write-Host "Cannot select '$chosen': it could not be opened for reading ($($_.Exception.Message)). Pick again or R to refresh."
                continue
            }
            if ($size -le 0) {
                Write-Host "Cannot select '$chosen': the file is empty (0 bytes). Pick again or R to refresh."
                continue
            }
            return $chosen
        }
        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-Host 'Choose a listed number, text to filter, R or B.'
            continue
        }
        # Plain-text substring filter -- always matched against the full retained scan
        # ($allItems), never against whatever is currently displayed ($items), so typing
        # a different filter can still find an item that a prior filter narrowed out.
        $filtered = @($allItems | Where-Object { $_.FullName.IndexOf($answer, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($filtered.Count -eq 0) {
            Write-Host "No ISO in the full scan matches '$answer'. Showing the previous list; R re-scans from disk."
        } else {
            $items = $filtered
        }
    }
}

# --- Native seed-ISO builder and provisioning workspace (Task 5) ---
# Per-VM scratch space for files a future installer plan (Windows Autounattend.xml, Linux
# cloud-init user-data/meta-data) builds before handing them to New-LabSeedIso below. Deliberately
# never resolves under the configured -IsoRoot: that root is scanned read-only by
# Get-LabIsoCandidates above as a library to browse, and a generated, per-VM scratch folder has no
# business living inside it.
function Get-LabProvisioningWorkspacePath {
    param([guid]$VMId)
    $path = Join-Path $env:LOCALAPPDATA "LabVmManager\Provisioning\$VMId"
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Remove-LabProvisioningWorkspace {
    param([guid]$VMId)
    $path = Join-Path $env:LOCALAPPDATA "LabVmManager\Provisioning\$VMId"
    if ([IO.Directory]::Exists($path)) {
        [IO.Directory]::Delete($path, $true)
    }
}

# IMAPI2FS hands the finished image back as a raw COM IStream (CreateResultImage().ImageStream), not
# a .NET Stream -- a naive [IO.Stream] cast does not work against it, and PowerShell's own '-as
# [Runtime.InteropServices.ComTypes.IStream]' operator silently returns $null against it too (tried
# and confirmed against a real IMAPI2FS result image while building this function -- PowerShell's
# dynamic COM wrapper does not QueryInterface the way a statically compiled cast does). A tiny
# compiled C# helper performs the same cast at compile time, where it works, then reads the stream
# block-by-block through the interop IStream.Read(byte[], int, IntPtr) signature -- its third
# parameter is a raw pointer the COM method itself writes the actual bytes-read count through,
# rather than a normal .NET out/ref parameter, so unmanaged memory is allocated to receive it. This
# whole approach is the well-documented community workaround (search "IMAPI2FS PowerShell
# ImageStream write to file") for pulling bytes out of an IMAPI2FS result image from PowerShell, and
# is verified here against a real, mountable ISO in this task's MANUAL-TESTS.md step.
if (-not ('LabIsoStreamWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class LabIsoStreamWriter
{
    public static void WriteToFile(object imageStream, string path)
    {
        IStream stream = (IStream)imageStream;
        IntPtr bytesReadPtr = Marshal.AllocHGlobal(4);
        try
        {
            byte[] buffer = new byte[65536];
            using (FileStream output = new FileStream(path, FileMode.Create, FileAccess.Write))
            {
                while (true)
                {
                    stream.Read(buffer, buffer.Length, bytesReadPtr);
                    int bytesRead = Marshal.ReadInt32(bytesReadPtr);
                    if (bytesRead <= 0) { break; }
                    output.Write(buffer, 0, bytesRead);
                }
            }
        }
        finally
        {
            Marshal.FreeHGlobal(bytesReadPtr);
        }
    }
}
'@
}

function Write-LabIStreamToFile {
    param($Stream, [string]$Path)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [LabIsoStreamWriter]::WriteToFile($Stream, $Path)
}

# Builds a plain, non-bootable data ISO at $OutputPath. $Files keys are relative in-image paths
# ('Autounattend.xml', 'sub/dir/file.txt'); a rooted key ('\x', 'C:\x', 'C:x'), a ':' anywhere, an
# empty segment, a '..' segment, or two keys naming the same in-image file is refused before anything
# is staged. Each value says explicitly what it is -- nothing is ever inferred from whether a string
# happens to name an existing file:
#   - a plain [string] is ALWAYS the literal file content (written as UTF-8, no BOM), even if that
#     text looks like a path;
#   - @{ SourcePath = 'C:\...' } copies that local file in byte-for-byte, and a missing source file
#     is an error, never silently replaced by its path text;
#   - anything else ($null, numbers, byte arrays, FileInfo, other hashtables) is refused.
# Every key and value is validated before the COM image or the staging directory is created. Deliberately knows
# nothing about Autounattend.xml or cloud-init: the Windows/Linux unattended-install plans decide
# that content and pass it through this one generic function. BootImageOptions is never set, so the
# image stays non-bootable; FileSystemsToCreate is left at IMAPI2FS's own default (which includes
# Joliet) so exact long/mixed-case file names such as the ones future plans will need actually
# survive, not just 8.3-safe ones.
#
# IFsiDirectoryItem (the image's Root) has no method to fetch back an item it just created -- its
# AddDirectory/AddFile return nothing, and it has no GetFilesystemEntry/Items lookup at all (confirmed
# against the live COM object; both are DISP_E_UNKNOWNNAME). Building nested paths by walking that
# interface by hand is therefore not viable. Root.AddTree(path, $false) with $false (do not wrap in
# an extra folder named after $path) exists for exactly this, so every entry is first staged for real
# on local disk, in its final relative layout, and the whole tree is added in one call.
#
# Not independently unit-testable through Test-LabVM.ps1's fake-cmdlet harness: this instantiates a
# real COM object (IMAPI2FS.MsftFileSystemImage) rather than calling a mockable PowerShell cmdlet,
# so there is no fake for it there. Checked by source review (test_static.py) instead, and verified
# against a real, mounted ISO -- see MANUAL-TESTS.md, "ISO/installer provisioning".
function New-LabSeedIso {
    param([hashtable]$Files, [string]$OutputPath, [string]$VolumeLabel = 'LAB_SEED')
    if ($null -eq $Files -or $Files.Count -eq 0) {
        throw 'New-LabSeedIso requires at least one entry in -Files.'
    }
    $staged = [Collections.Generic.List[object]]::new()
    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Files.GetEnumerator()) {
        $key = [string]$entry.Key
        $relativePath = $key.Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($relativePath)) { throw "Invalid in-image path '$key': it is empty." }
        if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath.Contains(':')) {
            throw "Invalid in-image path '$key': it must be a relative path inside the image (no drive, ':' or leading slash)."
        }
        foreach ($segment in $relativePath.Split('\')) {
            if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') {
                throw "Invalid in-image path '$key': it must not contain empty, '.' or '..' segments."
            }
        }
        if (-not $seenPaths.Add($relativePath)) { throw "Invalid in-image path '$key': another key names the same file." }
        $value = $entry.Value
        if ($value -is [string]) {
            $staged.Add([pscustomobject]@{ RelativePath = $relativePath; Content = $value; SourcePath = $null })
        } elseif ($value -is [Collections.IDictionary] -and $value.Count -eq 1 -and $value.Contains('SourcePath')) {
            $sourcePath = [string]$value['SourcePath']
            if ([string]::IsNullOrWhiteSpace($sourcePath) -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "Source file '$sourcePath' for in-image path '$key' does not exist."
            }
            $staged.Add([pscustomobject]@{ RelativePath = $relativePath; Content = $null; SourcePath = $sourcePath })
        } else {
            $typeName = if ($null -eq $value) { '$null' } else { $value.GetType().FullName }
            throw "Unsupported value for in-image path '$key' ($typeName): use a [string] for literal content or @{ SourcePath = '<local file>' } to copy a file."
        }
    }
    try {
        $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage -ErrorAction Stop
    } catch {
        throw "IMAPI2FS.MsftFileSystemImage (Windows Image Mastering API) could not be instantiated: $($_.Exception.Message). This COM component ships with Windows; a stripped-down install may be missing it."
    }
    $image.VolumeName = $VolumeLabel
    $stagingDir = Join-Path ([IO.Path]::GetTempPath()) ('labseediso-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stagingDir)
    try {
        $stagingRoot = [IO.Path]::GetFullPath($stagingDir).TrimEnd('\') + '\'
        foreach ($item in $staged) {
            $destinationPath = [IO.Path]::GetFullPath((Join-Path $stagingDir $item.RelativePath))
            # Belt and braces behind the key validation above: never write outside the staging directory.
            if (-not $destinationPath.StartsWith($stagingRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Invalid in-image path '$($item.RelativePath)': it resolves outside the staging directory."
            }
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath))
            if ($null -ne $item.SourcePath) {
                [IO.File]::Copy($item.SourcePath, $destinationPath, $true)
            } else {
                [IO.File]::WriteAllText($destinationPath, $item.Content)
            }
        }
        $image.Root.AddTree($stagingDir, $false)
        $resultImage = $image.CreateResultImage()
        Write-LabIStreamToFile $resultImage.ImageStream $OutputPath
    } finally {
        if ([IO.Directory]::Exists($stagingDir)) { [IO.Directory]::Delete($stagingDir, $true) }
    }
}

# Enumerates every Windows edition inside a Windows installer ISO's sources\install.wim (or, if
# that is absent, sources\install.esd), and flags which ones are in this plan's scope: Windows 11
# client only. "Client" (never "Server") and BuildNumber -ge 22000 (the first public Windows 11
# build) together decide IsWindows11Client -- a high-build Server image must NOT qualify, and a
# low-build Client image must NOT qualify. Read-only: mounts $IsoPath purely to read it and always
# dismounts in a finally, even when a step below throws, so a bad/foreign ISO never leaves a stray
# mount behind.
#
# Mount-DiskImage/Get-Volume pairing (no existing precedent in this codebase to match): uses
# Mount-DiskImage -PassThru piped into Get-Volume, the exact pairing Plan 1 already live-verified
# against a real ISO while building New-LabSeedIso (see MANUAL-TESTS.md, "Seed-ISO round trip
# (verified live)": "Mount-DiskImage -ImagePath <iso> -PassThru | Get-Volume"), rather than the
# untried Get-DiskImage-by-path alternative. Task 2 reuses this same pairing.
function Get-LabWindowsInstallImages {
    param([string]$IsoPath)
    if (-not (Get-Module -ListAvailable -Name Dism)) {
        throw 'The Dism PowerShell module is missing. Install the Windows Assessment and Deployment Kit (or run this on a full Windows installation) before reading Windows install images.'
    }
    $mounted = $false
    try {
        $mountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        $mounted = $true
        $volume = Get-Volume -DiskImage $mountResult -ErrorAction Stop
        # Plain string concatenation, not Join-Path: Join-Path resolves the FileSystem provider's
        # drive at call time, which throws "Cannot find drive" for a drive letter the mount only
        # just assigned (and is unavailable at all in this file's fake-cmdlet harness).
        $sourcesRoot = "$($volume.DriveLetter):\sources"
        $imageFile = "$sourcesRoot\install.wim"
        if (-not (Test-Path -LiteralPath $imageFile -PathType Leaf)) {
            $imageFile = "$sourcesRoot\install.esd"
            if (-not (Test-Path -LiteralPath $imageFile -PathType Leaf)) {
                throw "'$IsoPath' doesn't look like a Windows installer ISO: no sources\install.wim or sources\install.esd was found after mounting it."
            }
        }
        # The index-less enumeration call does not carry InstallationType/Version; each entry needs
        # its own indexed call to read those.
        $summaries = @(Get-WindowsImage -ImagePath $imageFile -ErrorAction Stop)
        $images = [Collections.Generic.List[object]]::new()
        foreach ($summary in $summaries) {
            $detail = Get-WindowsImage -ImagePath $imageFile -Index $summary.ImageIndex -ErrorAction Stop
            $installationType = [string]$detail.InstallationType
            # Version's Build component (Major.Minor.Build.Revision), e.g. '10.0.26300.1000' -> 26300.
            $buildNumber = ([version]([string]$detail.Version)).Build
            $images.Add([pscustomobject]@{
                Index = [int]$summary.ImageIndex
                Name = [string]$summary.ImageName
                InstallationType = $installationType
                BuildNumber = $buildNumber
                IsWindows11Client = ($installationType -eq 'Client' -and $buildNumber -ge 22000)
            })
        }
        return $images.ToArray()
    } finally {
        # Only dismount if Mount-DiskImage itself actually succeeded. Otherwise nothing was ever
        # mounted, and an unconditional Dismount-DiskImage here would itself throw a confusing
        # "not currently mounted"-style error, masking the real Mount-DiskImage failure above.
        if ($mounted) {
            [void](Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop)
        }
    }
}

# Pure, read-only: decides whether a list already fetched by Get-LabWindowsInstallImages contains
# at least one in-scope edition, without re-mounting anything. Kept separate so Task 6's
# orchestrator can call it against a list it already has.
function Test-LabWindowsIsoInScope {
    param([object[]]$Images)
    return @($Images | Where-Object IsWindows11Client).Count -gt 0
}

# Read-only: mounts $IsoPath to read Ubuntu's own .disk/info (one plain-text file at the volume
# root) and reports whether it names an in-scope release, Ubuntu 26.04.x Desktop. Ubuntu names
# Desktop releases plainly ("Ubuntu 26.04.1 LTS ...") and Server releases "Ubuntu-Server ...", so
# the Server exclusion is a second check on top of the release pattern. Always dismounts in a
# finally, even when a step throws. Mount-DiskImage/Get-Volume/Dismount-DiskImage pairing and the
# $mounted dismount guard are identical to Get-LabWindowsInstallImages above.
function Get-LabLinuxIsoInfo {
    param([string]$IsoPath)
    $mounted = $false
    try {
        $mountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        $mounted = $true
        $volume = Get-Volume -DiskImage $mountResult -ErrorAction Stop
        # Plain string concatenation, not Join-Path, for the same drive-letter reason as above.
        $infoFile = "$($volume.DriveLetter):\.disk\info"
        if (-not (Test-Path -LiteralPath $infoFile -PathType Leaf)) {
            return [pscustomobject]@{ ReleaseText = ''; IsUbuntuDesktopInScope = $false }
        }
        $releaseText = [string](Get-Content -LiteralPath $infoFile -Raw -ErrorAction Stop)
        # In scope = Ubuntu 26.04.x Desktop: a 26.04 release line that is not a Server release.
        return [pscustomobject]@{
            ReleaseText = $releaseText
            IsUbuntuDesktopInScope = ($releaseText -match 'Ubuntu 26\.04(\.\d+)? LTS' -and $releaseText -notmatch 'Server')
        }
    } finally {
        # Only dismount if Mount-DiskImage itself actually succeeded, for the same reason as above.
        if ($mounted) {
            [void](Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop)
        }
    }
}

# Patches an Ubuntu Desktop installer ISO's grub.cfg in place, inserting the literal `autoinstall`
# kernel boot parameter into its `linux` boot line, so Subiquity runs its NoCloud autoinstall
# instead of the normal interactive installer, with zero interaction at GRUB's own menu either.
# Never modifies $SourceIsoPath itself -- always writes a new file at $OutputPath, and only once
# every check below holds. On any ambiguity it returns Patched=$false with a clear Reason and makes
# no copy at all, so a multi-gigabyte ISO is never duplicated for nothing; the caller falls back to
# the unpatched $SourceIsoPath in that case -- same fallback contract as New-LabPatchedBootableIso
# below, whose house style (verify everything before writing, copy only once verified, refuse rather
# than guess) this function follows directly.
#
# This is pure byte-array math over the ISO9660/Joliet structure (ECMA-119), parsed directly from
# $SourceIsoPath ON DISK, never a mounted volume -- same discipline as New-LabPatchedBootableIso.
# The Primary Volume Descriptor is always at sector 16, but the Joliet Supplementary Volume
# Descriptor is NOT reliably at a fixed sector: any El-Torito-bootable ISO (e.g. Hyper-V Gen2/UEFI
# booting this very ISO) also carries a type-0 Boot Record Volume Descriptor -- typically at
# sector 17, same as New-LabPatchedBootableIso's own El Torito BRVD read below -- which pushes a
# real Ubuntu ISO's Joliet SVD to sector 18 or later, never 17. So the volume descriptor set
# starting at sector 16 is scanned one 2048-byte descriptor at a time until a type-255 terminator
# descriptor is hit, taking the first Primary Volume Descriptor (type 1) and the first
# Supplementary Volume Descriptor
# (type 2) whose escape-sequence bytes (offset 88, 32 bytes) name a Joliet Level 1/2/3 sequence
# ("%/@", "%/C", or "%/E"). Both descriptors carry a 34-byte root directory record at byte offset
# 156 within the descriptor's own 2048-byte sector (ECMA-119 8.4/8.5/9.1: a directory record whose
# own file identifier is a single NUL byte is always exactly 34 bytes, so this offset is fixed, not
# walked). From there, grub.cfg is found by walking root -> boot -> grub -> grub.cfg in BOTH trees
# independently -- the primary tree's plain ASCII names, the Joliet tree's UCS-2BE-encoded names --
# since the two trees are parallel, separately-recorded namespaces, normally over the very same
# file data. Real ISO9660-authoring tools (xorriso/libisofs) emit primary-tree names as
# uppercase-only d-characters with a trailing ";<version>" on file names (e.g. "GRUB.CFG;1"), and
# the Joliet tree's leaf is typically "grub.cfg;1" too, not bare "grub.cfg" -- so each path
# component's identifier is normalized before comparing (the ";<version>" suffix stripped in both
# trees), and the primary tree's normalized names are compared case-insensitively (Joliet supports
# mixed case natively, so real tools preserve the original case there -- it stays case-sensitive).
# Each directory record (ECMA-119 9.1) is variable-length: byte 0 is the record's own length; bytes 2-9 and 10-17
# are the extent location and data length, each in ISO9660's "both-byte-order" (LSB_MSB) 8-byte
# encoding (a 4-byte little-endian copy, then a 4-byte big-endian copy, of the same 32-bit value);
# byte 32 is the file identifier's own length, and the identifier itself starts at byte 33. A
# record's own file identifier being a single 0x00 or single 0x01 byte is the "." / ".."
# self/parent entry ECMA-119 requires at the start of every directory extent; this walk skips both.
#
# Once grub.cfg's own directory record is found in both trees, this verifies they agree with each
# other (same extent, same data length) before touching anything -- a real ISO image normally keeps
# ONE copy of a file's data, referenced by both namespaces' directory entries; if they disagree,
# this ISO's layout isn't what this technique understands, and nothing is patched or copied. The
# file's current content is then read from its extent and searched for a `linux` boot line (the
# fixture's own test pattern: a line containing "/casper/vmlinuz"); if not found, this refuses
# rather than ever patching blind. ` autoinstall` is inserted right before a trailing "---" marker
# on that line if present (GRUB's own kernel/initrd-argument separator), otherwise appended to the
# line's end. Since ISO9660 extents are sector-aligned but file content inside them is often
# shorter than a whole number of sectors, the edit can only be written in place if the sector(s)
# already backing the extent have enough slack for the longer content (rounded up to the next
# 2048-byte boundary); if not, this refuses with a Reason naming the shortfall -- never grows a file
# across a sector boundary this function doesn't also account for in both trees' directory records.
#
# Only once every check above holds: copy the whole source file, write the new content into the
# existing extent (zero-padding the remainder of its sector(s), matching ISO9660 convention), and
# patch BOTH trees' own grub.cfg directory-record data-length fields (each its own 4-byte
# little-endian + 4-byte big-endian pair) to the new length -- the file's length genuinely changed
# here, unlike New-LabPatchedBootableIso's equal-length byte swap, so both records naming that
# length must be corrected, not just the content bytes themselves.
function New-LabPatchedBootableLinuxIso {
    param([string]$SourceIsoPath, [string]$OutputPath)
    $sectorSize = 2048
    $kernelLinePattern = '/casper/vmlinuz'
    $autoinstallParam = 'autoinstall'
    $pathComponents = @('boot', 'grub', 'grub.cfg')

    # Reads exactly $Count bytes at $Offset from the real ISO file on disk, looping Read since a
    # single call is not guaranteed to fill the buffer. Never loads the whole, possibly
    # multi-gigabyte, file into memory. A scriptblock, not a nested function -- see
    # New-LabPatchedBootableIso's own identical note on why (this function's own text is extracted
    # and evaluated standalone by Test-LabVM.ps1's AST harness).
    $readIsoBytes = {
        param([string]$Path, [int64]$Offset, [int]$Count)
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] $Count
            $readTotal = 0
            while ($readTotal -lt $Count) {
                $read = $stream.Read($buffer, $readTotal, $Count - $readTotal)
                if ($read -le 0) {
                    throw "Unexpected end of file reading $Count byte(s) at offset $Offset from '$Path'."
                }
                $readTotal += $read
            }
            return $buffer
        } finally {
            $stream.Dispose()
        }
    }

    # Finds $Name's own directory record among the records packed into a directory's extent
    # ($ExtentSector/$DataLength, as recorded by that directory's OWN parent). Walks the extent a
    # sector at a time (ECMA-119: a directory record never spans a sector boundary; a zero length
    # byte signals "no more records in THIS sector", not "no more records at all", for an extent
    # spanning more than one sector) and skips the mandatory "." (0x00) / ".." (0x01) self/parent
    # entries every directory extent starts with. Returns $null if not found.
    $findChildRecord = {
        param([string]$Path, [scriptblock]$ReadIsoBytes, [int64]$ExtentSector, [uint32]$DataLength, [string]$Name, [bool]$Joliet, [int]$SectorSize)
        $bytesWalked = 0L
        $sectorIndex = 0L
        while ($bytesWalked -lt $DataLength) {
            $chunkOffset = ($ExtentSector + $sectorIndex) * $SectorSize
            $chunk = & $ReadIsoBytes $Path $chunkOffset $SectorSize
            $pos = 0
            while ($pos -lt $SectorSize) {
                $lenDr = [int]$chunk[$pos]
                if ($lenDr -eq 0) { break }
                $lenFi = [int]$chunk[$pos + 32]
                $fileIdBytes = $chunk[($pos + 33)..($pos + 33 + $lenFi - 1)]
                $isDotEntry = ($lenFi -eq 1 -and ($fileIdBytes[0] -eq 0 -or $fileIdBytes[0] -eq 1))
                if (-not $isDotEntry) {
                    $fileName = if ($Joliet) { [Text.Encoding]::BigEndianUnicode.GetString($fileIdBytes) } else { [Text.Encoding]::ASCII.GetString($fileIdBytes) }
                    # Real authoring tools append ";<version>" to file identifiers in BOTH trees
                    # (e.g. "GRUB.CFG;1" primary, "grub.cfg;1" Joliet) -- strip it before comparing.
                    # The primary tree's d-characters are uppercase-only by the ISO9660 Level 1/2
                    # charset, so its normalized name is compared case-insensitively; Joliet natively
                    # supports mixed case and real tools preserve it there, so it stays case-sensitive.
                    $normalizedFileName = $fileName -replace ';\d+$', ''
                    $isNameMatch = if ($Joliet) { $normalizedFileName -ceq $Name } else { $normalizedFileName -ieq $Name }
                    if ($isNameMatch) {
                        return [pscustomobject]@{
                            ExtentSector = [int64][BitConverter]::ToUInt32($chunk, $pos + 2)
                            DataLength = [uint32][BitConverter]::ToUInt32($chunk, $pos + 10)
                            IsDirectory = (([int]$chunk[$pos + 25] -band 0x02) -ne 0)
                            DataLengthFieldOffset = [int64]($chunkOffset + $pos + 10)
                        }
                    }
                }
                $pos += $lenDr
            }
            $bytesWalked += $SectorSize
            $sectorIndex++
        }
        return $null
    }

    # Walks root -> boot -> grub -> grub.cfg in one tree (primary or Joliet), starting from that
    # tree's own root directory record's extent/length. Returns the leaf (grub.cfg) record, or
    # $null plus the path component that could not be found.
    $walkToGrubCfg = {
        param([string]$Path, [scriptblock]$ReadIsoBytes, [scriptblock]$FindChildRecord, [int64]$RootExtentSector, [uint32]$RootDataLength, [string[]]$PathComponents, [bool]$Joliet, [int]$SectorSize)
        $extent = $RootExtentSector
        $length = $RootDataLength
        $record = $null
        foreach ($component in $PathComponents) {
            $record = & $FindChildRecord $Path $ReadIsoBytes $extent $length $component $Joliet $SectorSize
            if ($null -eq $record) {
                return [pscustomobject]@{ Record = $null; MissingComponent = $component }
            }
            $extent = $record.ExtentSector
            $length = $record.DataLength
        }
        return [pscustomobject]@{ Record = $record; MissingComponent = $null }
    }

    # Scan the volume descriptor set starting at sector 16, one 2048-byte descriptor at a time,
    # until a type-255 terminator descriptor is hit. The Joliet SVD cannot be assumed to be at a
    # fixed sector: an El-Torito-bootable ISO (type-0 Boot Record Volume Descriptor, typically at
    # sector 17) pushes it to sector 18+. Take the first type-1 descriptor as the PVD, and the
    # first type-2 descriptor whose escape-sequence bytes (offset 88) name a Joliet Level 1/2/3
    # sequence as the Joliet SVD; other descriptor types (0 = Boot Record, 2 without a Joliet
    # escape, etc.) are simply walked past.
    $jolietEscapeSequences = @(
        [byte[]]@(0x25, 0x2F, 0x40),  # Level 1: '%/@'
        [byte[]]@(0x25, 0x2F, 0x43),  # Level 2: '%/C'
        [byte[]]@(0x25, 0x2F, 0x45)   # Level 3: '%/E'
    )
    $pvd = $null
    $svd = $null
    $descriptorSector = [int64]16
    while ($true) {
        $descriptor = & $readIsoBytes $SourceIsoPath ($descriptorSector * $sectorSize) $sectorSize
        if ([Text.Encoding]::ASCII.GetString($descriptor, 1, 5) -ne 'CD001') {
            return [pscustomobject]@{
                Patched = $false
                Reason = "'$SourceIsoPath' has no valid ISO9660 volume descriptor at sector " +
                    "$descriptorSector ('CD001' was not found there). This ISO's filesystem " +
                    "structure isn't one this technique understands."
                OutputPath = $null
            }
        }
        $descriptorType = [int]$descriptor[0]
        if ($descriptorType -eq 255) {
            break
        } elseif ($descriptorType -eq 1 -and $null -eq $pvd) {
            $pvd = $descriptor
        } elseif ($descriptorType -eq 2 -and $null -eq $svd) {
            $escapeBytes = $descriptor[88..90]
            foreach ($pattern in $jolietEscapeSequences) {
                if ($escapeBytes[0] -eq $pattern[0] -and $escapeBytes[1] -eq $pattern[1] -and $escapeBytes[2] -eq $pattern[2]) {
                    $svd = $descriptor
                    break
                }
            }
        }
        $descriptorSector++
    }
    if ($null -eq $pvd) {
        return [pscustomobject]@{
            Patched = $false
            Reason = "'$SourceIsoPath' has no Primary Volume Descriptor in its volume descriptor " +
                "set. This ISO's filesystem structure isn't one this technique understands."
            OutputPath = $null
        }
    }
    if ($null -eq $svd) {
        return [pscustomobject]@{
            Patched = $false
            Reason = "'$SourceIsoPath' has no Joliet (UCS-2 Level 1/2/3) Supplementary Volume " +
                "Descriptor in its volume descriptor set (no '%/@', '%/C', or '%/E' escape " +
                "sequence was found on any Supplementary Volume Descriptor). This ISO's filesystem " +
                "structure isn't one this technique understands."
            OutputPath = $null
        }
    }

    $primaryRootExtent = [int64][BitConverter]::ToUInt32($pvd, 156 + 2)
    $primaryRootLength = [uint32][BitConverter]::ToUInt32($pvd, 156 + 10)
    $jolietRootExtent = [int64][BitConverter]::ToUInt32($svd, 156 + 2)
    $jolietRootLength = [uint32][BitConverter]::ToUInt32($svd, 156 + 10)

    $primaryWalk = & $walkToGrubCfg $SourceIsoPath $readIsoBytes $findChildRecord $primaryRootExtent $primaryRootLength $pathComponents $false $sectorSize
    if ($null -eq $primaryWalk.Record) {
        return [pscustomobject]@{
            Patched = $false
            Reason = "'$SourceIsoPath': 'grub.cfg' was not found -- '$($primaryWalk.MissingComponent)' " +
                "is missing while walking the primary ISO9660 tree's /$($pathComponents -join '/') " +
                "path. This ISO's layout isn't one this technique understands."
            OutputPath = $null
        }
    }
    $jolietWalk = & $walkToGrubCfg $SourceIsoPath $readIsoBytes $findChildRecord $jolietRootExtent $jolietRootLength $pathComponents $true $sectorSize
    if ($null -eq $jolietWalk.Record) {
        return [pscustomobject]@{
            Patched = $false
            Reason = "'$SourceIsoPath': 'grub.cfg' was not found -- '$($jolietWalk.MissingComponent)' " +
                "is missing while walking the Joliet tree's /$($pathComponents -join '/') path. " +
                "This ISO's layout isn't one this technique understands."
            OutputPath = $null
        }
    }

    $primaryRecord = $primaryWalk.Record
    $jolietRecord = $jolietWalk.Record
    if ($primaryRecord.ExtentSector -ne $jolietRecord.ExtentSector -or $primaryRecord.DataLength -ne $jolietRecord.DataLength) {
        return [pscustomobject]@{
            Patched = $false
            Reason = "'$SourceIsoPath': the primary and Joliet trees disagree about grub.cfg's " +
                "own extent/length (primary: sector $($primaryRecord.ExtentSector), " +
                "$($primaryRecord.DataLength) byte(s); Joliet: sector $($jolietRecord.ExtentSector), " +
                "$($jolietRecord.DataLength) byte(s)). Refusing to patch blind."
            OutputPath = $null
        }
    }

    $dataLength = [int]$primaryRecord.DataLength
    $sectorsUsed = [math]::Max(1, [int][math]::Ceiling($dataLength / [double]$sectorSize))
    $maxBytesInExtent = $sectorsUsed * $sectorSize
    $extentBytes = & $readIsoBytes $SourceIsoPath ([int64]$primaryRecord.ExtentSector * $sectorSize) $maxBytesInExtent
    $contentText = [Text.Encoding]::ASCII.GetString($extentBytes, 0, $dataLength)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($contentText -split "`n"))
    $kernelLineIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match [regex]::Escape($kernelLinePattern)) { $kernelLineIndex = $i; break }
    }
    if ($kernelLineIndex -lt 0) {
        return [pscustomobject]@{
            Patched = $false
            Reason = "'$SourceIsoPath': grub.cfg has no recognizable Linux kernel boot line " +
                "(expected a 'linux' line naming '$kernelLinePattern'). Refusing to patch blind."
            OutputPath = $null
        }
    }
    $trimmedLine = $lines[$kernelLineIndex].TrimEnd()
    $newLine = if ($trimmedLine.EndsWith('---')) {
        $head = $trimmedLine.Substring(0, $trimmedLine.Length - 3).TrimEnd()
        "$head $autoinstallParam ---"
    } else {
        "$trimmedLine $autoinstallParam"
    }
    $lines[$kernelLineIndex] = $newLine
    $newContentText = [string]::Join("`n", $lines)
    $newContentBytes = [Text.Encoding]::ASCII.GetBytes($newContentText)

    if ($newContentBytes.Length -gt $maxBytesInExtent) {
        return [pscustomobject]@{
            Patched = $false
            Reason = "'$SourceIsoPath': grub.cfg's extent has no slack space left for this edit " +
                "-- it has $maxBytesInExtent byte(s) available across $sectorsUsed sector(s), but " +
                "the patched content needs $($newContentBytes.Length) byte(s) (a shortfall of " +
                "$($newContentBytes.Length - $maxBytesInExtent) byte(s)). This in-place technique " +
                'cannot grow a file across a sector boundary.'
            OutputPath = $null
        }
    }

    # Only once every check above holds: copy the whole source file, write the new content into
    # the existing extent (zero-padding the rest of its sector(s)), then patch both trees' own
    # grub.cfg directory-record data-length fields to the new length.
    Copy-Item -LiteralPath $SourceIsoPath -Destination $OutputPath -Force -ErrorAction Stop
    $outputStream = [IO.File]::Open($OutputPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $paddedContent = New-Object byte[] $maxBytesInExtent
        [Array]::Copy($newContentBytes, 0, $paddedContent, 0, $newContentBytes.Length)
        [void]$outputStream.Seek(([int64]$primaryRecord.ExtentSector * $sectorSize), [IO.SeekOrigin]::Begin)
        $outputStream.Write($paddedContent, 0, $paddedContent.Length)

        $newLengthLsb = [BitConverter]::GetBytes([uint32]$newContentBytes.Length)
        $newLengthMsb = [BitConverter]::GetBytes([uint32]$newContentBytes.Length)
        [Array]::Reverse($newLengthMsb)
        foreach ($fieldOffset in @($primaryRecord.DataLengthFieldOffset, $jolietRecord.DataLengthFieldOffset)) {
            [void]$outputStream.Seek($fieldOffset, [IO.SeekOrigin]::Begin)
            $outputStream.Write($newLengthLsb, 0, 4)
            $outputStream.Write($newLengthMsb, 0, 4)
        }
    } finally {
        $outputStream.Dispose()
    }
    return [pscustomobject]@{ Patched = $true; Reason = $null; OutputPath = $OutputPath }
}

# The standard, mechanical POSIX-shell single-quoted-literal escape: a value wrapped in '...' is a
# shell literal with NO escape character at all, so it is inherently immune to $, `, \, and " inside
# it -- the only character that needs any handling is an embedded single quote itself, which closes
# the literal, inserts an escaped literal quote ('\''), then reopens the literal. A small,
# independently-testable primitive, not folded into New-LabLinuxAutoinstallUserData below.
function ConvertTo-LabPosixShellSingleQuoted {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

# Linux `adduser`-compatible username rule: lowercase letters, digits, underscore and hyphen only,
# must start with a lowercase letter or underscore, 1-32 characters total.
function Test-LabLinuxUserName {
    param([string]$Value)
    return [bool]($Value -cmatch '^[a-z_][a-z0-9_-]{0,31}$')
}

# Pure string builder: no I/O, no COM, no Hyper-V. Its only job is to hand back a well-formed Ubuntu
# autoinstall user-data YAML document for Task 6's orchestrator to write into the NoCloud seed ISO
# via New-LabSeedIso. identity.password below is never the real password -- Subiquity's schema wants
# a crypt(3) hash there, which .NET cannot produce, so it carries a fixed placeholder hash (nobody
# holds this plaintext) and late-commands overwrites the account's real password via chpasswd once
# curtin has a target to run commands in -- see the design doc's "Already proven" section.
#
# The real password crosses two separate syntax layers on its way into that late-commands entry, and
# each is escaped with its own purpose-built, mechanical routine -- never ad hoc character
# replacement. First, ConvertTo-LabPosixShellSingleQuoted wraps "username:password" as a POSIX shell
# single-quoted literal, giving the exact argument `sh -c` will see after curtin's shell parses it.
# Then that whole shell command string is embedded in the YAML document as a double-quoted scalar,
# built via ConvertTo-Json -Compress: a JSON double-quoted string literal is also a valid YAML
# double-quoted scalar (both escape \ and " the same way, and both accept \uXXXX for anything else),
# so this reuses .NET's own tested JSON escaper instead of writing a second, separate escaper for a
# mechanically identical job. Each layer only has to defend against the characters that are special
# to IT -- the shell layer makes the password's literal bytes opaque to the shell, and the YAML layer
# then only has to carry that already-opaque literal safely as a string scalar -- so the two layers
# compose safely without either one needing to know about the other's special characters.
function New-LabLinuxAutoinstallUserData {
    param(
        [string]$ComputerName,
        [string]$Locale,
        [string]$TimeZone,
        [string]$UserName,
        [securestring]$Password,
        [string]$SshPublicKey
    )
    # Same discipline as New-LabWindowsAnswerFileXml: the SecureString is decrypted to plaintext only
    # in this narrow scope, for exactly as long as it takes to build the escaped late-commands shell
    # command below, then the unmanaged memory holding it is explicitly zeroed and freed in the
    # finally -- never logged, never written anywhere by this function itself.
    $passwordPtr = [IntPtr]::Zero
    try {
        $passwordPtr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($passwordPtr)
        $shellCommand = 'echo ' + (ConvertTo-LabPosixShellSingleQuoted "${UserName}:${plainPassword}") + ' | chpasswd'
        $yamlEscapedShellCommand = $shellCommand | ConvertTo-Json -Compress
    } finally {
        if ($passwordPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($passwordPtr) }
    }
    # Fixed placeholder hash, constructed to be syntactically plausible ($6$<salt>$<hash> SHA-512-crypt
    # shape, correct character set and length) -- nobody holds this plaintext, and late-commands above
    # replaces the account's real password before first login, so this value is never actually used to
    # authenticate anything; see this function's own header comment.
    $placeholderPasswordHash = '$6$sC.928AhS010gxvH$9LC/yT6v693W6axhWTNu07.eGwkJ47zI7PG1gCGbu3pX3KWHaHv3lgzfvw3wJssZXDLprDBykUMgBIWHdt78mP'
    return @"
autoinstall:
  version: 1
  identity:
    hostname: $ComputerName
    username: $UserName
    password: "$placeholderPasswordHash"
  locale: $Locale
  timezone: $TimeZone
  ssh:
    install-server: true
    authorized-keys:
      - $SshPublicKey
  late-commands:
    - [curtin, in-target, --, sh, -c, $yamlEscapedShellCommand]
  storage:
    layout:
      name: direct
"@
}

# Patches a Windows installer ISO's EFI boot-loader image (efi\microsoft\boot\efisys.bin) in place
# with its own no-prompt variant (efisys_noprompt.bin), so Hyper-V Gen2's "Press any key to boot
# from CD or DVD" prompt never appears. Never modifies $SourceIsoPath itself -- always writes a
# new file at $OutputPath, and only once every check below holds. On any ambiguity it returns
# Patched=$false with a clear Reason and makes no copy at all, so a multi-gigabyte ISO is never
# duplicated for nothing; the caller falls back to the unpatched $SourceIsoPath in that case.
#
# This is pure byte-array math over the ISO9660/El Torito structure, parsed by hand against a real
# Windows 11 ISO and confirmed to work this way (see the design doc's "Already proven" section): a
# Boot Record Volume Descriptor at sector 17 names "EL TORITO SPECIFICATION" and points at a boot
# catalog sector; the catalog's EFI entry carries a Load RBA -- the sector firmware actually loads
# efisys.bin's bytes from. $offset = LoadRBA * 2048 is where those bytes live in the raw ISO file.
# Finding the EFI entry takes two forms, both walked below: when the catalog's Validation Entry
# itself already names platform id 0xEF, the catalog is EFI-only and the Initial/Default Entry
# (catalog offset 32) directly carries the EFI Load RBA. Otherwise -- the real Windows 11 ISO's own
# shape, confirmed by reading its raw boot-catalog bytes directly -- the Validation Entry names the
# BIOS platform (0x00) and the EFI entry instead lives inside a Section Header group starting at
# catalog offset 64, which is walked header-by-header until one with platform id 0xEF is found.
# Before touching anything, the content actually AT the resulting offset is compared byte-for-byte
# against efisys.bin's own bytes (read from the mounted volume); if they don't match, this ISO's
# boot layout isn't one this technique understands, and nothing is patched or copied -- never patch
# blind.
#
# Mount-DiskImage/Get-Volume/Dismount-DiskImage pairing and the $mounted dismount guard: identical
# to Get-LabWindowsInstallImages above, reused verbatim, including the plain string concatenation
# for the mounted-volume path (Join-Path resolves the FileSystem provider's drive at call time,
# which throws "Cannot find drive" for a drive letter the mount only just assigned). The mount is
# used only to read the two loose efisys*.bin files; the El Torito structure itself is parsed
# straight from $SourceIsoPath on disk, never through the mount.
#
# Copy-Item, not [IO.File]::Copy, performs the whole-file copy: unlike New-LabSeedIso (which
# instantiates real COM and so has no fake-able surface), this function's logic is independently
# unit-testable, and a cmdlet -- unlike a static .NET call -- can be verified in Test-LabVM.ps1 as
# never invoked on any of the refusal paths below, so a multi-gigabyte copy is never made for
# nothing.
function New-LabPatchedBootableIso {
    param([string]$SourceIsoPath, [string]$OutputPath)
    $sectorSize = 2048
    $bootDirName = 'efi\microsoft\boot'

    # Reads exactly $Count bytes at $Offset from the real ISO file on disk, looping Read since a
    # single call is not guaranteed to fill the buffer. Never loads the whole, possibly
    # multi-gigabyte, file into memory. A scriptblock, not a nested function: this function's own
    # text is extracted and evaluated standalone by Test-LabVM.ps1's AST harness, and a second
    # top-level "function" statement in here would confuse tooling that locates this function's
    # body by searching for the next "function" keyword.
    $readIsoBytes = {
        param([string]$Path, [int64]$Offset, [int]$Count)
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] $Count
            $readTotal = 0
            while ($readTotal -lt $Count) {
                $read = $stream.Read($buffer, $readTotal, $Count - $readTotal)
                if ($read -le 0) {
                    throw "Unexpected end of file reading $Count byte(s) at offset $Offset from '$Path'."
                }
                $readTotal += $read
            }
            return $buffer
        } finally {
            $stream.Dispose()
        }
    }

    $mounted = $false
    $efisysBytes = $null
    $noPromptBytes = $null
    $earlyReason = $null
    try {
        $mountResult = Mount-DiskImage -ImagePath $SourceIsoPath -PassThru -ErrorAction Stop
        $mounted = $true
        $volume = Get-Volume -DiskImage $mountResult -ErrorAction Stop
        # Plain string concatenation, not Join-Path: Join-Path resolves the FileSystem provider's
        # drive at call time, which throws "Cannot find drive" for a drive letter the mount only
        # just assigned (and is unavailable at all in this file's fake-cmdlet harness).
        $bootDir = "$($volume.DriveLetter):\$bootDirName"
        $efisysPath = "$bootDir\efisys.bin"
        $noPromptPath = "$bootDir\efisys_noprompt.bin"
        if (-not (Test-Path -LiteralPath $noPromptPath -PathType Leaf)) {
            $earlyReason = "'$SourceIsoPath' does not ship the no-prompt boot-loader variant " +
                "($bootDirName\efisys_noprompt.bin is missing after mounting it). It will still " +
                'prompt for a key press at boot; fall back to the unpatched ISO.'
        } else {
            $efisysBytes = [byte[]](Get-Content -LiteralPath $efisysPath -Encoding Byte -ReadCount 0 -ErrorAction Stop)
            $noPromptBytes = [byte[]](Get-Content -LiteralPath $noPromptPath -Encoding Byte -ReadCount 0 -ErrorAction Stop)
        }
    } finally {
        # Only dismount if Mount-DiskImage itself actually succeeded. Otherwise nothing was ever
        # mounted, and an unconditional Dismount-DiskImage here would itself throw a confusing
        # "not currently mounted"-style error, masking the real Mount-DiskImage failure above.
        if ($mounted) {
            [void](Dismount-DiskImage -ImagePath $SourceIsoPath -ErrorAction Stop)
        }
    }
    if ($null -ne $earlyReason) {
        return [pscustomobject]@{ Patched = $false; Reason = $earlyReason; OutputPath = $null }
    }
    if ($efisysBytes.Length -ne $noPromptBytes.Length) {
        return [pscustomobject]@{
            Patched = $false
            Reason = "'$SourceIsoPath' cannot be patched: $bootDirName\efisys.bin is " +
                "$($efisysBytes.Length) byte(s) but $bootDirName\efisys_noprompt.bin is " +
                "$($noPromptBytes.Length) byte(s). The in-place byte swap this technique uses " +
                'requires them to be exactly the same length.'
            OutputPath = $null
        }
    }

    # Parse the El Torito boot structure from the SOURCE ISO FILE ON DISK, not the mounted volume
    # -- the mount above is only ever used to read the two loose efisys*.bin files.
    $brvd = & $readIsoBytes $SourceIsoPath ([int64]17 * $sectorSize) $sectorSize
    $standardIdentifier = [Text.Encoding]::ASCII.GetString($brvd, 1, 5)
    $bootSystemIdentifier = [Text.Encoding]::ASCII.GetString($brvd, 7, 32).TrimEnd([char]0)
    if ($brvd[0] -ne 0 -or $standardIdentifier -ne 'CD001' -or $bootSystemIdentifier -ne 'EL TORITO SPECIFICATION') {
        return [pscustomobject]@{
            Patched = $false
            Reason = "'$SourceIsoPath' has no El Torito Boot Record Volume Descriptor at sector " +
                "17 ('EL TORITO SPECIFICATION' was not found there). This ISO's boot structure " +
                "isn't one this technique understands."
            OutputPath = $null
        }
    }
    $catalogSector = [BitConverter]::ToUInt32($brvd, 71)
    $catalog = & $readIsoBytes $SourceIsoPath ([int64]$catalogSector * $sectorSize) $sectorSize
    $catalogSectorBytes = $catalog.Length
    $boundsReason = "'$SourceIsoPath': the El Torito boot catalog did not point where expected " +
        "-- its EFI entry's Load RBA does not point at $bootDirName\efisys.bin's own content. " +
        'Refusing to patch blind.'
    $noEfiEntryReason = "'$SourceIsoPath': no EFI (platform id 0xEF) boot catalog entry was " +
        'found -- neither the Validation Entry nor any Section Header in the boot catalog names ' +
        "platform id 0xEF. This ISO's boot structure isn't one this technique understands."

    # Validation Entry (catalog offset 0-31): byte 1 is its platform id. A real Windows 11 ISO's
    # boot catalog carries BOTH a BIOS entry (Validation Entry platform id 0x00, an Initial/Default
    # Entry at catalog offset 32 pointing at the BIOS etfsboot image) AND a separate EFI entry living
    # inside a Section Header group starting at catalog offset 64 -- so the Initial/Default Entry at
    # offset 32 is NOT reliably the EFI entry; that's only true when the catalog is EFI-only. Only
    # when the Validation Entry's own platform id is already 0xEF does the Initial/Default Entry at
    # offset 32 directly carry the EFI Load RBA (local offset 8, catalog offset 40).
    $loadRba = $null
    if ($catalog[1] -eq 0xEF) {
        $loadRba = [BitConverter]::ToUInt32($catalog, 40)
    } else {
        # Walk 32-byte Section Header groups starting at catalog offset 64. A Section Header's byte 0
        # is 0x90 ("more headers follow") or 0x91 ("this is the final header"); byte 1 is its platform
        # id; bytes 2-3 are a little-endian uint16 count of Section Entries (each also 32 bytes, same
        # Load-RBA-at-local-offset-8 shape) immediately following it. The whole catalog sector is 64
        # entries of 32 bytes each (2048 bytes total, including the Validation Entry), so the walk
        # never reads past $catalogSectorBytes.
        $entryOffset = 64
        while ($entryOffset + 32 -le $catalogSectorBytes) {
            $headerByte0 = $catalog[$entryOffset]
            $headerPlatformId = $catalog[$entryOffset + 1]
            $sectionCount = [BitConverter]::ToUInt16($catalog, $entryOffset + 2)
            if ($headerPlatformId -eq 0xEF -and $sectionCount -ge 1) {
                # Windows's own ISOs carry exactly one EFI boot entry -- only the first Section Entry
                # following an 0xEF header is needed; no selection logic beyond that.
                $firstEntryOffset = $entryOffset + 32
                if ($firstEntryOffset + 32 -le $catalogSectorBytes) {
                    $loadRba = [BitConverter]::ToUInt32($catalog, $firstEntryOffset + 8)
                }
                break
            }
            $isFinalHeader = ($headerByte0 -eq 0x91)
            $entryOffset += 32 * (1 + [int]$sectionCount)
            if ($isFinalHeader) { break }
        }
    }
    if ($null -eq $loadRba) {
        return [pscustomobject]@{ Patched = $false; Reason = $noEfiEntryReason; OutputPath = $null }
    }
    $offset = [int64]$loadRba * $sectorSize
    $actualBytes = & $readIsoBytes $SourceIsoPath $offset $efisysBytes.Length
    $bytesMatch = $true
    for ($i = 0; $i -lt $actualBytes.Length; $i++) {
        if ($actualBytes[$i] -ne $efisysBytes[$i]) { $bytesMatch = $false; break }
    }
    if (-not $bytesMatch) {
        return [pscustomobject]@{ Patched = $false; Reason = $boundsReason; OutputPath = $null }
    }

    # Only once every check above holds: copy the whole source file, then overwrite exactly
    # efisys.bin's-length bytes at $offset with efisys_noprompt.bin's content.
    Copy-Item -LiteralPath $SourceIsoPath -Destination $OutputPath -Force -ErrorAction Stop
    $outputStream = [IO.File]::Open($OutputPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        [void]$outputStream.Seek($offset, [IO.SeekOrigin]::Begin)
        $outputStream.Write($noPromptBytes, 0, $noPromptBytes.Length)
    } finally {
        $outputStream.Dispose()
    }
    return [pscustomobject]@{ Patched = $true; Reason = $null; OutputPath = $OutputPath }
}

function Test-LabVMHasKeyProtector {
    param([guid]$VMId)
    # Pure, read-only presence check -- it must never mutate. Set-LabVMBootProfile below calls this
    # to decide whether to add a key protector, and a standalone preview (Task 6) calls it before
    # any confirmation, so merely checking "does this VM already have one" can never itself create
    # one.
    #
    # Output shape, CONFIRMED by reflection against the installed Hyper-V module (no elevation, no VM
    # touched): GetVMKeyProtector.ProcessOneOperand calls VMSecurity.GetKeyProtector, which returns a
    # bare System.Byte[], and hands it to Cmdlet.WriteObject(object) without enumerating it. The
    # cmdlet therefore emits ONE raw byte[] -- there is no wrapper object, and no type anywhere in the
    # module has a RawKeyProtector or RawData property (RawData in Microsoft's docs belongs to the
    # HgsClient's New-HgsKeyProtector object, not to Hyper-V). Test-LabVM.ps1's drift guard re-checks
    # this against the installed module on every run.
    #
    # Not knowable by reflection: the exact bytes Hyper-V returns for a VM with NO key protector (they
    # come from WMI at run time; reportedly empty or the 4-byte header 0,0,0,4). A real local key
    # protector is kilobytes. So "present" means longer than 4 bytes. This errs on the safe side: if
    # the empty form were ever longer, the VM would be reported as already protected, which skips
    # creation and never rotates; a wrong "absent" would need a real protector of 4 bytes or fewer.
    # $null and an enumerated array (count of items) are normalized too, so neither can throw.
    $vm = Get-LabVM $VMId
    $raw = Get-VMKeyProtector -VM $vm -ErrorAction Stop
    $length = if ($null -eq $raw) { 0 } elseif ($raw -is [byte[]]) { $raw.Length } else { @($raw).Count }
    return ($length -gt 4)
}

function Set-LabVMBootProfile {
    param([guid]$VMId, [ValidateSet('Windows11', 'UbuntuDesktop')][string]$OsProfile)
    $vm = Assert-LabVMOff $VMId
    if ([int]$vm.Generation -ne 2) {
        throw "'$($vm.Name)' is Generation $($vm.Generation). Secure Boot and vTPM boot profiles require Generation 2."
    }
    $secureBootTemplateChanged = $false
    $keyProtectorAdded = $false
    $tpmEnabled = $false
    switch ($OsProfile) {
        'Windows11' {
            $firmware = Get-VMFirmware -VM $vm -ErrorAction Stop
            if ([string]$firmware.SecureBootTemplate -ne 'MicrosoftWindows') {
                Set-VMFirmware -VM $vm -SecureBootTemplate MicrosoftWindows -Confirm:$false -ErrorAction Stop
                $secureBootTemplateChanged = $true
            }
            if (-not (Test-LabVMHasKeyProtector $VMId)) {
                # Only add a key protector when none exists yet: rotating an existing one would
                # invalidate anything already encrypted under it.
                Set-VMKeyProtector -VM $vm -NewLocalKeyProtector -Confirm:$false -ErrorAction Stop
                Enable-VMTPM -VM $vm -Confirm:$false -ErrorAction Stop
                $keyProtectorAdded = $true
                $tpmEnabled = $true
            }
        }
        'UbuntuDesktop' {
            # Ubuntu's Secure Boot template never touches the key protector or vTPM.
            $firmware = Get-VMFirmware -VM $vm -ErrorAction Stop
            if ([string]$firmware.SecureBootTemplate -ne 'MicrosoftUEFICertificateAuthority') {
                Set-VMFirmware -VM $vm -SecureBootTemplate MicrosoftUEFICertificateAuthority -Confirm:$false -ErrorAction Stop
                $secureBootTemplateChanged = $true
            }
        }
    }
    # Both profiles need Secure Boot actually ON, not just the right template: a VM whose Secure Boot
    # was turned off (e.g. to boot some other distro) would otherwise keep the right template and
    # still not be Secure-Boot-protected. VMFirmware.SecureBoot is an OnOffState (reflection-checked),
    # read from the same Get-VMFirmware snapshot the template decision used. Turning it on touches no
    # key protector or encryption state.
    $secureBootEnabled = $false
    if ([string]$firmware.SecureBoot -ne 'On') {
        Set-VMFirmware -VM $vm -EnableSecureBoot On -Confirm:$false -ErrorAction Stop
        $secureBootEnabled = $true
    }
    return [pscustomobject]@{
        SecureBootTemplateChanged = $secureBootTemplateChanged
        SecureBootEnabled = $secureBootEnabled
        KeyProtectorAdded = $keyProtectorAdded
        TpmEnabled = $tpmEnabled
    }
}

function Get-LabVMInstallMediaPath {
    param([guid]$VMId)
    return Join-Path $env:LOCALAPPDATA "LabVmManager\InstallMedia\$VMId.json"
}

function Set-LabVMInstallMedia {
    param([guid]$VMId, [string]$IsoPath)
    $vm = Assert-LabVMOff $VMId
    # v1 limitation (disclosed, not a stub): the issue asks for drive selection among several DVD
    # drives, but a freshly-created VM (this plan's primary case) only ever has zero or one, so
    # choosing among more than one is deliberately deferred rather than built now.
    $drives = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
    if ($drives.Count -gt 1) {
        throw "'$($vm.Name)': more than one DVD drive exists; this version doesn't choose among them. Attach the ISO to one of them manually in Hyper-V Manager."
    }

    # Re-validate BEFORE any change (adding a drive, writing the record, attaching): the ISO may have
    # been deleted, moved, or truncated since it was selected, and callers outside the menu's preview
    # flow (the unattended-install plans) rely on this function never half-applying. Same checks as
    # Select-LabIsoPath's own selection-time validation.
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw "ISO '$IsoPath' no longer exists."
    }
    try {
        $stream = [IO.File]::OpenRead($IsoPath)
        try { $length = $stream.Length } finally { $stream.Close() }
    } catch {
        throw "ISO '$IsoPath' could not be opened for reading ($($_.Exception.Message))."
    }
    if ($length -le 0) { throw "ISO '$IsoPath' is empty (0 bytes)." }

    $dvdDriveAdded = $false
    if ($drives.Count -eq 0) {
        Add-VMDvdDrive -VM $vm -Confirm:$false -ErrorAction Stop
        $drives = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
        $dvdDriveAdded = $true
    }
    $drive = $drives[0]
    $previousAttachment = [string]$drive.Path

    # Before the ISO attachment below, record the drive's current attachment (which may be
    # $null/empty for a newly added drive) so a later "show previous attachment" or restore can use it.
    $path = Get-LabVMInstallMediaPath $VMId
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    ([ordered]@{ PreviousAttachment = $previousAttachment } | ConvertTo-Json) | Set-Content -LiteralPath $path

    Set-VMDvdDrive -VMDvdDrive $drive -Path $IsoPath -Confirm:$false -ErrorAction Stop
    return [pscustomobject]@{ PreviousAttachment = $previousAttachment; DvdDriveAdded = $dvdDriveAdded }
}

function Remove-LabVMInstallMedia {
    param([guid]$VMId)
    $vm = Assert-LabVMOff $VMId
    # Same disclosed v1 limitation as Set-LabVMInstallMedia: does not choose among several drives.
    $drives = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
    if ($drives.Count -gt 1) {
        throw "'$($vm.Name)': more than one DVD drive exists; this version doesn't choose among them. Eject the ISO manually in Hyper-V Manager."
    }
    if ($drives.Count -eq 0) { return }
    # $null ejects the attached media while leaving the drive itself in place.
    Set-VMDvdDrive -VMDvdDrive $drives[0] -Path $null -Confirm:$false -ErrorAction Stop
}

function Get-LabBootEntryKind {
    param($Entry)
    # CONFIRMED by reflection against the installed Hyper-V module (no elevation, no VM touched; the
    # drift guard in Test-LabVM.ps1 re-checks it): VMFirmware.BootOrder is a
    # Microsoft.HyperV.PowerShell.VMBootSource[] whose entries carry BootType (Unknown/Drive/Network/
    # File), Description, FirmwarePath and Device, and the DVD/disk device classes are named DvdDrive
    # and HardDiskDrive -- with NO 'VM' prefix. So the real shape is VMBootSource{ Device = DvdDrive }.
    # Classifying by the device's type-name suffix covers that and also a bare device or a VM-prefixed
    # name; anything unrecognized is 'Other' and is never dropped by a reorder. Still live-only (see
    # MANUAL-TESTS.md): what .Device holds for BootType = File entries such as "Windows Boot Manager".
    $device = $Entry
    $deviceProperty = $Entry.PSObject.Properties['Device']
    if ($null -ne $deviceProperty -and $null -ne $deviceProperty.Value) { $device = $deviceProperty.Value }
    $typeName = $device.GetType().Name
    if ($typeName -match 'DvdDrive$') { return 'Dvd' }
    if ($typeName -match 'HardDiskDrive$') { return 'Disk' }
    return 'Other'
}

function Set-LabVMUnattendedLinuxInstallMedia {
    param([guid]$VMId, [string]$LinuxIsoPath, [string]$SeedIsoPath)
    # Unlike Set-LabVMInstallMedia (manual-install flow, reuses/adds a single drive on a VM that may
    # already have one), this is only ever called against a VM this plan just created itself: zero
    # existing DVD drives, so there is no "choose among several drives" ambiguity to handle.
    $vm = Assert-LabVMOff $VMId
    if ([int]$vm.Generation -ne 2) {
        throw "'$($vm.Name)' is Generation $($vm.Generation). Unattended Linux install requires Generation 2."
    }
    $drives = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
    if ($drives.Count -gt 0) {
        throw "'$($vm.Name)' already has $($drives.Count) DVD drive(s) attached; this function is for a freshly created VM with none yet."
    }

    # Re-validate the Linux ISO immediately before attaching it -- not once up front for both -- so
    # a problem with the Linux ISO is caught before anything is touched at all.
    if (-not (Test-Path -LiteralPath $LinuxIsoPath -PathType Leaf)) {
        throw "ISO '$LinuxIsoPath' no longer exists."
    }
    try {
        $stream = [IO.File]::OpenRead($LinuxIsoPath)
        try { $length = $stream.Length } finally { $stream.Close() }
    } catch {
        throw "ISO '$LinuxIsoPath' could not be opened for reading ($($_.Exception.Message))."
    }
    if ($length -le 0) { throw "ISO '$LinuxIsoPath' is empty (0 bytes)." }
    $linuxDrive = Add-VMDvdDrive -VM $vm -Confirm:$false -Passthru -ErrorAction Stop
    Set-VMDvdDrive -VMDvdDrive $linuxDrive -Path $LinuxIsoPath -Confirm:$false -ErrorAction Stop

    # Re-validate the seed ISO immediately before attaching it, too -- so a problem with the seed ISO
    # is caught before the Linux drive above is touched, except that the Linux drive already was:
    # a seed-ISO failure here is reported with that drive left attached, not rolled back.
    if (-not (Test-Path -LiteralPath $SeedIsoPath -PathType Leaf)) {
        throw "ISO '$SeedIsoPath' no longer exists."
    }
    try {
        $stream = [IO.File]::OpenRead($SeedIsoPath)
        try { $length = $stream.Length } finally { $stream.Close() }
    } catch {
        throw "ISO '$SeedIsoPath' could not be opened for reading ($($_.Exception.Message))."
    }
    if ($length -le 0) { throw "ISO '$SeedIsoPath' is empty (0 bytes)." }
    $seedDrive = Add-VMDvdDrive -VM $vm -Confirm:$false -Passthru -ErrorAction Stop
    Set-VMDvdDrive -VMDvdDrive $seedDrive -Path $SeedIsoPath -Confirm:$false -ErrorAction Stop

    # Both new drives are DVD-kind; which one ends up first doesn't matter -- UEFI firmware skips a
    # non-bootable disc and falls through, so the seed drive being tried first costs nothing.
    Set-LabVMBootOrder $VMId 'Dvd'

    # Set-LabVMBootOrder only guarantees that SOME DVD-kind entry was recognized and moved first. If
    # only the seed drive's entry was, it still "succeeds", and the real failure (the installer never
    # boots) would surface only as an opaque PowerShell Direct timeout much later. So re-read the
    # applied order and confirm that one of its leading DVD entries is the Linux installer drive.
    $appliedOrder = @((Get-VMFirmware -VM $vm -ErrorAction Stop).BootOrder)
    $linuxEntryFound = $false
    foreach ($entry in $appliedOrder) {
        if ((Get-LabBootEntryKind $entry) -ne 'Dvd') { break }
        $device = $entry
        $deviceProperty = $entry.PSObject.Properties['Device']
        if ($null -ne $deviceProperty -and $null -ne $deviceProperty.Value) { $device = $deviceProperty.Value }
        $pathProperty = $device.PSObject.Properties['Path']
        if ($null -ne $pathProperty -and [string]$pathProperty.Value -eq $LinuxIsoPath) { $linuxEntryFound = $true; break }
    }
    if (-not $linuxEntryFound) {
        throw "'$($vm.Name)': the boot order was set DVD-first, but the Linux installer drive's own boot entry (for '$LinuxIsoPath') was not confirmed among the leading DVD entries, so the VM would likely never boot the installer. Both drives were left attached. Check Firmware > Boot order in Hyper-V Manager."
    }
}

function Complete-LabLinuxProvisioning {
    param([guid]$VMId, [string]$LinuxIsoPath, [string]$SeedIsoPath)
    $vm = Assert-LabVMOff $VMId
    $drives = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
    $seedDrive = @($drives | Where-Object { [string]$_.Path -eq $SeedIsoPath })
    $linuxDrive = @($drives | Where-Object { [string]$_.Path -eq $LinuxIsoPath })
    if ($seedDrive.Count -ne 1 -or $linuxDrive.Count -ne 1) {
        throw "'$($vm.Name)': could not find exactly one DVD drive attached to each of the seed ISO and the Linux ISO (found $($seedDrive.Count) matching the seed path, $($linuxDrive.Count) matching the Linux ISO path). Check the drives manually in Hyper-V Manager."
    }
    # The seed drive (its job was only to deliver the NoCloud user-data/meta-data to the installer) is
    # removed entirely. The installer drive is only ejected, keeping the drive itself in place --
    # matching Remove-LabVMInstallMedia's own "the drive itself stays" behavior.
    Remove-VMDvdDrive -VMDvdDrive $seedDrive[0] -Confirm:$false -ErrorAction Stop
    Set-VMDvdDrive -VMDvdDrive $linuxDrive[0] -Path $null -Confirm:$false -ErrorAction Stop
    Set-LabVMBootOrder $VMId 'Disk'
}

function New-LabEphemeralSshKeyPair {
    # A fresh ed25519 key pair minted by this script itself, never supplied by the operator: the
    # unattended Linux install flow has no existing identity to reuse, so it generates one here, embeds
    # the public half in the NoCloud user-data (New-LabLinuxAutoinstallUserData's AuthorizedKeys), and
    # keeps the private half at a stable path -- never inside the per-VM workspace that is deleted and
    # recreated across runs -- so it survives long enough to become the IdentityFilePath that
    # Set-LabSshConnectionSettings later saves for this VM.
    param([guid]$VMId)
    # ssh-keygen.exe ships with the same Windows OpenSSH Client optional feature as ssh.exe/sftp.exe,
    # so the already-shipped Get-LabSshToolingInfo availability check doubles as this tool's own
    # availability check too, unmodified.
    $tooling = Get-LabSshToolingInfo
    if (-not $tooling.Available) {
        throw 'ssh.exe/sftp.exe (Windows OpenSSH Client) were not found. Install the OpenSSH Client optional feature on this host.'
    }
    $privateKeyPath = Join-Path $env:LOCALAPPDATA "LabVmManager\SshConnections\$VMId.key"
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $privateKeyPath))
    $publicKeyPath = "$privateKeyPath.pub"
    # ssh-keygen.exe prompts to overwrite an existing file, a prompt this fully unattended process could
    # never answer; clear out any stale pair from an earlier run first so that prompt can never occur.
    if ([IO.File]::Exists($privateKeyPath)) { [IO.File]::Delete($privateKeyPath) }
    if ([IO.File]::Exists($publicKeyPath)) { [IO.File]::Delete($publicKeyPath) }
    # Empty passphrase (-N '""'): this key authenticates a fully unattended process with no human ever
    # present to type one in. Its file alone is the secret -- the same trust model
    # Get-LabSshConnectionSettingsPath's own stored IdentityFilePath already assumes for every other
    # VM's identity file. The doubled quotes are deliberate: ssh-keygen.exe on Windows can otherwise
    # drop a genuinely empty -N argument outright.
    & ssh-keygen.exe -t ed25519 -N '""' -f $privateKeyPath -q
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "ssh-keygen.exe exited with code $exitCode while generating an ephemeral key pair at '$privateKeyPath'."
    }
    if (-not ([IO.File]::Exists($privateKeyPath)) -or -not ([IO.File]::Exists($publicKeyPath))) {
        throw "ssh-keygen.exe reported success but the expected key files were not found at '$privateKeyPath' / '$publicKeyPath'."
    }
    return [pscustomobject]@{
        PrivateKeyPath = $privateKeyPath
        PublicKeyContent = (Get-Content -LiteralPath $publicKeyPath -Raw).Trim()
    }
}

function Get-LabSshUserKnownHostsPath {
    # The operator's own per-user known_hosts file: where OpenSSH's default UserKnownHostsFile
    # (~/.ssh/known_hosts) points, and therefore the file the strict SSH functions above check.
    # Win32-OpenSSH resolves '~' to the user's profile folder, the folder GetFolderPath('UserProfile')
    # returns.
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh\known_hosts'
}

function ConvertTo-LabSshOptionPath {
    # Turns a local path into a value for ssh's own '-o UserKnownHostsFile=' option. OpenSSH splits that
    # value on whitespace (it is a list of files), and Windows PowerShell 5.1 cannot pass an embedded
    # double quote to a native command, so a path containing whitespace or a quote cannot be passed
    # safely. A path under the user's profile folder (where a space in the user name is common) is
    # rewritten as '~/...', which OpenSSH expands itself; backslashes become forward slashes, which
    # Win32-OpenSSH accepts. Anything that still contains whitespace, a quote or a control character is
    # refused, never passed on.
    param([string]$Path)
    $profilePath = [Environment]::GetFolderPath('UserProfile').TrimEnd('\')
    $value = $Path
    if (-not [string]::IsNullOrEmpty($profilePath) -and
        $value.StartsWith($profilePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = '~/' + $value.Substring($profilePath.Length + 1)
    }
    $value = $value.Replace('\', '/')
    if ([string]::IsNullOrEmpty($value) -or $value -match '[\s"''\x00-\x1F\x7F]') {
        throw "The path '$Path' cannot be passed to ssh.exe as a known_hosts file: it contains whitespace, a quote or a control character outside the user profile folder."
    }
    return $value
}

function Wait-LabSshSession {
    # Trust-on-first-connect (StrictHostKeyChecking=accept-new) applies ONLY to this function's own
    # probe, and only against the single VM this same plan just created and whose ephemeral key
    # New-LabEphemeralSshKeyPair just minted for it: there is no human at a console yet to approve a
    # brand-new guest's host key fingerprint. Every other SSH connection this script ever makes --
    # Invoke-LabSshCommand, Invoke-LabSftpCommand, Test-LabSshConnection, Add-LabSshKnownHost -- keeps
    # requiring a strict, already-known host key (or Add-LabSshKnownHost's own deliberately interactive
    # confirmation); none of those four functions are touched by this one.
    #
    # How the exception stays scoped to "this VM, proven by its own key":
    # - The identity file is never a parameter. It is derived from $VMId: the exact stable path
    #   New-LabEphemeralSshKeyPair wrote this VM's ephemeral key to. -F none drops the operator's ssh
    #   config (so no IdentityFile, HashKnownHosts or other setting of theirs applies) and
    #   IdentitiesOnly=yes keeps the operator's agent keys out, so the ONLY key ever offered is this
    #   VM's own ephemeral key, and no other host the operator can already log in to can pass the probe.
    # - Two-phase trust commit. Phase 1 (probe): accept-new writes a new host key only to the FIRST
    #   UserKnownHostsFile, which is a fresh scratch file per attempt; the operator's real known_hosts is
    #   listed second, read-only, so a key already trusted there still matches and a CHANGED key there is
    #   still refused. A host that merely answers on port 22 but does not accept our ephemeral key only
    #   ever reaches the scratch file, which is deleted. Phase 2 (commit): only after the probe exits 0
    #   -- this VM's own ephemeral key authenticated against that exact host -- is the single line OpenSSH
    #   itself wrote into the scratch file appended to the real known_hosts. This script relocates a line
    #   OpenSSH authored; it never composes a host key entry itself.
    # - Candidate addresses must parse as IP addresses, the username is validated like every other SSH
    #   value, and the VM must still be Running on every iteration.
    param([guid]$VMId, [string]$UserName, [int]$TimeoutSeconds)
    if (-not (Test-LabSshUserName $UserName)) {
        throw "Invalid SSH username '$UserName': it must not be empty, start with '-', or contain whitespace or control characters."
    }
    $tooling = Get-LabSshToolingInfo
    if (-not $tooling.Available) {
        throw 'ssh.exe/sftp.exe (Windows OpenSSH Client) were not found. Install the OpenSSH Client optional feature on this host.'
    }
    $identityFilePath = Join-Path $env:LOCALAPPDATA "LabVmManager\SshConnections\$VMId.key"
    if (-not [IO.File]::Exists($identityFilePath)) {
        throw "No ephemeral SSH key exists for VM $VMId at '$identityFilePath'. New-LabEphemeralSshKeyPair must create it before the VM's first boot."
    }
    $knownHostsPath = Get-LabSshUserKnownHostsPath
    $knownHostsOption = ConvertTo-LabSshOptionPath $knownHostsPath
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastError = $null
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        # Fails fast with a clear "not Running" error if the VM stopped or crashed mid-wait, the same
        # check Wait-LabPSDirectSession gets through New-LabPSDirectSession.
        $null = Assert-LabVMRunning $VMId
        $candidates = @(Get-LabGuestAddressCandidates $VMId)
        # Guest-reported values reach ssh.exe's command line, so only real IP addresses are used; any
        # other value is skipped (not echoed, not thrown on), like an address that does not answer yet.
        $addresses = @($candidates | Where-Object { $null -ne $_ -and [Net.IPAddress]::TryParse([string]$_, [ref]$null) } |
            ForEach-Object { [string]$_ })
        if ($addresses.Count -eq 0) {
            $lastError = if ($candidates.Count -eq 0) { 'the guest has not reported a network address yet' }
                else { "the guest has not reported a usable IP address yet ($($candidates.Count) non-IP value(s) skipped)" }
            Write-Host "Waiting for SSH ($([int]$watch.Elapsed.TotalSeconds)s elapsed): $lastError"
        }
        foreach ($address in $addresses) {
            $scratchPath = Join-Path ([IO.Path]::GetTempPath()) ('lab-ssh-probe-' + [guid]::NewGuid().ToString('N') + '.known_hosts')
            try {
                [IO.File]::WriteAllText($scratchPath, '')
                $scratchOption = ConvertTo-LabSshOptionPath $scratchPath
                # -n: redirect ssh's stdin from /dev/null, same reasoning as Invoke-LabSshCommand's own
                # KeyAgent branch -- a BatchMode=yes call must never read from this process's own stdin.
                # ConnectTimeout bounds each attempt, so one unresponsive address cannot stall the wait
                # past its timeout. UpdateHostKeys=no: only the one key this connection verified is ever
                # recorded.
                $arguments = @('-n', '-F', 'none',
                    '-o', 'BatchMode=yes',
                    '-o', 'StrictHostKeyChecking=accept-new',
                    '-o', "UserKnownHostsFile=$scratchOption $knownHostsOption",
                    '-o', 'UpdateHostKeys=no',
                    '-o', 'IdentitiesOnly=yes',
                    '-o', 'ConnectTimeout=10',
                    '-i', $identityFilePath,
                    "$UserName@$address", 'exit')
                $exitCode = $null
                $probeOutput = ''
                try {
                    $ErrorActionPreference = 'Continue'
                    $raw = & ssh.exe @arguments 2>&1
                    $exitCode = $LASTEXITCODE
                    $probeOutput = (@($raw | ForEach-Object { [string]$_ } | Where-Object { $_ }) -join ' ')
                } catch {
                    $probeOutput = $_.Exception.Message
                }
                if ($exitCode -eq 0) {
                    # Phase 2: this VM's own key authenticated against this exact host. An empty scratch
                    # file means the real known_hosts already trusted this key, so nothing is added.
                    $verified = @([IO.File]::ReadAllLines($scratchPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    if ($verified.Count -gt 1) {
                        throw "The SSH probe of $address recorded $($verified.Count) host key lines where one was expected; known_hosts was not changed."
                    }
                    if ($verified.Count -eq 1) {
                        $line = $verified[0].Trim()
                        $fields = @($line -split ' ')
                        $names = @(if ($fields.Count -ge 3) { $fields[0].Split(',') })
                        if ($names.Count -eq 0 -or @($names | Where-Object { $_ -ne $address }).Count -gt 0) {
                            throw "The SSH probe of $address recorded a host key line for a different host; known_hosts was not changed."
                        }
                        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $knownHostsPath))
                        $separator = ''
                        if ([IO.File]::Exists($knownHostsPath)) {
                            $existing = [IO.File]::ReadAllText($knownHostsPath)
                            if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { $separator = "`n" }
                        }
                        [IO.File]::AppendAllText($knownHostsPath, $separator + $line + "`n")
                    }
                    return [string]$address
                }
                # A key already saved for this address that no longer matches is refused by OpenSSH
                # (accept-new never replaces a changed key). Retrying cannot fix that, so stop now.
                if ($probeOutput -match 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED') {
                    throw "SSH refused the host key at $address for VM ${VMId}: known_hosts already holds a DIFFERENT key for that address (for example from an earlier VM that used the same address). Clear the old entry with option U, then retry. OpenSSH said: $probeOutput"
                }
                $lastError = if ([string]::IsNullOrEmpty($probeOutput)) { "ssh exited with code $exitCode" } else { $probeOutput }
            } finally {
                if ([IO.File]::Exists($scratchPath)) { [IO.File]::Delete($scratchPath) }
            }
            Write-Host "Waiting for SSH at $UserName@$address ($([int]$watch.Elapsed.TotalSeconds)s elapsed): $lastError"
        }
        Start-Sleep -Seconds 10
    }
    $lastErrorText = if ($null -eq $lastError) { ' No connection attempt was made.' } else { " Last error: $lastError" }
    throw "Timed out after $([int]$watch.Elapsed.TotalSeconds) seconds waiting for an SSH session to come up on VM ${VMId}.$lastErrorText"
}

function Write-LabLinuxProvisioningNote {
    # The Linux counterpart of the already-shipped Write-LabProvisioningNote (which delivers its note
    # over PowerShell Direct's Invoke-Command, Windows-only): this guest has no PowerShell Direct
    # endpoint, so the note travels over SFTP instead. By this point Wait-LabSshSession has already
    # authenticated with this VM's own key and committed the guest's verified host key to known_hosts,
    # so Invoke-LabSftpCommand's own unmodified, always-strict host key check succeeds here without any
    # relaxed setting of its own.
    param([string]$HostNameOrAddress, [string]$UserName, [string]$IdentityFilePath, [string]$Content)
    $localPath = Join-Path ([IO.Path]::GetTempPath()) ('lab-linux-note-' + [guid]::NewGuid().ToString('N') + '.txt')
    $batchPath = Join-Path ([IO.Path]::GetTempPath()) ('lab-linux-note-' + [guid]::NewGuid().ToString('N') + '.batch')
    try {
        [IO.File]::WriteAllText($localPath, $Content)
        # sftp's batch parser treats '\' as an escape character, so the local path uses forward slashes
        # (the same convention as the transfer code). The remote path is relative: sftp starts in the
        # user's home directory, and an older client may send '~' literally instead of expanding it.
        # '-mkdir': the leading '-' lets the batch continue when Desktop already exists.
        $batch = "-mkdir Desktop`nput `"$($localPath.Replace('\', '/'))`" `"Desktop/lab-vm-manager-provisioning-note.txt`"`n"
        [IO.File]::WriteAllText($batchPath, $batch)
        $result = Invoke-LabSftpCommand $HostNameOrAddress 22 $UserName $IdentityFilePath $batchPath 'KeyAgent'
        if ($result.ExitCode -ne 0) {
            $reason = @($result.Output | Where-Object { $_ -and $_ -notmatch '^sftp>' } | Select-Object -Last 3) -join ' '
            $reasonText = if ($reason) { ": $reason" } else { '' }
            throw "Delivering the provisioning note to $UserName@${HostNameOrAddress} failed (sftp exit code $($result.ExitCode))$reasonText."
        }
    } finally {
        if ([IO.File]::Exists($localPath)) { [IO.File]::Delete($localPath) }
        if ([IO.File]::Exists($batchPath)) { [IO.File]::Delete($batchPath) }
    }
}

function Set-LabVMBootOrder {
    param([guid]$VMId, [ValidateSet('Dvd', 'Disk')][string]$Preference)
    # Deliberately generic: puts the chosen device class first without deleting any other existing
    # boot-order entry, so the Windows/Linux unattended-install plans can reuse this for "swap back to
    # disk-first after the installer's first reboot", not just this plan's "DVD first" need.
    $vm = Assert-LabVMOff $VMId
    $firmware = Get-VMFirmware -VM $vm -ErrorAction Stop
    $currentOrder = @($firmware.BootOrder)
    $preferred = @($currentOrder | Where-Object { (Get-LabBootEntryKind $_) -eq $Preference })
    $rest = @($currentOrder | Where-Object { (Get-LabBootEntryKind $_) -ne $Preference })
    if ($preferred.Count -eq 0) {
        # Fail loudly rather than "succeed" with an unchanged order the operator would assume was set.
        throw "'$($vm.Name)': no $Preference entry was recognized in the firmware boot order, so it was left unchanged. Check Firmware > Boot order in Hyper-V Manager and set it manually."
    }
    $newOrder = @($preferred + $rest)
    Set-VMFirmware -VM $vm -BootOrder $newOrder -Confirm:$false -ErrorAction Stop
}

function Set-LabVMUnattendedInstallMedia {
    param([guid]$VMId, [string]$WindowsIsoPath, [string]$SeedIsoPath)
    # Unlike Set-LabVMInstallMedia (manual-install flow, reuses/adds a single drive on a VM that may
    # already have one), this is only ever called against a VM this plan just created itself: zero
    # existing DVD drives, so there is no "choose among several drives" ambiguity to handle.
    $vm = Assert-LabVMOff $VMId
    if ([int]$vm.Generation -ne 2) {
        throw "'$($vm.Name)' is Generation $($vm.Generation). Unattended Windows install requires Generation 2."
    }
    $drives = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
    if ($drives.Count -gt 0) {
        throw "'$($vm.Name)' already has $($drives.Count) DVD drive(s) attached; this function is for a freshly created VM with none yet."
    }

    # Re-validate the Windows ISO immediately before attaching it -- not once up front for both -- so
    # a problem with the Windows ISO is caught before anything is touched at all.
    if (-not (Test-Path -LiteralPath $WindowsIsoPath -PathType Leaf)) {
        throw "ISO '$WindowsIsoPath' no longer exists."
    }
    try {
        $stream = [IO.File]::OpenRead($WindowsIsoPath)
        try { $length = $stream.Length } finally { $stream.Close() }
    } catch {
        throw "ISO '$WindowsIsoPath' could not be opened for reading ($($_.Exception.Message))."
    }
    if ($length -le 0) { throw "ISO '$WindowsIsoPath' is empty (0 bytes)." }
    $windowsDrive = Add-VMDvdDrive -VM $vm -Confirm:$false -Passthru -ErrorAction Stop
    Set-VMDvdDrive -VMDvdDrive $windowsDrive -Path $WindowsIsoPath -Confirm:$false -ErrorAction Stop

    # Re-validate the seed ISO immediately before attaching it, too -- so a problem with the seed ISO
    # is caught before the Windows drive above is touched, except that the Windows drive already was:
    # a seed-ISO failure here is reported with that drive left attached, not rolled back.
    if (-not (Test-Path -LiteralPath $SeedIsoPath -PathType Leaf)) {
        throw "ISO '$SeedIsoPath' no longer exists."
    }
    try {
        $stream = [IO.File]::OpenRead($SeedIsoPath)
        try { $length = $stream.Length } finally { $stream.Close() }
    } catch {
        throw "ISO '$SeedIsoPath' could not be opened for reading ($($_.Exception.Message))."
    }
    if ($length -le 0) { throw "ISO '$SeedIsoPath' is empty (0 bytes)." }
    $seedDrive = Add-VMDvdDrive -VM $vm -Confirm:$false -Passthru -ErrorAction Stop
    Set-VMDvdDrive -VMDvdDrive $seedDrive -Path $SeedIsoPath -Confirm:$false -ErrorAction Stop

    # Both new drives are DVD-kind; which one ends up first doesn't matter -- UEFI firmware skips a
    # non-bootable disc and falls through, so the seed drive being tried first costs nothing.
    Set-LabVMBootOrder $VMId 'Dvd'

    # Set-LabVMBootOrder only guarantees that SOME DVD-kind entry was recognized and moved first. If
    # only the seed drive's entry was, it still "succeeds", and the real failure (the installer never
    # boots) would surface only as an opaque PowerShell Direct timeout much later. So re-read the
    # applied order and confirm that one of its leading DVD entries is the Windows installer drive.
    $appliedOrder = @((Get-VMFirmware -VM $vm -ErrorAction Stop).BootOrder)
    $windowsEntryFound = $false
    foreach ($entry in $appliedOrder) {
        if ((Get-LabBootEntryKind $entry) -ne 'Dvd') { break }
        $device = $entry
        $deviceProperty = $entry.PSObject.Properties['Device']
        if ($null -ne $deviceProperty -and $null -ne $deviceProperty.Value) { $device = $deviceProperty.Value }
        $pathProperty = $device.PSObject.Properties['Path']
        if ($null -ne $pathProperty -and [string]$pathProperty.Value -eq $WindowsIsoPath) { $windowsEntryFound = $true; break }
    }
    if (-not $windowsEntryFound) {
        throw "'$($vm.Name)': the boot order was set DVD-first, but the Windows installer drive's own boot entry (for '$WindowsIsoPath') was not confirmed among the leading DVD entries, so the VM would likely never boot the installer. Both drives were left attached. Check Firmware > Boot order in Hyper-V Manager."
    }
}

function Complete-LabWindowsProvisioning {
    param([guid]$VMId, [string]$WindowsIsoPath, [string]$SeedIsoPath)
    $vm = Assert-LabVMOff $VMId
    $drives = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
    $seedDrive = @($drives | Where-Object { [string]$_.Path -eq $SeedIsoPath })
    $windowsDrive = @($drives | Where-Object { [string]$_.Path -eq $WindowsIsoPath })
    if ($seedDrive.Count -ne 1 -or $windowsDrive.Count -ne 1) {
        throw "'$($vm.Name)': could not find exactly one DVD drive attached to each of the seed ISO and the Windows ISO (found $($seedDrive.Count) matching the seed path, $($windowsDrive.Count) matching the Windows ISO path). Check the drives manually in Hyper-V Manager."
    }
    # The seed drive (its job was only to deliver the unattend answer file/first-boot script) is
    # removed entirely. The installer drive is only ejected, keeping the drive itself in place --
    # matching Remove-LabVMInstallMedia's own "the drive itself stays" behavior.
    Remove-VMDvdDrive -VMDvdDrive $seedDrive[0] -Confirm:$false -ErrorAction Stop
    Set-VMDvdDrive -VMDvdDrive $windowsDrive[0] -Path $null -Confirm:$false -ErrorAction Stop
    Set-LabVMBootOrder $VMId 'Disk'
}

function New-LabWindowsAnswerFileXml {
    # Pure string builder: no I/O, no COM, no Hyper-V. Its only job is to hand back a well-formed
    # Windows unattend.xml answer file for Task 6's orchestrator to write into the seed ISO via
    # New-LabSeedIso. Partition layout (EFI system partition + MSR + a single primary OS partition
    # filling the rest of the disk) is the standard whole-disk UEFI/GPT shape for a single-disk
    # Gen2 VM -- no separate Windows RE partition, since nothing here needs to recover this VM.
    # The windowsPE pass carries International-Core-WinPE as well as the oobeSystem pass's
    # International-Core, so Setup's own language/keyboard page is answered too, not just OOBE's.
    param(
        [string]$ComputerName,
        [string]$Locale,
        [string]$TimeZone,
        [int]$ImageIndex,
        [string]$UserName,
        [securestring]$Password,
        [string]$ProductKey = ''
    )
    # The SecureString is decrypted to plaintext only in this narrow scope, for exactly as long as
    # it takes to interpolate it into the XML below, then the unmanaged memory holding it is
    # explicitly zeroed and freed in the finally -- never logged, never written anywhere by this
    # function itself.
    $passwordPtr = [IntPtr]::Zero
    try {
        $passwordPtr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($passwordPtr)
        $escapedComputerName = [Security.SecurityElement]::Escape($ComputerName)
        $escapedLocale = [Security.SecurityElement]::Escape($Locale)
        $escapedTimeZone = [Security.SecurityElement]::Escape($TimeZone)
        $escapedUserName = [Security.SecurityElement]::Escape($UserName)
        $escapedPassword = [Security.SecurityElement]::Escape($plainPassword)
        $escapedProductKey = [Security.SecurityElement]::Escape($ProductKey)
        # Default (empty): no <ProductKey> element at all, no activation -- the exact pre-existing
        # behavior for every caller that does not opt in. Non-empty: adds a ProductKey block with
        # WillShowUI=OnError, which also suppresses a possible Setup product-key prompt on some
        # multi-edition ISOs without activating anything (see MANUAL-TESTS.md).
        $productKeyElement = if ($ProductKey -ne '') {
            @"

                <ProductKey>
                    <Key>$escapedProductKey</Key>
                    <WillShowUI>OnError</WillShowUI>
                </ProductKey>
"@
        } else { '' }
        if ($productKeyElement -ne '') { $productKeyElement = $productKeyElement.TrimEnd("`r", "`n") }
        return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>$escapedLocale</UILanguage>
            </SetupUILanguage>
            <InputLocale>$escapedLocale</InputLocale>
            <SystemLocale>$escapedLocale</SystemLocale>
            <UILanguage>$escapedLocale</UILanguage>
            <UserLocale>$escapedLocale</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Type>EFI</Type>
                            <Size>300</Size>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>2</Order>
                            <Type>MSR</Type>
                            <Size>128</Size>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>3</Order>
                            <Type>Primary</Type>
                            <Extend>true</Extend>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                            <Label>System</Label>
                            <Format>FAT32</Format>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>2</Order>
                            <PartitionID>2</PartitionID>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>3</Order>
                            <PartitionID>3</PartitionID>
                            <Label>Windows</Label>
                            <Format>NTFS</Format>
                            <Letter>C</Letter>
                        </ModifyPartition>
                    </ModifyPartitions>
                </Disk>
            </DiskConfiguration>
            <UserData>
                <AcceptEula>true</AcceptEula>$productKeyElement
            </UserData>
            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/INDEX</Key>
                            <Value>$ImageIndex</Value>
                        </MetaData>
                    </InstallFrom>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>3</PartitionID>
                    </InstallTo>
                </OSImage>
            </ImageInstall>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>$escapedComputerName</ComputerName>
            <TimeZone>$escapedTimeZone</TimeZone>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Name>$escapedUserName</Name>
                        <Group>Administrators</Group>
                        <Password>
                            <Value>$escapedPassword</Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>$escapedUserName</Username>
                <Password>
                    <Value>$escapedPassword</Value>
                    <PlainText>true</PlainText>
                </Password>
            </AutoLogon>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>$escapedLocale</InputLocale>
            <SystemLocale>$escapedLocale</SystemLocale>
            <UILanguage>$escapedLocale</UILanguage>
            <UserLocale>$escapedLocale</UserLocale>
        </component>
    </settings>
</unattend>
"@
    } finally {
        if ($passwordPtr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($passwordPtr)
        }
    }
}

function Wait-LabPSDirectSession {
    # Polls the already-shipped New-LabPSDirectSession (not a raw New-PSSession call) on each
    # attempt: if the VM's state changes mid-wait (e.g. it stops unexpectedly), Assert-LabVMRunning
    # inside that call surfaces a clear "not Running" error instead of a confusing raw connection
    # failure. The caller owns the returned session and is responsible for Remove-PSSession.
    param([guid]$VMId, [PSCredential]$Credential, [int]$TimeoutSeconds)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastError = $null
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            return New-LabPSDirectSession $VMId $Credential
        } catch {
            $lastError = $_
            # New-PSSession -VMId's own raw error text is accurate but easy to misread as a real
            # failure while this is actually expected, normal waiting. Two specific, well-understood
            # transient states get a calibrated explanation instead; anything else shows the raw
            # message unchanged, so a genuinely unexpected error is never hidden behind generic text.
            # The final timeout error (below) still carries the exact raw message either way, for
            # real diagnosis if this never resolves.
            $rawMessage = $_.Exception.Message
            $shownMessage = switch -Regex ($rawMessage) {
                'remote session might have ended' {
                    'Windows is not far enough along yet to accept a PowerShell Direct connection (still booting or installing). This is expected.'
                    break
                }
                'credential is invalid' {
                    'the account exists but may still be finishing first-logon setup; this is expected for a while after the first sign-in.'
                    break
                }
                default { $rawMessage }
            }
            Write-Host "Waiting for PowerShell Direct to come up ($([int]$watch.Elapsed.TotalSeconds)s elapsed): $shownMessage"
            Start-Sleep -Seconds 10
        }
    }
    # The per-attempt lines above scroll away during a long wait; the last specific failure is the
    # operator's only diagnostic clue, so it is carried into the final error itself.
    $lastErrorText = if ($null -eq $lastError) { ' No connection attempt was made.' } else { " Last error: $($lastError.Exception.Message)" }
    throw "Timed out after $([int]$watch.Elapsed.TotalSeconds) seconds waiting for a PowerShell Direct session to open. The guest may still be booting or applying the unattend answer file; retry once it has settled.$lastErrorText"
}

function Write-LabProvisioningNote {
    # Delivers $Content to a fixed file name on the connected account's own Desktop. The path is
    # resolved INSIDE the session (via Invoke-Command) so [Environment]::GetFolderPath('Desktop')
    # answers for the guest account, not for whatever account is running this script on the host.
    param([System.Management.Automation.Runspaces.PSSession]$Session, [string]$Content)
    Invoke-Command -Session $Session -ScriptBlock {
        param($Text)
        $path = Join-Path ([Environment]::GetFolderPath('Desktop')) 'lab-vm-manager-provisioning-note.txt'
        Set-Content -LiteralPath $path -Value $Text -Encoding UTF8
    } -ArgumentList $Content
}

function Format-LabBootEntry {
    param($Entry)
    $kind = Get-LabBootEntryKind $Entry
    $device = $Entry
    $deviceProperty = $Entry.PSObject.Properties['Device']
    if ($null -ne $deviceProperty -and $null -ne $deviceProperty.Value) { $device = $deviceProperty.Value }
    $detail = [string](Get-LabProperty $device 'Path' '')
    if ([string]::IsNullOrEmpty($detail)) { $detail = [string](Get-LabProperty $Entry 'Description' '') }
    if ([string]::IsNullOrEmpty($detail)) { $detail = [string](Get-LabProperty $device 'Name' '') }
    if ($kind -eq 'Dvd' -and [string]::IsNullOrEmpty([string](Get-LabProperty $device 'Path' ''))) { $detail = '(no media)' }
    return ('{0} [{1}] {2}' -f $kind, $device.GetType().Name, $detail).TrimEnd()
}

function Show-LabVMInstallMediaConfiguration {
    param([guid]$VMId)
    # Read-only: nothing here changes the VM, so this is the one sub-action offered under -ReadOnly.
    $vm = Get-LabVM $VMId
    Write-Host "--- Installation media: $($vm.Name) | Generation $($vm.Generation) | $($vm.State) ---"
    $drives = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
    if ($drives.Count -eq 0) { Write-Host 'DVD drives: none.' }
    else {
        $drives | Select-Object ControllerType, ControllerNumber, ControllerLocation,
            @{n='Media'; e={ $p = [string](Get-LabProperty $_ 'Path' ''); if ($p) { $p } else { '(empty)' } }} |
            Format-Table -AutoSize -Wrap | Out-Host
        if ($drives.Count -gt 1) {
            Write-Host 'More than one DVD drive: this version cannot choose among them for attach/eject.'
        }
    }
    $recordPath = Get-LabVMInstallMediaPath $VMId
    if ([IO.File]::Exists($recordPath)) {
        try {
            $record = Get-Content -LiteralPath $recordPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $previous = [string](Get-LabProperty $record 'PreviousAttachment' '')
            if ([string]::IsNullOrEmpty($previous)) { $previous = '(empty)' }
            Write-Host "Attachment before this tool last attached an ISO: $previous"
        } catch { Write-Warning "Could not read the previous-attachment record '$recordPath': $($_.Exception.Message)" }
    }
    if ([int]$vm.Generation -ne 2) {
        Write-Host 'Generation 1 VM: Secure Boot, vTPM and the UEFI boot order do not apply.'
        return
    }
    $firmware = Get-VMFirmware -VM $vm -ErrorAction Stop
    Write-Host "Secure Boot: $(Get-LabProperty $firmware 'SecureBoot' '-'); template: $(Get-LabProperty $firmware 'SecureBootTemplate' '-')"
    # Each security sub-read is guarded on its own: the inspect view must never die part-way on one.
    try { $tpm = Get-LabProperty (Get-VMSecurity -VM $vm -ErrorAction Stop) 'TpmEnabled' '-' } catch { $tpm = 'unknown' }
    try { $keyProtector = Test-LabVMHasKeyProtector $VMId } catch { $keyProtector = "unknown ($($_.Exception.Message))" }
    Write-Host "Key protector configured: $keyProtector; vTPM enabled: $tpm"
    Write-Host 'Firmware boot order (persistent; checked on every boot):'
    $order = @($firmware.BootOrder)
    if ($order.Count -eq 0) { Write-Host '  (empty)' }
    for ($i = 0; $i -lt $order.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), (Format-LabBootEntry $order[$i])) }
}

function Get-LabVMInstallationMediaPreview {
    param([guid]$VMId, [ValidateSet('Windows11', 'UbuntuDesktop')][string]$OsProfile, [string]$IsoPath)
    # READ-ONLY. This runs before the operator confirms anything, so every fact here comes from a
    # Get-* cmdlet or a file-system read. In particular the encryption warning is decided by the
    # read-only Test-LabVMHasKeyProtector, never by running the boot-profile apply step to find out.
    $vm = Get-LabVM $VMId
    $drives = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
    $firmware = Get-VMFirmware -VM $vm -ErrorAction Stop
    $order = @($firmware.BootOrder)
    # With exactly one DVD drive, its boot entry already exists, so whether the DVD-first step can
    # recognize it is checked NOW, with the same classifier that step uses, rather than after the boot
    # profile and media have already been applied. With no drive yet, the entry only appears once the
    # drive is added, so it can only be verified at that last step ($null here).
    $dvdBootEntryRecognized = $null
    $dvdPlan = if ($drives.Count -eq 0) { 'A new DVD drive will be added (none exists yet); its firmware boot entry is verified at the last step.' }
        elseif ($drives.Count -eq 1) {
            $dvdBootEntryRecognized = (@($order | Where-Object { (Get-LabBootEntryKind $_) -eq 'Dvd' }).Count -gt 0)
            $current = [string](Get-LabProperty $drives[0] 'Path' '')
            'The existing DVD drive ({0} {1}:{2}) will be used; current media: {3}.' -f
                (Get-LabProperty $drives[0] 'ControllerType' '?'), (Get-LabProperty $drives[0] 'ControllerNumber' '?'),
                (Get-LabProperty $drives[0] 'ControllerLocation' '?'), $(if ($current) { $current } else { '(empty)' })
        } else { 'More than one DVD drive exists; this version cannot choose among them.' }

    # Mirrors the boot-profile apply step's own decisions so the preview states exactly what it will do.
    $hasKeyProtector = Test-LabVMHasKeyProtector $VMId
    $currentTemplate = [string](Get-LabProperty $firmware 'SecureBootTemplate' '')
    $secureBootState = [string](Get-LabProperty $firmware 'SecureBoot' '')
    $profileChanges = [Collections.Generic.List[string]]::new()
    $targetTemplate = if ($OsProfile -eq 'Windows11') { 'MicrosoftWindows' } else { 'MicrosoftUEFICertificateAuthority' }
    if ($currentTemplate -ne $targetTemplate) {
        $profileChanges.Add("Secure Boot template: '$currentTemplate' -> '$targetTemplate'.")
    }
    # The template alone is not protection: Secure Boot itself must be on (same test as the apply step).
    if ($secureBootState -ne 'On') {
        $shownState = if ([string]::IsNullOrEmpty($secureBootState)) { '(unknown)' } else { $secureBootState }
        $profileChanges.Add("Secure Boot: $shownState -> On.")
    }
    if ($OsProfile -eq 'Windows11' -and -not $hasKeyProtector) {
        $profileChanges.Add('A new local key protector will be created and vTPM enabled.')
    }
    try { $tpmEnabled = Get-LabProperty (Get-VMSecurity -VM $vm -ErrorAction Stop) 'TpmEnabled' $null } catch { $tpmEnabled = $null }
    $firstBoot = if ($order.Count -gt 0) { Format-LabBootEntry $order[0] } else { '(empty)' }

    # Existing-data check: real checkpoints and real on-disk sizes, never names. A differencing disk's
    # parent chain is followed, since the attached file alone can be tiny while its parent holds an OS.
    $thresholdBytes = 256MB
    $reasons = [Collections.Generic.List[string]]::new()
    $checkpointCount = @(Get-VMSnapshot -VM $vm -ErrorAction Stop).Count
    if ($checkpointCount -gt 0) { $reasons.Add("The VM has $checkpointCount checkpoint(s).") }
    foreach ($disk in @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)) {
        $diskPath = [string](Get-LabProperty $disk 'Path' '')
        if ([string]::IsNullOrEmpty($diskPath)) {
            $reasons.Add("A physical/pass-through disk is attached (disk number $(Get-LabProperty $disk 'DiskNumber' '?')); its contents cannot be sized here.")
            continue
        }
        $total = [long]0
        $current = $diskPath
        $measured = $true
        for ($depth = 0; -not [string]::IsNullOrEmpty($current); $depth++) {
            if ($depth -ge 64 -or -not [IO.File]::Exists($current)) { $measured = $false; break }
            $total += ([IO.FileInfo]::new($current)).Length
            try { $current = [string](Get-LabProperty (Get-VHD -Path $current -ErrorAction Stop) 'ParentPath' '') }
            catch { $measured = $false; break }
        }
        if (-not $measured) { $reasons.Add("Virtual disk '$diskPath' (or its parent chain) could not be measured.") }
        elseif ($total -ge $thresholdBytes) {
            $reasons.Add(("Virtual disk '{0}' already uses {1:N1} GiB on disk." -f $diskPath, ($total / 1GB)))
        }
    }

    return [pscustomobject]@{
        VMName = $vm.Name
        OsProfile = $OsProfile
        IsoPath = $IsoPath
        DvdDriveCount = $drives.Count
        DvdPlan = $dvdPlan
        DvdBootEntryRecognized = $dvdBootEntryRecognized
        SecureBootState = $secureBootState
        BootProfileChanges = [string[]]$profileChanges.ToArray()
        HasKeyProtector = $hasKeyProtector
        TpmEnabled = $tpmEnabled
        CurrentFirstBoot = $firstBoot
        CheckpointCount = $checkpointCount
        ExistingDataRisk = ($reasons.Count -gt 0)
        ExistingDataReasons = [string[]]$reasons.ToArray()
    }
}

function Set-LabVMInstallationMediaInteractive {
    param([guid]$VMId)
    # Self-gating, like New-LabVM, but narrower: the menu wrapper lets this run under -ReadOnly because
    # it has a genuinely read-only sub-action, so this function itself refuses everything else there.
    # Under $script:LabReadOnly it never prompts for an OS profile, an ISO, attach or eject.
    if ($script:LabReadOnly) {
        Write-Host 'Read-only mode: showing the current DVD/boot configuration only; attach, eject and boot-profile changes are disabled.'
        Show-LabVMInstallMediaConfiguration $VMId
        return 'NO_CHANGE'
    }
    while ($true) {
        Write-Host @'
  A  Attach an installer ISO and prepare the VM to boot it   [requires Off]
  E  Eject the current DVD media                             [requires Off]
  I  Inspect current DVD/boot configuration (read-only)
  B  Back
'@
        $choice = (Read-LabText 'Installation media').ToUpperInvariant()
        if ($choice -eq 'I') { Show-LabVMInstallMediaConfiguration $VMId; return 'NO_CHANGE' }
        if ($choice -eq 'B' -or $choice -eq '') { return 'CANCELLED' }
        if ($choice -eq 'E') {
            $vm = Assert-LabVMOff $VMId
            $drives = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
            if ($drives.Count -gt 1) {
                Write-Warning "'$($vm.Name)': more than one DVD drive exists; this version doesn't choose among them. Eject the ISO manually in Hyper-V Manager."
                return 'CANCELLED'
            }
            $attached = if ($drives.Count -eq 1) { [string](Get-LabProperty $drives[0] 'Path' '') } else { '' }
            if ([string]::IsNullOrEmpty($attached)) { Write-Host 'No media is attached; nothing to eject.'; return 'NO_CHANGE' }
            Write-Host "Eject '$attached' from '$($vm.Name)'. The DVD drive itself stays; the firmware boot order is not changed (an empty DVD entry is skipped at boot)."
            if ((Read-LabYesNoCancel 'Eject now?') -ne 'Y') { return 'CANCELLED' }
            Remove-LabVMInstallMedia $VMId
            Write-LabAudit 'eject-install-media' 'COMPLETED' $vm ("Ejected={0}; DvdDriveKept=True; BootOrderChanged=False" -f $attached)
            Write-Host 'Media ejected.'
            return 'COMPLETED'
        }
        if ($choice -eq 'A') { break }
        Write-Host 'Choose A, E, I or B.'
    }

    # --- Attach: gather choices, then a READ-ONLY preview; nothing below changes the VM until confirmed.
    $vm = Assert-LabVMOff $VMId
    if ([int]$vm.Generation -ne 2) {
        Write-Warning "'$($vm.Name)' is Generation $($vm.Generation). Secure Boot and vTPM boot profiles require Generation 2; nothing was changed."
        return 'CANCELLED'
    }
    $osProfile = $null
    while ($null -eq $osProfile) {
        $answer = Read-LabText 'OS profile: 1 Windows11; 2 UbuntuDesktop; B cancel'
        if ($answer -eq '1') { $osProfile = 'Windows11' }
        elseif ($answer -eq '2') { $osProfile = 'UbuntuDesktop' }
        elseif ($answer -ieq 'B' -or $answer -eq '') { return 'CANCELLED' }
        else { Write-Host 'Choose 1, 2 or B.' }
    }
    $isoPath = Select-LabIsoPath $script:LabIsoRoot
    if ($null -eq $isoPath) { return 'CANCELLED' }

    $preview = Get-LabVMInstallationMediaPreview $VMId $osProfile $isoPath
    if ($preview.DvdDriveCount -gt 1) {
        Write-Warning "'$($preview.VMName)': more than one DVD drive exists; this version doesn't choose among them. Attach the ISO manually in Hyper-V Manager. Nothing was changed."
        return 'CANCELLED'
    }
    if ($preview.DvdDriveCount -eq 1 -and $preview.DvdBootEntryRecognized -eq $false) {
        # Refuse now rather than apply the boot profile and media and only then fail at the boot-order step.
        Write-Warning "'$($preview.VMName)': the existing DVD drive has no recognizable entry in the firmware boot order, so DVD-first could not be set. Check Firmware > Boot order in Hyper-V Manager (and run I to see the entries). Nothing was changed."
        return 'CANCELLED'
    }
    Write-Host "`n=== Installation media preview (nothing has been changed yet) ==="
    Write-Host "Target VM:   $($preview.VMName) [$VMId]"
    Write-Host "OS profile:  $($preview.OsProfile)"
    Write-Host "ISO:         $($preview.IsoPath)"
    Write-Host "DVD drive:   $($preview.DvdPlan)"
    if ($preview.BootProfileChanges.Count -eq 0) { Write-Host 'Boot profile: already matches; no Secure Boot/vTPM change.' }
    else { Write-Host 'Boot profile changes:'; foreach ($line in $preview.BootProfileChanges) { Write-Host "  - $line" } }
    if ($preview.OsProfile -eq 'Windows11' -and $preview.HasKeyProtector -and $preview.TpmEnabled -eq $false) {
        Write-Host '  - Note: a key protector exists but vTPM is disabled; it is left as-is (never rotated), so enable vTPM manually if Windows 11 setup needs it.'
    }
    Write-Host 'Boot order:  DVD will be moved to the FIRST position in the firmware boot order. This is a'
    Write-Host '             PERSISTENT firmware preference, not a one-time boot: it applies to every later boot'
    Write-Host "             until changed back. Currently first: $($preview.CurrentFirstBoot)"
    if ($preview.HasKeyProtector) {
        Write-Warning ('This VM already has encryption-related state configured (a key protector exists). Security/firmware ' +
            'changes on an already-encrypted guest (e.g. BitLocker) can require recovery material (a recovery key) at next boot. ' +
            'Make sure you have it before continuing.')
    }
    if ($preview.ExistingDataRisk) {
        Write-Warning 'This VM may already contain an operating system or data. Booting installer media can overwrite it:'
        foreach ($reason in $preview.ExistingDataReasons) { Write-Host "  - $reason" }
        Write-Host 'Consider taking a Checkpoint (menu 5) or a full export (menu 9) first.'
    }

    if ((Read-LabYesNoCancel 'Apply these changes') -ne 'Y') { return 'CANCELLED' }
    if ($preview.ExistingDataRisk) {
        # Extra, typed confirmation that defaults to cancel: anything but the exact phrase cancels.
        Write-Host 'Existing data may be overwritten. A second, explicit confirmation is required.'
        if (-not (Confirm-LabText "INSTALL OVER $($preview.VMName)")) { return 'CANCELLED' }
    }

    # --- Apply, in this order. Each function re-asserts the VM is Off before it changes anything.
    $done = [Collections.Generic.List[string]]::new()
    try {
        $profileResult = Set-LabVMBootProfile $VMId $osProfile
        $done.Add(('boot profile (template changed: {0}; Secure Boot turned on: {1}; key protector added: {2}; vTPM enabled: {3})' -f
            $profileResult.SecureBootTemplateChanged, $profileResult.SecureBootEnabled, $profileResult.KeyProtectorAdded, $profileResult.TpmEnabled))
        if ($profileResult.KeyProtectorAdded -or $profileResult.TpmEnabled) {
            # Security-relevant and hard to undo: recorded on its own, immediately, so the audit log
            # shows it even if a later step (media, boot order) fails.
            Write-LabAudit 'add-key-protector' 'COMPLETED' $vm ("OsProfile={0}; NewLocalKeyProtector={1}; VTpmEnabled={2}" -f
                $osProfile, $profileResult.KeyProtectorAdded, $profileResult.TpmEnabled)
        }
        $mediaResult = Set-LabVMInstallMedia $VMId $isoPath
        $previous = if ([string]::IsNullOrEmpty($mediaResult.PreviousAttachment)) { '(empty)' } else { $mediaResult.PreviousAttachment }
        $done.Add(('ISO attached (DVD drive added: {0}; previous media: {1})' -f $mediaResult.DvdDriveAdded, $previous))
        Set-LabVMBootOrder $VMId 'Dvd'
        $done.Add('DVD first in firmware boot order')
    } catch {
        $completedText = if ($done.Count -eq 0) { 'none' } else { $done -join '; ' }
        throw "Installation media setup stopped partway: $($_.Exception.Message) Steps already applied: $completedText. Use I to inspect the VM before retrying."
    }
    Write-LabAudit 'attach-install-media' 'COMPLETED' $vm (("OsProfile={0}; Iso={1}; SecureBootTemplateChanged={2}; SecureBootEnabled={3}; " +
        "KeyProtectorAdded={4}; VTpmEnabled={5}; DvdDriveAdded={6}; PreviousMedia={7}; BootOrder=DvdFirst") -f
        $osProfile, $isoPath, $profileResult.SecureBootTemplateChanged, $profileResult.SecureBootEnabled,
        $profileResult.KeyProtectorAdded, $profileResult.TpmEnabled, $mediaResult.DvdDriveAdded, $previous)
    foreach ($line in $done) { Write-Host "Done: $line" }
    Write-Host 'Start the VM to boot the installer. No OS is installed automatically by this action.'
    return 'COMPLETED'
}

# --- Windows unattended install, Task 6: "Provision Windows VM" orchestrator ---
function ConvertTo-LabLocalAccountName {
    param([PSCredential]$Credential)
    # The answer file creates a LOCAL account, so a 'COMPUTER\' or '.\' prefix the operator typed is
    # dropped for the account name; the credential itself is used unchanged for PowerShell Direct.
    $userName = [string]$Credential.UserName
    $accountName = $userName.Substring($userName.LastIndexOf('\') + 1)
    if ($accountName.Length -lt 1 -or $accountName.Length -gt 20 -or $accountName -ne $accountName.Trim() -or
        $accountName -match '["/\\\[\]:;|=,+*?<>@\x00-\x1F]' -or $accountName -match '^\.+$') {
        throw "Guest account name '$accountName' is not a valid local Windows account name: 1-20 characters, no leading/trailing spaces, none of `" / \ [ ] : ; | = , + * ? < > @."
    }
    if ($Credential.Password.Length -eq 0) {
        throw 'The guest account password must not be empty: the new account signs in through PowerShell Direct with it.'
    }
    return $accountName
}

function Select-LabWindowsEdition {
    param([object[]]$Images, [AllowNull()][AllowEmptyString()][string]$OsEdition, [bool]$NonInteractive)
    # Only Windows 11 client editions are ever offered; anything else on the ISO cannot be chosen.
    # Returns the chosen image object, or $null if the operator cancelled the picker.
    $choices = @($Images | Where-Object IsWindows11Client | Sort-Object Index)
    $available = ($choices | ForEach-Object { "'$($_.Name)'" }) -join ', '
    if (-not [string]::IsNullOrWhiteSpace($OsEdition)) {
        # A full image name ('Windows 11 Pro') or its short form ('Pro'), case-insensitive, exact.
        $wanted = $OsEdition.Trim()
        $match = @($choices | Where-Object { $_.Name -ieq $wanted -or ($_.Name -replace '^Windows 11 ', '') -ieq $wanted })
        if ($match.Count -eq 1) { return $match[0] }
        if ($NonInteractive) { throw "Edition '$OsEdition' is not one of this ISO's Windows 11 client editions. Available: $available." }
        Write-Host "Edition '$OsEdition' is not one of this ISO's Windows 11 client editions. Choose one of these instead."
    }
    $defaultIndex = -1
    for ($i = 0; $i -lt $choices.Count; $i++) {
        if ($choices[$i].Name -match '(^|\s)Pro$') { $defaultIndex = $i; break }
    }
    if ($NonInteractive) {
        if ($defaultIndex -ge 0) { return $choices[$defaultIndex] }
        if ($choices.Count -eq 1) { return $choices[0] }
        throw "Supply -OsEdition: this ISO has several Windows 11 client editions and no 'Pro' edition to default to. Available: $available."
    }
    $rows = for ($i = 0; $i -lt $choices.Count; $i++) {
        [pscustomobject]@{ No = $i + 1; Edition = $choices[$i].Name; ImageIndex = $choices[$i].Index
            Build = $choices[$i].BuildNumber; Default = $(if ($i -eq $defaultIndex) { '*' } else { '' }) }
    }
    $rows | Format-Table -AutoSize | Out-Host
    $prompt = if ($defaultIndex -ge 0) { "Edition number (blank = $($defaultIndex + 1), $($choices[$defaultIndex].Name)); B cancel" }
        else { 'Edition number; B cancel' }
    while ($true) {
        $answer = Read-LabText $prompt
        if ($answer -ieq 'B') { return $null }
        if ($answer -eq '' -and $defaultIndex -ge 0) { return $choices[$defaultIndex] }
        $index = ConvertTo-LabMenuIndex $answer $choices.Count
        if ($index -ge 0) { return $choices[$index] }
        Write-Host 'Choose a listed number or B.'
    }
}

function Start-LabWindowsVMProvisioning {
    param([hashtable]$Options = @{})
    # Creates a new LAB- VM and installs Windows 11 on it unattended: menu W (all defaults) and the
    # engine behind -ProvisionWindowsVM ($Options carries only the parameters the caller bound).
    # Returns COMPLETED or CANCELLED; throws on any failure. Not wrapped in Invoke-LabAction, since
    # the VM does not exist yet when this starts: like New-LabVM, it takes the create-name lock around
    # New-LabVMCore, then the new VM's own per-VM lock for everything after, and writes its own audit
    # records. Unlike New-LabVM's per-field wizard, VM hardware comes from $Options or the defaults
    # below and is shown in ONE combined preview with the Windows settings, so the same code serves
    # -NonInteractive. Defaults here must match the documented top-level parameter defaults.
    if ($script:LabReadOnly) { Write-Warning 'Read-only mode: VM creation is disabled.'; return 'CANCELLED' }
    $getOption = {
        param([string]$Key, $Default)
        if ($Options.ContainsKey($Key) -and $null -ne $Options[$Key] -and -not ($Options[$Key] -is [string] -and $Options[$Key] -eq '')) {
            return $Options[$Key]
        }
        return $Default
    }
    $nonInteractive = [bool](& $getOption 'NonInteractive' $false)
    $suppliedCredential = & $getOption 'Credential' $null
    # Checked now, before an ISO is read or a VM exists: Resolve-LabWindowsCredential runs after VM
    # creation (it may prompt), and would otherwise only then refuse a scripted run without -Credential.
    if ($null -ne $suppliedCredential) { $null = ConvertTo-LabLocalAccountName $suppliedCredential }
    elseif ($nonInteractive) { throw 'Guest Windows credentials are required in non-interactive mode. Supply -Credential.' }

    # --- 1. ISO, then its editions: refused here, before any VM exists, unless it has Windows 11 client.
    $isoPath = [string](& $getOption 'WindowsIsoPath' '')
    if ($isoPath -eq '') {
        if ($nonInteractive) { throw 'Supply -WindowsIsoPath in non-interactive mode.' }
        $isoPath = Select-LabIsoPath $script:LabIsoRoot
        if ($null -eq $isoPath) { return 'CANCELLED' }
    } else {
        # Same checks as Select-LabIsoPath's own selection-time validation.
        if (-not (Test-Path -LiteralPath $isoPath -PathType Leaf)) { throw "Windows ISO '$isoPath' does not exist." }
        try {
            $stream = [IO.File]::OpenRead($isoPath)
            try { $isoLength = $stream.Length } finally { $stream.Close() }
        } catch { throw "Windows ISO '$isoPath' could not be opened for reading ($($_.Exception.Message))." }
        if ($isoLength -le 0) { throw "Windows ISO '$isoPath' is empty (0 bytes)." }
    }
    Write-Host "Reading the Windows editions in '$isoPath'..."
    $images = @(Get-LabWindowsInstallImages $isoPath)
    if (-not (Test-LabWindowsIsoInScope $images)) {
        $found = if ($images.Count -eq 0) { '(no images)' } else {
            ($images | ForEach-Object { "#$($_.Index) '$($_.Name)' ($($_.InstallationType), build $($_.BuildNumber))" }) -join '; ' }
        throw "Refusing '$isoPath': it contains no Windows 11 client edition (installation type Client, build 22000 or later), which is the only thing this action installs. Found: $found. No VM was created."
    }
    $edition = Select-LabWindowsEdition $images ([string](& $getOption 'OsEdition' '')) $nonInteractive
    if ($null -eq $edition) { return 'CANCELLED' }

    # --- 2. VM hardware and Windows settings: explicit values are validated strictly, never adjusted.
    $defaults = Get-LabHostDefaults
    $existingNames = @(Get-VM -ErrorAction Stop | ForEach-Object { [string]$_.Name })
    $nameRule = 'it must start with LAB- (case-insensitive), be unique, be at most 100 characters, and contain no path, wildcard or control characters.'
    $name = [string](& $getOption 'NewVMName' '')
    while (-not (Test-LabNewVMName $name $existingNames)) {
        if ($nonInteractive) {
            if ($name -eq '') { throw 'Supply -NewVMName in non-interactive mode.' }
            throw "Invalid -NewVMName '$name': $nameRule"
        }
        if ($name -ne '') { Write-Host "VM name '$name' cannot be used: $nameRule" }
        $name = Read-LabText 'New VM name, must start with LAB- and be unique (blank cancels)'
        if ($name -eq '') { return 'CANCELLED' }
    }
    $vmRoot = [string](& $getOption 'VmStorageRoot' $defaults.VirtualMachinePath)
    $vhdxRoot = [string](& $getOption 'VhdxStorageRoot' $defaults.VirtualHardDiskPath)
    foreach ($root in @(@{ Label = 'VM storage root (-VmStorageRoot)'; Path = $vmRoot }, @{ Label = 'VHDX storage root (-VhdxStorageRoot)'; Path = $vhdxRoot })) {
        # Same local-only rules as New-LabVM's storage prompts.
        if ($root.Path -notmatch '^[A-Za-z]:\\' -or -not (Test-Path -LiteralPath $root.Path -PathType Container) -or
            [IO.DriveInfo]::new([IO.Path]::GetPathRoot($root.Path)).DriveType -eq [IO.DriveType]::Network) {
            throw "$($root.Label) '$($root.Path)' must be an existing folder on a local drive (absolute path, not UNC or a mapped network drive)."
        }
    }
    $vmStoragePath = Join-Path $vmRoot $name
    $vhdxPath = Join-Path (Join-Path $vhdxRoot $name) "$name.vhdx"
    $requestedVCpu = & $getOption 'VCpuCount' $null
    $vCpuCount = if ($null -eq $requestedVCpu) { [math]::Min(2, [int]$defaults.LogicalProcessorCount) } else { [int]$requestedVCpu }
    if (-not (Test-LabVCpuCount $vCpuCount $defaults.LogicalProcessorCount)) {
        throw "-VCpuCount $vCpuCount is outside 1-$($defaults.LogicalProcessorCount) (this host's logical processor count)."
    }
    $minimumBytes = [long](& $getOption 'MemoryMinimumGB' 2) * 1GB
    $startupBytes = [long](& $getOption 'MemoryStartupGB' 4) * 1GB
    $maximumBytes = [long](& $getOption 'MemoryMaximumGB' 8) * 1GB
    if (-not (Test-LabMemorySpec $minimumBytes $startupBytes $maximumBytes $true)) {
        throw 'Memory must satisfy 0 < -MemoryMinimumGB <= -MemoryStartupGB <= -MemoryMaximumGB.'
    }
    $vhdxSizeGB = [int](& $getOption 'VhdxSizeGB' 150)
    if ($vhdxSizeGB -lt 64) { throw "-VhdxSizeGB $vhdxSizeGB is below Windows 11's 64 GB minimum." }
    # $getOption treats a bound-but-empty string as "not supplied" and falls back to Default, which is
    # correct for every other option here -- but -SwitchName '' is itself a meaningful, distinct value
    # (Disconnected), not an omission, so it is resolved directly against $Options instead.
    $switchName = if ($Options.ContainsKey('SwitchName')) { [string]$Options['SwitchName'] } else { 'Default Switch' }
    if ($switchName -ne '' -and (Get-LabSwitchNames) -notcontains $switchName) {
        throw "Virtual switch '$switchName' does not exist. Omit -SwitchName to use 'Default Switch', or supply -SwitchName '' to leave the adapter Disconnected."
    }
    $computerName = [string](& $getOption 'ComputerName' 'lab-agent-test')
    if ($computerName -notmatch '^[A-Za-z0-9-]{1,15}$' -or $computerName -match '^\d+$') {
        throw "Computer name '$computerName' is invalid: use 1-15 letters, digits or hyphens, not digits only. Supply -ComputerName."
    }
    $locale = [string](& $getOption 'Locale' 'en-US')
    if ($locale -notmatch '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$') { throw "Locale '$locale' is not a language tag such as en-US." }
    $timeZone = [string](& $getOption 'TimeZone' 'Central America Standard Time')
    try { $null = [TimeZoneInfo]::FindSystemTimeZoneById($timeZone) }
    catch { throw "Time zone '$timeZone' is not a Windows time zone ID such as 'Pacific Standard Time' (list them with tzutil /l)." }
    $productKey = [string](& $getOption 'ProductKey' '')
    if ($productKey -ne '' -and $productKey -notmatch '^[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}$') {
        throw "-ProductKey '$productKey' is not a Windows product key: expected five groups of five letters/digits separated by dashes, e.g. 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'. Omit it for no product key/no activation."
    }
    $timeoutSeconds = [int](& $getOption 'ProvisioningTimeoutSeconds' 1800)
    if ($timeoutSeconds -lt 300 -or $timeoutSeconds -gt 7200) { throw "-ProvisioningTimeoutSeconds $timeoutSeconds is outside 300-7200." }
    $workspaceHint = Join-Path $env:LOCALAPPDATA 'LabVmManager\Provisioning\<new VM id>'

    # --- 3. One combined preview, one confirmation. Nothing has been created or changed above.
    Write-Host "`n=== Provision Windows VM preview (nothing has been created yet) ==="
    [pscustomobject]@{
        Name = $name
        VMStoragePath = $vmStoragePath
        VhdxPath = $vhdxPath
        VhdxMaximumGiB = $vhdxSizeGB
        VCpuCount = $vCpuCount
        DynamicMemoryGiB = '{0} min / {1} startup / {2} max' -f ($minimumBytes / 1GB), ($startupBytes / 1GB), ($maximumBytes / 1GB)
        Switch = $(if ($switchName -eq '') { 'Disconnected' } else { $switchName })
        Generation = 2
        CheckpointPolicy = 'Standard; automatic checkpoints disabled'
        WindowsIso = $isoPath
        Edition = '{0} (image {1}, build {2})' -f $edition.Name, $edition.Index, $edition.BuildNumber
        ComputerName = $computerName
        Locale = $locale
        TimeZone = $timeZone
        ProductKey = $(if ($productKey -eq '') { 'none (no activation)' } else { 'supplied (not shown here)' })
        GuestAccount = $(if ($null -ne $suppliedCredential) { "$(ConvertTo-LabLocalAccountName $suppliedCredential) (local administrator)" } else { 'prompted for after the VM is created (local administrator)' })
        BootProfile = 'Windows11: Secure Boot (MicrosoftWindows template), new local key protector + vTPM'
        WaitPerSignIn = "$timeoutSeconds seconds"
    } | Format-List | Out-Host
    Write-Host 'The VM is created, Windows is installed unattended from the ISO plus a generated answer-file ISO, and the VM'
    Write-Host 'boots twice: once to install (proven by a PowerShell Direct sign-in and a note on the guest desktop), then,'
    Write-Host 'after the install media are removed, once more to prove it boots cleanly on its own.'
    Write-Warning ("Until the end of the run, the provisioning workspace ($workspaceHint) holds a copy of the ISO and " +
        'the answer file containing the account password in plain text. It is deleted after a successful run and KEPT if a step fails.')
    if (-not $nonInteractive) {
        Write-Host 'To change any value above, cancel and rerun with -ProvisionWindowsVM and the matching parameter.'
        if ((Read-LabYesNoCancel 'Create this VM and install Windows now') -ne 'Y') { return 'CANCELLED' }
    }

    # --- 4. Create the VM under the create-name lock (same lock as New-LabVM), then hand over to the VM's own lock.
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $getAuditDetail = { 'Iso={0}; Edition={1} (index {2}); ComputerName={3}; ElapsedSeconds={4}' -f
        $isoPath, $edition.Name, $edition.Index, $computerName, [int]$watch.Elapsed.TotalSeconds }
    $createMutex = [Threading.Mutex]::new($false, "Global\LabVmManager-Create-$($name.ToUpperInvariant())")
    $createHeld = $false
    $vmMutex = $null
    $vmHeld = $false
    try {
        try { $createHeld = $createMutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $createHeld = $true }
        if (-not $createHeld) { throw 'Another copy of this script is already creating a VM with this name. No operation was started here.' }
        try {
            $vm = New-LabVMCore -Name $name -VmStoragePath $vmStoragePath -VCpuCount $vCpuCount `
                -MinimumBytes $minimumBytes -StartupBytes $startupBytes -MaximumBytes $maximumBytes `
                -IsDynamic $true -VhdxPath $vhdxPath -VhdxMaximumBytes ([long]$vhdxSizeGB * 1GB) -SwitchName $switchName
        } catch [Management.Automation.PipelineStoppedException] {
            throw
        } catch {
            $message = $_.Exception.Message
            try { Write-LabAudit 'provision-windows-vm' 'FAILED_OR_UNCONFIRMED' $null "$name`: VM creation: $message; $(& $getAuditDetail)" }
            catch { Write-Warning 'Audit logging also failed.' }
            throw "Creating '$name' failed or is unconfirmed: $message Inspect Hyper-V inventory; do not assume nothing was created. No Windows provisioning step ran, so no workspace or password file was written."
        }
        $vmId = [guid]$vm.Id

        # --- 5. Everything after creation: one catch, which names what was applied and keeps the workspace.
        $done = [Collections.Generic.List[string]]::new()
        $done.Add("VM '$name' [$vmId] created")
        $workspace = $null
        $seedIsoBuilt = $false
        $workspaceRemoved = $false
        $session = $null
        $completed = $false
        $reported = $false
        $getFailureText = {
            param([string]$Cause)
            $workspaceText = if ($null -eq $workspace) {
                'No provisioning workspace was created, so no password was written to disk.'
            } elseif ($workspaceRemoved) {
                'The provisioning workspace (and the password in it) was already deleted.'
            } elseif ($seedIsoBuilt) {
                "The provisioning workspace was KEPT, not deleted: $workspace -- it contains the account password in plain text (the answer file inside seed.iso). Delete that folder yourself once you no longer need it."
            } else {
                "The provisioning workspace was KEPT, not deleted: $workspace -- no password had been written to it yet, but check it and delete that folder yourself once you no longer need it."
            }
            "Windows provisioning of '$name' stopped partway: $Cause Steps already applied: $($done -join '; '). The VM was left exactly as it is (not powered off, not deleted); inspect it before retrying. $workspaceText"
        }
        try {
            # A brand-new VM id: nobody else can hold this lock yet, but take it before releasing the
            # create lock so there is no moment when the new VM is unlocked.
            $vmMutex = [Threading.Mutex]::new($false, "Global\LabVmManager-$vmId")
            try { $vmHeld = $vmMutex.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $vmHeld = $true }
            if (-not $vmHeld) { throw 'Another copy of this script is already operating on the new VM.' }
            $createMutex.ReleaseMutex()
            $createHeld = $false
            Write-LabAudit 'provision-windows-vm' 'STARTED' $vm (& $getAuditDetail)

            # VM-level settings this plan's own experience showed are worth having from the start, on
            # a VM meant to actually be used afterward: file-copy support ready without a later manual
            # step, and a graceful shutdown (not a forced power-off) if the host itself restarts.
            Enable-VMIntegrationService -VM $vm -Name 'Guest Service Interface' -Confirm:$false -ErrorAction Stop
            Set-VM -VM $vm -AutomaticStopAction ShutDown -Confirm:$false -ErrorAction Stop
            $done.Add('Guest Service Interface enabled; automatic stop action set to Shut Down')

            $guestCredential = Resolve-LabWindowsCredential -Credential $suppliedCredential -NonInteractive $nonInteractive
            $accountName = ConvertTo-LabLocalAccountName $guestCredential
            $done.Add("guest credential resolved (account '$accountName')")
            $workspace = Get-LabProvisioningWorkspacePath $vmId
            $done.Add("provisioning workspace created ($workspace)")
            Write-Host 'Writing a no-prompt boot copy of the ISO into the workspace (this can take a few minutes)...'
            $patchResult = New-LabPatchedBootableIso -SourceIsoPath $isoPath -OutputPath (Join-Path $workspace 'windows-noprompt.iso')
            # OutputPath is $null when nothing was patched: fall back to the original ISO here, by design.
            $windowsIsoPath = if ($patchResult.Patched) { [string]$patchResult.OutputPath } else { $isoPath }
            if ($patchResult.Patched) {
                $done.Add('no-prompt boot copy of the ISO written')
            } else {
                Write-Warning ("The ISO's boot loader was not patched ($($patchResult.Reason)); the original ISO is used. When the VM " +
                    "first starts, its console may show 'Press any key to boot from CD or DVD': open it in Hyper-V Manager and press a key within a few seconds.")
                $done.Add("boot loader not patched ($($patchResult.Reason)); original ISO used")
            }
            # Splatted: the SecureString goes straight through; it is never turned into plaintext here.
            $answerFileArguments = @{ ComputerName = $computerName; Locale = $locale; TimeZone = $timeZone
                ImageIndex = $edition.Index; UserName = $accountName; Password = $guestCredential.Password
                ProductKey = $productKey }
            $answerFileXml = New-LabWindowsAnswerFileXml @answerFileArguments
            $seedIsoPath = Join-Path $workspace 'seed.iso'
            # From here on the workspace holds the password, so mark that before the write, not after.
            $seedIsoBuilt = $true
            New-LabSeedIso -Files @{ 'Autounattend.xml' = $answerFileXml } -OutputPath $seedIsoPath
            $answerFileXml = $null
            $done.Add('answer-file seed ISO built')
            Set-LabVMUnattendedInstallMedia -VMId $vmId -WindowsIsoPath $windowsIsoPath -SeedIsoPath $seedIsoPath
            $done.Add('Windows and seed ISOs attached, DVD first in boot order')
            $profileResult = Set-LabVMBootProfile $vmId 'Windows11'
            $done.Add(('Windows11 boot profile (template changed: {0}; Secure Boot turned on: {1}; key protector added: {2}; vTPM enabled: {3})' -f
                $profileResult.SecureBootTemplateChanged, $profileResult.SecureBootEnabled, $profileResult.KeyProtectorAdded, $profileResult.TpmEnabled))
            if ($profileResult.KeyProtectorAdded -or $profileResult.TpmEnabled) {
                # Same separate, immediate record as the installation-media menu action writes.
                Write-LabAudit 'add-key-protector' 'COMPLETED' $vm ("OsProfile=Windows11; NewLocalKeyProtector={0}; VTpmEnabled={1}" -f
                    $profileResult.KeyProtectorAdded, $profileResult.TpmEnabled)
            }
            $null = Start-LabVM $vmId
            $done.Add('VM started (Windows setup running)')
            Write-Host "Windows setup is running unattended. Waiting up to $timeoutSeconds seconds for the first PowerShell Direct sign-in..."
            $session = Wait-LabPSDirectSession -VMId $vmId -Credential $guestCredential -TimeoutSeconds $timeoutSeconds
            $done.Add('first PowerShell Direct sign-in succeeded (Windows installed)')
            $installElapsed = $watch.Elapsed
            $note = (@(
                "This VM ($name) was installed unattended by LAB VM Manager from $env:COMPUTERNAME on $(Get-Date -Format 'yyyy-MM-dd HH:mm').",
                "Windows ISO: $isoPath$(if ($patchResult.Patched) { ' (booted from a no-prompt copy of it)' } else { ' (booted as-is; its boot loader was not patched)' }).",
                "Edition: $($edition.Name) (image $($edition.Index), build $($edition.BuildNumber)). Computer name: $computerName. Local administrator account: $accountName.",
                ('Boot profile: Windows11 (Secure Boot template changed: {0}; Secure Boot turned on: {1}; key protector added: {2}; vTPM enabled: {3}).' -f
                    $profileResult.SecureBootTemplateChanged, $profileResult.SecureBootEnabled, $profileResult.KeyProtectorAdded, $profileResult.TpmEnabled),
                ('Time from VM creation to this first sign-in: {0} min {1} s ({2} seconds).' -f
                    [int][math]::Floor($installElapsed.TotalMinutes), $installElapsed.Seconds, [int]$installElapsed.TotalSeconds),
                'Right after this note was written, the host shut the VM down once, removed the installer and answer-file media,',
                'deleted its host-side copy of the answer file, and started the VM again.'
            ) -join [Environment]::NewLine)
            Write-LabProvisioningNote -Session $session -Content $note
            $done.Add('completion note written to the guest desktop')
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            $session = $null
            Request-LabVMGuestShutdown $vmId 'LAB VM Manager: Windows unattended install finished; removing install media'
            # A first shutdown right after OOBE can take far longer than the short general state-change
            # wait (-TimeoutSeconds, default 180 s), and timing out here would strand a finished VM with
            # its media still attached and its password-bearing workspace kept. A 10-minute floor was
            # tried first and was NOT enough: a real live run's first post-OOBE shutdown took longer than
            # that (confirmed 2026-10-20 -- Windows settling in after a clean install, not a script bug).
            # Floor it at the same 1800 s ceiling already given to the PS-Direct waits, for consistency
            # with "a brand-new Windows instance can be slow the first time" rather than guessing a
            # smaller number again.
            $null = Wait-LabVMState $vmId 'Off' -TimeoutSeconds ([math]::Max($script:LabTimeout, 1800))
            $done.Add('VM shut down')
            Complete-LabWindowsProvisioning -VMId $vmId -WindowsIsoPath $windowsIsoPath -SeedIsoPath $seedIsoPath
            $done.Add('seed drive removed, installer ISO ejected, disk first in boot order')
            Remove-LabProvisioningWorkspace $vmId
            $workspaceRemoved = $true
            $done.Add('provisioning workspace deleted')
            $null = Start-LabVM $vmId
            $done.Add('VM restarted without install media')
            Write-Host "Waiting up to $timeoutSeconds seconds for a PowerShell Direct sign-in after the clean restart..."
            $session = Wait-LabPSDirectSession -VMId $vmId -Credential $guestCredential -TimeoutSeconds $timeoutSeconds
            $done.Add('second PowerShell Direct sign-in succeeded (boots cleanly on its own)')
            $completed = $true
        } catch [Management.Automation.PipelineStoppedException] {
            throw
        } catch {
            $failureText = & $getFailureText $_.Exception.Message
            $reported = $true
            try { Write-LabAudit 'provision-windows-vm' 'FAILED_OR_UNCONFIRMED' $vm "$($_.Exception.Message); $(& $getAuditDetail)" }
            catch { Write-Warning 'Audit logging also failed. Inspect the VM; do not assume nothing changed.' }
            throw $failureText
        } finally {
            if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
            if (-not $completed -and -not $reported) {
                # Interrupted (e.g. Ctrl+C): the catch above never ran, so say where things stand here.
                try { $Host.UI.WriteWarningLine((& $getFailureText 'the run was interrupted.')) } catch { }
                try { Write-LabAudit 'provision-windows-vm' 'FAILED_OR_UNCONFIRMED' $vm "interrupted; $(& $getAuditDetail)" } catch { }
            }
        }
        Write-LabAudit 'provision-windows-vm' 'COMPLETED' $vm (& $getAuditDetail)
        foreach ($line in $done) { Write-Host "Done: $line" }
        Write-Host "'$name' is installed and running, signed in once as '$accountName'. A note is on that account's desktop."
        return 'COMPLETED'
    } finally {
        if ($createHeld) { $createMutex.ReleaseMutex() }
        $createMutex.Dispose()
        if ($vmHeld) { $vmMutex.ReleaseMutex() }
        if ($null -ne $vmMutex) { $vmMutex.Dispose() }
    }
}

function Get-LabVMRemovalPreview {
    param([guid]$VMId)
    $vm = Get-LabVM $VMId
    $disks = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop | Select-Object -ExpandProperty Path)
    $snapshots = @(Get-LabSnapshots $VMId)
    $nonStandard = @($snapshots | Where-Object { [string]$_.SnapshotType -ne 'Standard' })
    return [pscustomobject]@{
        Name = $vm.Name
        Id = $vm.Id
        Path = $vm.Path
        DiskPaths = $disks
        CheckpointCount = $snapshots.Count
        HasNonStandardCheckpoints = ($nonStandard.Count -gt 0)
    }
}

function Remove-LabVM {
    param([guid]$VMId)
    $vm = Assert-LabVMOff $VMId
    $preview = Get-LabVMRemovalPreview $VMId
    Write-Host "`n=== Removal preview: $($preview.Name) [$($preview.Id)] ==="
    Write-Host "Path: $($preview.Path)"
    Write-Host ('Disk paths: {0}' -f $(if ($preview.DiskPaths.Count -eq 0) { '(none found)' } else { $preview.DiskPaths -join '; ' }))
    Write-Host "Checkpoint count: $($preview.CheckpointCount)"
    if ($preview.HasNonStandardCheckpoints) {
        throw 'This VM has one or more recovery/backup (non-Standard) checkpoints. Resolve/merge those outside this tool before deletion; removal is blocked while they exist.'
    }
    Write-Warning 'Deleting a VM removes it from Hyper-V inventory and configuration. Its virtual disk files are retained on disk, never deleted automatically.'
    Write-Host 'Never manually delete AVHDX/VHDX files; Hyper-V may still need to finish merging checkpoint storage.'
    $exportChoice = Read-LabYesNoCancel 'Export this VM before deletion?'
    if ($exportChoice -eq 'C') { return 'CANCELLED' }
    $exportPerformed = $false
    if ($exportChoice -eq 'Y') {
        $exportStatus = Export-LabVM $VMId
        # A throw here propagates untouched; only a non-COMPLETED return needs handling.
        if ($exportStatus -ne 'COMPLETED') { return 'CANCELLED' }
        $exportPerformed = $true
    }
    # State may have changed during export; re-resolve before the strong confirmation.
    $vm = Assert-LabVMOff $VMId
    $preview = Get-LabVMRemovalPreview $VMId
    if ($preview.HasNonStandardCheckpoints) {
        throw 'This VM now has one or more recovery/backup (non-Standard) checkpoints. Resolve/merge those outside this tool before deletion.'
    }
    if (-not (Confirm-LabText "DELETE VM $($vm.Name) $($vm.Id.ToString().Substring(0, 8))")) { return 'CANCELLED' }

    $manifestFileName = 'removal-manifest.json'
    $manifestPath = Join-Path (Split-Path $script:LabLogFile) ("{0}-{1}" -f $vm.Id, $manifestFileName)
    $manifest = [ordered]@{
        VMName = $preview.Name
        VMId = [string]$preview.Id
        Path = $preview.Path
        DiskPaths = @($preview.DiskPaths)
        CheckpointCount = $preview.CheckpointCount
        ExportPerformed = $exportPerformed
        RemovedUtc = $null
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop

    $vm = Assert-LabVMOff $VMId
    Write-LabAudit 'delete-vm' 'STARTED' $vm ("Disks: {0}; Checkpoints: {1}; ExportPerformed: {2}" -f ($preview.DiskPaths -join '; '), $preview.CheckpointCount, $exportPerformed)
    Remove-VM -VM $vm -Confirm:$false -ErrorAction Stop
    if (@(Get-VM -Id $VMId -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'VM still appears in inventory after removal. Inspect Hyper-V before retrying.'
    }
    $manifest.RemovedUtc = [DateTime]::UtcNow.ToString('o')
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop

    Write-Host 'VM removed from Hyper-V inventory. Retained disk file(s), never deleted by this tool:'
    if ($preview.DiskPaths.Count -eq 0) { Write-Host '  (none found)' }
    else { $preview.DiskPaths | ForEach-Object { Write-Host "  $_" } }
    Write-Host "Removal manifest: $manifestPath"
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

function Get-LabSettingsDiff {
    param([pscustomobject]$Current, [pscustomobject]$Proposed)
    $fields = @('Name', 'Notes', 'VCpuCount', 'StartupBytes', 'MinimumBytes', 'MaximumBytes', 'DynamicMemoryEnabled', 'SwitchName')
    $diff = @()
    foreach ($field in $fields) {
        $currentProperty = $Current.PSObject.Properties[$field]
        $proposedProperty = $Proposed.PSObject.Properties[$field]
        if ($null -eq $currentProperty -or $null -eq $proposedProperty) { continue }
        $oldValue = $currentProperty.Value
        $newValue = $proposedProperty.Value
        # DynamicMemoryEnabled: the explicit [bool] casts make this a bool-to-bool comparison regardless
        # of either operand's original type (PowerShell otherwise converts the right operand to the
        # left's type). Case sensitivity is irrelevant for bools; -cne behaves exactly like -ne here.
        # Name/Notes: case-sensitive, so a casing-only rename or Notes edit counts as a real change.
        $changed = $(if ($field -eq 'DynamicMemoryEnabled') { ([bool]$oldValue) -cne ([bool]$newValue) }
            elseif ($field -eq 'Name' -or $field -eq 'Notes') { [string]$oldValue -cne [string]$newValue }
            else { $oldValue -ne $newValue })
        if ($changed) {
            $diff += [pscustomobject]@{ Field = $field; OldValue = $oldValue; NewValue = $newValue }
        }
    }
    # Comma forces this out as one array object; plain `return @($diff)` would unwrap a
    # 0- or 1-element result through the pipeline and strip its array-ness.
    return ,$diff
}

function Set-LabVMSettingsCore {
    param([guid]$VMId, [pscustomobject[]]$Diff)
    $vm = Assert-LabVMOff $VMId
    $applied = @()
    try {
        foreach ($entry in $Diff) {
            switch ($entry.Field) {
                'Name' {
                    $existingNames = @((Get-VM -ErrorAction Stop).Name | Where-Object { $_ -ne $vm.Name })
                    if (-not (Test-LabNewVMName $entry.NewValue $existingNames)) {
                        throw "New name '$($entry.NewValue)' is invalid or already in use."
                    }
                    Rename-VM -VM $vm -NewName $entry.NewValue -Confirm:$false -ErrorAction Stop
                    $vm = Get-LabVM $VMId
                    if ($vm.Name -cne $entry.NewValue) { throw "Field 'Name' did not verify after applying." }
                    $applied += 'Name'
                }
                'Notes' {
                    Set-VM -VM $vm -Notes $entry.NewValue -Confirm:$false -ErrorAction Stop
                    $vm = Get-LabVM $VMId
                    if ([string]$vm.Notes -cne [string]$entry.NewValue) { throw "Field 'Notes' did not verify after applying." }
                    $applied += 'Notes'
                }
                'VCpuCount' {
                    Set-VMProcessor -VM $vm -Count $entry.NewValue -Confirm:$false -ErrorAction Stop
                    $vm = Get-LabVM $VMId
                    if ($vm.ProcessorCount -ne $entry.NewValue) { throw "Field 'VCpuCount' did not verify after applying." }
                    $applied += 'VCpuCount'
                }
                'SwitchName' {
                    $adapter = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)[0]
                    if ($null -eq $adapter) { throw 'VM has no network adapter to reconnect.' }
                    if ([string]::IsNullOrEmpty($entry.NewValue)) {
                        Disconnect-VMNetworkAdapter -VMNetworkAdapter $adapter -Confirm:$false -ErrorAction Stop
                    } else {
                        if ((Get-LabSwitchNames) -notcontains $entry.NewValue) { throw "Virtual switch '$($entry.NewValue)' is no longer available." }
                        Connect-VMNetworkAdapter -VMNetworkAdapter $adapter -SwitchName $entry.NewValue -Confirm:$false -ErrorAction Stop
                    }
                    $vm = Get-LabVM $VMId
                    $actualSwitch = [string]@(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)[0].SwitchName
                    $expectedSwitch = $(if ([string]::IsNullOrEmpty($entry.NewValue)) { '' } else { $entry.NewValue })
                    if ($actualSwitch -cne $expectedSwitch) { throw "Field 'SwitchName' did not verify after applying." }
                    $applied += 'SwitchName'
                }
                default {
                    # MinimumBytes/StartupBytes/MaximumBytes/DynamicMemoryEnabled are applied together below,
                    # since Set-VMMemory validates minimum <= startup <= maximum as one consistent set.
                }
            }
        }

        $memoryFieldNames = @('MinimumBytes', 'StartupBytes', 'MaximumBytes', 'DynamicMemoryEnabled')
        $memoryDiff = @($Diff | Where-Object { $memoryFieldNames -contains $_.Field })
        if ($memoryDiff.Count -gt 0) {
            $minimumBytes = [long]$vm.MemoryMinimum
            $startupBytes = [long]$vm.MemoryStartup
            $maximumBytes = [long]$vm.MemoryMaximum
            $isDynamic = [bool]$vm.DynamicMemoryEnabled
            foreach ($entry in $memoryDiff) {
                switch ($entry.Field) {
                    'MinimumBytes' { $minimumBytes = $entry.NewValue }
                    'StartupBytes' { $startupBytes = $entry.NewValue }
                    'MaximumBytes' { $maximumBytes = $entry.NewValue }
                    'DynamicMemoryEnabled' { $isDynamic = $entry.NewValue }
                }
            }
            Set-VMMemory -VM $vm -DynamicMemoryEnabled $isDynamic -MinimumBytes $minimumBytes `
                -StartupBytes $startupBytes -MaximumBytes $maximumBytes -Confirm:$false -ErrorAction Stop
            $vm = Get-LabVM $VMId
            foreach ($entry in $memoryDiff) {
                $actual = switch ($entry.Field) {
                    'MinimumBytes' { [long]$vm.MemoryMinimum }
                    'StartupBytes' { [long]$vm.MemoryStartup }
                    'MaximumBytes' { [long]$vm.MemoryMaximum }
                    'DynamicMemoryEnabled' { [bool]$vm.DynamicMemoryEnabled }
                }
                if ($actual -ne $entry.NewValue) { throw "Field '$($entry.Field)' did not verify after applying." }
                $applied += $entry.Field
            }
        }
    } catch [Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $appliedText = $(if ($applied.Count -eq 0) { '(none)' } else { $applied -join ', ' })
        throw "$($_.Exception.Message) Fields applied before this failure: $appliedText."
    }
    return (Get-LabVM $VMId)
}

function Edit-LabVMSettings {
    param([guid]$VMId)
    $vm = Assert-LabVMOff $VMId
    $adapters = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
    if ($adapters.Count -eq 0) {
        $adapter = $null
    } else {
        if ($adapters.Count -gt 1) {
            Write-Host "Multiple network adapters found; this tool manages only '$($adapters[0].Name)'. Use Hyper-V Manager directly for the others."
        }
        $adapter = $adapters[0]
    }
    $currentSwitchName = $(if ($null -eq $adapter -or [string]::IsNullOrEmpty($adapter.SwitchName)) { $null } else { [string]$adapter.SwitchName })
    $current = [pscustomobject]@{
        Name = $vm.Name
        Notes = [string]$vm.Notes
        VCpuCount = [int]$vm.ProcessorCount
        StartupBytes = [long]$vm.MemoryStartup
        MinimumBytes = [long]$vm.MemoryMinimum
        MaximumBytes = [long]$vm.MemoryMaximum
        DynamicMemoryEnabled = [bool]$vm.DynamicMemoryEnabled
        SwitchName = $currentSwitchName
    }
    Write-Host "`n=== Current settings ==="
    $current | Format-List | Out-Host

    $existingNames = @((Get-VM -ErrorAction Stop).Name | Where-Object { $_ -ne $vm.Name })
    while ($true) {
        $nameInput = Read-LabText "Name [$($current.Name)] (blank keeps current; C cancels)"
        if ($nameInput -ieq 'C') { return 'CANCELLED' }
        $newName = $(if ($nameInput -eq '') { $current.Name } else { $nameInput })
        # Case-sensitive: an exact match keeps the current name; a casing-only change is a real rename
        # and, like any rename, must pass Test-LabNewVMName (own name excluded from the duplicate check).
        if ($newName -ceq $current.Name -or (Test-LabNewVMName $newName $existingNames)) { break }
        Write-Host 'Name must start with LAB- (case-insensitive), be unique, be at most 100 characters, and contain no path, wildcard or control characters.'
    }

    $notesInput = Read-LabText "Notes [$($current.Notes)] (blank keeps current)"
    $newNotes = $(if ($notesInput -eq '') { $current.Notes } else { $notesInput })

    $defaults = Get-LabHostDefaults
    while ($true) {
        $vCpuInput = Read-LabText "vCPU count [$($current.VCpuCount)], 1-$($defaults.LogicalProcessorCount) (blank keeps current; C cancels)"
        if ($vCpuInput -ieq 'C') { return 'CANCELLED' }
        if ($vCpuInput -eq '') { $newVCpuCount = $current.VCpuCount; break }
        $parsedVCpu = 0
        if ([int]::TryParse($vCpuInput, [ref]$parsedVCpu) -and (Test-LabVCpuCount $parsedVCpu $defaults.LogicalProcessorCount)) {
            $newVCpuCount = $parsedVCpu; break
        }
        Write-Host "Enter a whole number from 1 to $($defaults.LogicalProcessorCount), or blank to keep current."
    }

    while ($true) {
        $dynInput = (Read-LabText "Dynamic memory, Y/N [currently $($current.DynamicMemoryEnabled)] (blank keeps current; C cancels)").ToUpperInvariant()
        if ($dynInput -eq 'C') { return 'CANCELLED' }
        if ($dynInput -eq '') { $newIsDynamic = $current.DynamicMemoryEnabled; break }
        if ($dynInput -eq 'Y' -or $dynInput -eq 'YES') { $newIsDynamic = $true; break }
        if ($dynInput -eq 'N' -or $dynInput -eq 'NO') { $newIsDynamic = $false; break }
        Write-Host 'Enter Y, N, blank to keep current, or C to cancel.'
    }

    if ($newIsDynamic) {
        while ($true) {
            $minInput = Read-LabText "Minimum memory bytes [$($current.MinimumBytes)] (blank keeps current; C cancels)"
            if ($minInput -ieq 'C') { return 'CANCELLED' }
            $startupInput = Read-LabText "Startup memory bytes [$($current.StartupBytes)] (blank keeps current; C cancels)"
            if ($startupInput -ieq 'C') { return 'CANCELLED' }
            $maxInput = Read-LabText "Maximum memory bytes [$($current.MaximumBytes)] (blank keeps current; C cancels)"
            if ($maxInput -ieq 'C') { return 'CANCELLED' }
            $newMinimumBytes = $current.MinimumBytes; $newStartupBytes = $current.StartupBytes; $newMaximumBytes = $current.MaximumBytes
            $parsedOk = $true
            if ($minInput -ne '') { $parsedValue = 0L; if ([long]::TryParse($minInput, [ref]$parsedValue)) { $newMinimumBytes = $parsedValue } else { $parsedOk = $false } }
            if ($startupInput -ne '') { $parsedValue = 0L; if ([long]::TryParse($startupInput, [ref]$parsedValue)) { $newStartupBytes = $parsedValue } else { $parsedOk = $false } }
            if ($maxInput -ne '') { $parsedValue = 0L; if ([long]::TryParse($maxInput, [ref]$parsedValue)) { $newMaximumBytes = $parsedValue } else { $parsedOk = $false } }
            if ($parsedOk -and (Test-LabMemorySpec $newMinimumBytes $newStartupBytes $newMaximumBytes $true)) { break }
            Write-Host 'Enter whole-byte values, multiples of 2MB, with minimum <= startup <= maximum, or blank to keep current.'
        }
    } else {
        while ($true) {
            $startupInput = Read-LabText "Startup (static) memory bytes [$($current.StartupBytes)] (blank keeps current; C cancels)"
            if ($startupInput -ieq 'C') { return 'CANCELLED' }
            $newStartupBytes = $current.StartupBytes
            $parsedOk = $true
            if ($startupInput -ne '') { $parsedValue = 0L; if ([long]::TryParse($startupInput, [ref]$parsedValue)) { $newStartupBytes = $parsedValue } else { $parsedOk = $false } }
            if ($parsedOk -and (Test-LabMemorySpec 0 $newStartupBytes 0 $false)) { break }
            Write-Host 'Enter a whole-byte value that is a multiple of 2MB, or blank to keep current.'
        }
        # Static memory ignores min/max; carry the stored values forward so a no-op edit yields no diff.
        $newMinimumBytes = $current.MinimumBytes
        $newMaximumBytes = $current.MaximumBytes
    }

    $newSwitchName = $current.SwitchName
    if ($null -eq $adapter) {
        Write-Host 'No network adapter found; switch assignment is not editable.'
    } else {
        $switchNames = @(Get-LabSwitchNames)
        $rows = for ($i = 0; $i -lt $switchNames.Count; $i++) { [pscustomobject]@{ No = $i + 1; Switch = $switchNames[$i] } }
        $rows += [pscustomobject]@{ No = $switchNames.Count + 1; Switch = 'Disconnected' }
        $rows | Format-Table -AutoSize | Out-Host
        $currentLabel = $(if ([string]::IsNullOrEmpty($current.SwitchName)) { 'Disconnected' } else { $current.SwitchName })
        while ($true) {
            $switchAnswer = Read-LabText "Switch number [currently $currentLabel] (blank keeps current; C cancels)"
            if ($switchAnswer -ieq 'C') { return 'CANCELLED' }
            if ($switchAnswer -eq '') { break }
            $switchIndex = ConvertTo-LabMenuIndex $switchAnswer $rows.Count
            if ($switchIndex -ge 0) {
                $newSwitchName = $(if ($switchIndex -eq $switchNames.Count) { $null } else { $switchNames[$switchIndex] })
                break
            }
            Write-Host 'Choose a listed number, or blank to keep current.'
        }
    }

    $proposed = [pscustomobject]@{
        Name = $newName
        Notes = $newNotes
        VCpuCount = $newVCpuCount
        StartupBytes = $newStartupBytes
        MinimumBytes = $newMinimumBytes
        MaximumBytes = $newMaximumBytes
        DynamicMemoryEnabled = $newIsDynamic
        SwitchName = $newSwitchName
    }
    $diff = Get-LabSettingsDiff $current $proposed
    if ($diff.Count -eq 0) { Write-Host 'No changes.'; return 'NO_CHANGE' }

    Write-Host "`n=== Proposed changes ==="
    $diff | Format-Table -AutoSize -Wrap | Out-Host
    if (-not (Confirm-LabText "EDIT $($vm.Name)")) { return 'CANCELLED' }

    $updated = Set-LabVMSettingsCore -VMId $VMId -Diff $diff
    Write-Host "Updated '$($updated.Name)' [$($updated.Id)]."
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

function Invoke-LabTransferSide {
    param([System.Management.Automation.Runspaces.PSSession]$Session, [bool]$Remote,
        [scriptblock]$ScriptBlock, [object[]]$ArgumentList)
    if ($Remote) { return Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop }
    return & $ScriptBlock @ArgumentList
}

function Resolve-LabTransferItemAction {
    param([hashtable]$State, [string]$SourceLabel, [string]$DestinationLabel, [bool]$SourceIsDirectory,
        [bool]$SourceIsReparse, $Destination, [string]$OnConflict)
    $reason = $null
    if ($SourceIsReparse) { $reason = "${SourceLabel}: source is a symbolic link, junction or other reparse point; only regular files and plain directories are supported." }
    elseif ($Destination.Error) { $reason = "${DestinationLabel}: destination could not be inspected: $($Destination.Error)" }
    elseif ($Destination.IsReparse) { $reason = "${DestinationLabel}: destination is a symbolic link, junction or other reparse point; refusing to write through it." }
    if ($reason) { $State.Failed++; $State.Errors.Add($reason); return 'Error' }
    $kind = Get-LabTransferConflictKind $SourceIsDirectory ([bool]$Destination.Exists) ([bool]$Destination.IsDirectory)
    # An existing directory is merged into; -OnConflict then applies to each file inside it.
    if ($SourceIsDirectory -and $kind -eq 'Exists') { return 'Merge' }
    $action = Resolve-LabConflictAction $kind $OnConflict
    if ($action -eq 'Error') {
        $why = if ($kind -eq 'TypeMismatch') { 'destination exists as a different type (file vs directory)' } else { 'destination already exists' }
        $State.Failed++
        $State.Errors.Add("${DestinationLabel}: $why.")
    } elseif ($action -eq 'Skip') {
        $State.Skipped++
        Write-Host "Skipped (destination exists): $DestinationLabel"
    }
    return $action
}

function Set-LabTransferPrivateAcl {
    param(
        [AllowNull()][System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$Path,
        [bool]$IsDirectory
    )
    # icacls, not Get-Acl/Set-Acl: one external call both strips inherited ACEs and grants the
    # owner, non-recursively (no /T) against exactly this path -- never a parent or a child.
    $applySb = {
        param([string]$TargetPath, [bool]$TargetIsDirectory)
        # Local, not inherited: a caller-set -Stop preference would otherwise turn icacls's own
        # stderr (captured below via 2>&1) into an immediate throw before $LASTEXITCODE is checked.
        $ErrorActionPreference = 'Continue'
        $account = "$env:USERDOMAIN\$env:USERNAME"
        $kind = if ($TargetIsDirectory) { 'directory' } else { 'file' }
        $output = & icacls.exe $TargetPath /inheritance:r /grant:r "${account}:(F)" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "icacls could not restrict the $kind '$TargetPath' to '$account' (exit ${LASTEXITCODE}): $output" }
    }
    if ($null -eq $Session) {
        & $applySb $Path $IsDirectory
    } else {
        # $env:USERNAME inside this scriptblock resolves in the guest runspace, i.e. the account the
        # PS Direct session authenticated as -- never an owner inferred from the (host-relative) path.
        Invoke-Command -Session $Session -ScriptBlock $applySb -ArgumentList $Path, $IsDirectory -ErrorAction Stop
    }
}

function Copy-LabTransferItem {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [ValidateSet('ToVM', 'FromVM')][string]$Direction,
        [string]$SourcePath,
        [string]$DestinationPath,
        [bool]$Recurse,
        [ValidateSet('Error', 'Skip', 'Overwrite')][string]$OnConflict,
        [bool]$VerifyHash,
        [bool]$DryRun,
        [ValidateSet('Default', 'PrivateFiles')][string]$PermissionProfile = 'Default'
    )
    if ($null -eq $Session -or [string]$Session.State -ne 'Opened') {
        throw 'The PowerShell Direct session is not open. No transfer was attempted.'
    }
    $state = @{ Completed = 0; Skipped = 0; Failed = 0; BytesTransferred = [long]0
        Errors = [Collections.Generic.List[string]]::new() }
    $summary = {
        [pscustomobject]@{ Completed = [int]$state.Completed; Skipped = [int]$state.Skipped; Failed = [int]$state.Failed
            BytesTransferred = [long]$state.BytesTransferred; Errors = [string[]]$state.Errors.ToArray() }
    }
    $fail = { param([string]$Message) $state.Failed++; $state.Errors.Add($Message) }
    $sourceRemote = $Direction -eq 'FromVM'
    $destinationRemote = $Direction -eq 'ToVM'

    foreach ($path in @($SourcePath, $DestinationPath)) {
        if ($path -notmatch '^[A-Za-z]:[\\/]') { & $fail "${path}: transfer paths must be absolute drive-letter paths."; return & $summary }
    }
    $SourcePath = $SourcePath.TrimEnd('\', '/')
    $DestinationPath = $DestinationPath.TrimEnd('\', '/')
    foreach ($path in @($SourcePath, $DestinationPath)) {
        if ($path -match '^[A-Za-z]:$') { & $fail "${path}\: a drive root cannot be a transfer source or destination."; return & $summary }
    }

    # These scriptblocks run on whichever side owns the path: locally, or in the guest via
    # Invoke-Command. They return plain values only, so nothing depends on deserialized types.
    $statSb = {
        param([string[]]$Paths, [bool]$Hash)
        foreach ($path in $Paths) {
            $info = [ordered]@{ Path = $path; Exists = $false; IsDirectory = $false; IsReparse = $false
                Length = [long]0; Hash = $null; Error = $null }
            try {
                # GetAttributes reports a link itself (even a dangling one), never its target.
                $attributes = [IO.File]::GetAttributes($path)
                $info.Exists = $true
                $info.IsDirectory = [bool]($attributes -band [IO.FileAttributes]::Directory)
                $info.IsReparse = [bool]($attributes -band [IO.FileAttributes]::ReparsePoint)
                if (-not $info.IsDirectory) {
                    $info.Length = [long]([IO.FileInfo]::new($path)).Length
                    if ($Hash) { $info.Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash }
                }
            } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
                $info.Exists = $false
            } catch { $info.Error = $_.Exception.Message }
            [pscustomobject]$info
        }
    }
    $listSb = {
        param([string]$Root)
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push('')
        while ($pending.Count -gt 0) {
            $relativeDirectory = $pending.Pop()
            foreach ($child in @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($Root, $relativeDirectory)) -Force -ErrorAction Stop)) {
                $relative = if ($relativeDirectory) { [IO.Path]::Combine($relativeDirectory, $child.Name) } else { $child.Name }
                $isReparse = [bool]($child.Attributes -band [IO.FileAttributes]::ReparsePoint)
                [pscustomobject]@{ RelativePath = $relative; IsDirectory = [bool]$child.PSIsContainer; IsReparse = $isReparse }
                # Never descend into a link: it can loop or lead outside the source tree.
                if ($child.PSIsContainer -and -not $isReparse) { $pending.Push($relative) }
            }
        }
    }
    $finalizeSb = {
        param([object[]]$Moves)
        foreach ($move in $Moves) {
            $removed = $false
            try {
                if ($move.IsDirectory) {
                    [void][IO.Directory]::CreateDirectory($move.Destination)
                } else {
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($move.Destination))
                    if ($move.Overwrite -and [IO.File]::Exists($move.Destination)) {
                        [IO.File]::SetAttributes($move.Destination, [IO.FileAttributes]::Normal)
                        [IO.File]::Delete($move.Destination)
                        $removed = $true
                    }
                    Move-Item -LiteralPath $move.Temp -Destination $move.Destination -Force -ErrorAction Stop
                }
                [pscustomobject]@{ Ok = $true; Error = $null; TempRetained = $false }
            } catch {
                # If the old file is already gone, keep the verified copy rather than delete the only one left.
                [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message
                    TempRetained = [bool]($removed -and [IO.File]::Exists($move.Temp)) }
            }
        }
    }
    $removeSb = {
        param([string]$Path)
        $removeTree = {
            param([string]$Target)
            $attributes = [IO.File]::GetAttributes($Target)
            [IO.File]::SetAttributes($Target, [IO.FileAttributes]::Normal)
            if (-not ($attributes -band [IO.FileAttributes]::Directory)) { [IO.File]::Delete($Target); return }
            if (-not ($attributes -band [IO.FileAttributes]::ReparsePoint)) {
                foreach ($entry in [IO.Directory]::GetFileSystemEntries($Target)) { & $removeTree $entry }
            }
            [IO.Directory]::Delete($Target, $false)
        }
        if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { & $removeTree $Path }
    }
    # Deepest first; non-recursive, so it stops at the first directory that is not empty (or is gone),
    # and never touches a directory that already existed before this transfer.
    $removeEmptyCreatedSb = {
        param([string[]]$Paths)
        foreach ($path in $Paths) {
            if (-not [IO.Directory]::Exists($path)) { continue }
            if ([IO.Directory]::GetFileSystemEntries($path).Length -gt 0) { return }
            [IO.Directory]::Delete($path, $false)
        }
    }
    $copyPayload = {
        param([string]$From, [string]$To, [bool]$Tree)
        if ($Direction -eq 'ToVM') {
            Copy-Item -LiteralPath $From -ToSession $Session -Destination $To -Recurse:$Tree -Force -ErrorAction Stop
        } else {
            Copy-Item -LiteralPath $From -FromSession $Session -Destination $To -Recurse:$Tree -Force -ErrorAction Stop
        }
    }
    $removeTemp = {
        param([string]$Path)
        try { $null = Invoke-LabTransferSide $Session $destinationRemote $removeSb @($Path) }
        catch { Write-Warning "Could not remove temporary transfer item '$Path': $($_.Exception.Message)" }
    }
    $assertConnected = {
        param($ErrorRecord)
        if ([string]$Session.State -eq 'Opened' -and
            $ErrorRecord.Exception -isnot [Management.Automation.Remoting.PSRemotingTransportException]) { return }
        throw ("The PowerShell Direct connection failed during the transfer: {0} Counts before the failure: Completed={1}, Skipped={2}, Failed={3}. Inspect the destination before retrying; a '*.labxfer-*.tmp' item may remain next to it." -f
            $ErrorRecord.Exception.Message, $state.Completed, $state.Skipped, $state.Failed)
    }
    $getMismatch = {
        param($Expected, $Actual)
        if ($Expected.Error) { return "could not re-read the source: $($Expected.Error)" }
        if ($Actual.Error) { return "could not inspect the copied data: $($Actual.Error)" }
        if (-not $Actual.Exists -or $Actual.IsDirectory) { return 'the copied file is missing from the temporary location' }
        if ($Actual.Length -ne $Expected.Length) { return "size mismatch after copy (source $($Expected.Length) bytes, copy $($Actual.Length) bytes)" }
        if ($VerifyHash -and (-not $Expected.Hash -or $Actual.Hash -ne $Expected.Hash)) { return 'SHA-256 mismatch after copy' }
        return $null
    }
    # Runs on the destination side, same as $finalizeSb -- the executing session there is the guest
    # account that owns a ToVM destination, or $null (host) for a FromVM destination.
    $applyPrivateAcl = {
        param([string]$Path, [bool]$IsDirectory)
        Set-LabTransferPrivateAcl -Session $(if ($destinationRemote) { $Session } else { $null }) -Path $Path -IsDirectory $IsDirectory
    }
    # Unique sibling name: same volume as the destination (so finalize is a rename) and never
    # mistaken for, or colliding with, a real item.
    $tempPath = "$DestinationPath.labxfer-$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    $retainTemp = $false

    if ($Recurse) {
        $root = @(Invoke-LabTransferSide $Session $sourceRemote $statSb @([string[]]@($SourcePath), $false))[0]
        if ($root.Error) { & $fail "${SourcePath}: source could not be inspected: $($root.Error)"; return & $summary }
        if (-not $root.Exists) { & $fail "${SourcePath}: source does not exist."; return & $summary }
        if (-not $root.IsDirectory) { & $fail "${SourcePath}: source is a file; a recursive transfer requires a directory."; return & $summary }
        $destinationRoot = @(Invoke-LabTransferSide $Session $destinationRemote $statSb @([string[]]@($DestinationPath), $false))[0]
        $rootAction = Resolve-LabTransferItemAction $state $SourcePath $DestinationPath $true $root.IsReparse $destinationRoot $OnConflict
        if ($rootAction -eq 'Error') { return & $summary }

        try { $items = @(Invoke-LabTransferSide $Session $sourceRemote $listSb @($SourcePath)) }
        catch {
            & $assertConnected $_
            & $fail "${SourcePath}: source tree could not be enumerated: $($_.Exception.Message)"
            return & $summary
        }
        # Every conflict is resolved against the real destination before any payload moves.
        $destinationStats = @{}
        if ($items.Count -gt 0) {
            $paths = [string[]]@($items | ForEach-Object { [IO.Path]::Combine($DestinationPath, $_.RelativePath) })
            foreach ($stat in @(Invoke-LabTransferSide $Session $destinationRemote $statSb @($paths, $false))) {
                $destinationStats[[string]$stat.Path] = $stat
            }
        }
        $plan = [Collections.Generic.List[object]]::new()
        $excludedDirectories = [Collections.Generic.List[string]]::new()
        foreach ($item in $items) {
            $sourceItem = [IO.Path]::Combine($SourcePath, $item.RelativePath)
            $destinationItem = [IO.Path]::Combine($DestinationPath, $item.RelativePath)
            $underExcluded = @($excludedDirectories | Where-Object {
                $item.RelativePath.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            if ($underExcluded) { & $fail "${destinationItem}: not transferred because a parent directory failed."; continue }
            $action = Resolve-LabTransferItemAction $state $sourceItem $destinationItem ([bool]$item.IsDirectory) `
                ([bool]$item.IsReparse) $destinationStats[$destinationItem] $OnConflict
            if ($action -in @('Error', 'Skip')) {
                if ($item.IsDirectory) { $excludedDirectories.Add([string]$item.RelativePath) }
                continue
            }
            $plan.Add([pscustomobject]@{ RelativePath = [string]$item.RelativePath; IsDirectory = [bool]$item.IsDirectory
                Source = $sourceItem; Destination = $destinationItem; Temp = [IO.Path]::Combine($tempPath, $item.RelativePath)
                Action = $action; Done = $false; Length = [long]0 })
        }
        $files = @($plan | Where-Object { -not $_.IsDirectory })
        if ($DryRun) {
            foreach ($entry in $files) {
                $verb = if ($entry.Action -eq 'Overwrite') { 'overwrite' } else { 'copy' }
                Write-Host "Dry run: would $verb $($entry.Source) -> $($entry.Destination)"
                $state.Completed++
            }
            return & $summary
        }

        try {
            if ($files.Count -gt 0) {
                if (@($items | Where-Object { $_.IsReparse }).Count -gt 0) {
                    # A whole-tree Copy-Item would follow the rejected links, so copy surviving files one by one.
                    $temporaryDirectories = @(@{ IsDirectory = $true; Destination = $tempPath }) +
                        @($plan | Where-Object { $_.IsDirectory } | ForEach-Object { @{ IsDirectory = $true; Destination = $_.Temp } })
                    $null = Invoke-LabTransferSide $Session $destinationRemote $finalizeSb @(, $temporaryDirectories)
                    foreach ($entry in $files) {
                        try { & $copyPayload $entry.Source $entry.Temp $false }
                        catch {
                            & $assertConnected $_
                            & $fail "$($entry.Destination): copy failed: $($_.Exception.Message)"
                            $entry.Done = $true
                        }
                    }
                } else {
                    & $copyPayload $SourcePath $tempPath $true
                }
                $pendingFiles = @($files | Where-Object { -not $_.Done })
                if ($pendingFiles.Count -gt 0) {
                    $expected = @(Invoke-LabTransferSide $Session $sourceRemote $statSb @([string[]]@($pendingFiles | ForEach-Object { $_.Source }), $VerifyHash))
                    $actual = @(Invoke-LabTransferSide $Session $destinationRemote $statSb @([string[]]@($pendingFiles | ForEach-Object { $_.Temp }), $VerifyHash))
                    for ($i = 0; $i -lt $pendingFiles.Count; $i++) {
                        $problem = & $getMismatch $expected[$i] $actual[$i]
                        if ($problem) { & $fail "$($pendingFiles[$i].Destination): $problem"; $pendingFiles[$i].Done = $true }
                        else { $pendingFiles[$i].Length = [long]$actual[$i].Length }
                    }
                }
            }
            # No file survived (for example, a remote copy nested the tree one level deeper): abandon the
            # whole operation without touching the destination, not even to create its directory skeleton.
            if ($files.Count -gt 0 -and @($files | Where-Object { -not $_.Done }).Count -eq 0) {
                $abandoned = "directory transfer abandoned: none of the $($files.Count) file(s) copied verified, so nothing was created or changed under '$DestinationPath'."
                & $fail "${DestinationPath}: $abandoned"
                foreach ($entry in @($plan | Where-Object { $_.IsDirectory })) { & $fail "$($entry.Destination): not created; $abandoned" }
                return & $summary
            }
            # Only items that passed the upfront check and verification ever reach the real destination.
            $finalEntries = @($null) + @($plan | Where-Object { $_.IsDirectory -or -not $_.Done })
            $moves = @($finalEntries | ForEach-Object {
                if ($null -eq $_) { @{ IsDirectory = $true; Destination = $DestinationPath } }
                elseif ($_.IsDirectory) { @{ IsDirectory = $true; Destination = $_.Destination } }
                else { @{ IsDirectory = $false; Temp = $_.Temp; Destination = $_.Destination; Overwrite = ($_.Action -eq 'Overwrite') } }
            })
            $results = @(Invoke-LabTransferSide $Session $destinationRemote $finalizeSb @(, $moves))
            for ($i = 0; $i -lt $finalEntries.Count; $i++) {
                $entry = $finalEntries[$i]
                $label = if ($null -eq $entry) { $DestinationPath } else { $entry.Destination }
                $isDirectory = ($null -eq $entry) -or $entry.IsDirectory
                if ($null -ne $entry -and -not $entry.IsDirectory) { $entry.Done = $true }
                if (-not $results[$i].Ok) {
                    if ($results[$i].TempRetained) {
                        $retainTemp = $true
                        & $fail "${label}: the existing file was removed but the verified copy could not be moved into place ($($results[$i].Error)); the copy was kept in '$tempPath'."
                    } else { & $fail "${label}: could not be finalized: $($results[$i].Error)" }
                } else {
                    # A directory is only re-secured when this transfer itself created it: re-touching
                    # an already-existing directory would reach pre-existing siblings inside it.
                    $newlyCreatedDirectory = if ($null -eq $entry) { -not $destinationRoot.Exists }
                        elseif ($entry.IsDirectory) { -not [bool]$destinationStats[$entry.Destination].Exists } else { $false }
                    $aclOk = $true
                    if ($PermissionProfile -eq 'PrivateFiles' -and (-not $isDirectory -or $newlyCreatedDirectory)) {
                        try { & $applyPrivateAcl $label $isDirectory }
                        catch { $aclOk = $false; & $fail "${label}: copied successfully but the private-file permission could not be applied: $($_.Exception.Message)" }
                    }
                    if ($aclOk -and $null -ne $entry -and -not $entry.IsDirectory) {
                        $state.Completed++
                        $state.BytesTransferred += $entry.Length
                    }
                }
            }
        } catch {
            $transferError = $_
            & $assertConnected $transferError
            foreach ($entry in @($files | Where-Object { -not $_.Done })) {
                & $fail "$($entry.Destination): not transferred: $($transferError.Exception.Message)"
            }
        } finally {
            if (-not $retainTemp) { & $removeTemp $tempPath }
        }
        return & $summary
    } else {
        $source = @(Invoke-LabTransferSide $Session $sourceRemote $statSb @([string[]]@($SourcePath), $false))[0]
        if ($source.Error) { & $fail "${SourcePath}: source could not be inspected: $($source.Error)"; return & $summary }
        if (-not $source.Exists) { & $fail "${SourcePath}: source does not exist."; return & $summary }
        if ($source.IsDirectory -and -not $source.IsReparse) {
            & $fail "${SourcePath}: source is a directory; use a recursive transfer."
            return & $summary
        }
        # The destination's ancestors (deepest first, drive root excluded) are inspected in the same call,
        # so a missing parent directory can be created like the directory branch creates its own.
        $ancestors = [Collections.Generic.List[string]]::new()
        try {
            for ($ancestor = [IO.Path]::GetDirectoryName($DestinationPath); $ancestor -and $ancestor -notmatch '^[A-Za-z]:[\\/]?$';
                $ancestor = [IO.Path]::GetDirectoryName($ancestor)) { $ancestors.Add($ancestor) }
        } catch [ArgumentException] {
            # An invalid path is left to the destination inspection below, which reports it as a failed item.
            $ancestors.Clear()
        }
        # The conflict is resolved before any Copy-Item: a refused or skipped item moves zero bytes.
        $destinationStats = @(Invoke-LabTransferSide $Session $destinationRemote $statSb @([string[]](@($DestinationPath) + $ancestors.ToArray()), $false))
        $destination = $destinationStats[0]
        $action = Resolve-LabTransferItemAction $state $SourcePath $DestinationPath $false $source.IsReparse $destination $OnConflict
        if ($action -in @('Error', 'Skip')) { return & $summary }
        # Only the contiguous run of missing directories directly above the destination; never one that exists.
        $missingParents = [Collections.Generic.List[string]]::new()
        for ($i = 1; $i -lt $destinationStats.Count; $i++) {
            if ($destinationStats[$i].Exists -or $destinationStats[$i].Error) { break }
            $missingParents.Add([string]$destinationStats[$i].Path)
        }
        if ($DryRun) {
            $verb = if ($action -eq 'Overwrite') { 'overwrite' } else { 'copy' }
            Write-Host "Dry run: would $verb $SourcePath -> $DestinationPath"
            $state.Completed++
            return & $summary
        }
        $createdParents = @()
        try {
            if ($missingParents.Count -gt 0) {
                # Recorded before the attempt: a partial creation is still cleaned up below.
                $createdParents = $missingParents.ToArray()
                $parentResult = @(Invoke-LabTransferSide $Session $destinationRemote $finalizeSb @(, @(@{ IsDirectory = $true; Destination = $missingParents[0] })))[0]
                if (-not $parentResult.Ok) {
                    & $fail "${DestinationPath}: the missing destination parent directory could not be created: $($parentResult.Error)"
                    return & $summary
                }
            }
            & $copyPayload $SourcePath $tempPath $false
            $expected = @(Invoke-LabTransferSide $Session $sourceRemote $statSb @([string[]]@($SourcePath), $VerifyHash))[0]
            $actual = @(Invoke-LabTransferSide $Session $destinationRemote $statSb @([string[]]@($tempPath), $VerifyHash))[0]
            $problem = & $getMismatch $expected $actual
            if ($problem) {
                & $fail "${DestinationPath}: $problem"
            } else {
                $move = @{ IsDirectory = $false; Temp = $tempPath; Destination = $DestinationPath; Overwrite = ($action -eq 'Overwrite') }
                $result = @(Invoke-LabTransferSide $Session $destinationRemote $finalizeSb @(, @($move)))[0]
                if ($result.Ok) {
                    $aclOk = $true
                    if ($PermissionProfile -eq 'PrivateFiles') {
                        try { & $applyPrivateAcl $DestinationPath $false }
                        catch { $aclOk = $false; & $fail "${DestinationPath}: copied successfully but the private-file permission could not be applied: $($_.Exception.Message)" }
                    }
                    if ($aclOk) {
                        $state.Completed++
                        $state.BytesTransferred += [long]$actual.Length
                    }
                } elseif ($result.TempRetained) {
                    $retainTemp = $true
                    & $fail "${DestinationPath}: the existing file was removed but the verified copy could not be moved into place ($($result.Error)); the copy was kept at '$tempPath'."
                } else { & $fail "${DestinationPath}: could not be finalized: $($result.Error)" }
            }
        } catch {
            & $assertConnected $_
            & $fail "${DestinationPath}: not transferred: $($_.Exception.Message)"
        } finally {
            if (-not $retainTemp) { & $removeTemp $tempPath }
            # A failed copy does not leave behind the empty parent directories it created itself.
            if ($createdParents.Count -gt 0 -and $state.Completed -eq 0) {
                try { $null = Invoke-LabTransferSide $Session $destinationRemote $removeEmptyCreatedSb @(, [string[]]$createdParents) }
                catch { Write-Warning "Could not remove the directory created for this transfer above '$DestinationPath': $($_.Exception.Message)" }
            }
        }
        return & $summary
    }
}

function ConvertFrom-LabSftpListing {
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Output,
        [int]$ExitCode,
        [string]$Path,
        [switch]$ParentListing
    )
    # Parses captured sftp batch output (KeyAgent mode only; password mode captures none) for the
    # long-listing line naming $Path. Returns the same shape as the engine's other probes: the leading
    # mode character ('-' file, 'd' directory, 'l' symlink, anything else a special file) and the size.
    # The name is matched exactly, either as the bare leaf name (a server's own long name, used when
    # listing a directory) or as the full path (the client's reformatted line) -- both forms occur.
    # ListingNotFound is $true only when the listed path itself was reported missing.
    #
    # -ParentListing: $Output is an `ls -la` of $Path's parent directory, and "no line names $Path"
    # becomes "absent" only when the listing is positively recognized -- its own '.' entry parsed, and
    # no unparsed line ends in $Path's name. Otherwise it is an error, never "absent": an existing
    # destination misread as absent would let the final rename replace it under Error or Skip.
    $lines = @($Output | Where-Object { $_ } | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -notmatch '^sftp>' })
    if ($ExitCode -ne 0) {
        if (@($lines | Where-Object { $_ -match 'not found|No such file' }).Count -gt 0) {
            return [pscustomobject]@{ Exists = $false; Mode = $null; Size = [long]-1; Error = $null; ListingNotFound = $true }
        }
        return [pscustomobject]@{ Exists = $false; Mode = $null; Size = [long]-1; ListingNotFound = $false
            Error = "the guest-side listing failed (sftp exit $ExitCode): $(@($lines | Select-Object -Last 3) -join ' ')" }
    }
    $leaf = $Path.Substring($Path.LastIndexOf('/') + 1)
    $parent = $Path.Substring(0, [Math]::Max($Path.LastIndexOf('/'), 0))
    if ($parent -eq '') { $parent = '/' }
    $pattern = '^(?<mode>\S)\S*\s+\d+\s+\S+\s+\S+\s+(?<size>\d+)\s+\S+\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4})\s(?<name>.+)$'
    $selfParsed = $false
    $parentNotDirectory = $false
    $unparsedNamesTarget = $false
    foreach ($line in $lines) {
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) {
            # Something is listed under the target's name in a shape the pattern does not know (a device
            # node's "major, minor" size field, an unexpected date format, ...).
            $trimmed = $line.TrimEnd()
            foreach ($suffix in @(" $leaf", "/$leaf")) {
                if ($trimmed.EndsWith($suffix, [StringComparison]::Ordinal) -or $trimmed.Contains("$suffix -> ")) { $unparsedNamesTarget = $true }
            }
            continue
        }
        $name = $match.Groups['name'].Value
        $mode = $match.Groups['mode'].Value
        # Some servers append " -> target" to a symlink's long name.
        if ($mode -eq 'l' -and $name.Contains(' -> ')) { $name = $name.Substring(0, $name.IndexOf(' -> ')) }
        if ($name -ceq '.' -and $mode -eq 'd') { $selfParsed = $true }
        # Listing a non-directory prints that item's own line, under its full path.
        if ($ParentListing -and $name -ceq $parent -and $mode -ne 'd') { $parentNotDirectory = $true }
        if ($name -ceq $leaf -or $name -ceq $Path) {
            return [pscustomobject]@{ Exists = $true; Mode = $mode; Size = [long]$match.Groups['size'].Value; Error = $null; ListingNotFound = $false }
        }
    }
    $problem = $null
    if ($ParentListing) {
        if ($parentNotDirectory) { $problem = "the guest-side parent '$parent' exists but is not a directory" }
        elseif ($unparsedNamesTarget) { $problem = "the guest-side listing of '$parent' has an entry named '$leaf' in a format that was not recognized; refusing to treat it as absent" }
        elseif (-not $selfParsed) { $problem = "the guest-side listing format of '$parent' was not recognized (its '.' entry did not parse); refusing to treat '$leaf' as absent" }
    }
    return [pscustomobject]@{ Exists = $false; Mode = $null; Size = [long]-1; Error = $problem; ListingNotFound = $false }
}

function Copy-LabTransferItemSftp {
    param(
        [string]$HostNameOrAddress,
        [int]$Port,
        [string]$UserName,
        [AllowNull()][AllowEmptyString()][string]$IdentityFilePath,
        [string]$AuthMode,
        [ValidateSet('ToVM', 'FromVM')][string]$Direction,
        [string]$SourcePath,
        [string]$DestinationPath,
        [bool]$Recurse,
        [ValidateSet('Error', 'Skip', 'Overwrite')][string]$OnConflict,
        [bool]$VerifyHash,
        [bool]$DryRun,
        [ValidateSet('Default', 'PrivateFiles')][string]$PermissionProfile = 'Default'
    )
    # Every connection is a separate ssh.exe/sftp.exe process (no connection reuse; see README), so in
    # InteractivePassword mode each one below asks for the password: a single-file upload needs up to
    # four (upfront check, upload, size/hash check, finalize), a single-file download three (upfront
    # check, download, size/hash check), a directory two, plus one for cleanup after a failed upload and
    # one more to remove guest-side parent directories the failed upload created. Creating missing
    # parents costs none: the walk rides in the upfront check and the mkdir lines in the payload batch.
    # PrivateFiles on an upload costs none either (its mode line rides in the finalize batch), except
    # that a failed finalize batch then needs up to two more to tell whether the rename had already
    # landed. That is the cost of checking the copy strictly before it is moved into place.
    if ($AuthMode -notin @('KeyAgent', 'InteractivePassword')) { throw "Unknown SSH auth mode '$AuthMode'." }
    $state = @{ Completed = 0; Skipped = 0; Failed = 0; BytesTransferred = [long]0
        Errors = [Collections.Generic.List[string]]::new() }
    $summary = {
        [pscustomobject]@{ Completed = [int]$state.Completed; Skipped = [int]$state.Skipped; Failed = [int]$state.Failed
            BytesTransferred = [long]$state.BytesTransferred; Errors = [string[]]$state.Errors.ToArray() }
    }
    $fail = { param([string]$Message) $state.Failed++; $state.Errors.Add($Message) }
    $toVM = $Direction -eq 'ToVM'
    $passwordMode = $AuthMode -eq 'InteractivePassword'
    $privateFiles = $PermissionProfile -eq 'PrivateFiles'

    # --- Paths: validated before any connection is made. ---
    # Characters sftp's batch parser or its globbing treat specially even inside double quotes are
    # rejected rather than escaped.
    $localPath = if ($toVM) { $SourcePath } else { $DestinationPath }
    $remotePath = if ($toVM) { $DestinationPath } else { $SourcePath }
    if ($localPath -notmatch '^[A-Za-z]:[\\/]') { & $fail "${localPath}: host-side transfer paths must be absolute drive-letter paths."; return & $summary }
    $localPath = $localPath.TrimEnd('\', '/')
    if ($localPath -match '^[A-Za-z]:$') { & $fail "${localPath}\: a drive root cannot be a transfer source or destination."; return & $summary }
    if ($localPath -match '[\x00-\x1F\x7F"*?\[\]{}]') {
        & $fail "${localPath}: host-side path contains a character sftp treats specially even when quoted (`", *, ?, [, ], {, } or a control character); such paths are not supported."
        return & $summary
    }
    $remoteProblem = $null
    if (-not $remotePath.StartsWith('/')) { $remoteProblem = 'guest-side transfer paths must be absolute POSIX paths (starting with /).' }
    else {
        $remotePath = $remotePath.TrimEnd('/')
        if ($remotePath -eq '') { $remoteProblem = 'the guest root directory cannot be a transfer source or destination.' }
        elseif ($remotePath -match '[\x00-\x1F\x7F"\\*?\[\]{}]') {
            $remoteProblem = 'guest-side path contains a character sftp treats specially even when quoted (", \, *, ?, [, ], {, } or a control character); such paths are not supported.'
        } elseif (@($remotePath.Substring(1).Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
            $remoteProblem = 'guest-side path must not contain empty, "." or ".." segments.'
        }
    }
    if ($remoteProblem) { & $fail "${remotePath}: $remoteProblem"; return & $summary }
    $sourceLabel = if ($toVM) { $localPath } else { $remotePath }
    $destinationLabel = if ($toVM) { $remotePath } else { $localPath }
    # Unique sibling name, same directory as the destination so the finalize is a rename.
    $tempSuffix = ".labxfer-$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    $remoteTemp = "$remotePath$tempSuffix"
    $localTemp = "$localPath$tempSuffix"

    # --- Connection helpers. Exit code 255 is OpenSSH's connection-level failure (unreachable, refused,
    # authentication or host-key failure, dropped connection); it throws. Any other nonzero exit is a
    # command failing inside a working session and becomes a per-item failure. ---
    $quote = { param([string]$Path) '"' + $Path + '"' }
    $shellQuote = { param([string]$Path) "'" + $Path.Replace("'", "'\''") + "'" }
    $tail = { param($Result) @($Result.Output | Where-Object { $_ -and $_ -notmatch '^sftp>' } | Select-Object -Last 3) -join ' ' }
    $connectionLost = {
        param([string]$Tool, $Result)
        throw ("The SSH connection failed during the transfer ({0} exit 255: {1}). Counts before the failure: Completed={2}, Skipped={3}, Failed={4}. Inspect the destination before retrying; if the copy had started, a '*.labxfer-*.tmp' item may remain next to it." -f
            $Tool, (& $tail $Result), $state.Completed, $state.Skipped, $state.Failed)
    }
    $runBatch = {
        param([string[]]$Lines)
        $batchPath = Join-Path ([IO.Path]::GetTempPath()) ('labsftp-' + [guid]::NewGuid().ToString('N') + '.batch')
        $result = $null
        try {
            [IO.File]::WriteAllText($batchPath, (($Lines -join "`n") + "`n"))
            # Invoke-LabSftpCommand returns exactly one result object in both modes (its password branch
            # sends sftp's stdout to the console, not to its return value).
            $result = Invoke-LabSftpCommand $HostNameOrAddress $Port $UserName $IdentityFilePath $batchPath $AuthMode
        } finally {
            if ([IO.File]::Exists($batchPath)) { [IO.File]::Delete($batchPath) }
        }
        if ($null -eq $result) { throw 'sftp returned no result.' }
        if ($result.ExitCode -eq 255) { & $connectionLost 'sftp' $result }
        return $result
    }
    $runSsh = {
        param([string]$RemoteCommand)
        $result = Invoke-LabSshCommand $HostNameOrAddress $Port $UserName $IdentityFilePath $AuthMode $RemoteCommand
        if ($result.ExitCode -eq 255) { & $connectionLost 'ssh' $result }
        return $result
    }

    # --- Probes: one shape for both sides, Mode being '-' file, 'd' directory, 'l' link, else special. ---
    $probeLocal = {
        param([string]$Path)
        $info = @{ Exists = $false; Mode = $null; Size = [long]-1; Error = $null }
        try {
            # GetAttributes reports a link itself (even a dangling one), never its target.
            $attributes = [IO.File]::GetAttributes($Path)
            $info.Exists = $true
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { $info.Mode = 'l' }
            elseif ($attributes -band [IO.FileAttributes]::Directory) { $info.Mode = 'd' }
            else { $info.Mode = '-'; $info.Size = [long]([IO.FileInfo]::new($Path)).Length }
        } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
            $info.Exists = $false
        } catch { $info.Error = $_.Exception.Message }
        return [pscustomobject]$info
    }
    $remoteParentOf = {
        param([string]$Path)
        $i = $Path.LastIndexOf('/')
        if ($i -le 0) { return '/' }
        return $Path.Substring(0, $i)
    }
    # -WithAncestors (the upload destination): when the path does not exist, MissingParents also lists
    # the contiguous run of missing directories directly above it, deepest first -- never one that
    # exists -- and a nearest existing ancestor that is not a directory is an error.
    $probeRemote = {
        param([string]$Path, [bool]$WithAncestors = $false)
        $missingParents = [Collections.Generic.List[string]]::new()
        $ancestors = [Collections.Generic.List[string]]::new()
        for ($a = & $remoteParentOf $Path; $a -ne '/'; $a = & $remoteParentOf $a) { $ancestors.Add($a) }
        if ($passwordMode) {
            # Password mode captures no output (the console is the operator's), so the guest's shell
            # answers through its exit code, which $LASTEXITCODE reports either way. The ancestor walk
            # rides in the same call, so it costs no extra password prompt: 10 = missing with its
            # parent present, 30+N = missing with N missing parents, 15 = the nearest existing
            # ancestor is not a directory.
            $p = & $shellQuote $Path
            $command = "if [ -L $p ]; then exit 13; elif [ -d $p ]; then exit 12; elif [ -f $p ]; then exit 11; elif [ -e $p ]; then exit 14; "
            if (-not $WithAncestors) { $command += 'else exit 10; fi' }
            else {
                if ($ancestors.Count -gt 200) {
                    return [pscustomobject]@{ Exists = $false; Mode = $null; Size = [long]-1; MissingParents = [string[]]@()
                        Error = 'the guest-side path is too deeply nested (more than 200 parent directories).' }
                }
                $command += 'fi'
                for ($i = 0; $i -lt $ancestors.Count; $i++) {
                    $q = & $shellQuote $ancestors[$i]
                    $code = if ($i -eq 0) { 10 } else { 30 + $i }
                    $command += "; if [ -d $q ]; then exit $code; elif [ -e $q ] || [ -L $q ]; then exit 15; fi"
                }
                $command += "; exit $(if ($ancestors.Count -eq 0) { 10 } else { 30 + $ancestors.Count })"
            }
            $result = & $runSsh $command
            $modes = @{ 11 = '-'; 12 = 'd'; 13 = 'l'; 14 = '?' }
            $code = $result.ExitCode
            if ($code -eq 10) { return [pscustomobject]@{ Exists = $false; Mode = $null; Size = [long]-1; Error = $null; MissingParents = [string[]]@() } }
            if ($modes.ContainsKey($code)) {
                return [pscustomobject]@{ Exists = $true; Mode = $modes[$code]; Size = [long]-1; Error = $null; MissingParents = [string[]]@() }
            }
            if ($WithAncestors -and $code -eq 15) {
                return [pscustomobject]@{ Exists = $false; Mode = $null; Size = [long]-1; MissingParents = [string[]]@()
                    Error = 'a guest-side parent directory exists but is not a directory.' }
            }
            if ($WithAncestors -and $code -gt 30 -and $code -le 30 + $ancestors.Count) {
                return [pscustomobject]@{ Exists = $false; Mode = $null; Size = [long]-1; Error = $null
                    MissingParents = [string[]]@($ancestors | Select-Object -First ($code - 30)) }
            }
            return [pscustomobject]@{ Exists = $false; Mode = $null; Size = [long]-1; MissingParents = [string[]]@()
                Error = "the guest-side check failed (ssh exit $code); password mode needs a POSIX-compatible login shell on the guest." }
        }
        # The parent is listed, not the path itself: sftp's ls of a symlink to a directory silently
        # lists the target's contents, so only the parent's listing shows the entry's own mode.
        $listParentOf = {
            param([string]$Item)
            $listing = & $runBatch @('ls -la ' + (& $quote (& $remoteParentOf $Item)))
            return ConvertFrom-LabSftpListing $listing.Output $listing.ExitCode $Item -ParentListing
        }
        $info = & $listParentOf $Path
        if ($WithAncestors -and -not $info.Error -and -not $info.Exists -and $info.ListingNotFound) {
            # The parent itself is missing: walk upward one listing (one connection) per missing level
            # until a listing succeeds, so the run of missing directories is known before any write.
            foreach ($ancestor in $ancestors) {
                $up = & $listParentOf $ancestor
                if ($up.Error) { return [pscustomobject]@{ Exists = $false; Mode = $null; Size = [long]-1; Error = $up.Error; MissingParents = [string[]]@() } }
                if ($up.Exists) {
                    # Its own listing said "not found", yet its parent lists it: a broken link or another
                    # non-directory, which no file can be created under.
                    return [pscustomobject]@{ Exists = $false; Mode = $null; Size = [long]-1; MissingParents = [string[]]@()
                        Error = "the guest-side parent '$ancestor' exists but is not a directory." }
                }
                $missingParents.Add($ancestor)
                if (-not $up.ListingNotFound) { break }
            }
            if ($missingParents.Count -eq 0 -or ($missingParents.Count -eq $ancestors.Count -and $up.ListingNotFound)) {
                return [pscustomobject]@{ Exists = $false; Mode = $null; Size = [long]-1; MissingParents = [string[]]@()
                    Error = 'the guest-side listing could not find any existing parent directory.' }
            }
        }
        return [pscustomobject]@{ Exists = $info.Exists; Mode = $info.Mode; Size = $info.Size; Error = $info.Error
            MissingParents = [string[]]$missingParents.ToArray() }
    }
    # Guest-side size/hash check, answered by exit code: 0 match, 20 size mismatch, 21 no sha256sum,
    # 22 hash mismatch, 23 the size check itself could not run (stat produced no usable number -- e.g.
    # the file is missing or unreadable -- so no size comparison happened at all).
    # A negative $Size skips the size test; an empty $Hash skips the hash test.
    $verifyRemote = {
        param([string]$Path, [long]$Size, [AllowEmptyString()][string]$Hash)
        $p = & $shellQuote $Path
        $parts = [Collections.Generic.List[string]]::new()
        if ($Size -ge 0) {
            # stat's own failure (missing file, permission denied, ...) must not be mistaken for a real
            # size disagreement: the old one-line '[ $(stat ...) -eq N ]' sent a stat error (an empty
            # command substitution) down the same exit-20 path as a genuinely differing size. $s is
            # captured and validated as pure digits first, so exit 20 now only fires once a real number
            # was compared against $Size. (No double quotes: Invoke-LabSshCommand rejects any remote
            # command containing one, and none are needed here since stat's output is digits-only.)
            $parts.Add('s=$(stat -c %s ' + $p + ' 2>/dev/null)')
            $parts.Add('case ${s:-X} in *[!0-9]*) exit 23 ;; esac')
            $parts.Add('[ $s -eq ' + $Size + ' ] || exit 20')
        }
        if ($Hash) {
            $parts.Add('command -v sha256sum >/dev/null 2>&1 || exit 21')
            $parts.Add('h=$(sha256sum ' + $p + ' 2>/dev/null) || exit 22')
            $parts.Add('[ ${h%% *} = ' + $Hash + ' ] 2>/dev/null || exit 22')
        }
        $parts.Add('exit 0')
        $result = & $runSsh ($parts -join '; ')
        switch ($result.ExitCode) {
            0 { return $null }
            20 { return "size mismatch after copy (expected $Size bytes)" }
            21 { return 'SHA-256 could not be checked: sha256sum is not available on the guest' }
            22 { return 'SHA-256 mismatch after copy' }
            23 { return "the guest-side size check could not be completed for '$Path' (stat returned no usable size, e.g. the file is missing or unreadable); this is not a confirmed size mismatch." }
        }
        return "the guest-side size/hash check failed (ssh exit $($result.ExitCode)); it needs a POSIX-compatible login shell on the guest."
    }
    # $null when the host-side file cannot be hashed; callers turn that into a per-item failure.
    $localHash = {
        param([string]$Path)
        try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { return $null }
    }
    # Sums file sizes and reports the first reparse point; never descends into a link.
    $scanLocalTree = {
        param([string]$Root)
        $scan = @{ Bytes = [long]0; Reparse = $null; Error = $null }
        try {
            $pending = [Collections.Generic.Stack[string]]::new()
            $pending.Push($Root)
            while ($pending.Count -gt 0 -and -not $scan.Reparse) {
                foreach ($entry in ([IO.DirectoryInfo]::new($pending.Pop())).GetFileSystemInfos()) {
                    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $scan.Reparse = $entry.FullName; break }
                    if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry.FullName) } else { $scan.Bytes += $entry.Length }
                }
            }
        } catch { $scan.Error = $_.Exception.Message }
        return [pscustomobject]$scan
    }
    $removeLocal = {
        param([string]$Path)
        $removeTree = {
            param([string]$Target)
            $attributes = [IO.File]::GetAttributes($Target)
            [IO.File]::SetAttributes($Target, [IO.FileAttributes]::Normal)
            if (-not ($attributes -band [IO.FileAttributes]::Directory)) { [IO.File]::Delete($Target); return }
            if (-not ($attributes -band [IO.FileAttributes]::ReparsePoint)) {
                foreach ($entry in [IO.Directory]::GetFileSystemEntries($Target)) { & $removeTree $entry }
            }
            [IO.Directory]::Delete($Target, $false)
        }
        try { if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { & $removeTree $Path } }
        catch { Write-Warning "Could not remove temporary transfer item '$Path': $($_.Exception.Message)" }
    }
    $removeRemoteTemp = {
        try {
            $result = & $runBatch @('rm ' + (& $quote $remoteTemp))
            if ($result.ExitCode -ne 0) { Write-Warning "Could not remove temporary transfer item '$remoteTemp' on the guest (sftp exit $($result.ExitCode))." }
        } catch { Write-Warning "Could not remove temporary transfer item '$remoteTemp' on the guest: $($_.Exception.Message)" }
    }
    # --- PrivateFiles. The guest-side mode line is appended after the rename in the finalize batch, so
    # when that batch fails, its exit code alone cannot say whether the rename had already run. ---
    # $true: the rename landed (the temp is gone and the destination is there as $ExpectedMode), so only
    # the mode line can have failed. $false: it did not land. $null: the guest could not be inspected.
    $renameLanded = {
        param([string]$ExpectedMode)
        $temp = & $probeRemote $remoteTemp
        if ($temp.Error) { return $null }
        if ($temp.Exists) { return $false }
        $landedItem = & $probeRemote $remotePath
        if ($landedItem.Error) { return $null }
        return [bool]($landedItem.Exists -and $landedItem.Mode -eq $ExpectedMode)
    }
    # A successful batch exit with a setstat error line in its output (OpenSSH prints "Couldn't setstat
    # on ..." or "remote setstat ..." for a failed mode change) still counts as a failed mode change.
    # Password mode captures no output, so there the exit code is the only signal.
    $setstatError = {
        param($Result)
        return @($Result.Output | Where-Object { $_ -and $_ -notmatch '^sftp>' -and $_ -match '(?i)setstat' } | Select-Object -First 1)
    }
    # Host side (a download's destination): the same Set-LabTransferPrivateAcl the Windows adapter applies
    # to its own downloads, with no session. A downloaded tree is restricted item by item, deepest first:
    # protecting a directory before its contents would strip what they inherit from it. Returns $null,
    # or a description of what could not be restricted.
    $restrictLocal = {
        param([string]$Path, [bool]$IsDirectory)
        $items = [Collections.Generic.List[object]]::new()
        $items.Add([pscustomobject]@{ Path = $Path; IsDirectory = $IsDirectory })
        try {
            if ($IsDirectory) {
                # Parents are listed before their contents, so the reverse order below is deepest first.
                $pending = [Collections.Generic.Stack[string]]::new()
                $pending.Push($Path)
                while ($pending.Count -gt 0) {
                    foreach ($entry in ([IO.DirectoryInfo]::new($pending.Pop())).GetFileSystemInfos()) {
                        $isDir = $entry -is [IO.DirectoryInfo]
                        $items.Add([pscustomobject]@{ Path = $entry.FullName; IsDirectory = $isDir })
                        if ($isDir) { $pending.Push($entry.FullName) }
                    }
                }
            }
        } catch { return "the downloaded tree could not be enumerated: $($_.Exception.Message)" }
        $errors = [Collections.Generic.List[string]]::new()
        for ($i = $items.Count - 1; $i -ge 0; $i--) {
            try { Set-LabTransferPrivateAcl -Session $null -Path $items[$i].Path -IsDirectory $items[$i].IsDirectory }
            catch { $errors.Add($_.Exception.Message) }
        }
        if ($errors.Count -eq 0) { return $null }
        if ($items.Count -eq 1) { return $errors[0] }
        return "$($errors.Count) of $($items.Count) items could not be restricted (first: $($errors[0]))"
    }

    # --- Upfront check: source, then destination, then the conflict decision -- all before any payload
    # command, so a refused or skipped item moves nothing (the same guarantee as the Windows engine). ---
    $source = if ($toVM) { & $probeLocal $localPath } else { & $probeRemote $remotePath }
    if ($source.Error) { & $fail "${sourceLabel}: source could not be inspected: $($source.Error)"; return & $summary }
    if (-not $source.Exists) { & $fail "${sourceLabel}: source does not exist."; return & $summary }
    if ($source.Mode -eq 'l') {
        & $fail "${sourceLabel}: source is a symbolic link, junction or other reparse point; only regular files and plain directories are supported."
        return & $summary
    }
    if ($Recurse -and $source.Mode -ne 'd') { & $fail "${sourceLabel}: source is not a directory; a recursive transfer requires a directory."; return & $summary }
    if (-not $Recurse -and $source.Mode -eq 'd') { & $fail "${sourceLabel}: source is a directory; use a recursive transfer."; return & $summary }
    if (-not $Recurse -and $source.Mode -ne '-') { & $fail "${sourceLabel}: source is not a regular file."; return & $summary }
    $sourceTree = $null
    if ($toVM -and $Recurse) {
        # put -r copies a whole tree and cannot leave out one entry, so a link anywhere inside the
        # host-side tree refuses the whole transfer instead of being followed.
        $sourceTree = & $scanLocalTree $localPath
        if ($sourceTree.Error) { & $fail "${sourceLabel}: source tree could not be enumerated: $($sourceTree.Error)"; return & $summary }
        if ($sourceTree.Reparse) {
            & $fail "${sourceLabel}: the source tree contains a symbolic link, junction or other reparse point ('$($sourceTree.Reparse)'); a recursive SFTP upload cannot exclude it, so nothing was transferred."
            return & $summary
        }
    }
    $destination = if ($toVM) { & $probeRemote $remotePath $true } else { & $probeLocal $localPath }
    if ($destination.Error) { & $fail "${destinationLabel}: destination could not be inspected: $($destination.Error)"; return & $summary }
    # Like the Windows engine, missing parent directories above the destination are created -- only the
    # contiguous run directly above it, never one that exists -- and removed again if nothing completes.
    # Deepest first.
    $missingParents = @()
    if ($toVM) { $missingParents = @($destination.MissingParents) }
    elseif (-not $destination.Exists) {
        try {
            for ($dir = [IO.Path]::GetDirectoryName($localPath); $dir -and $dir -notmatch '^[A-Za-z]:[\\/]?$'; $dir = [IO.Path]::GetDirectoryName($dir)) {
                if ([IO.Directory]::Exists($dir)) { break }
                if ([IO.File]::Exists($dir)) { & $fail "${destinationLabel}: the host-side parent '$dir' exists but is not a directory."; return & $summary }
                $missingParents += $dir
            }
        } catch { & $fail "${destinationLabel}: destination could not be inspected: $($_.Exception.Message)"; return & $summary }
    }
    if ($destination.Mode -eq 'l') {
        & $fail "${destinationLabel}: destination is a symbolic link, junction or other reparse point; refusing to write through it."
        return & $summary
    }
    if ($destination.Exists -and $destination.Mode -notin @('-', 'd')) {
        & $fail "${destinationLabel}: destination exists but is not a regular file or directory; refusing to write to it."
        return & $summary
    }
    $kind = Get-LabTransferConflictKind $Recurse ([bool]$destination.Exists) ($destination.Mode -eq 'd')
    if ($Recurse -and $kind -eq 'Exists') {
        & $fail "Directory '$destinationLabel' already exists; merging into an existing directory on the Linux/SFTP adapter is not supported in this version."
        return & $summary
    }
    $action = Resolve-LabConflictAction $kind $OnConflict
    if ($action -eq 'Error') {
        $why = if ($kind -eq 'TypeMismatch') { 'destination exists as a different type (file vs directory)' } else { 'destination already exists' }
        & $fail "${destinationLabel}: $why."
        return & $summary
    }
    if ($action -eq 'Skip') {
        $state.Skipped++
        Write-Host "Skipped (destination exists): $destinationLabel"
        return & $summary
    }
    if ($Recurse -and $VerifyHash) {
        Write-Warning 'SHA-256 verification is not applied to the files inside a recursive Linux/SFTP transfer in this version; only a single-file transfer is hash-verified.'
    }
    if ($DryRun) {
        $verb = if ($action -eq 'Overwrite') { 'overwrite' } elseif ($Recurse) { 'copy directory' } else { 'copy' }
        $parentsNote = if ($missingParents.Count -eq 1) { ' (creating 1 missing parent directory)' }
            elseif ($missingParents.Count -gt 1) { " (creating $($missingParents.Count) missing parent directories)" } else { '' }
        Write-Host "Dry run: would $verb $sourceLabel -> $destinationLabel$parentsNote"
        $state.Completed++
        return & $summary
    }
    # Guest side: mkdir lines (top-down) lead the payload batch itself, so creating them costs no extra
    # connection; a failing mkdir stops the batch before anything is copied. Cleanup is one best-effort
    # rmdir batch (bottom-up, each line '-'-prefixed so one failure does not stop the rest): sftp's rmdir
    # removes only empty directories, and only the ones found missing upfront are named.
    $remoteMkdirLines = @()
    if ($toVM) { for ($i = $missingParents.Count - 1; $i -ge 0; $i--) { $remoteMkdirLines += 'mkdir ' + (& $quote $missingParents[$i]) } }
    $removeCreatedRemoteParents = {
        if (-not $toVM -or $missingParents.Count -eq 0) { return }
        try {
            $result = & $runBatch @($missingParents | ForEach-Object { '-rmdir ' + (& $quote $_) })
            if ($result.ExitCode -ne 0) { Write-Warning "Could not remove every parent directory created on the guest above '$remotePath' (sftp exit $($result.ExitCode))." }
        } catch { Write-Warning "Could not remove the parent directories created on the guest above '$remotePath': $($_.Exception.Message)" }
    }
    # Host side: created one at a time, top-down, recording only those this call actually created.
    $createdLocalParents = [Collections.Generic.List[string]]::new()
    $createLocalParents = {
        for ($i = $missingParents.Count - 1; $i -ge 0; $i--) {
            if (-not [IO.Directory]::Exists($missingParents[$i])) {
                [void][IO.Directory]::CreateDirectory($missingParents[$i])
                $createdLocalParents.Add($missingParents[$i])
            }
        }
    }
    $removeCreatedLocalParents = {
        for ($i = $createdLocalParents.Count - 1; $i -ge 0; $i--) {
            $dir = $createdLocalParents[$i]
            try {
                # Only while empty: a non-recursive delete fails on anything left inside.
                if ([IO.Directory]::Exists($dir) -and @([IO.Directory]::GetFileSystemEntries($dir)).Count -eq 0) { [IO.Directory]::Delete($dir, $false) }
                else { break }
            } catch { Write-Warning "Could not remove the directory '$dir' created for this transfer: $($_.Exception.Message)"; break }
        }
    }

    # --- Payload. A recursive transfer counts as one item: the tree lands all at once or not at all. ---
    # Unverified without a live guest: what OpenSSH's put -r/get -r do with a symlink nested inside the
    # tree (follow it, skip it, or fail). A host-side tree was scanned above, so for an upload this is
    # moot; for a download the host-side copy is scanned before it is moved into place. See
    # MANUAL-TESTS.md ("Linux transfer engine") for the live step that settles this.
    if ($toVM -and $Recurse) {
        # One session: rename runs only if put -r succeeded (a failing batch command stops the batch),
        # and it is a single atomic POSIX rename of the whole tree.
        $treeBatch = @($remoteMkdirLines + @(('put -r ' + (& $quote $localPath.Replace('\', '/')) + ' ' + (& $quote $remoteTemp)),
            ('rename ' + (& $quote $remoteTemp) + ' ' + (& $quote $remotePath))))
        # PrivateFiles restricts the new directory root only (README: the files inside keep the mode the
        # guest gives them); after the rename, so it runs only once the tree is in place.
        if ($privateFiles) { $treeBatch += 'chmod 700 ' + (& $quote $remotePath) }
        $tree = & $runBatch $treeBatch
        $permissionProblem = $null
        $treeLanded = $tree.ExitCode -eq 0
        if ($privateFiles) {
            if ($treeLanded) {
                $line = & $setstatError $tree
                if ($line) { $permissionProblem = $line }
            } else {
                $treeLanded = & $renameLanded 'd'
                if ($treeLanded) { $permissionProblem = "sftp exit $($tree.ExitCode): $(& $tail $tree)" }
            }
        }
        if ($null -eq $treeLanded) {
            & $fail "${destinationLabel}: recursive upload failed (sftp exit $($tree.ExitCode): $(& $tail $tree)), and the guest could not be inspected to tell whether the directory reached its destination; inspect '$remotePath' and '$remoteTemp' on the guest by hand."
        } elseif ($treeLanded -and $permissionProblem) {
            # The tree is in place: nothing is rolled back, and the parents holding it are kept.
            & $fail "${destinationLabel}: copied successfully but the private-file permission (mode 700 on the directory) could not be applied: $permissionProblem"
        } elseif ($treeLanded) {
            $state.Completed++
            # Measured from the host-side tree that was uploaded, not parsed from sftp's progress output.
            $state.BytesTransferred += $sourceTree.Bytes
        } else {
            # sftp has no recursive delete, so a partial temporary tree is reported, not removed (and any
            # parent directory holding it stays, since rmdir only removes an empty one).
            & $fail "${destinationLabel}: recursive upload failed (sftp exit $($tree.ExitCode): $(& $tail $tree)); the destination was not created. A partial temporary tree may remain at '$remoteTemp' on the guest and must be removed by hand."
            & $removeCreatedRemoteParents
        }
        return & $summary
    }
    if (-not $toVM -and $Recurse) {
        try {
            try { & $createLocalParents }
            catch { & $fail "${destinationLabel}: the missing destination parent directory could not be created: $($_.Exception.Message)"; return & $summary }
            $tree = & $runBatch @('get -r ' + (& $quote $remotePath) + ' ' + (& $quote $localTemp.Replace('\', '/')))
            if ($tree.ExitCode -ne 0) {
                & $fail "${destinationLabel}: recursive download failed (sftp exit $($tree.ExitCode): $(& $tail $tree)); nothing was written to the destination."
                return & $summary
            }
            $landed = & $scanLocalTree $localTemp
            if ($landed.Error) { & $fail "${destinationLabel}: the downloaded tree could not be inspected: $($landed.Error)"; return & $summary }
            if ($landed.Reparse) {
                & $fail "${destinationLabel}: the downloaded tree contains a symbolic link, junction or other reparse point ('$($landed.Reparse)'); it was not moved into place."
                return & $summary
            }
            $moved = $false
            try {
                # Fails rather than overwrites if the destination appeared since the upfront check.
                [IO.Directory]::Move($localTemp, $localPath)
                $moved = $true
            } catch { & $fail "${destinationLabel}: could not be finalized: $($_.Exception.Message)" }
            if ($moved) {
                $permissionProblem = if ($privateFiles) { & $restrictLocal $localPath $true } else { $null }
                if ($permissionProblem) {
                    & $fail "${destinationLabel}: copied successfully but the private-file permission could not be applied: $permissionProblem"
                } else {
                    $state.Completed++
                    # Measured from the tree that landed on this host, not parsed from sftp's progress output.
                    $state.BytesTransferred += $landed.Bytes
                }
            }
        } finally {
            & $removeLocal $localTemp
            if ($state.Completed -eq 0) { & $removeCreatedLocalParents }
        }
        return & $summary
    }
    if ($toVM) {
        # Upload: two batches on two connections. Batch A puts the copy beside the destination (and, in
        # KeyAgent mode, lists it in the same session); the copy is checked between the batches; only then
        # does batch B replace the destination. A rename in batch A itself would run before any check
        # of its output could, letting an unverified file reach the real destination.
        $expectedHash = ''
        if ($VerifyHash) {
            $expectedHash = & $localHash $localPath
            if (-not $expectedHash) { & $fail "${sourceLabel}: the source could not be hashed for -VerifyHash; nothing was transferred."; return & $summary }
        }
        $batchA = @($remoteMkdirLines) + @('put ' + (& $quote $localPath.Replace('\', '/')) + ' ' + (& $quote $remoteTemp))
        if (-not $passwordMode) { $batchA += 'ls -la ' + (& $quote $remoteTemp) }
        $upload = & $runBatch $batchA
        if ($upload.ExitCode -ne 0) {
            & $fail "${destinationLabel}: upload failed (sftp exit $($upload.ExitCode): $(& $tail $upload))."
            & $removeRemoteTemp
            & $removeCreatedRemoteParents
            return & $summary
        }
        $problem = $null
        if ($passwordMode) {
            $problem = & $verifyRemote $remoteTemp $source.Size $expectedHash
        } else {
            $copy = ConvertFrom-LabSftpListing $upload.Output 0 $remoteTemp
            if (-not $copy.Exists -or $copy.Mode -ne '-') { $problem = 'the copied file is missing from the temporary location' }
            elseif ($copy.Size -ne $source.Size) { $problem = "size mismatch after copy (source $($source.Size) bytes, copy $($copy.Size) bytes)" }
            elseif ($VerifyHash) { $problem = & $verifyRemote $remoteTemp -1 $expectedHash }
        }
        if ($problem) {
            & $fail "${destinationLabel}: $problem"
            & $removeRemoteTemp
            & $removeCreatedRemoteParents
            return & $summary
        }
        # The explicit rm keeps Overwrite portable: a server with the posix-rename@openssh.com extension
        # would let rename replace the file atomically on its own, but that cannot be verified here
        # without a live guest. On such a server, a file created at the destination after the upfront
        # check (a race this check-then-act design cannot close) would also be replaced by the rename.
        $batchB = @()
        if ($action -eq 'Overwrite') { $batchB += 'rm ' + (& $quote $remotePath) }
        $batchB += 'rename ' + (& $quote $remoteTemp) + ' ' + (& $quote $remotePath)
        # PrivateFiles: after the rename, in the same batch, so it runs only once the file is in place.
        if ($privateFiles) { $batchB += 'chmod 600 ' + (& $quote $remotePath) }
        $finalize = & $runBatch $batchB
        $permissionProblem = $null
        $fileLanded = $finalize.ExitCode -eq 0
        if ($privateFiles) {
            if ($fileLanded) {
                $line = & $setstatError $finalize
                if ($line) { $permissionProblem = $line }
            } else {
                $fileLanded = & $renameLanded '-'
                if ($fileLanded) { $permissionProblem = "sftp exit $($finalize.ExitCode): $(& $tail $finalize)" }
            }
        }
        if ($null -eq $fileLanded) {
            # Nothing is removed: the verified copy may be the only one left, at either path.
            & $fail "${destinationLabel}: could not be finalized (sftp exit $($finalize.ExitCode): $(& $tail $finalize)), and the guest could not be inspected to tell whether the file reached its destination; inspect '$remotePath' and '$remoteTemp' on the guest by hand."
        } elseif ($fileLanded -and $permissionProblem) {
            # The file is in place: nothing is rolled back, and the parents holding it are kept.
            & $fail "${destinationLabel}: copied successfully but the private-file permission (mode 600) could not be applied: $permissionProblem"
        } elseif ($fileLanded) {
            $state.Completed++
            $state.BytesTransferred += $source.Size
        } elseif ($action -eq 'Overwrite') {
            # The rm may already have run, so the verified copy may now be the only one left.
            & $fail "${destinationLabel}: could not be finalized (sftp exit $($finalize.ExitCode): $(& $tail $finalize)); the existing file may already have been removed, so the verified copy was kept at '$remoteTemp'."
        } else {
            & $fail "${destinationLabel}: could not be finalized (sftp exit $($finalize.ExitCode): $(& $tail $finalize))."
            & $removeRemoteTemp
            & $removeCreatedRemoteParents
        }
        return & $summary
    }
    # Download: the copy lands beside the host-side destination and is checked before the host-side move.
    $retainTemp = $false
    try {
        try { & $createLocalParents }
        catch { & $fail "${destinationLabel}: the missing destination parent directory could not be created: $($_.Exception.Message)"; return & $summary }
        $download = & $runBatch @('get ' + (& $quote $remotePath) + ' ' + (& $quote $localTemp.Replace('\', '/')))
        if ($download.ExitCode -ne 0) {
            & $fail "${destinationLabel}: download failed (sftp exit $($download.ExitCode): $(& $tail $download))."
            return & $summary
        }
        $copy = & $probeLocal $localTemp
        $problem = $null
        if ($copy.Error) { $problem = "could not inspect the copied data: $($copy.Error)" }
        elseif (-not $copy.Exists -or $copy.Mode -ne '-') { $problem = 'the copied file is missing from the temporary location' }
        else {
            $expectedHash = if ($VerifyHash) { & $localHash $localTemp } else { '' }
            if ($VerifyHash -and -not $expectedHash) {
                $problem = 'the downloaded copy could not be hashed for -VerifyHash'
            } elseif ($passwordMode) {
                $problem = & $verifyRemote $remotePath $copy.Size $expectedHash
            } elseif ($copy.Size -ne $source.Size) {
                $problem = "size mismatch after copy (source $($source.Size) bytes, copy $($copy.Size) bytes)"
            } elseif ($VerifyHash) {
                $problem = & $verifyRemote $remotePath -1 $expectedHash
            }
        }
        if ($problem) { & $fail "${destinationLabel}: $problem"; return & $summary }
        $removed = $false
        $moved = $false
        try {
            if ($action -eq 'Overwrite' -and [IO.File]::Exists($localPath)) {
                [IO.File]::SetAttributes($localPath, [IO.FileAttributes]::Normal)
                [IO.File]::Delete($localPath)
                $removed = $true
            }
            [IO.File]::Move($localTemp, $localPath)
            $moved = $true
        } catch {
            if ($removed) {
                # The old file is already gone: keep the verified copy rather than delete the only one left.
                $retainTemp = $true
                & $fail "${destinationLabel}: the existing file was removed but the verified copy could not be moved into place ($($_.Exception.Message)); the copy was kept at '$localTemp'."
            } else { & $fail "${destinationLabel}: could not be finalized: $($_.Exception.Message)" }
        }
        if ($moved) {
            $permissionProblem = if ($privateFiles) { & $restrictLocal $localPath $false } else { $null }
            if ($permissionProblem) {
                & $fail "${destinationLabel}: copied successfully but the private-file permission could not be applied: $permissionProblem"
            } else {
                $state.Completed++
                $state.BytesTransferred += $copy.Size
            }
        }
    } finally {
        if (-not $retainTemp) { & $removeLocal $localTemp }
        # A failed copy does not leave behind the empty parent directories it created itself.
        if ($state.Completed -eq 0) { & $removeCreatedLocalParents }
    }
    return & $summary
}

function Get-LabTransferAdapterKind {
    param([guid]$VMId)
    # An unreadable settings file throws from Get-LabSshConnectionSettings and propagates from here: it is
    # never mistaken for "not configured", which would silently pick PowerShell Direct.
    if ($null -ne (Get-LabSshConnectionSettings $VMId)) { return 'SFTP' }
    return 'PSDirect'
}

function Invoke-LabFileTransfer {
    param(
        [guid]$VMId,
        [ValidateSet('ToVM', 'FromVM')][string]$Direction,
        [string]$SourcePath,
        [string]$DestinationPath,
        [bool]$Recurse,
        [string]$OnConflict,
        [bool]$VerifyHash,
        [bool]$DryRun,
        [AllowNull()][PSCredential]$Credential,
        [bool]$NonInteractive,
        [ValidateSet('Default', 'PrivateFiles')][string]$PermissionProfile = 'Default'
    )
    $vm = $null
    $result = $null
    $blockedReadOnly = $false
    $copyAttempted = $false
    $transferError = $null
    $session = $null
    try {
        $vm = Assert-LabVMRunning $VMId
        # The Invoke-LabAction caller may pass -AllowReadOnly so a dry run's audit record still gets
        # written; this is still the one place that decides whether a real copy is allowed to happen.
        # Checked before credentials are resolved, so a blocked attempt never prompts first.
        if (-not $DryRun -and $script:LabReadOnly) {
            $blockedReadOnly = $true
            $result = [pscustomobject]@{ VMId = $VMId; Completed = 0; Skipped = 0; Failed = 1
                BytesTransferred = [long]0
                Errors = [string[]]@('Read-only mode: a real file copy is blocked under -ReadOnly. Retry with a dry run.') }
            return $result
        }
        if ((Get-LabTransferAdapterKind $VMId) -eq 'SFTP') {
            $sshSettings = Get-LabSshConnectionSettings $VMId
            $authMode = Resolve-LabSshAuthMode $sshSettings.IdentityFilePath $NonInteractive
            $copyAttempted = $true
            $result = Copy-LabTransferItemSftp $sshSettings.HostNameOrAddress $sshSettings.Port $sshSettings.UserName $sshSettings.IdentityFilePath $authMode $Direction $SourcePath $DestinationPath $Recurse $OnConflict $VerifyHash $DryRun $PermissionProfile
            $result = $result | Add-Member -NotePropertyName VMId -NotePropertyValue $VMId -PassThru
            return $result
        } else {
            $resolvedCredential = Resolve-LabWindowsCredential $Credential $NonInteractive
            $session = New-LabPSDirectSession $VMId $resolvedCredential
            $copyAttempted = $true
            $result = Copy-LabTransferItem $session $Direction $SourcePath $DestinationPath $Recurse $OnConflict $VerifyHash $DryRun $PermissionProfile
            $result = $result | Add-Member -NotePropertyName VMId -NotePropertyValue $VMId -PassThru
            return $result
        }
    } catch {
        $transferError = $_
        throw
    } finally {
        if ($session) { Remove-PSSession $session }
        # One record per transfer attempt, whichever entry point called this. Paths, counts and
        # options only: never credential material or file contents.
        $status = if ($null -eq $result) { if ($copyAttempted) { 'FAILED_OR_UNCONFIRMED' } else { 'FAILED' } }
            elseif ($blockedReadOnly) { 'BLOCKED_READONLY' }
            elseif ($DryRun) { 'DRY_RUN' }
            elseif ($result.Failed -eq 0) { 'COMPLETED' }
            elseif ($result.Completed -gt 0) { 'PARTIAL' }
            else { 'FAILED' }
        $detail = 'Direction={0}; Source={1}; Destination={2}; Recurse={3}; OnConflict={4}; PermissionProfile={5}; VerifyHash={6}; DryRun={7}' -f
            $Direction, $SourcePath, $DestinationPath, $Recurse, $OnConflict, $PermissionProfile, $VerifyHash, $DryRun
        if ($null -ne $result) {
            $detail += '; Completed={0}; Skipped={1}; Failed={2}; BytesTransferred={3}' -f
                $result.Completed, $result.Skipped, $result.Failed, $result.BytesTransferred
        } elseif ($null -ne $transferError) {
            $detail += '; Error={0}' -f $transferError.Exception.Message
        }
        $auditVm = if ($null -ne $vm) { $vm } else { [pscustomobject]@{ Id = $VMId; Name = $null } }
        try { Write-LabAudit 'file-transfer' $status $auditVm $detail }
        catch { Write-Warning "Could not write the file-transfer audit record ($status): $($_.Exception.Message)" }
    }
}

function Copy-LabVMItemInteractive {
    param([guid]$VMId, [ValidateSet('ToVM', 'FromVM')][string]$Direction)
    $vm = Assert-LabVMRunning $VMId

    $sourcePrompt = $(if ($Direction -eq 'ToVM') { 'Source path on this host (blank cancels)' } else { "Source path on '$($vm.Name)' (blank cancels)" })
    $sourcePath = Read-LabText $sourcePrompt
    if ($sourcePath -eq '') { return 'CANCELLED' }

    $destinationPrompt = $(if ($Direction -eq 'ToVM') { "Destination path on '$($vm.Name)' (blank cancels)" } else { 'Destination path on this host (blank cancels)' })
    $destinationPath = Read-LabText $destinationPrompt
    if ($destinationPath -eq '') { return 'CANCELLED' }

    $adapterKind = Get-LabTransferAdapterKind $VMId
    $sourceRemote = ($Direction -eq 'FromVM')
    $credential = $null
    if ($sourceRemote -and $adapterKind -eq 'SFTP') {
        # A guest-side source on the SFTP adapter: there is no PowerShell Direct session to inspect it with
        # (opening one would ask for Windows credentials for a Linux guest), and an SSH probe would cost an
        # extra password prompt in password mode, so ask instead. A wrong answer is harmless: the engine
        # checks the real type itself and fails the item before any data moves. No credential is needed.
        $sourceIsDirectory = $null
        while ($null -eq $sourceIsDirectory) {
            $directoryAnswer = (Read-LabText "Is the source on '$($vm.Name)' a directory? [y/N] (C cancels)").ToUpperInvariant()
            if ($directoryAnswer -in @('C', 'CANCEL')) { return 'CANCELLED' }
            if ($directoryAnswer -in @('', 'N', 'NO')) { $sourceIsDirectory = $false }
            elseif ($directoryAnswer -in @('Y', 'YES')) { $sourceIsDirectory = $true }
            else { Write-Host 'Enter Y, N, or C.' }
        }
    } else {
        # Resolve the source's type by inspection (not a blind prompt) so recursion is only asked about
        # when it is actually relevant; a FromVM source lives in the guest, so that inspection needs a session.
        $probeSb = { param([string]$Path) [bool](Test-Path -LiteralPath $Path -PathType Container) }
        $session = $null
        try {
            if ($sourceRemote) {
                $credential = Resolve-LabWindowsCredential $null $false
                $session = New-LabPSDirectSession $VMId $credential
            }
            $sourceIsDirectory = [bool](Invoke-LabTransferSide $session $sourceRemote $probeSb @($sourcePath))
        } finally {
            if ($session) { Remove-PSSession $session }
        }
    }

    $recurse = $false
    if ($sourceIsDirectory) {
        $recurseAnswer = Read-LabYesNoCancel 'Source is a directory. Copy its contents recursively?'
        if ($recurseAnswer -eq 'C') { return 'CANCELLED' }
        $recurse = ($recurseAnswer -eq 'Y')
    }

    # Only a listed number ever reaches $onConflict, never free text; Copy-LabTransferItem's own
    # [ValidateSet('Error', 'Skip', 'Overwrite')] would throw on anything else.
    $conflictOptions = @('Error', 'Skip', 'Overwrite')
    $rows = for ($i = 0; $i -lt $conflictOptions.Count; $i++) { [pscustomobject]@{ No = $i + 1; OnConflict = $conflictOptions[$i] } }
    $rows | Format-Table -AutoSize | Out-Host
    $onConflict = 'Error'
    while ($true) {
        $conflictAnswer = Read-LabText 'Conflict policy number [blank = Error] (C cancels)'
        if ($conflictAnswer -ieq 'C') { return 'CANCELLED' }
        if ($conflictAnswer -eq '') { break }
        $conflictIndex = ConvertTo-LabMenuIndex $conflictAnswer $rows.Count
        if ($conflictIndex -ge 0) { $onConflict = $conflictOptions[$conflictIndex]; break }
        Write-Host 'Choose a listed number, or blank for Error.'
    }

    $verifyAnswer = Read-LabYesNoCancel 'Verify SHA-256 hash after copy?'
    if ($verifyAnswer -eq 'C') { return 'CANCELLED' }
    $verifyHash = ($verifyAnswer -eq 'Y')

    # Defaults to No: restricting permissions is an opt-in choice, not the safe default.
    $permissionProfile = 'Default'
    while ($true) {
        $privateAnswer = (Read-LabText 'Private files (SSH keys / private configuration)? [y/N] (C cancels)').ToUpperInvariant()
        if ($privateAnswer -in @('C', 'CANCEL')) { return 'CANCELLED' }
        if ($privateAnswer -in @('', 'N', 'NO')) { $permissionProfile = 'Default'; break }
        if ($privateAnswer -in @('Y', 'YES')) { $permissionProfile = 'PrivateFiles'; break }
        Write-Host 'Enter Y, N, or C.'
    }

    $adapterLabel = 'PowerShell Direct'
    if ($adapterKind -eq 'SFTP') {
        $sshSettings = Get-LabSshConnectionSettings $VMId
        $adapterLabel = "SFTP ($($sshSettings.UserName)@$($sshSettings.HostNameOrAddress):$($sshSettings.Port))"
    }
    Write-Host "`n=== Copy preview ==="
    [pscustomobject]@{
        Adapter = $adapterLabel
        Direction = $Direction
        VMName = $vm.Name
        VMId = $vm.Id
        SourcePath = $sourcePath
        DestinationPath = $destinationPath
        Recurse = $recurse
        OnConflict = $onConflict
        VerifyHash = $verifyHash
        PermissionProfile = $permissionProfile
    } | Format-List | Out-Host

    $confirmPhrase = $(if ($Direction -eq 'ToVM') { "COPY TO VM $($vm.Name)" } else { "COPY FROM VM $($vm.Name)" })
    if (-not (Confirm-LabText $confirmPhrase)) { return 'CANCELLED' }

    $result = Invoke-LabFileTransfer -VMId $VMId -Direction $Direction -SourcePath $sourcePath -DestinationPath $destinationPath `
        -Recurse $recurse -OnConflict $onConflict -VerifyHash $verifyHash -DryRun $false -Credential $credential -NonInteractive $false `
        -PermissionProfile $permissionProfile

    Write-Host "Completed: $($result.Completed); Skipped: $($result.Skipped); Failed: $($result.Failed); Bytes transferred: $($result.BytesTransferred)"
    # Completed/Skipped/Failed counts are independent outcomes per item; a partial failure is still a
    # completed operation overall (not a cancellation), so this reports COMPLETED with a loud warning.
    if ($result.Failed -gt 0) {
        Write-Warning "$($result.Failed) of $($result.Completed + $result.Skipped + $result.Failed) item(s) FAILED:"
        foreach ($errorMessage in $result.Errors) { Write-Warning "  $errorMessage" }
    }
    return 'COMPLETED'
}

function Invoke-LabAction {
    param([guid]$VMId, [string]$Name, [scriptblock]$Action, [switch]$AllowReadOnly)
    if ($script:LabReadOnly -and -not $AllowReadOnly) { Write-Warning 'Read-only mode: VM-changing operations are disabled.'; return }
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
        # A completed delete-VM leaves no VM to re-resolve; only when the action reported COMPLETED
        # and the VM is genuinely gone, fall back to the object captured before the action.
        # Any other lookup failure (e.g. renamed out of LAB scope) still counts as a failure.
        $finalVm = $vm
        try { $finalVm = Get-LabVM $VMId }
        catch {
            $lookupError = $_
            if ($status -ne 'COMPLETED' -or @(Get-VM -Id $VMId -ErrorAction SilentlyContinue).Count -ne 0) {
                throw $lookupError
            }
        }
        Write-LabAudit $Name $status $finalVm
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
 13  Copy file/directory to VM          [requires Running]
 14  Copy file/directory from VM        [requires Running]
  T  Test guest connectivity (PowerShell Direct or SSH, adapter-aware)
  C  Configure SSH connection for this VM
  K  Trust this VM's SSH host key (first connection; OpenSSH asks you)
  U  Clear this VM's stale SSH host key (after the guest's key changed)
  M  Installation media: inspect DVD/boot configuration (read-only)
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
 11  Edit VM settings                          [requires Off]
 12  Delete VM (retain virtual disks)          [requires Off]
 13  Copy file/directory to VM          [requires Running]
 14  Copy file/directory from VM        [requires Running]
  T  Test guest connectivity (PowerShell Direct or SSH, adapter-aware) [requires Running]
  C  Configure SSH connection for this VM
  K  Trust this VM's SSH host key (first connection; OpenSSH asks you) [requires Running]
  U  Clear this VM's stale SSH host key (after the guest's key changed)
  M  Installation media: attach ISO + boot profile, eject, inspect [attach/eject require Off]
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
                '11' { Invoke-LabAction $VMId 'edit-settings-menu' { param($id) Edit-LabVMSettings $id } }
                '12' { Invoke-LabAction $VMId 'delete-vm-menu' { param($id) Remove-LabVM $id } }
                '13' { Invoke-LabAction $VMId 'copy-to-vm-menu' -AllowReadOnly { param($id) Copy-LabVMItemInteractive $id 'ToVM' } }
                '14' { Invoke-LabAction $VMId 'copy-from-vm-menu' -AllowReadOnly { param($id) Copy-LabVMItemInteractive $id 'FromVM' } }
                'T'  {
                    if ((Get-LabTransferAdapterKind $VMId) -eq 'SFTP') { Test-LabSshConnection $VMId }
                    else { Test-LabTransferConnection $VMId }
                }
                'C'  { Configure-LabSshConnectionInteractive $VMId }
                # K and U change only the operator's own known_hosts on this host, never the VM, each behind
                # a typed confirmation; like C they stay available under -ReadOnly.
                'K'  { Add-LabSshKnownHost $VMId }
                'U'  {
                    $sshSettings = Get-LabSshConnectionSettings $VMId
                    if ($null -eq $sshSettings) { Write-Host 'SSH connection is not configured for this VM. Use Configure SSH connection first.' }
                    else { Update-LabSshKnownHost $sshSettings.HostNameOrAddress $sshSettings.Port }
                }
                # M self-gates under -ReadOnly (inspect only); -AllowReadOnly just lets that sub-action through.
                'M'  { Invoke-LabAction $VMId 'install-media-menu' -AllowReadOnly { param($id) Set-LabVMInstallationMediaInteractive $id } }
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

function Get-LabTransferOnlyParameter {
    param([AllowEmptyCollection()][string[]]$BoundParameterNames)
    $transferOnly = @('VMName', 'VMId', 'SourcePath', 'DestinationPath', 'Recurse', 'OnConflict', 'DryRun',
        'NonInteractive', 'VerifyHash', 'PermissionProfile', 'Credential')
    return @($transferOnly | Where-Object { $BoundParameterNames -contains $_ })
}

function Get-LabProvisioningOnlyParameter {
    param([AllowEmptyCollection()][string[]]$BoundParameterNames)
    # -NonInteractive and -Credential are shared with file transfer, so they stay in the transfer list only.
    $provisioningOnly = @('NewVMName', 'WindowsIsoPath', 'ComputerName', 'Locale', 'TimeZone', 'OsEdition', 'ProductKey',
        'VhdxSizeGB', 'VCpuCount', 'MemoryMinimumGB', 'MemoryStartupGB', 'MemoryMaximumGB', 'SwitchName', 'VmStorageRoot',
        'VhdxStorageRoot', 'ProvisioningTimeoutSeconds')
    return @($provisioningOnly | Where-Object { $BoundParameterNames -contains $_ })
}

function Start-LabWindowsVMProvisioningCli {
    param([hashtable]$Options, [string]$RequestedLogRoot)
    # $Options carries only the parameters the caller actually bound, plus NonInteractive/Credential,
    # so Start-LabWindowsVMProvisioning's own defaults (e.g. vCPUs capped to the host) apply to the rest.
    # Required-value checks run here as well, so a scripted run fails before any host check or log.
    if ($Options['NonInteractive']) {
        foreach ($required in @('NewVMName', 'WindowsIsoPath', 'Credential')) {
            if (-not $Options.ContainsKey($required) -or $null -eq $Options[$required] -or [string]$Options[$required] -eq '') {
                throw "Supply -$required with -ProvisionWindowsVM -NonInteractive."
            }
        }
    }
    $ErrorActionPreference = 'Stop'
    Assert-LabHost
    Initialize-LabLog $RequestedLogRoot
    Write-LabAudit 'session' 'STARTED' $null ("ReadOnly={0}" -f $script:LabReadOnly)
    try {
        return Start-LabWindowsVMProvisioning $Options
    } finally {
        try { Write-LabAudit 'session' 'ENDED' }
        catch { Write-Warning 'Could not write the final audit entry.' }
        Write-Host "Audit log: $script:LabLogFile"
    }
}

function Start-LabSshConfigurationCli {
    param(
        [string]$VMName, [Nullable[guid]]$VMId, [string]$SshHost, [int]$SshPort,
        [string]$SshUser, [AllowNull()][AllowEmptyString()][string]$SshIdentityFile, [string]$RequestedLogRoot
    )
    $hasVMName = -not [string]::IsNullOrEmpty($VMName)
    $hasVMId = $null -ne $VMId
    if ($hasVMName -eq $hasVMId) { throw 'Supply exactly one of -VMName or -VMId.' }
    if ([string]::IsNullOrEmpty($SshHost)) { throw 'Supply -SshHost with -ConfigureSsh.' }
    if ([string]::IsNullOrEmpty($SshUser)) { throw 'Supply -SshUser with -ConfigureSsh.' }
    # Checked here as well as in Set-LabSshConnectionSettings, so a bad value fails before any host check or log.
    if (-not (Test-LabSshHostName $SshHost)) { throw "Invalid -SshHost '$SshHost': it must not start with '-' or contain whitespace, control characters or '@'." }
    if (-not (Test-LabSshUserName $SshUser)) { throw "Invalid -SshUser '$SshUser': it must not start with '-' or contain whitespace or control characters." }
    if ($SshPort -lt 1 -or $SshPort -gt 65535) { throw "Invalid -SshPort ${SshPort}: it must be between 1 and 65535." }
    $ErrorActionPreference = 'Stop'
    Assert-LabHost
    Initialize-LabLog $RequestedLogRoot
    Write-LabAudit 'session' 'STARTED' $null ("ReadOnly={0}" -f $script:LabReadOnly)
    try {
        $resolvedVMId = Resolve-LabVMByNameOrId -VMName $VMName -VMId $VMId
        $vm = Get-LabVM $resolvedVMId
        Set-LabSshConnectionSettings -VMId $resolvedVMId -HostNameOrAddress $SshHost -Port $SshPort -UserName $SshUser -IdentityFilePath $SshIdentityFile
        Write-LabAudit 'configure-ssh-cli' 'COMPLETED' $vm ("HostNameOrAddress={0}; Port={1}; UserName={2}; IdentityFileConfigured={3}" -f
            $SshHost, $SshPort, $SshUser, (-not [string]::IsNullOrEmpty($SshIdentityFile)))
        Write-Host "SSH connection settings saved for VM '$($vm.Name)' [$resolvedVMId]."
    } finally {
        try { Write-LabAudit 'session' 'ENDED' }
        catch { Write-Warning 'Could not write the final audit entry.' }
        Write-Host "Audit log: $script:LabLogFile"
    }
}

function Start-LabFileTransferCli {
    param(
        [bool]$CopyToVM, [bool]$CopyFromVM, [string]$VMName, [Nullable[guid]]$VMId,
        [string]$SourcePath, [string]$DestinationPath, [bool]$Recurse, [string]$OnConflict,
        [bool]$DryRun, [bool]$NonInteractive, [bool]$VerifyHash, [string]$PermissionProfile,
        [AllowNull()][PSCredential]$Credential, [string]$RequestedLogRoot
    )
    if ($CopyToVM -and $CopyFromVM) { throw 'Supply exactly one of -CopyToVM or -CopyFromVM, not both.' }
    $hasVMName = -not [string]::IsNullOrEmpty($VMName)
    $hasVMId = $null -ne $VMId
    if ($hasVMName -eq $hasVMId) { throw 'Supply exactly one of -VMName or -VMId.' }
    $direction = $(if ($CopyToVM) { 'ToVM' } else { 'FromVM' })
    $ErrorActionPreference = 'Stop'
    Assert-LabHost
    Initialize-LabLog $RequestedLogRoot
    Write-LabAudit 'session' 'STARTED' $null ("ReadOnly={0}" -f $script:LabReadOnly)
    try {
        $resolvedVMId = Resolve-LabVMByNameOrId -VMName $VMName -VMId $VMId
        # Same per-VM lock as Invoke-LabAction (which the menu's copy options go through), held for the
        # whole transfer. Taken directly rather than via Invoke-LabAction, which would discard the
        # summary object the exit code is derived from.
        $mutex = [Threading.Mutex]::new($false, "Global\LabVmManager-$resolvedVMId")
        $held = $false
        try {
            try { $held = $mutex.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $held = $true }
            if (-not $held) { throw 'Another copy of this script is operating on this VM. No transfer was started here.' }
            $result = Invoke-LabFileTransfer -VMId $resolvedVMId -Direction $direction -SourcePath $SourcePath `
                -DestinationPath $DestinationPath -Recurse $Recurse -OnConflict $OnConflict -VerifyHash $VerifyHash `
                -DryRun $DryRun -Credential $Credential -NonInteractive $NonInteractive -PermissionProfile $PermissionProfile
        } finally {
            if ($held) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
        Write-Host "Completed: $($result.Completed); Skipped: $($result.Skipped); Failed: $($result.Failed); Bytes transferred: $($result.BytesTransferred)"
        if ($result.Failed -gt 0) {
            foreach ($errorMessage in $result.Errors) { Write-Warning "  $errorMessage" }
        }
        return [int]$result.Failed
    } finally {
        try { Write-LabAudit 'session' 'ENDED' }
        catch { Write-Warning 'Could not write the final audit entry.' }
        Write-Host "Audit log: $script:LabLogFile"
    }
}

# Dot-sourcing loads functions without launching the UI; normal invocation runs it.
if ($MyInvocation.InvocationName -ne '.') {
    if (@(@([bool]$ConfigureSsh, [bool]($CopyToVM -or $CopyFromVM), [bool]$ProvisionWindowsVM) | Where-Object { $_ }).Count -gt 1) {
        Write-Error -Message 'Supply only one of -ConfigureSsh, -CopyToVM, -CopyFromVM, or -ProvisionWindowsVM; one action per invocation.' -ErrorAction Continue
        exit 1
    }
    # Provisioning parameters without -ProvisionWindowsVM are refused in every other mode (menu,
    # -ConfigureSsh, -CopyToVM/-CopyFromVM) rather than silently ignored, mirroring the transfer gate below.
    $boundParameterNames = @($PSBoundParameters.Keys)
    if (-not $ProvisionWindowsVM) {
        $orphanProvisioningParameters = @(Get-LabProvisioningOnlyParameter $boundParameterNames)
        if ($orphanProvisioningParameters.Count -gt 0) {
            Write-Error -Message ('{0} only apply to -ProvisionWindowsVM; add it. Nothing was run.' -f
                (($orphanProvisioningParameters | ForEach-Object { "-$_" }) -join ', ')) -ErrorAction Continue
            exit 1
        }
    }
    if ($ProvisionWindowsVM) {
        # -VMName/-VMId always mean an EXISTING VM; the VM to create is named with -NewVMName. Transfer
        # parameters other than the shared -NonInteractive/-Credential are refused rather than ignored.
        $foreignParameters = @(Get-LabTransferOnlyParameter $boundParameterNames | Where-Object { $_ -notin @('NonInteractive', 'Credential') })
        if ($foreignParameters.Count -gt 0) {
            Write-Error -Message ('{0} do not apply to -ProvisionWindowsVM (name the new VM with -NewVMName). Nothing was run.' -f
                (($foreignParameters | ForEach-Object { "-$_" }) -join ', ')) -ErrorAction Continue
            exit 1
        }
        $provisioningOptions = @{ NonInteractive = [bool]$NonInteractive; Credential = $Credential }
        foreach ($key in (Get-LabProvisioningOnlyParameter $boundParameterNames)) { $provisioningOptions[$key] = $PSBoundParameters[$key] }
        try {
            $status = Start-LabWindowsVMProvisioningCli -Options $provisioningOptions -RequestedLogRoot $LogRoot
            exit $(if ($status -eq 'COMPLETED') { 0 } else { 1 })
        }
        catch {
            Write-Error -Message $_.Exception.Message -ErrorAction Continue
            exit 1
        }
    } elseif ($ConfigureSsh) {
        try {
            Start-LabSshConfigurationCli -VMName $VMName -VMId $VMId -SshHost $SshHost -SshPort $SshPort `
                -SshUser $SshUser -SshIdentityFile $SshIdentityFile -RequestedLogRoot $LogRoot
            exit 0
        }
        catch {
            Write-Error -Message $_.Exception.Message -ErrorAction Continue
            exit 1
        }
    } elseif ($CopyToVM -or $CopyFromVM) {
        try {
            $failedCount = Start-LabFileTransferCli -CopyToVM ([bool]$CopyToVM) -CopyFromVM ([bool]$CopyFromVM) `
                -VMName $VMName -VMId $VMId -SourcePath $SourcePath -DestinationPath $DestinationPath `
                -Recurse ([bool]$Recurse) -OnConflict $OnConflict -DryRun ([bool]$DryRun) `
                -NonInteractive ([bool]$NonInteractive) -VerifyHash ([bool]$VerifyHash) -PermissionProfile $PermissionProfile `
                -Credential $Credential -RequestedLogRoot $LogRoot
            exit $(if ($failedCount -eq 0) { 0 } else { 1 })
        }
        catch {
            Write-Error -Message $_.Exception.Message -ErrorAction Continue
            exit 1
        }
    } else {
        # Transfer parameters without a direction switch must not silently open the menu: an
        # unattended -NonInteractive run would otherwise hang at its first prompt.
        $orphanTransferParameters = @(Get-LabTransferOnlyParameter @($PSBoundParameters.Keys))
        if ($orphanTransferParameters.Count -gt 0) {
            Write-Error -Message ('{0} only apply to file transfer; add -CopyToVM or -CopyFromVM. The menu was not opened.' -f
                (($orphanTransferParameters | ForEach-Object { "-$_" }) -join ', ')) -ErrorAction Continue
            exit 1
        }
        try { Start-LabVMManager -RequestedLogRoot $LogRoot }
        catch {
            Write-Error -Message $_.Exception.Message -ErrorAction Continue
            exit 1
        }
    }
}
