#requires -Version 5.1
<#
.SYNOPSIS
    Parse Lab-VM.ps1 and test its small input/selection helpers without Hyper-V.
.DESCRIPTION
    This does NOT run the UI, dot-source the whole manager, or import Hyper-V.
    Only explicitly allowlisted function definitions are evaluated from its AST.
    Get-VM is replaced with an in-memory function for VM-ID/state guard tests.
    One test launches Lab-VM.ps1 in a child powershell.exe with transfer-only
    parameters and no direction switch, which exits at the invocation gate
    before host checks, logging or the UI.
    The Hyper-V shape drift guard launches one more child powershell.exe that
    imports the Hyper-V module only to read its type metadata by reflection
    (no cmdlet is called, no VM is touched, no elevation is needed) and
    compares it with the fakes in this file and the calls in Lab-VM.ps1. It is
    skipped when the Hyper-V module is not installed.
    Run without administrator privileges. This is not a Hyper-V integration test.
#>
[CmdletBinding()]
param([string]$ScriptPath)
$ErrorActionPreference = 'Stop'
if (-not $ScriptPath) { $ScriptPath = Join-Path $PSScriptRoot 'Lab-VM.ps1' }
Set-StrictMode -Version Latest
$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param($Actual, $Expected)
    if ($Actual -cne $Expected) { throw "Expected [$Expected], got [$Actual]." }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    $caught = $null
    try { $null = & $Body } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught) { throw 'Expected an exception, but none was thrown.' }
    if ($caught -notmatch $Pattern) { throw "Exception did not match '$Pattern': $caught" }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++; Write-Host "PASS: $Name" }
    catch { $script:Failed++; Write-Host "FAIL: $Name -- $($_.Exception.Message)" }
}

$tokens = $null
$errors = $null
$resolved = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
$ast = [Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | Format-List | Out-Host
    throw 'PowerShell syntax validation failed. No function definitions were loaded.'
}
Write-Host 'PASS: the full script parses in this PowerShell runtime.'

$allowlist = @('Test-LabVMName', 'ConvertTo-LabMenuIndex', 'Test-LabCheckpointName',
    'Get-LabVM', 'Assert-LabVMOff', 'Test-LabNewVMName', 'Test-LabVCpuCount', 'Test-LabMemorySpec',
    'Get-LabTransferConflictKind', 'Resolve-LabConflictAction', 'Get-LabSettingsDiff',
    'Assert-LabVMRunning', 'Get-LabTransferOnlyParameter', 'Get-LabSshConnectionSettingsPath',
    'Resolve-LabSshAuthMode', 'Get-LabTransferAdapterKind', 'Test-LabSshHostName', 'Test-LabSshUserName',
    'Test-LabVMHasKeyProtector', 'Set-LabVMBootProfile', 'Get-LabVMInstallMediaPath',
    'Set-LabVMInstallMedia', 'Remove-LabVMInstallMedia', 'Set-LabVMBootOrder', 'Get-LabProperty',
    'Get-LabBootEntryKind', 'Format-LabBootEntry', 'Show-LabVMInstallMediaConfiguration',
    'Get-LabVMInstallationMediaPreview', 'Get-LabWindowsInstallImages', 'Test-LabWindowsIsoInScope',
    'New-LabPatchedBootableIso', 'Set-LabVMUnattendedInstallMedia', 'Complete-LabWindowsProvisioning',
    'New-LabWindowsAnswerFileXml', 'Wait-LabPSDirectSession', 'Get-LabLinuxIsoInfo',
    'New-LabPatchedBootableLinuxIso', 'ConvertTo-LabPosixShellSingleQuoted', 'Test-LabLinuxUserName',
    'New-LabLinuxAutoinstallUserData', 'Set-LabVMUnattendedLinuxInstallMedia', 'Complete-LabLinuxProvisioning')
$definitions = $ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true)
foreach ($name in $allowlist) {
    $matches = @($definitions | Where-Object { $_.Name -ceq $name })
    if ($matches.Count -ne 1) { throw "Expected one definition of $name." }
    . ([scriptblock]::Create($matches[0].Extent.Text))
}

# No Hyper-V cmdlet is invoked by these tests.
$script:FakeId = [guid]'00000000-0000-0000-0000-000000000123'
$script:FakeVM = [pscustomobject]@{ Id = $script:FakeId; Name = 'LAB-Test'; State = 'Off'; Generation = 2 }
function Get-VM {
    [CmdletBinding()]
    param([guid]$Id)
    if ($Id -eq $script:FakeId) { return $script:FakeVM }
    return @()
}

# Fake for Get-LabSshConnectionSettings (Task 2): a single-dependency pure wrapper
# (Get-LabTransferAdapterKind) is tested by overriding its one dependency, same as Get-VM above.
$script:FakeSshSettings = $null
function Get-LabSshConnectionSettings {
    param([guid]$VMId)
    return $script:FakeSshSettings
}

Test-Case 'Uppercase LAB- prefix accepted' { Assert-Equal (Test-LabVMName 'LAB-WINDOWS') $true }
Test-Case 'Lowercase prefix accepted' { Assert-Equal (Test-LabVMName 'lab-linux') $true }
Test-Case 'Mixed-case prefix accepted' { Assert-Equal (Test-LabVMName 'LaB-Test') $true }
Test-Case 'Non-LAB VM rejected' { Assert-Equal (Test-LabVMName 'PROD-ERP') $false }
Test-Case 'Embedded LAB- rejected' { Assert-Equal (Test-LabVMName 'OTHER-LAB-Test') $false }
Test-Case 'Prefix without hyphen rejected' { Assert-Equal (Test-LabVMName 'LABTEST') $false }
Test-Case 'Leading space rejected' { Assert-Equal (Test-LabVMName ' LAB-Test') $false }
Test-Case 'Null name rejected' { Assert-Equal (Test-LabVMName $null) $false }
Test-Case 'Empty name rejected' { Assert-Equal (Test-LabVMName '') $false }
Test-Case 'First menu entry resolves to index zero' { Assert-Equal (ConvertTo-LabMenuIndex '1' 2) 0 }
Test-Case 'Last entry resolves correctly' { Assert-Equal (ConvertTo-LabMenuIndex '2' 2) 1 }
Test-Case 'Zero is invalid' { Assert-Equal (ConvertTo-LabMenuIndex '0' 2) -1 }
Test-Case 'Out-of-range entry invalid' { Assert-Equal (ConvertTo-LabMenuIndex '3' 2) -1 }
Test-Case 'Negative entry invalid' { Assert-Equal (ConvertTo-LabMenuIndex '-1' 2) -1 }
Test-Case 'Expression is not evaluated' { Assert-Equal (ConvertTo-LabMenuIndex '1+1' 2) -1 }
Test-Case 'Integer overflow rejected' { Assert-Equal (ConvertTo-LabMenuIndex '99999999999999' 2) -1 }
Test-Case 'Empty inventory cannot be selected' { Assert-Equal (ConvertTo-LabMenuIndex '1' 0) -1 }
Test-Case 'Baseline name accepted' { Assert-Equal (Test-LabCheckpointName '10-toolchain-v1') $true }
Test-Case 'Blank checkpoint name rejected' { Assert-Equal (Test-LabCheckpointName ' ') $false }
Test-Case 'Wildcard name rejected' { Assert-Equal (Test-LabCheckpointName 'baseline*') $false }
Test-Case 'Path name rejected' { Assert-Equal (Test-LabCheckpointName 'a\b') $false }
Test-Case 'Control character rejected' { Assert-Equal (Test-LabCheckpointName "a`nb") $false }
Test-Case 'Excessive name length rejected' { Assert-Equal (Test-LabCheckpointName ('a' * 101)) $false }
Test-Case 'Checkpoint whitespace rejected' { Assert-Equal (Test-LabCheckpointName ' baseline') $false }
Test-Case 'VM lookup uses selected ID' { Assert-Equal (Get-LabVM $script:FakeId).Id $script:FakeId }
Test-Case 'Missing VM does not retarget another VM' {
    Assert-Throws { Get-LabVM ([guid]::NewGuid()) } 'exactly one'
}
Test-Case 'VM renamed out of LAB scope is rejected' {
    $script:FakeVM.Name = 'PROD-Test'
    try { Assert-Throws { Get-LabVM $script:FakeId } 'does not start with LAB-' }
    finally { $script:FakeVM.Name = 'LAB-Test' }
}
Test-Case 'Off VM passes state guard' { Assert-Equal (Assert-LabVMOff $script:FakeId).State 'Off' }
Test-Case 'Saved VM is not Off' {
    $script:FakeVM.State = 'Saved'
    try { Assert-Throws { Assert-LabVMOff $script:FakeId } 'requires Off' }
    finally { $script:FakeVM.State = 'Off' }
}
Test-Case 'Running VM is not Off' {
    $script:FakeVM.State = 'Running'
    try { Assert-Throws { Assert-LabVMOff $script:FakeId } 'requires Off' }
    finally { $script:FakeVM.State = 'Off' }
}
Test-Case 'Paused VM is not Off' {
    $script:FakeVM.State = 'Paused'
    try { Assert-Throws { Assert-LabVMOff $script:FakeId } 'requires Off' }
    finally { $script:FakeVM.State = 'Off' }
}
# --- Boot profile (Task 3): Secure Boot template + vTPM/key-protector preparation ---
# Fakes for the Hyper-V cmdlets Set-LabVMBootProfile and Test-LabVMHasKeyProtector call. No real
# Hyper-V cmdlet is invoked by these tests.
# Get-VMKeyProtector mirrors the REAL cmdlet's shape, confirmed by reflection against the installed
# Hyper-V module (and re-checked by the drift guard at the end of this file): it writes ONE bare
# System.Byte[] to the pipeline, un-enumerated (Cmdlet.WriteObject(object)), with no wrapper object.
# Write-Output -NoEnumerate reproduces that; a plain 'return $bytes' would enumerate it byte by byte.
# The absent form defaults to the reported 4-byte header 0,0,0,4; tests override it via
# $script:FakeKeyProtectorBytes ($null = use the default for FakeHasKeyProtector).
$script:FakeFirmware = [pscustomobject]@{ SecureBoot = 'On'; SecureBootTemplate = 'MicrosoftWindows'; BootOrder = @() }
$script:FakeHasKeyProtector = $false
$script:FakeKeyProtectorBytes = $null
$script:FakeKeyProtectorThrows = $false
$script:SetVMFirmwareCalls = [Collections.Generic.List[string]]::new()
$script:SetVMFirmwareSecureBootCalls = [Collections.Generic.List[string]]::new()
$script:SetVMFirmwareBootOrderCalls = [Collections.Generic.List[object]]::new()
$script:SetVMKeyProtectorCalls = 0
$script:EnableVMTPMCalls = 0
function Get-VMFirmware {
    [CmdletBinding()]
    param($VM)
    return $script:FakeFirmware
}
function Set-VMFirmware {
    [CmdletBinding()]
    param($VM, [string]$SecureBootTemplate, [string]$EnableSecureBoot, [object[]]$BootOrder, [switch]$Confirm)
    if ($PSBoundParameters.ContainsKey('SecureBootTemplate')) {
        $script:SetVMFirmwareCalls.Add($SecureBootTemplate)
        $script:FakeFirmware.SecureBootTemplate = $SecureBootTemplate
    }
    if ($PSBoundParameters.ContainsKey('EnableSecureBoot')) {
        $script:SetVMFirmwareSecureBootCalls.Add($EnableSecureBoot)
        $script:FakeFirmware.SecureBoot = $EnableSecureBoot
    }
    if ($PSBoundParameters.ContainsKey('BootOrder')) {
        $script:SetVMFirmwareBootOrderCalls.Add($BootOrder)
        $script:FakeFirmware.BootOrder = $BootOrder
    }
}
function Get-VMKeyProtector {
    [CmdletBinding()]
    param($VM, [switch]$Confirm)
    if ($script:FakeKeyProtectorThrows) { throw 'The operation failed: Get-VMKeyProtector (fake read failure).' }
    # Plain assignments, not '$bytes = if (...)': an if-expression would re-collect the array as object[].
    if ($null -ne $script:FakeKeyProtectorBytes) { [byte[]]$bytes = $script:FakeKeyProtectorBytes }
    elseif ($script:FakeHasKeyProtector) { [byte[]]$bytes = 1..1024 | ForEach-Object { $_ % 256 } }
    else { [byte[]]$bytes = 0, 0, 0, 4 }
    Write-Output -NoEnumerate $bytes
}
function Set-VMKeyProtector {
    [CmdletBinding()]
    param($VM, [switch]$NewLocalKeyProtector, [switch]$Confirm)
    $script:SetVMKeyProtectorCalls++
    $script:FakeHasKeyProtector = $true
}
function Enable-VMTPM {
    [CmdletBinding()]
    param($VM, [switch]$Confirm)
    $script:EnableVMTPMCalls++
}

Test-Case 'Test-LabVMHasKeyProtector reads existing state without calling any mutating cmdlet' {
    $script:FakeHasKeyProtector = $true
    $script:SetVMKeyProtectorCalls = 0
    $script:EnableVMTPMCalls = 0
    try {
        Assert-Equal (Test-LabVMHasKeyProtector $script:FakeId) $true
        Assert-Equal $script:SetVMKeyProtectorCalls 0
        Assert-Equal $script:EnableVMTPMCalls 0
    } finally { $script:FakeHasKeyProtector = $false }
}
Test-Case 'Test-LabVMHasKeyProtector: the real un-enumerated byte[] shape really reaches the code' {
    # Guards the fake itself: the real cmdlet emits one byte[] object, not a stream of bytes.
    $script:FakeHasKeyProtector = $true
    try {
        $raw = Get-VMKeyProtector -VM $script:FakeVM
        Assert-Equal ($raw -is [byte[]]) $true
        Assert-Equal $raw.Length 1024
        Assert-Equal ($null -eq $raw.PSObject.Properties['RawKeyProtector']) $true
    } finally { $script:FakeHasKeyProtector = $false }
}
Test-Case 'Test-LabVMHasKeyProtector: absent forms (4-byte header, empty, $null) all read as $false, read-only' {
    $script:SetVMKeyProtectorCalls = 0
    $script:EnableVMTPMCalls = 0
    try {
        $script:FakeHasKeyProtector = $false
        $script:FakeKeyProtectorBytes = $null
        Assert-Equal (Test-LabVMHasKeyProtector $script:FakeId) $false
        $script:FakeKeyProtectorBytes = [byte[]]@()
        Assert-Equal (Test-LabVMHasKeyProtector $script:FakeId) $false
        $script:FakeKeyProtectorBytes = [byte[]]@(0, 0, 0, 4)
        Assert-Equal (Test-LabVMHasKeyProtector $script:FakeId) $false
        $script:FakeKeyProtectorBytes = $null
        & {
            function Get-VMKeyProtector { [CmdletBinding()] param($VM) }
            Assert-Equal (Test-LabVMHasKeyProtector $script:FakeId) $false
        }
        Assert-Equal $script:SetVMKeyProtectorCalls 0
        Assert-Equal $script:EnableVMTPMCalls 0
    } finally { $script:FakeKeyProtectorBytes = $null; $script:FakeHasKeyProtector = $false }
}
Test-Case 'Test-LabVMHasKeyProtector: a real-sized blob reads as $true, also when a caller enumerated it' {
    try {
        $script:FakeKeyProtectorBytes = [byte[]](1..1024 | ForEach-Object { $_ % 256 })
        Assert-Equal (Test-LabVMHasKeyProtector $script:FakeId) $true
        # Defensive normalization: the same bytes streamed one by one still count as present.
        & {
            function Get-VMKeyProtector { [CmdletBinding()] param($VM) return [byte[]](1..64) }
            Assert-Equal (Test-LabVMHasKeyProtector $script:FakeId) $true
        }
    } finally { $script:FakeKeyProtectorBytes = $null }
}
Test-Case 'Test-LabVMHasKeyProtector: a read failure propagates (fails closed, never reads as absent)' {
    $script:FakeKeyProtectorThrows = $true
    try { Assert-Throws { Test-LabVMHasKeyProtector $script:FakeId } 'fake read failure' }
    finally { $script:FakeKeyProtectorThrows = $false }
}
Test-Case 'Set-LabVMBootProfile rejects a Generation 1 VM before changing anything' {
    $script:FakeVM.Generation = 1
    $script:SetVMFirmwareCalls.Clear()
    $script:SetVMKeyProtectorCalls = 0
    $script:EnableVMTPMCalls = 0
    try {
        Assert-Throws { Set-LabVMBootProfile $script:FakeId 'Windows11' } 'Generation'
        Assert-Equal $script:SetVMFirmwareCalls.Count 0
        Assert-Equal $script:SetVMKeyProtectorCalls 0
        Assert-Equal $script:EnableVMTPMCalls 0
    } finally { $script:FakeVM.Generation = 2 }
}
Test-Case 'Set-LabVMBootProfile leaves an existing key protector alone' {
    $script:FakeHasKeyProtector = $true
    $script:FakeFirmware.SecureBootTemplate = 'MicrosoftWindows'
    $script:SetVMKeyProtectorCalls = 0
    $script:EnableVMTPMCalls = 0
    try {
        $result = Set-LabVMBootProfile $script:FakeId 'Windows11'
        Assert-Equal $script:SetVMKeyProtectorCalls 0
        Assert-Equal $script:EnableVMTPMCalls 0
        Assert-Equal $result.KeyProtectorAdded $false
    } finally { $script:FakeHasKeyProtector = $false }
}
Test-Case 'Set-LabVMBootProfile adds a key protector and vTPM when absent' {
    $script:FakeHasKeyProtector = $false
    $script:FakeFirmware.SecureBootTemplate = 'MicrosoftWindows'
    $script:SetVMKeyProtectorCalls = 0
    $script:EnableVMTPMCalls = 0
    try {
        $result = Set-LabVMBootProfile $script:FakeId 'Windows11'
        Assert-Equal $script:SetVMKeyProtectorCalls 1
        Assert-Equal $script:EnableVMTPMCalls 1
        Assert-Equal $result.KeyProtectorAdded $true
        Assert-Equal $result.TpmEnabled $true
    } finally { $script:FakeHasKeyProtector = $false }
}
Test-Case 'Set-LabVMBootProfile applies the Ubuntu Secure Boot template without touching vTPM' {
    $script:FakeFirmware.SecureBootTemplate = 'MicrosoftWindows'
    $script:SetVMFirmwareCalls.Clear()
    $script:SetVMKeyProtectorCalls = 0
    $script:EnableVMTPMCalls = 0
    $result = Set-LabVMBootProfile $script:FakeId 'UbuntuDesktop'
    Assert-Equal $script:SetVMFirmwareCalls[-1] 'MicrosoftUEFICertificateAuthority'
    Assert-Equal $script:SetVMKeyProtectorCalls 0
    Assert-Equal $script:EnableVMTPMCalls 0
}
Test-Case 'Set-LabVMBootProfile UbuntuServer applies the same Secure Boot template as UbuntuDesktop, touches no key protector' {
    $script:FakeFirmware.SecureBootTemplate = 'MicrosoftWindows'
    $script:SetVMFirmwareCalls.Clear()
    $script:SetVMKeyProtectorCalls = 0
    $script:EnableVMTPMCalls = 0
    $result = Set-LabVMBootProfile $script:FakeId 'UbuntuServer'
    Assert-Equal $script:SetVMFirmwareCalls[-1] 'MicrosoftUEFICertificateAuthority'
    Assert-Equal $script:SetVMKeyProtectorCalls 0
    Assert-Equal $script:EnableVMTPMCalls 0
}
Test-Case 'Set-LabVMBootProfile turns Secure Boot on when it is Off, for both profiles' {
    foreach ($osProfileName in @('Windows11', 'UbuntuDesktop')) {
        $script:FakeFirmware.SecureBoot = 'Off'
        $script:FakeHasKeyProtector = $true
        $script:SetVMFirmwareSecureBootCalls.Clear()
        $script:SetVMKeyProtectorCalls = 0
        try {
            $result = Set-LabVMBootProfile $script:FakeId $osProfileName
            Assert-Equal $script:SetVMFirmwareSecureBootCalls.Count 1
            Assert-Equal $script:SetVMFirmwareSecureBootCalls[0] 'On'
            Assert-Equal $script:FakeFirmware.SecureBoot 'On'
            Assert-Equal $result.SecureBootEnabled $true
            Assert-Equal $script:SetVMKeyProtectorCalls 0
        } finally { $script:FakeFirmware.SecureBoot = 'On'; $script:FakeHasKeyProtector = $false }
    }
}
Test-Case 'Set-LabVMBootProfile leaves Secure Boot alone when it is already On, for both profiles' {
    foreach ($osProfileName in @('Windows11', 'UbuntuDesktop')) {
        $script:FakeFirmware.SecureBoot = 'On'
        $script:SetVMFirmwareSecureBootCalls.Clear()
        try {
            $result = Set-LabVMBootProfile $script:FakeId $osProfileName
            Assert-Equal $script:SetVMFirmwareSecureBootCalls.Count 0
            Assert-Equal $result.SecureBootEnabled $false
        } finally { $script:FakeHasKeyProtector = $false }
    }
}
Test-Case 'Set-LabVMBootProfile does not turn Secure Boot on for a Generation 1 VM' {
    $script:FakeVM.Generation = 1
    $script:FakeFirmware.SecureBoot = 'Off'
    $script:SetVMFirmwareSecureBootCalls.Clear()
    try {
        Assert-Throws { Set-LabVMBootProfile $script:FakeId 'UbuntuDesktop' } 'Generation'
        Assert-Equal $script:SetVMFirmwareSecureBootCalls.Count 0
    } finally { $script:FakeVM.Generation = 2; $script:FakeFirmware.SecureBoot = 'On' }
}

# --- DVD media attach/eject and generic boot-order control (Task 4) ---
# Fakes for Add-VMDvdDrive/Get-VMDvdDrive/Set-VMDvdDrive. No real Hyper-V cmdlet is invoked. Each
# fake DVD-drive object is a mutable pscustomobject, so Set-VMDvdDrive's in-place Path update is
# visible to a caller still holding the object Get-VMDvdDrive returned, same as on a live VM.
# Stand-ins for the REAL Get-VMFirmware BootOrder shape, confirmed by reflection against the installed
# Hyper-V module (and re-checked by the drift guard at the end of this file): BootOrder is a
# Microsoft.HyperV.PowerShell.VMBootSource[] whose Device property holds the device, and the DVD/disk
# device classes are named DvdDrive and HardDiskDrive -- with NO 'VM' prefix. These classes supply
# the same short type names without the Hyper-V module loaded, so the primary fixtures below are
# VMBootSource{ Device = DvdDrive/HardDiskDrive/VMNetworkAdapter }, exactly the shape the suffix match
# in Get-LabBootEntryKind exists for. VMDvdDrive/VMHardDiskDrive are kept ONLY for the
# backward-compatibility cases (a bare or VM-prefixed device), not as the primary shape.
# DvdDrive carries Path like the real device object does, so Set-LabVMUnattendedInstallMedia's
# "is the Windows installer drive's own entry among the leading DVD entries" check can be exercised.
class DvdDrive { [string]$Path }
class HardDiskDrive {}
class VMNetworkAdapter {}
class VMDvdDrive {}
class VMHardDiskDrive {}
class VMBootSource {
    [string]$BootType
    [string]$Description
    [string]$FirmwarePath
    [object]$Device
    VMBootSource([string]$BootType, [object]$Device) { $this.BootType = $BootType; $this.Device = $Device }
}
function New-FakeBootEntry {
    param([ValidateSet('Dvd', 'Disk', 'Nic')][string]$Kind, [string]$Path = '')
    switch ($Kind) {
        'Dvd' { $dvd = [DvdDrive]::new(); $dvd.Path = $Path; return [VMBootSource]::new('Drive', $dvd) }
        'Disk' { return [VMBootSource]::new('Drive', [HardDiskDrive]::new()) }
        'Nic' { return [VMBootSource]::new('Network', [VMNetworkAdapter]::new()) }
    }
}
$script:FakeDvdDrives = [Collections.Generic.List[object]]::new()
$script:AddVMDvdDriveCalls = 0
$script:SetVMDvdDriveCalls = [Collections.Generic.List[object]]::new()
function Add-VMDvdDrive {
    [CmdletBinding()]
    param($VM, [switch]$Confirm, [switch]$Passthru)
    $script:AddVMDvdDriveCalls++
    $drive = [pscustomobject]@{ Path = $null }
    $script:FakeDvdDrives.Add($drive)
    if ($Passthru) { return $drive }
}
function Get-VMDvdDrive {
    [CmdletBinding()]
    param($VM)
    return @($script:FakeDvdDrives)
}
function Set-VMDvdDrive {
    [CmdletBinding()]
    param($VMDvdDrive, [AllowNull()][AllowEmptyString()][string]$Path, [switch]$Confirm)
    $script:SetVMDvdDriveCalls.Add($Path)
    $VMDvdDrive.Path = $Path
}
# Fake for Remove-VMDvdDrive (Task 3): removes the drive object from the fake VM's drive list
# entirely, matching the real cmdlet's "the drive itself is gone" behavior (unlike Set-VMDvdDrive
# -Path $null, which only ejects the media and keeps the drive).
$script:RemoveVMDvdDriveCalls = [Collections.Generic.List[object]]::new()
function Remove-VMDvdDrive {
    [CmdletBinding()]
    param($VMDvdDrive, [switch]$Confirm)
    $script:RemoveVMDvdDriveCalls.Add($VMDvdDrive)
    [void]$script:FakeDvdDrives.Remove($VMDvdDrive)
}

Test-Case 'Get-LabVMInstallMediaPath is scoped by VM GUID' {
    $id = [guid]'55555555-5555-5555-5555-555555555555'
    $path = Get-LabVMInstallMediaPath $id
    Assert-Equal ($path -like "*InstallMedia*$id.json") $true
}
Test-Case 'Set-LabVMInstallMedia reuses a single existing DVD drive' {
    $script:FakeDvdDrives.Clear()
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = $null })
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $tempLocal = Join-Path ([IO.Path]::GetTempPath()) ('labinstallmedia-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('labiso-' + [guid]::NewGuid().ToString('N') + '.iso')
    [IO.File]::WriteAllBytes($isoPath, [byte[]]@(1, 2, 3))
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $tempLocal
        $result = Set-LabVMInstallMedia $script:FakeId $isoPath
        Assert-Equal $script:AddVMDvdDriveCalls 0
        Assert-Equal $result.DvdDriveAdded $false
        Assert-Equal $result.PreviousAttachment ''
        Assert-Equal $script:FakeDvdDrives[0].Path $isoPath
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        if ([IO.Directory]::Exists($tempLocal)) { [IO.Directory]::Delete($tempLocal, $true) }
        [IO.File]::Delete($isoPath)
    }
}
Test-Case 'Set-LabVMInstallMedia adds a drive when none exists' {
    $script:FakeDvdDrives.Clear()
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $tempLocal = Join-Path ([IO.Path]::GetTempPath()) ('labinstallmedia-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('labiso-' + [guid]::NewGuid().ToString('N') + '.iso')
    [IO.File]::WriteAllBytes($isoPath, [byte[]]@(1, 2, 3))
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $tempLocal
        $result = Set-LabVMInstallMedia $script:FakeId $isoPath
        Assert-Equal $script:AddVMDvdDriveCalls 1
        Assert-Equal $result.DvdDriveAdded $true
        Assert-Equal $script:FakeDvdDrives.Count 1
        Assert-Equal $script:FakeDvdDrives[0].Path $isoPath
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        if ([IO.Directory]::Exists($tempLocal)) { [IO.Directory]::Delete($tempLocal, $true) }
        [IO.File]::Delete($isoPath)
    }
}
Test-Case 'Set-LabVMInstallMedia throws when multiple drives exist' {
    $script:FakeDvdDrives.Clear()
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = $null })
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = $null })
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('labiso-' + [guid]::NewGuid().ToString('N') + '.iso')
    [IO.File]::WriteAllBytes($isoPath, [byte[]]@(1, 2, 3))
    try {
        Assert-Throws { Set-LabVMInstallMedia $script:FakeId $isoPath } 'more than one DVD drive exists'
        Assert-Equal $script:AddVMDvdDriveCalls 0
        Assert-Equal $script:SetVMDvdDriveCalls.Count 0
    } finally {
        [IO.File]::Delete($isoPath)
        $script:FakeDvdDrives.Clear()
    }
}
Test-Case 'Set-LabVMInstallMedia rejects a since-deleted ISO path' {
    $script:FakeDvdDrives.Clear()
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = $null })
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $tempLocal = Join-Path ([IO.Path]::GetTempPath()) ('labinstallmedia-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $missingIsoPath = Join-Path ([IO.Path]::GetTempPath()) ('labiso-missing-' + [guid]::NewGuid().ToString('N') + '.iso')
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $tempLocal
        Assert-Throws { Set-LabVMInstallMedia $script:FakeId $missingIsoPath } 'no longer exists'
        Assert-Equal $script:SetVMDvdDriveCalls.Count 0
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        if ([IO.Directory]::Exists($tempLocal)) { [IO.Directory]::Delete($tempLocal, $true) }
    }
}
Test-Case 'Remove-LabVMInstallMedia ejects without removing the drive' {
    $script:FakeDvdDrives.Clear()
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = 'E:\ISO\old.iso' })
    $script:SetVMDvdDriveCalls.Clear()
    Remove-LabVMInstallMedia $script:FakeId
    Assert-Equal $script:FakeDvdDrives.Count 1
    # The fake's [string]$Path parameter coerces the $null argument to '' during binding, same as
    # [string]$drive.Path elsewhere in this file; the real Set-VMDvdDrive -Path $null idiom is what
    # the production code actually calls (see Lab-VM.ps1), this only reflects the fake's own typing.
    Assert-Equal $script:FakeDvdDrives[0].Path ''
    Assert-Equal $script:SetVMDvdDriveCalls.Count 1
    Assert-Equal $script:SetVMDvdDriveCalls[0] ''
}
Test-Case 'Set-LabVMInstallMedia re-validates the ISO before adding a drive or writing the record' {
    $script:FakeDvdDrives.Clear()
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $tempLocal = Join-Path ([IO.Path]::GetTempPath()) ('labinstallmedia-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $emptyIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-empty-' + [guid]::NewGuid().ToString('N') + '.iso')
    [IO.File]::WriteAllBytes($emptyIso, [byte[]]@())
    $missingIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-missing-' + [guid]::NewGuid().ToString('N') + '.iso')
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $tempLocal
        Assert-Throws { Set-LabVMInstallMedia $script:FakeId $missingIso } 'no longer exists'
        Assert-Throws { Set-LabVMInstallMedia $script:FakeId $emptyIso } 'is empty'
        Assert-Equal $script:AddVMDvdDriveCalls 0
        Assert-Equal $script:FakeDvdDrives.Count 0
        Assert-Equal $script:SetVMDvdDriveCalls.Count 0
        Assert-Equal ([IO.File]::Exists((Get-LabVMInstallMediaPath $script:FakeId))) $false
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        if ([IO.Directory]::Exists($tempLocal)) { [IO.Directory]::Delete($tempLocal, $true) }
        [IO.File]::Delete($emptyIso)
    }
}
Test-Case 'Set-LabVMBootOrder reorders real-shape VMBootSource{DvdDrive} entries without dropping any' {
    $nic = New-FakeBootEntry 'Nic'; $hdd = New-FakeBootEntry 'Disk'; $dvd = New-FakeBootEntry 'Dvd'
    $script:FakeFirmware.BootOrder = @($nic, $hdd, $dvd)
    $script:SetVMFirmwareBootOrderCalls.Clear()
    Set-LabVMBootOrder $script:FakeId 'Dvd'
    $applied = @($script:SetVMFirmwareBootOrderCalls[-1])
    Assert-Equal $applied.Count 3
    Assert-Equal ([object]::ReferenceEquals($applied[0], $dvd)) $true
    Assert-Equal ([object]::ReferenceEquals($applied[1], $nic)) $true
    Assert-Equal ([object]::ReferenceEquals($applied[2], $hdd)) $true
}
Test-Case 'Set-LabVMBootOrder preference Disk puts the real-shape HardDiskDrive entry first' {
    $dvd = New-FakeBootEntry 'Dvd'; $nic = New-FakeBootEntry 'Nic'; $hdd = New-FakeBootEntry 'Disk'
    $script:FakeFirmware.BootOrder = @($dvd, $nic, $hdd)
    $script:SetVMFirmwareBootOrderCalls.Clear()
    Set-LabVMBootOrder $script:FakeId 'Disk'
    $applied = @($script:SetVMFirmwareBootOrderCalls[-1])
    Assert-Equal $applied.Count 3
    Assert-Equal ([object]::ReferenceEquals($applied[0], $hdd)) $true
    Assert-Equal ([object]::ReferenceEquals($applied[1], $dvd)) $true
    Assert-Equal ([object]::ReferenceEquals($applied[2], $nic)) $true
}
Test-Case 'Set-LabVMBootOrder backward compatibility: bare VM-prefixed devices still reorder' {
    $script:FakeFirmware.BootOrder = @([VMNetworkAdapter]::new(), [VMHardDiskDrive]::new(), [VMDvdDrive]::new())
    $script:SetVMFirmwareBootOrderCalls.Clear()
    Set-LabVMBootOrder $script:FakeId 'Dvd'
    $applied = @($script:SetVMFirmwareBootOrderCalls[-1])
    Assert-Equal $applied.Count 3
    Assert-Equal ($applied[0] -is [VMDvdDrive]) $true
    Assert-Equal ($applied[1] -is [VMNetworkAdapter]) $true
    Assert-Equal ($applied[2] -is [VMHardDiskDrive]) $true
}

# --- Two-drive unattended-install media attach and post-install cleanup (Task 3) ---
Test-Case 'Set-LabVMUnattendedInstallMedia attaches both drives in order and sets DVD boot order' {
    $script:FakeDvdDrives.Clear()
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $script:SetVMFirmwareBootOrderCalls.Clear()
    $windowsIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-win-' + [guid]::NewGuid().ToString('N') + '.iso')
    $seedIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-seed-' + [guid]::NewGuid().ToString('N') + '.iso')
    # The entries the two new drives would get on a live VM: the seed drive's listed first, so the
    # Windows-drive check must look past it rather than only at the very first entry.
    $script:FakeFirmware.BootOrder = @((New-FakeBootEntry 'Disk'), (New-FakeBootEntry 'Dvd' $seedIso), (New-FakeBootEntry 'Dvd' $windowsIso))
    [IO.File]::WriteAllBytes($windowsIso, [byte[]]@(1, 2, 3))
    [IO.File]::WriteAllBytes($seedIso, [byte[]]@(4, 5, 6))
    try {
        Set-LabVMUnattendedInstallMedia $script:FakeId $windowsIso $seedIso
        Assert-Equal $script:AddVMDvdDriveCalls 2
        Assert-Equal $script:FakeDvdDrives.Count 2
        Assert-Equal $script:FakeDvdDrives[0].Path $windowsIso
        Assert-Equal $script:FakeDvdDrives[1].Path $seedIso
        Assert-Equal ($script:SetVMDvdDriveCalls -join '|') "$windowsIso|$seedIso"
        Assert-Equal $script:SetVMFirmwareBootOrderCalls.Count 1
        $applied = @($script:SetVMFirmwareBootOrderCalls[0])
        Assert-Equal (Get-LabBootEntryKind $applied[0]) 'Dvd'
        Assert-Equal (Get-LabBootEntryKind $applied[1]) 'Dvd'
        Assert-Equal (Get-LabBootEntryKind $applied[2]) 'Disk'
    } finally {
        [IO.File]::Delete($windowsIso)
        [IO.File]::Delete($seedIso)
        $script:FakeDvdDrives.Clear()
    }
}
Test-Case 'Set-LabVMUnattendedInstallMedia throws when only the SEED drive has a recognized boot entry, not the Windows installer drive' {
    $script:FakeDvdDrives.Clear()
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $script:SetVMFirmwareBootOrderCalls.Clear()
    $windowsIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-win-' + [guid]::NewGuid().ToString('N') + '.iso')
    $seedIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-seed-' + [guid]::NewGuid().ToString('N') + '.iso')
    # Only the seed drive's entry is recognizable: Set-LabVMBootOrder itself succeeds (some DVD
    # entry exists and is moved first), so only the new Windows-drive check can catch this.
    $script:FakeFirmware.BootOrder = @((New-FakeBootEntry 'Disk'), (New-FakeBootEntry 'Nic'), (New-FakeBootEntry 'Dvd' $seedIso))
    [IO.File]::WriteAllBytes($windowsIso, [byte[]]@(1, 2, 3))
    [IO.File]::WriteAllBytes($seedIso, [byte[]]@(4, 5, 6))
    try {
        Assert-Throws { Set-LabVMUnattendedInstallMedia $script:FakeId $windowsIso $seedIso } "Windows installer drive's own boot entry"
        # The reorder really did succeed first: this is the specific post-reorder check, not
        # Set-LabVMBootOrder's own generic "no Dvd entry was recognized" refusal.
        Assert-Equal $script:SetVMFirmwareBootOrderCalls.Count 1
        Assert-Equal (Get-LabBootEntryKind @($script:SetVMFirmwareBootOrderCalls[0])[0]) 'Dvd'
        Assert-Equal $script:FakeDvdDrives.Count 2
    } finally {
        [IO.File]::Delete($windowsIso)
        [IO.File]::Delete($seedIso)
        $script:FakeDvdDrives.Clear()
    }
}
Test-Case 'Set-LabVMUnattendedInstallMedia refuses a VM that already has a DVD drive, before any mutation' {
    $script:FakeDvdDrives.Clear()
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = $null })
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $windowsIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-win-' + [guid]::NewGuid().ToString('N') + '.iso')
    $seedIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-seed-' + [guid]::NewGuid().ToString('N') + '.iso')
    [IO.File]::WriteAllBytes($windowsIso, [byte[]]@(1, 2, 3))
    [IO.File]::WriteAllBytes($seedIso, [byte[]]@(4, 5, 6))
    try {
        Assert-Throws { Set-LabVMUnattendedInstallMedia $script:FakeId $windowsIso $seedIso } 'DVD drive'
        Assert-Equal $script:AddVMDvdDriveCalls 0
        Assert-Equal $script:SetVMDvdDriveCalls.Count 0
    } finally {
        [IO.File]::Delete($windowsIso)
        [IO.File]::Delete($seedIso)
        $script:FakeDvdDrives.Clear()
    }
}
Test-Case 'Set-LabVMUnattendedInstallMedia refuses a Generation 1 VM, before any mutation' {
    $script:FakeVM.Generation = 1
    $script:FakeDvdDrives.Clear()
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $windowsIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-win-' + [guid]::NewGuid().ToString('N') + '.iso')
    $seedIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-seed-' + [guid]::NewGuid().ToString('N') + '.iso')
    [IO.File]::WriteAllBytes($windowsIso, [byte[]]@(1, 2, 3))
    [IO.File]::WriteAllBytes($seedIso, [byte[]]@(4, 5, 6))
    try {
        Assert-Throws { Set-LabVMUnattendedInstallMedia $script:FakeId $windowsIso $seedIso } 'Generation'
        Assert-Equal $script:AddVMDvdDriveCalls 0
        Assert-Equal $script:SetVMDvdDriveCalls.Count 0
    } finally {
        $script:FakeVM.Generation = 2
        [IO.File]::Delete($windowsIso)
        [IO.File]::Delete($seedIso)
    }
}
Test-Case 'Set-LabVMUnattendedInstallMedia leaves the Windows drive attached, unrolled back, when the seed ISO fails re-validation' {
    $script:FakeDvdDrives.Clear()
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $windowsIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-win-' + [guid]::NewGuid().ToString('N') + '.iso')
    [IO.File]::WriteAllBytes($windowsIso, [byte[]]@(1, 2, 3))
    $missingSeedIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-seed-missing-' + [guid]::NewGuid().ToString('N') + '.iso')
    try {
        Assert-Throws { Set-LabVMUnattendedInstallMedia $script:FakeId $windowsIso $missingSeedIso } 'no longer exists'
        # Proves the ordering: the Windows drive (drive 1) was already added and attached before the
        # seed ISO's re-validation ran and threw -- so no cleanup/rollback happens here.
        Assert-Equal $script:AddVMDvdDriveCalls 1
        Assert-Equal $script:FakeDvdDrives.Count 1
        Assert-Equal $script:FakeDvdDrives[0].Path $windowsIso
        Assert-Equal $script:SetVMDvdDriveCalls.Count 1
        Assert-Equal $script:SetVMDvdDriveCalls[0] $windowsIso
    } finally {
        [IO.File]::Delete($windowsIso)
        $script:FakeDvdDrives.Clear()
    }
}
Test-Case 'Complete-LabWindowsProvisioning removes the seed drive and ejects (not removes) the installer drive' {
    $windowsIso = 'D:\iso\win.iso'
    $seedIso = 'D:\iso\seed.iso'
    $script:FakeDvdDrives.Clear()
    $windowsDrive = [pscustomobject]@{ Path = $windowsIso }
    $seedDrive = [pscustomobject]@{ Path = $seedIso }
    $script:FakeDvdDrives.Add($windowsDrive)
    $script:FakeDvdDrives.Add($seedDrive)
    $script:SetVMDvdDriveCalls.Clear()
    $script:RemoveVMDvdDriveCalls.Clear()
    $script:SetVMFirmwareBootOrderCalls.Clear()
    $script:FakeFirmware.BootOrder = @((New-FakeBootEntry 'Dvd'), (New-FakeBootEntry 'Disk'))
    Complete-LabWindowsProvisioning $script:FakeId $windowsIso $seedIso
    Assert-Equal $script:RemoveVMDvdDriveCalls.Count 1
    Assert-Equal ([object]::ReferenceEquals($script:RemoveVMDvdDriveCalls[0], $seedDrive)) $true
    Assert-Equal $script:FakeDvdDrives.Count 1
    Assert-Equal $script:SetVMDvdDriveCalls.Count 1
    Assert-Equal $script:SetVMDvdDriveCalls[0] ''
    Assert-Equal $windowsDrive.Path ''
    Assert-Equal $script:SetVMFirmwareBootOrderCalls.Count 1
    $applied = @($script:SetVMFirmwareBootOrderCalls[0])
    Assert-Equal (Get-LabBootEntryKind $applied[0]) 'Disk'
}
Test-Case 'Complete-LabWindowsProvisioning throws clearly when neither known ISO path matches an attached drive' {
    $script:FakeDvdDrives.Clear()
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = 'D:\iso\other1.iso' })
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = 'D:\iso\other2.iso' })
    $script:SetVMDvdDriveCalls.Clear()
    $script:RemoveVMDvdDriveCalls.Clear()
    try {
        Assert-Throws { Complete-LabWindowsProvisioning $script:FakeId 'D:\iso\win.iso' 'D:\iso\seed.iso' } 'could not find'
        Assert-Equal $script:SetVMDvdDriveCalls.Count 0
        Assert-Equal $script:RemoveVMDvdDriveCalls.Count 0
    } finally {
        $script:FakeDvdDrives.Clear()
    }
}

# --- Windows unattended install, Task 4: Autounattend.xml content builder ---
# Pure function -- no fakes needed, call it directly. Namespace-agnostic XPath (local-name()) is
# used throughout because the real unattend.xml document declares a default namespace, and
# PowerShell's dot-notation adapter is not reliably trustworthy to assert against here.
function Select-LabXmlNode {
    param([xml]$Xml, [string]$LocalName)
    return $Xml.SelectSingleNode("//*[local-name()='$LocalName']")
}
Test-Case 'New-LabWindowsAnswerFileXml returns well-formed XML containing the given computer name, locale, timezone and username' {
    $securePassword = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    $result = New-LabWindowsAnswerFileXml 'LAB-PC01' 'en-US' 'Pacific Standard Time' 1 'labadmin' $securePassword
    $xml = [xml]$result
    Assert-Equal (Select-LabXmlNode $xml 'ComputerName').InnerText 'LAB-PC01'
    Assert-Equal (Select-LabXmlNode $xml 'TimeZone').InnerText 'Pacific Standard Time'
    Assert-Equal (Select-LabXmlNode $xml 'SystemLocale').InnerText 'en-US'
    Assert-Equal (Select-LabXmlNode $xml 'InputLocale').InnerText 'en-US'
    Assert-Equal (Select-LabXmlNode $xml 'UILanguage').InnerText 'en-US'
    Assert-Equal (Select-LabXmlNode $xml 'UserLocale').InnerText 'en-US'
    Assert-Equal (Select-LabXmlNode $xml 'Username').InnerText 'labadmin'
    Assert-Equal ($xml.SelectSingleNode("//*[local-name()='LocalAccount']/*[local-name()='Name']")).InnerText 'labadmin'
}
Test-Case 'New-LabWindowsAnswerFileXml selects the passed ImageIndex in InstallFrom metadata, with no product key' {
    $securePassword = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    $result = New-LabWindowsAnswerFileXml 'LAB-PC01' 'en-US' 'Pacific Standard Time' 3 'labadmin' $securePassword
    $xml = [xml]$result
    $installFrom = $xml.SelectSingleNode("//*[local-name()='InstallFrom']")
    Assert-Equal ($installFrom.SelectSingleNode("*[local-name()='MetaData']/*[local-name()='Key']")).InnerText '/IMAGE/INDEX'
    Assert-Equal ($installFrom.SelectSingleNode("*[local-name()='MetaData']/*[local-name()='Value']")).InnerText '3'
    Assert-Equal ($result.Contains('ProductKey')) $false
}
Test-Case 'New-LabWindowsAnswerFileXml enables AutoLogon for exactly one logon' {
    $securePassword = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    $result = New-LabWindowsAnswerFileXml 'LAB-PC01' 'en-US' 'Pacific Standard Time' 1 'labadmin' $securePassword
    $xml = [xml]$result
    $autoLogon = $xml.SelectSingleNode("//*[local-name()='AutoLogon']")
    Assert-Equal ($autoLogon.SelectSingleNode("*[local-name()='LogonCount']")).InnerText '1'
    Assert-Equal ($autoLogon.SelectSingleNode("*[local-name()='Enabled']")).InnerText 'true'
}
Test-Case 'New-LabWindowsAnswerFileXml puts the identical plaintext password in both the local account and AutoLogon' {
    $plainPassword = 'Tr0ub4dor&3'
    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    $result = New-LabWindowsAnswerFileXml 'LAB-PC01' 'en-US' 'Pacific Standard Time' 1 'labadmin' $securePassword
    $xml = [xml]$result
    $accountPassword = ($xml.SelectSingleNode("//*[local-name()='LocalAccount']/*[local-name()='Password']/*[local-name()='Value']")).InnerText
    $autoLogonPassword = ($xml.SelectSingleNode("//*[local-name()='AutoLogon']/*[local-name()='Password']/*[local-name()='Value']")).InnerText
    Assert-Equal $accountPassword $plainPassword
    Assert-Equal $autoLogonPassword $plainPassword
    Assert-Equal $accountPassword $autoLogonPassword
}
Test-Case 'New-LabWindowsAnswerFileXml output varies with its inputs' {
    $securePasswordA = ConvertTo-SecureString 'Secret1!' -AsPlainText -Force
    $securePasswordB = ConvertTo-SecureString 'Secret2!' -AsPlainText -Force
    $resultA = New-LabWindowsAnswerFileXml 'LAB-ONE' 'en-US' 'Pacific Standard Time' 1 'alice' $securePasswordA
    $resultB = New-LabWindowsAnswerFileXml 'LAB-TWO' 'fr-FR' 'W. Europe Standard Time' 2 'bob' $securePasswordB
    Assert-Equal ($resultA -eq $resultB) $false
    $xmlA = [xml]$resultA
    $xmlB = [xml]$resultB
    Assert-Equal (Select-LabXmlNode $xmlA 'ComputerName').InnerText 'LAB-ONE'
    Assert-Equal (Select-LabXmlNode $xmlB 'ComputerName').InnerText 'LAB-TWO'
    Assert-Equal (Select-LabXmlNode $xmlA 'SystemLocale').InnerText 'en-US'
    Assert-Equal (Select-LabXmlNode $xmlB 'SystemLocale').InnerText 'fr-FR'
    Assert-Equal (Select-LabXmlNode $xmlA 'TimeZone').InnerText 'Pacific Standard Time'
    Assert-Equal (Select-LabXmlNode $xmlB 'TimeZone').InnerText 'W. Europe Standard Time'
    $installFromA = $xmlA.SelectSingleNode("//*[local-name()='InstallFrom']/*[local-name()='MetaData']/*[local-name()='Value']")
    $installFromB = $xmlB.SelectSingleNode("//*[local-name()='InstallFrom']/*[local-name()='MetaData']/*[local-name()='Value']")
    Assert-Equal $installFromA.InnerText '1'
    Assert-Equal $installFromB.InnerText '2'
}
Test-Case 'New-LabWindowsAnswerFileXml skips every OOBE prompt this plan depends on' {
    $securePassword = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    $result = New-LabWindowsAnswerFileXml 'LAB-PC01' 'en-US' 'Pacific Standard Time' 1 'labadmin' $securePassword
    $xml = [xml]$result
    foreach ($elementName in @('HideEULAPage', 'HideOEMRegistrationScreen', 'HideWirelessSetupInOOBE', 'NetworkLocation', 'ProtectYourPC')) {
        $node = Select-LabXmlNode $xml $elementName
        if ($null -eq $node) { throw "Missing OOBE element: $elementName" }
    }
}
Test-Case 'New-LabWindowsAnswerFileXml answers Setup''s own language page via International-Core-WinPE in the windowsPE pass' {
    $securePassword = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    # A non-default locale, so a hard-coded en-US in the WinPE component could not pass by accident.
    $result = New-LabWindowsAnswerFileXml 'LAB-PC01' 'fr-FR' 'W. Europe Standard Time' 1 'labadmin' $securePassword
    $xml = [xml]$result
    $component = $xml.SelectSingleNode("//*[local-name()='settings'][@pass='windowsPE']/*[local-name()='component'][@name='Microsoft-Windows-International-Core-WinPE']")
    if ($null -eq $component) { throw 'Missing Microsoft-Windows-International-Core-WinPE component in the windowsPE pass.' }
    Assert-Equal $component.GetAttribute('processorArchitecture') 'amd64'
    Assert-Equal $component.GetAttribute('publicKeyToken') '31bf3856ad364e35'
    Assert-Equal $component.GetAttribute('language') 'neutral'
    Assert-Equal $component.GetAttribute('versionScope') 'nonSxS'
    Assert-Equal ($component.SelectSingleNode("*[local-name()='SetupUILanguage']/*[local-name()='UILanguage']")).InnerText 'fr-FR'
    foreach ($elementName in @('InputLocale', 'SystemLocale', 'UILanguage', 'UserLocale')) {
        $node = $component.SelectSingleNode("*[local-name()='$elementName']")
        if ($null -eq $node) { throw "Missing WinPE element: $elementName" }
        Assert-Equal $node.InnerText 'fr-FR'
    }
    # Same pass as Microsoft-Windows-Setup, and still no product key anywhere.
    $setup = $xml.SelectSingleNode("//*[local-name()='settings'][@pass='windowsPE']/*[local-name()='component'][@name='Microsoft-Windows-Setup']")
    if ($null -eq $setup) { throw 'Microsoft-Windows-Setup is no longer in the windowsPE pass.' }
    Assert-Equal ($result.Contains('ProductKey')) $false
}
Test-Case 'New-LabWindowsAnswerFileXml without -ProductKey has no ProductKey element anywhere' {
    $securePassword = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    $result = New-LabWindowsAnswerFileXml 'LAB-PC01' 'en-US' 'Pacific Standard Time' 1 'labadmin' $securePassword
    $xml = [xml]$result
    Assert-Equal (Select-LabXmlNode $xml 'ProductKey') $null
    # Same with the parameter explicitly supplied but empty: still no activation, by design.
    $resultExplicitEmpty = New-LabWindowsAnswerFileXml 'LAB-PC01' 'en-US' 'Pacific Standard Time' 1 'labadmin' $securePassword ''
    $xmlExplicitEmpty = [xml]$resultExplicitEmpty
    Assert-Equal (Select-LabXmlNode $xmlExplicitEmpty 'ProductKey') $null
}
Test-Case 'New-LabWindowsAnswerFileXml with -ProductKey adds the key and WillShowUI=OnError, keeping AcceptEula' {
    $securePassword = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    $result = New-LabWindowsAnswerFileXml 'LAB-PC01' 'en-US' 'Pacific Standard Time' 1 'labadmin' $securePassword '12345-ABCDE-12345-ABCDE-12345'
    $xml = [xml]$result
    $productKey = $xml.SelectSingleNode("//*[local-name()='ProductKey']")
    Assert-Equal ($productKey.SelectSingleNode("*[local-name()='Key']")).InnerText '12345-ABCDE-12345-ABCDE-12345'
    Assert-Equal ($productKey.SelectSingleNode("*[local-name()='WillShowUI']")).InnerText 'OnError'
    Assert-Equal (Select-LabXmlNode $xml 'AcceptEula').InnerText 'true'
}

Test-Case 'New VM name must start with LAB-' { Assert-Equal (Test-LabNewVMName 'OTHER-Test' @()) $false }
Test-Case 'New VM name rejects case-insensitive duplicate' { Assert-Equal (Test-LabNewVMName 'lab-test' @('LAB-Test')) $false }
Test-Case 'New VM name accepts unique name' { Assert-Equal (Test-LabNewVMName 'LAB-New' @('LAB-Test')) $true }
Test-Case 'New VM name rejects backslash path separator' { Assert-Equal (Test-LabNewVMName 'LAB-a\..\b' @()) $false }
Test-Case 'New VM name rejects forward slash path separator' { Assert-Equal (Test-LabNewVMName 'LAB-a/b' @()) $false }
Test-Case 'New VM name rejects wildcard' { Assert-Equal (Test-LabNewVMName 'LAB-*' @()) $false }
Test-Case 'New VM name rejects drive/colon character' { Assert-Equal (Test-LabNewVMName 'LAB-C:x' @()) $false }
Test-Case 'New VM name rejects control character' { Assert-Equal (Test-LabNewVMName "LAB-a`tb" @()) $false }
Test-Case 'New VM name rejects excessive length' { Assert-Equal (Test-LabNewVMName ('LAB-' + ('a' * 97)) @()) $false }
Test-Case 'New VM name accepts 100-character name' { Assert-Equal (Test-LabNewVMName ('LAB-' + ('a' * 96)) @()) $true }
Test-Case 'vCPU count zero rejected' { Assert-Equal (Test-LabVCpuCount 0 8) $false }
Test-Case 'vCPU count above host max rejected' { Assert-Equal (Test-LabVCpuCount 9 8) $false }
Test-Case 'vCPU count within range accepted' { Assert-Equal (Test-LabVCpuCount 4 8) $true }
Test-Case 'Dynamic memory requires minimum <= startup <= maximum' { Assert-Equal (Test-LabMemorySpec 1GB 512MB 4GB $true) $false }
Test-Case 'Dynamic memory rejects non-multiple-of-2MB value' { Assert-Equal (Test-LabMemorySpec 512MB (1GB+1MB) 4GB $true) $false }
Test-Case 'Dynamic memory accepts valid ordered range' { Assert-Equal (Test-LabMemorySpec 512MB 1GB 4GB $true) $true }
Test-Case 'Static memory ignores min/max and checks startup only' { Assert-Equal (Test-LabMemorySpec 0 2GB 0 $false) $true }
Test-Case 'Static memory rejects non-positive startup' { Assert-Equal (Test-LabMemorySpec 0 0 0 $false) $false }
Test-Case 'No destination means proceed' { Assert-Equal (Get-LabTransferConflictKind $false $false $false) 'None' }
Test-Case 'File onto existing directory is a type mismatch' { Assert-Equal (Get-LabTransferConflictKind $false $true $true) 'TypeMismatch' }
Test-Case 'Directory onto existing file is a type mismatch' { Assert-Equal (Get-LabTransferConflictKind $true $true $false) 'TypeMismatch' }
Test-Case 'File onto existing file is Exists' { Assert-Equal (Get-LabTransferConflictKind $false $true $false) 'Exists' }
Test-Case 'Directory onto existing directory is Exists' { Assert-Equal (Get-LabTransferConflictKind $true $true $true) 'Exists' }
Test-Case 'No conflict always proceeds' { Assert-Equal (Resolve-LabConflictAction 'None' 'Error') 'Proceed' }
Test-Case 'Type mismatch always errors under Error policy' { Assert-Equal (Resolve-LabConflictAction 'TypeMismatch' 'Error') 'Error' }
Test-Case 'Type mismatch always errors under Skip policy' { Assert-Equal (Resolve-LabConflictAction 'TypeMismatch' 'Skip') 'Error' }
Test-Case 'Type mismatch always errors under Overwrite policy' { Assert-Equal (Resolve-LabConflictAction 'TypeMismatch' 'Overwrite') 'Error' }
Test-Case 'Exists under Error policy errors' { Assert-Equal (Resolve-LabConflictAction 'Exists' 'Error') 'Error' }
Test-Case 'Exists under Skip policy skips' { Assert-Equal (Resolve-LabConflictAction 'Exists' 'Skip') 'Skip' }
Test-Case 'Exists under Overwrite policy overwrites' { Assert-Equal (Resolve-LabConflictAction 'Exists' 'Overwrite') 'Overwrite' }
Test-Case 'No diff when values are identical' {
    $current = [pscustomobject]@{ Name='LAB-Test'; VCpuCount=2; StartupBytes=2GB }
    Assert-Equal (Get-LabSettingsDiff $current $current).Count 0
}
Test-Case 'Diff reports only changed fields' {
    $current = [pscustomobject]@{ Name='LAB-Test'; VCpuCount=2; StartupBytes=2GB }
    $proposed = [pscustomobject]@{ Name='LAB-Test'; VCpuCount=4; StartupBytes=2GB }
    $diff = Get-LabSettingsDiff $current $proposed
    Assert-Equal $diff.Count 1
    Assert-Equal $diff[0].Field 'VCpuCount'
    Assert-Equal $diff[0].NewValue 4
}
Test-Case 'Diff only compares fields shared by both objects' {
    $current = [pscustomobject]@{ Name='LAB-Test' }
    $proposed = [pscustomobject]@{ Name='LAB-Test'; Notes='extra field not on current' }
    Assert-Equal (Get-LabSettingsDiff $current $proposed).Count 0
}
Test-Case 'Diff uses exact boolean comparison for DynamicMemoryEnabled' {
    $current = [pscustomobject]@{ DynamicMemoryEnabled = $false }
    $proposed = [pscustomobject]@{ DynamicMemoryEnabled = $true }
    $diff = Get-LabSettingsDiff $current $proposed
    Assert-Equal $diff.Count 1
    Assert-Equal $diff[0].Field 'DynamicMemoryEnabled'
}
Test-Case 'Diff reports a case-only Name change' {
    $current = [pscustomobject]@{ Name='LAB-Test' }
    $proposed = [pscustomobject]@{ Name='lab-test' }
    $diff = Get-LabSettingsDiff $current $proposed
    Assert-Equal $diff.Count 1
    Assert-Equal $diff[0].Field 'Name'
    Assert-Equal $diff[0].NewValue 'lab-test'
}
Test-Case 'Diff reports a case-only Notes change' {
    $current = [pscustomobject]@{ Notes='build box' }
    $proposed = [pscustomobject]@{ Notes='Build Box' }
    $diff = Get-LabSettingsDiff $current $proposed
    Assert-Equal $diff.Count 1
    Assert-Equal $diff[0].Field 'Notes'
}
Test-Case 'Static-memory no-op edit carrying min/max forward yields no diff' {
    # Mirrors Edit-LabVMSettings' static branch: unequal stored min/max (Hyper-V defaults) carried forward.
    $current = [pscustomobject]@{ Name='LAB-Test'; Notes=''; VCpuCount=2; StartupBytes=2GB;
        MinimumBytes=512MB; MaximumBytes=1TB; DynamicMemoryEnabled=$false; SwitchName=$null }
    $proposed = [pscustomobject]@{ Name='LAB-Test'; Notes=''; VCpuCount=2; StartupBytes=2GB;
        MinimumBytes=$current.MinimumBytes; MaximumBytes=$current.MaximumBytes; DynamicMemoryEnabled=$false; SwitchName=$null }
    Assert-Equal (Get-LabSettingsDiff $current $proposed).Count 0
}
Test-Case 'Identity file present selects KeyAgent mode' { Assert-Equal (Resolve-LabSshAuthMode 'C:\keys\id_ed25519' $false) 'KeyAgent' }
Test-Case 'No identity file, interactive allowed, selects InteractivePassword' { Assert-Equal (Resolve-LabSshAuthMode '' $false) 'InteractivePassword' }
Test-Case 'No identity file under NonInteractive throws' {
    Assert-Throws { Resolve-LabSshAuthMode '' $true } 'identity file'
}
Test-Case 'Identity file present under NonInteractive still selects KeyAgent' { Assert-Equal (Resolve-LabSshAuthMode 'C:\keys\id_ed25519' $true) 'KeyAgent' }
Test-Case 'Configured SSH settings select the SFTP adapter' {
    $script:FakeSshSettings = [pscustomobject]@{ HostNameOrAddress = '10.0.0.5'; Port = 22; UserName = 'dev'; IdentityFilePath = 'C:\keys\id_ed25519' }
    try { Assert-Equal (Get-LabTransferAdapterKind $script:FakeId) 'SFTP' }
    finally { $script:FakeSshSettings = $null }
}
Test-Case 'No SSH settings select the PSDirect adapter' {
    $script:FakeSshSettings = $null
    Assert-Equal (Get-LabTransferAdapterKind $script:FakeId) 'PSDirect'
}

# --- Windows unattended install, Task 5: PowerShell Direct completion wait and note delivery ---
# Write-LabProvisioningNote is loaded with its PSSession parameter type loosened, same as the
# transfer engine functions below, so a fake session object can stand in for a real
# PowerShell Direct connection. Wait-LabPSDirectSession takes no PSSession parameter, so it is
# loaded normally via the main allowlist above.
foreach ($name in @('Write-LabProvisioningNote')) {
    $matches = @($definitions | Where-Object { $_.Name -ceq $name })
    if ($matches.Count -ne 1) { throw "Expected one definition of $name." }
    . ([scriptblock]::Create($matches[0].Extent.Text.Replace('[System.Management.Automation.Runspaces.PSSession]$Session', '$Session')))
}

# New-LabPSDirectSession (the already-shipped, already-tested building block the real function
# reuses) is replaced here so no real Hyper-V / PowerShell Direct connection is attempted.
# $script:PSDirectFailuresBeforeSuccess failures are thrown before an "Opened" session is handed
# back; $script:PSDirectAlwaysFails models a guest that never becomes reachable within the test's
# timeout. Start-Sleep is a no-op so these tests run in real wall-clock milliseconds, not minutes --
# the one exception is the timeout test, which relies on the function's own real
# [Diagnostics.Stopwatch] to end the loop, so it genuinely takes about as long as its own
# $TimeoutSeconds.
$script:PSDirectAttempts = 0
$script:PSDirectFailuresBeforeSuccess = 0
$script:PSDirectAlwaysFails = $false
function New-LabPSDirectSession {
    param($VMId, $Credential)
    $script:PSDirectAttempts++
    if ($script:PSDirectAlwaysFails -or $script:PSDirectAttempts -le $script:PSDirectFailuresBeforeSuccess) {
        throw 'simulated: guest not ready to accept PowerShell Direct connections yet'
    }
    return [pscustomobject]@{ State = 'Opened' }
}
$script:SleepCalls = 0
function Start-Sleep { param([int]$Seconds) $script:SleepCalls++ }

Test-Case 'Wait-LabPSDirectSession retries past early failures, sleeping between attempts, and returns the opened session' {
    $script:PSDirectAttempts = 0; $script:PSDirectFailuresBeforeSuccess = 2; $script:PSDirectAlwaysFails = $false
    $script:SleepCalls = 0
    $session = Wait-LabPSDirectSession $script:FakeId $null 60
    Assert-Equal $session.State 'Opened'
    Assert-Equal ($script:PSDirectAttempts -ge 3) $true
    Assert-Equal ($script:SleepCalls -ge 2) $true
}
Test-Case 'Wait-LabPSDirectSession times out with a clear message once its own stopwatch runs out' {
    $script:PSDirectAttempts = 0; $script:PSDirectFailuresBeforeSuccess = 0; $script:PSDirectAlwaysFails = $true
    $script:SleepCalls = 0
    $realWatch = [Diagnostics.Stopwatch]::StartNew()
    # 6>$null discards this fast-spinning fake's hundreds of per-attempt Write-Host progress lines;
    # production use (seconds between real attempts) never produces output anywhere near this volume.
    # The final error must carry the last specific failure the loop saw, not just the elapsed time.
    Assert-Throws { Wait-LabPSDirectSession $script:FakeId $null 1 6>$null } 'Timed out.*Last error: simulated: guest not ready to accept PowerShell Direct'
    $realElapsedSeconds = $realWatch.Elapsed.TotalSeconds
    # The function's own 1-second budget, not this fast-spinning fake's retry count, bounds how
    # long the real stopwatch runs; a generous ceiling keeps this robust on a loaded CI box.
    Assert-Equal ($realElapsedSeconds -lt 15) $true
    Assert-Equal ($script:PSDirectAttempts -gt 1) $true
}
Test-Case 'Wait-LabPSDirectSession shows a calibrated explanation for the two known transient errors, not the raw text' {
    $script:PSDirectAttempts = 0; $script:PSDirectAlwaysFails = $false; $script:SleepCalls = 0
    $script:PSDirectRawMessages = @(
        'An error has occurred which Windows PowerShell cannot handle. A remote session might have ended.',
        'The credential is invalid.'
    )
    function New-LabPSDirectSession {
        param($VMId, $Credential)
        $script:PSDirectAttempts++
        if ($script:PSDirectAttempts -le $script:PSDirectRawMessages.Count) {
            throw $script:PSDirectRawMessages[$script:PSDirectAttempts - 1]
        }
        return [pscustomobject]@{ State = 'Opened' }
    }
    try {
        $lines = @(Wait-LabPSDirectSession $script:FakeId $null 60 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        if (-not $lines.Contains('Windows is not far enough along yet to accept a PowerShell Direct connection')) {
            throw "Expected the calibrated 'not far enough along' explanation in: $lines"
        }
        if (-not $lines.Contains('the account exists but may still be finishing first-logon setup')) {
            throw "Expected the calibrated 'finishing first-logon setup' explanation in: $lines"
        }
        if ($lines.Contains('cannot handle') -or $lines.Contains('A remote session might have ended') -or
            $lines.Contains('The credential is invalid.')) {
            throw "Raw, unfriendly text leaked into the progress output: $lines"
        }
    } finally {
        function New-LabPSDirectSession {
            param($VMId, $Credential)
            $script:PSDirectAttempts++
            if ($script:PSDirectAlwaysFails -or $script:PSDirectAttempts -le $script:PSDirectFailuresBeforeSuccess) {
                throw 'simulated: guest not ready to accept PowerShell Direct connections yet'
            }
            return [pscustomobject]@{ State = 'Opened' }
        }
    }
}
Test-Case 'Wait-LabPSDirectSession shows an unrecognized error message unchanged, never hidden' {
    $script:PSDirectAttempts = 0; $script:SleepCalls = 0
    function New-LabPSDirectSession {
        param($VMId, $Credential)
        $script:PSDirectAttempts++
        if ($script:PSDirectAttempts -eq 1) { throw 'simulated: an entirely unanticipated failure mode' }
        return [pscustomobject]@{ State = 'Opened' }
    }
    try {
        $lines = @(Wait-LabPSDirectSession $script:FakeId $null 60 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        if (-not $lines.Contains('simulated: an entirely unanticipated failure mode')) {
            throw "Expected the raw, unmapped message to pass through unchanged in: $lines"
        }
    } finally {
        function New-LabPSDirectSession {
            param($VMId, $Credential)
            $script:PSDirectAttempts++
            if ($script:PSDirectAlwaysFails -or $script:PSDirectAttempts -le $script:PSDirectFailuresBeforeSuccess) {
                throw 'simulated: guest not ready to accept PowerShell Direct connections yet'
            }
            return [pscustomobject]@{ State = 'Opened' }
        }
    }
}

$script:NoteInvokeArgs = $null
function Invoke-Command {
    [CmdletBinding()]
    param($Session, [scriptblock]$ScriptBlock, [object[]]$ArgumentList)
    $script:NoteInvokeArgs = [pscustomobject]@{ Session = $Session; ScriptBlock = $ScriptBlock; ArgumentList = $ArgumentList }
}
Test-Case 'Write-LabProvisioningNote invokes a script block that reads the guest Desktop, carrying the exact content through' {
    $script:NoteInvokeArgs = $null
    $fakeSession = [pscustomobject]@{ State = 'Opened' }
    Write-LabProvisioningNote $fakeSession 'hello from the host'
    Assert-Equal $script:NoteInvokeArgs.Session.State 'Opened'
    Assert-Equal ($script:NoteInvokeArgs.ScriptBlock.ToString().Contains("GetFolderPath('Desktop')")) $true
    Assert-Equal $script:NoteInvokeArgs.ArgumentList[0] 'hello from the host'
}

# --- Transfer engine (Copy-LabTransferItem) against a local temp tree ---
# The engine's functions are loaded from the AST with only the PSSession parameter type loosened,
# so a fake session object can be passed. Invoke-Command runs the "guest" scriptblock locally and
# Copy-Item drops -ToSession/-FromSession and copies locally. No PowerShell Direct, no Hyper-V.
foreach ($name in @('Invoke-LabTransferSide', 'Resolve-LabTransferItemAction', 'Copy-LabTransferItem')) {
    $matches = @($definitions | Where-Object { $_.Name -ceq $name })
    if ($matches.Count -ne 1) { throw "Expected one definition of $name." }
    . ([scriptblock]::Create($matches[0].Extent.Text.Replace('[System.Management.Automation.Runspaces.PSSession]$Session', '$Session')))
}
$script:CopyCalls = 0
$script:CopyMode = 'Normal'
function Invoke-Command {
    [CmdletBinding()]
    param($Session, [scriptblock]$ScriptBlock, [object[]]$ArgumentList)
    & $ScriptBlock @ArgumentList
}
function Copy-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, $ToSession, $FromSession, [string]$Destination, [switch]$Recurse, [switch]$Force)
    $script:CopyCalls++
    switch ($script:CopyMode) {
        'Throw' { throw 'simulated disk full' }
        'Nest' {
            # Simulates a remote -Recurse copy that nests the tree one level deeper (temp\<srcname>\...).
            [void][IO.Directory]::CreateDirectory($Destination)
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse -Force -ErrorAction Stop
        }
        default {
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse -Force -ErrorAction Stop
            if ($script:CopyMode -eq 'CorruptA') {
                $victim = if ($Recurse) { [IO.Path]::Combine($Destination, 'a.txt') } else { $Destination }
                [IO.File]::AppendAllText($victim, 'corrupt')
            }
        }
    }
}
$script:XferSession = [pscustomobject]@{ State = 'Opened' }
$script:XferBase = Join-Path ([IO.Path]::GetTempPath()) ('labxfer-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:XferSrc = Join-Path $script:XferBase 'src'
function Invoke-LabXfer {
    param([string]$Direction, [string]$Source, [string]$Destination, [bool]$Recurse, [string]$OnConflict,
        [bool]$DryRun = $false, [string]$Mode = 'Normal')
    $script:CopyCalls = 0
    $script:CopyMode = $Mode
    try { return Copy-LabTransferItem $script:XferSession $Direction $Source $Destination $Recurse $OnConflict $true $DryRun 6>$null }
    finally { $script:CopyMode = 'Normal' }
}
function Get-LabXferTempCount {
    @(Get-ChildItem -LiteralPath (Join-Path $script:XferBase 'dst') -Recurse -Force | Where-Object { $_.Name -like '*.labxfer-*' }).Count
}
function Get-LabXferDest { param([string]$Name) Join-Path $script:XferBase "dst\$Name" }
function Get-LabXferText { param([string]$Path) [IO.File]::ReadAllText($Path).Trim() }

# Source tree: 6 files (hidden, read-only and bracketed names included) and one empty directory.
foreach ($dir in @('sub\deeper', 'empty')) { [void][IO.Directory]::CreateDirectory((Join-Path $script:XferSrc $dir)) }
[void][IO.Directory]::CreateDirectory((Join-Path $script:XferBase 'dst'))
foreach ($pair in @(@('a.txt', 'alpha'), @('hidden.txt', 'hidden'), @('sub\b.txt', 'bravo'),
        @('sub\[odd] name.txt', 'brackets'), @('sub\readonly.txt', 'ro'), @('sub\deeper\c.txt', 'charlie'))) {
    [IO.File]::WriteAllText((Join-Path $script:XferSrc $pair[0]), $pair[1])
}
[IO.File]::SetAttributes((Join-Path $script:XferSrc 'hidden.txt'), [IO.FileAttributes]::Hidden)
[IO.File]::SetAttributes((Join-Path $script:XferSrc 'sub\readonly.txt'), [IO.FileAttributes]::ReadOnly)

try {
    Test-Case 'Transfer: single file copies and leaves no temp item' {
        $dest = Get-LabXferDest 'one.txt'
        $r = Invoke-LabXfer 'ToVM' (Join-Path $script:XferSrc 'a.txt') $dest $false 'Error'
        Assert-Equal $r.Completed 1
        Assert-Equal (Get-LabXferText $dest) 'alpha'
        Assert-Equal (Get-LabXferTempCount) 0
    }
    Test-Case 'Transfer: single-file Error conflict moves zero bytes' {
        $dest = Get-LabXferDest 'one.txt'
        $r = Invoke-LabXfer 'ToVM' (Join-Path $script:XferSrc 'sub\b.txt') $dest $false 'Error'
        Assert-Equal $r.Failed 1
        Assert-Equal $script:CopyCalls 0
        Assert-Equal (Get-LabXferText $dest) 'alpha'
    }
    Test-Case 'Transfer: single-file Skip conflict moves zero bytes' {
        $dest = Get-LabXferDest 'one.txt'
        $r = Invoke-LabXfer 'FromVM' (Join-Path $script:XferSrc 'sub\b.txt') $dest $false 'Skip'
        Assert-Equal $r.Skipped 1
        Assert-Equal $script:CopyCalls 0
        Assert-Equal (Get-LabXferText $dest) 'alpha'
    }
    Test-Case 'Transfer: single file into a missing nested parent directory creates it' {
        $dest = Get-LabXferDest 'newparent\.ssh\id_test'
        $r = Invoke-LabXfer 'ToVM' (Join-Path $script:XferSrc 'a.txt') $dest $false 'Error'
        Assert-Equal $r.Completed 1
        Assert-Equal $r.Failed 0
        Assert-Equal (Get-LabXferText $dest) 'alpha'
        Assert-Equal (Get-LabXferTempCount) 0
    }
    Test-Case 'Transfer: failed single-file copy removes the empty parents it created' {
        $dest = Get-LabXferDest 'orphan\a\b\id_test'
        $r = Invoke-LabXfer 'FromVM' (Join-Path $script:XferSrc 'a.txt') $dest $false 'Error' -Mode 'CorruptA'
        Assert-Equal $r.Failed 1
        Assert-Equal (Test-Path -LiteralPath (Get-LabXferDest 'orphan')) $false
        Assert-Equal ([IO.Directory]::Exists((Join-Path $script:XferBase 'dst'))) $true
    }
    Test-Case 'Transfer: failed single-file copy never removes a pre-existing parent' {
        $parent = Get-LabXferDest 'keepme'
        [void][IO.Directory]::CreateDirectory($parent)
        $r = Invoke-LabXfer 'ToVM' (Join-Path $script:XferSrc 'a.txt') (Join-Path $parent 'new\id_test') $false 'Error' -Mode 'Throw'
        Assert-Equal $r.Failed 1
        Assert-Equal ([IO.Directory]::Exists($parent)) $true
        Assert-Equal ([IO.Directory]::Exists((Join-Path $parent 'new'))) $false
    }
    Test-Case 'Transfer: an invalid destination path is a failed item, not a thrown error' {
        $r = Invoke-LabXfer 'ToVM' (Join-Path $script:XferSrc 'a.txt') (Get-LabXferDest 'bad|dir\id_test') $false 'Error'
        Assert-Equal $r.Failed 1
        Assert-Equal $script:CopyCalls 0
    }
    Test-Case 'Transfer: single-file dry run into a missing parent creates nothing' {
        $r = Invoke-LabXfer 'ToVM' (Join-Path $script:XferSrc 'a.txt') (Get-LabXferDest 'dryparent\id_test') $false 'Error' -DryRun $true
        Assert-Equal $r.Completed 1
        Assert-Equal $script:CopyCalls 0
        Assert-Equal (Test-Path -LiteralPath (Get-LabXferDest 'dryparent')) $false
    }
    Test-Case 'Transfer: single-file verification failure writes nothing and removes temp' {
        $dest = Get-LabXferDest 'bad.txt'
        $r = Invoke-LabXfer 'ToVM' (Join-Path $script:XferSrc 'a.txt') $dest $false 'Error' -Mode 'CorruptA'
        Assert-Equal $r.Failed 1
        Assert-Equal (Test-Path -LiteralPath $dest) $false
        Assert-Equal (Get-LabXferTempCount) 0
    }
    Test-Case 'Transfer: directory copy lands without nesting, keeps empty dirs, leaves no temp' {
        $tree = Get-LabXferDest 'tree'
        $r = Invoke-LabXfer 'ToVM' $script:XferSrc $tree $true 'Error'
        Assert-Equal $r.Completed 6
        Assert-Equal $r.Failed 0
        Assert-Equal (Get-LabXferText (Join-Path $tree 'sub\deeper\c.txt')) 'charlie'
        Assert-Equal ([IO.Directory]::Exists((Join-Path $tree 'empty'))) $true
        Assert-Equal (Test-Path -LiteralPath (Join-Path $tree 'src')) $false
        Assert-Equal (Get-LabXferTempCount) 0
    }
    Test-Case 'Transfer: repeated directory copy under Skip and Error moves zero bytes' {
        $tree = Get-LabXferDest 'tree'
        $r = Invoke-LabXfer 'ToVM' $script:XferSrc $tree $true 'Skip'
        Assert-Equal $r.Skipped 6
        Assert-Equal $script:CopyCalls 0
        $r = Invoke-LabXfer 'ToVM' $script:XferSrc $tree $true 'Error'
        Assert-Equal $r.Failed 6
        Assert-Equal $script:CopyCalls 0
        Assert-Equal (Test-Path -LiteralPath (Join-Path $tree 'src')) $false
    }
    Test-Case 'Transfer: repeated directory copy under Overwrite replaces in place, no nesting' {
        $tree = Get-LabXferDest 'tree'
        [IO.File]::WriteAllText((Join-Path $script:XferSrc 'sub\deeper\c.txt'), 'CHANGED')
        try {
            $r = Invoke-LabXfer 'FromVM' $script:XferSrc $tree $true 'Overwrite'
            Assert-Equal $r.Completed 6
            Assert-Equal (Get-LabXferText (Join-Path $tree 'sub\deeper\c.txt')) 'CHANGED'
            Assert-Equal (Test-Path -LiteralPath (Join-Path $tree 'src')) $false
            Assert-Equal (Get-LabXferTempCount) 0
        } finally { [IO.File]::WriteAllText((Join-Path $script:XferSrc 'sub\deeper\c.txt'), 'charlie') }
    }
    Test-Case 'Transfer: nested Error conflict leaves the colliding file untouched' {
        $tree = Get-LabXferDest 'nested'
        [void][IO.Directory]::CreateDirectory((Join-Path $tree 'sub\deeper'))
        [IO.File]::WriteAllText((Join-Path $tree 'sub\deeper\c.txt'), 'existing')
        $r = Invoke-LabXfer 'ToVM' $script:XferSrc $tree $true 'Error'
        Assert-Equal $r.Completed 5
        Assert-Equal $r.Failed 1
        Assert-Equal (Get-LabXferText (Join-Path $tree 'sub\deeper\c.txt')) 'existing'
        Assert-Equal (Get-LabXferTempCount) 0
    }
    Test-Case 'Transfer: directory dry run copies and creates nothing' {
        $tree = Get-LabXferDest 'drytree'
        $r = Invoke-LabXfer 'ToVM' $script:XferSrc $tree $true 'Error' -DryRun $true
        Assert-Equal $r.Completed 6
        Assert-Equal $script:CopyCalls 0
        Assert-Equal (Test-Path -LiteralPath $tree) $false
    }
    Test-Case 'Transfer: one unverified file fails alone; empty source dirs are still created' {
        $tree = Get-LabXferDest 'partial'
        $r = Invoke-LabXfer 'ToVM' $script:XferSrc $tree $true 'Error' -Mode 'CorruptA'
        Assert-Equal $r.Completed 5
        Assert-Equal $r.Failed 1
        Assert-Equal (Test-Path -LiteralPath (Join-Path $tree 'a.txt')) $false
        Assert-Equal ([IO.Directory]::Exists((Join-Path $tree 'empty'))) $true
        Assert-Equal (Get-LabXferTempCount) 0
    }
    Test-Case 'Transfer: no file verifying (nested remote copy) creates no destination directories' {
        $tree = Get-LabXferDest 'nestedcopy'
        $r = Invoke-LabXfer 'ToVM' $script:XferSrc $tree $true 'Error' -Mode 'Nest'
        Assert-Equal $r.Completed 0
        # 6 files plus the root and its 3 planned directories (sub, sub\deeper, empty).
        Assert-Equal $r.Failed 10
        Assert-Equal $r.Errors.Count 10
        Assert-Equal (Test-Path -LiteralPath $tree) $false
        Assert-Equal (Get-LabXferTempCount) 0
        if (-not (($r.Errors -join "`n") -match 'directory transfer abandoned')) { throw 'Missing the shared abandon message.' }
    }
    Test-Case 'Transfer: no file verifying into an existing destination leaves it unchanged' {
        $tree = Get-LabXferDest 'existingroot'
        [void][IO.Directory]::CreateDirectory($tree)
        $r = Invoke-LabXfer 'ToVM' $script:XferSrc $tree $true 'Error' -Mode 'Nest'
        Assert-Equal $r.Completed 0
        Assert-Equal @(Get-ChildItem -LiteralPath $tree -Force).Count 0
        Assert-Equal (Get-LabXferTempCount) 0
    }
    Test-Case 'Transfer: a failing tree copy finalizes nothing' {
        $tree = Get-LabXferDest 'failtree'
        $r = Invoke-LabXfer 'ToVM' $script:XferSrc $tree $true 'Error' -Mode 'Throw'
        Assert-Equal $r.Failed 6
        Assert-Equal $r.Completed 0
        Assert-Equal (Test-Path -LiteralPath $tree) $false
    }
    Test-Case 'Transfer: a junction in the source is rejected, not followed' {
        $junctionSrc = Join-Path $script:XferBase 'jsrc'
        [void][IO.Directory]::CreateDirectory($junctionSrc)
        [IO.File]::WriteAllText((Join-Path $junctionSrc 'x.txt'), 'x')
        $link = Join-Path $junctionSrc 'loop'
        $null = cmd /c mklink /J "$link" "$junctionSrc"
        try {
            if (-not [IO.Directory]::Exists($link)) { throw 'Could not create the test junction.' }
            $tree = Get-LabXferDest 'withjunction'
            $r = Invoke-LabXfer 'ToVM' $junctionSrc $tree $true 'Error'
            Assert-Equal $r.Completed 1
            Assert-Equal $r.Failed 1
            if (-not (($r.Errors -join "`n") -match 'reparse point')) { throw 'The junction was not reported as a reparse point.' }
            Assert-Equal (Test-Path -LiteralPath (Join-Path $tree 'loop')) $false
            Assert-Equal (Get-LabXferTempCount) 0
            $r = Invoke-LabXfer 'ToVM' $link (Get-LabXferDest 'jroot') $true 'Error'
            Assert-Equal $r.Failed 1
            Assert-Equal $script:CopyCalls 0
        } finally { $null = cmd /c rmdir "$link" }
    }
} finally {
    Get-ChildItem -LiteralPath $script:XferBase -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:XferBase -Recurse -Force
}

# --- SFTP engine (Copy-LabTransferItemSftp) against a fake guest ---
# Safety: the real Invoke-LabSftpCommand and Invoke-LabSshCommand are never loaded into this script;
# only the in-memory stand-ins below exist, and ssh.exe/sftp.exe tripwires throw if anything ever
# tries to launch either tool. No SSH connection, prompt or known_hosts access can happen here.
# The fake "guest" is a local temp directory: guest path /a/b maps to <guest root>\a\b.
foreach ($name in @('ConvertFrom-LabSftpListing', 'Copy-LabTransferItemSftp')) {
    $matches = @($definitions | Where-Object { $_.Name -ceq $name })
    if ($matches.Count -ne 1) { throw "Expected one definition of $name." }
    . ([scriptblock]::Create($matches[0].Extent.Text))
}
function ssh.exe { throw 'TRIPWIRE: a test attempted to launch the real ssh.exe.' }
function sftp.exe { throw 'TRIPWIRE: a test attempted to launch the real sftp.exe.' }
function ssh-keygen.exe { throw 'TRIPWIRE: a test attempted to launch the real ssh-keygen.exe.' }
$script:SftpBase = Join-Path ([IO.Path]::GetTempPath()) ('labsftp-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:GuestRoot = Join-Path $script:SftpBase 'guest'
$script:HostRoot = Join-Path $script:SftpBase 'host'
$script:FakeLinks = @{}
$script:SftpBatches = [Collections.Generic.List[string[]]]::new()
$script:SshCommands = [Collections.Generic.List[string]]::new()
$script:SftpFault = $null
$script:SftpCallIndex = 0
$script:DropAtCall = 0
# Guest-side modes set by the fake sftp's chmod, keyed by guest path.
$script:FakeModes = @{}
# Host-side PrivateFiles: a recording stand-in, so no real icacls runs; AclFailPath makes one path fail.
$script:AclCalls = [Collections.Generic.List[string]]::new()
$script:AclFailPath = $null
function Set-LabTransferPrivateAcl {
    param($Session, [string]$Path, [bool]$IsDirectory)
    if ($null -ne $Session) { throw 'An SFTP download must restrict host-side permissions without a session.' }
    $script:AclCalls.Add("$Path|$IsDirectory")
    if ($script:AclFailPath -and $Path -eq $script:AclFailPath) { throw "icacls could not restrict '$Path' (exit 5): Access is denied." }
}
function ConvertTo-FakeGuestPath { param([string]$Path) Join-Path $script:GuestRoot ($Path.TrimStart('/').Replace('/', '\')) }
function Copy-FakeTree {
    param([string]$From, [string]$To)
    [void][IO.Directory]::CreateDirectory($To)
    foreach ($entry in ([IO.DirectoryInfo]::new($From)).GetFileSystemInfos()) {
        $target = Join-Path $To $entry.Name
        if ($entry -is [IO.DirectoryInfo]) { Copy-FakeTree $entry.FullName $target } else { [IO.File]::Copy($entry.FullName, $target) }
    }
}
function Get-FakeLsLine {
    param([string]$Mode, [long]$Size, [string]$Name)
    # IsoListing: a server whose long names use a date shape the engine's pattern does not know.
    if ($script:SftpFault -eq 'IsoListing') { return ('{0}rw-r--r-- 1 labuser labuser {1} 2026-10-19 12:00 {2}' -f $Mode, $Size, $Name) }
    return ('{0}rw-r--r--    1 labuser  labuser  {1,8} Oct 19 12:00 {2}' -f $Mode, $Size, $Name)
}
function Invoke-LabSftpCommand {
    param([string]$HostNameOrAddress, [int]$Port, [string]$UserName, $IdentityFilePath, [string]$BatchFilePath, [string]$AuthMode)
    $script:SftpCallIndex++
    $lines = @([IO.File]::ReadAllText($BatchFilePath).Split("`n") | Where-Object { $_ })
    $script:SftpBatches.Add([string[]]$lines)
    if ($script:SftpFault -eq 'Connection' -or $script:DropAtCall -eq $script:SftpCallIndex) {
        foreach ($line in $lines) {
            # A dropped download can leave a partial host-side file behind.
            $m = [regex]::Match($line, '^get "[^"]*" "(?<b>[^"]*)"$')
            if ($m.Success) { [IO.File]::WriteAllText($m.Groups['b'].Value, 'partial') }
        }
        return [pscustomobject]@{ ExitCode = 255; Output = [string[]]@('ssh: connect to host guest.invalid port 22: Connection refused', 'Connection closed') }
    }
    $out = [Collections.Generic.List[string]]::new()
    $exit = 0
    foreach ($line in $lines) {
        $out.Add("sftp> $line")
        $m = [regex]::Match($line, '^(?<ign>-)?(?<cmd>\w+)(?<r> -r)?(?: -la)?(?: (?<mode>[0-7]{3}))? "(?<a>[^"]*)"(?: "(?<b>[^"]*)")?$')
        if (-not $m.Success) { throw "fake sftp: unparsed batch line [$line]" }
        $a = $m.Groups['a'].Value
        $b = $m.Groups['b'].Value
        $recursive = $m.Groups['r'].Success
        $ok = $true
        try {
            switch ($m.Groups['cmd'].Value) {
                'ls' {
                    $p = ConvertTo-FakeGuestPath $a
                    if ([IO.Directory]::Exists($p)) {
                        # A real ls -la of a directory always lists its own '.' and '..' entries.
                        $out.Add((Get-FakeLsLine 'd' 4096 '.'))
                        $out.Add((Get-FakeLsLine 'd' 4096 '..'))
                        foreach ($entry in ([IO.DirectoryInfo]::new($p)).GetFileSystemInfos()) {
                            $full = ($a.TrimEnd('/') + '/' + $entry.Name)
                            $mode = if ($script:FakeLinks.ContainsKey($full)) { 'l' } elseif ($entry -is [IO.DirectoryInfo]) { 'd' } else { '-' }
                            $size = if ($entry -is [IO.FileInfo]) { $entry.Length } else { 4096 }
                            $out.Add((Get-FakeLsLine $mode $size $entry.Name))
                        }
                    } elseif ([IO.File]::Exists($p)) {
                        $out.Add((Get-FakeLsLine '-' ([IO.FileInfo]::new($p)).Length $a))
                    } else { $out.Add("Can't ls: `"$a`" not found"); $ok = $false }
                }
                'put' {
                    $target = ConvertTo-FakeGuestPath $b
                    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($target))) { throw "dest open `"$b`": No such file or directory" }
                    if ($recursive) { Copy-FakeTree $a $target }
                    else {
                        [IO.File]::Copy($a, $target, $true)
                        if ($script:SftpFault -eq 'CorruptPut') { [IO.File]::AppendAllText($target, 'x') }
                        if ($script:SftpFault -eq 'FlipPut') { $bytes = [IO.File]::ReadAllBytes($target); $bytes[0] = $bytes[0] -bxor 1; [IO.File]::WriteAllBytes($target, $bytes) }
                    }
                }
                'get' {
                    $from = ConvertTo-FakeGuestPath $a
                    if ($recursive) { Copy-FakeTree $from $b }
                    else {
                        [IO.File]::Copy($from, $b, $true)
                        if ($script:SftpFault -eq 'CorruptGet') { [IO.File]::AppendAllText($b, 'x') }
                    }
                }
                'rm' { $p = ConvertTo-FakeGuestPath $a; if (-not [IO.File]::Exists($p)) { throw "Couldn't delete file: No such file or directory" }; [IO.File]::Delete($p) }
                'mkdir' {
                    $p = ConvertTo-FakeGuestPath $a
                    if ([IO.Directory]::Exists($p) -or [IO.File]::Exists($p)) { throw "Couldn't create directory: Failure" }
                    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($p))) { throw "Couldn't create directory: No such file or directory" }
                    [void][IO.Directory]::CreateDirectory($p)
                }
                'rmdir' {
                    $p = ConvertTo-FakeGuestPath $a
                    if (-not [IO.Directory]::Exists($p)) { throw "Couldn't remove directory: No such file or directory" }
                    if (@([IO.Directory]::GetFileSystemEntries($p)).Count -gt 0) { throw "Couldn't remove directory: Failure" }
                    [IO.Directory]::Delete($p, $false)
                }
                'rename' {
                    if ($script:SftpFault -eq 'FailRename') { throw "Couldn't rename file: Permission denied" }
                    $from = ConvertTo-FakeGuestPath $a
                    $to = ConvertTo-FakeGuestPath $b
                    if ([IO.Directory]::Exists($from)) { [IO.Directory]::Move($from, $to) } else { [IO.File]::Move($from, $to) }
                }
                'chmod' {
                    $p = ConvertTo-FakeGuestPath $a
                    if (-not ([IO.File]::Exists($p) -or [IO.Directory]::Exists($p))) { throw "remote setstat `"$a`": No such file or directory" }
                    if ($script:SftpFault -eq 'FailChmod') { throw "remote setstat `"$a`": Permission denied" }
                    # A setstat error line on a batch that still exits 0: the engine must not trust the exit code alone.
                    if ($script:SftpFault -eq 'SetstatOutputOnly') { $out.Add("Couldn't setstat on `"$a`": Failure") }
                    else { $script:FakeModes[$a] = $m.Groups['mode'].Value }
                }
                default { throw "fake sftp: unsupported command [$line]" }
            }
        } catch { $out.Add($_.Exception.Message); $ok = $false }
        # A failing batch command stops the batch, as in real sftp -b, unless it is '-'-prefixed.
        if (-not $ok -and -not $m.Groups['ign'].Success) { $exit = 1; break }
    }
    return [pscustomobject]@{ ExitCode = $exit; Output = [string[]]$out.ToArray() }
}
function Invoke-LabSshCommand {
    param([string]$HostNameOrAddress, [int]$Port, [string]$UserName, $IdentityFilePath, [string]$AuthMode, [string]$RemoteCommand)
    $script:SshCommands.Add($RemoteCommand)
    if ($script:SftpFault -eq 'Connection') { return [pscustomobject]@{ ExitCode = 255; Output = [string[]]@('Connection refused') } }
    $probe = [regex]::Match($RemoteCommand, "^if \[ -L '(?<p>[^']*)' \]")
    if ($probe.Success) {
        $guestPath = $probe.Groups['p'].Value
        $p = ConvertTo-FakeGuestPath $guestPath
        $code = if ($script:FakeLinks.ContainsKey($guestPath)) { 13 } elseif ([IO.Directory]::Exists($p)) { 12 } elseif ([IO.File]::Exists($p)) { 11 } else { 10 }
        if ($code -eq 10 -and $RemoteCommand -notmatch 'else exit 10; fi$') {
            # The upload-destination form: the ancestor clauses run in order, then the trailing exit.
            foreach ($clause in [regex]::Matches($RemoteCommand, "; if \[ -d '(?<a>[^']*)' \]; then exit (?<c>\d+); elif \[ -e '[^']*' \] \|\| \[ -L '[^']*' \]; then exit 15; fi")) {
                $ancestor = ConvertTo-FakeGuestPath $clause.Groups['a'].Value
                if ($script:FakeLinks.ContainsKey($clause.Groups['a'].Value)) { return [pscustomobject]@{ ExitCode = 15; Output = [string[]]@() } }
                if ([IO.Directory]::Exists($ancestor)) { return [pscustomobject]@{ ExitCode = [int]$clause.Groups['c'].Value; Output = [string[]]@() } }
                if ([IO.File]::Exists($ancestor)) { return [pscustomobject]@{ ExitCode = 15; Output = [string[]]@() } }
            }
            $code = [int][regex]::Match($RemoteCommand, '; exit (?<n>\d+)$').Groups['n'].Value
        }
        return [pscustomobject]@{ ExitCode = $code; Output = [string[]]@() }
    }
    # The size check is now two statements: 's=$(stat ...)' captures the value, then '[ $s -eq N ]'
    # compares it once a 'case' guard (matched separately below, not re-parsed here) has confirmed $s
    # is pure digits. Matching them separately keeps this fake tolerant of that guard's exact text.
    $size = [regex]::Match($RemoteCommand, "stat -c %s '(?<p>[^']*)' 2>/dev/null\)")
    $sizeEq = [regex]::Match($RemoteCommand, '\[ \$s -eq (?<n>\d+) \]')
    $hash = [regex]::Match($RemoteCommand, "h=\`$\(sha256sum '(?<p>[^']*)' 2>/dev/null\).*\[ \`$\{h%% \*\} = (?<h>[0-9a-f]{64}) \]")
    if (-not $size.Success -and -not $hash.Success) { throw "fake ssh: unparsed remote command [$RemoteCommand]" }
    if ($size.Success) {
        if (-not $sizeEq.Success) { throw "fake ssh: size check command missing its comparison [$RemoteCommand]" }
        $p = ConvertTo-FakeGuestPath $size.Groups['p'].Value
        # StatCheckFails: the guest-side stat itself could not produce a usable size (e.g. permission
        # denied) -- exit 23, distinct from exit 20's genuine, confirmed size disagreement.
        if ($script:SftpFault -eq 'StatCheckFails') { return [pscustomobject]@{ ExitCode = 23; Output = [string[]]@() } }
        if (-not [IO.File]::Exists($p) -or ([IO.FileInfo]::new($p)).Length -ne [long]$sizeEq.Groups['n'].Value) { return [pscustomobject]@{ ExitCode = 20; Output = [string[]]@() } }
    }
    if ($hash.Success) {
        if ($script:SftpFault -eq 'NoSha256sum') { return [pscustomobject]@{ ExitCode = 21; Output = [string[]]@() } }
        $actual = (Get-FileHash -LiteralPath (ConvertTo-FakeGuestPath $hash.Groups['p'].Value) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $hash.Groups['h'].Value) { return [pscustomobject]@{ ExitCode = 22; Output = [string[]]@() } }
    }
    return [pscustomobject]@{ ExitCode = 0; Output = [string[]]@() }
}
function Invoke-LabSftpXfer {
    param([string]$Direction, [string]$Source, [string]$Destination, [bool]$Recurse = $false, [string]$OnConflict = 'Error',
        [bool]$VerifyHash = $true, [bool]$DryRun = $false, [string]$AuthMode = 'KeyAgent', [string]$Fault = $null, [int]$DropAtCall = 0,
        [string]$PermissionProfile = 'Default')
    $script:SftpBatches.Clear()
    $script:SshCommands.Clear()
    $script:AclCalls.Clear()
    $script:FakeModes.Clear()
    $script:SftpFault = $Fault
    $script:SftpCallIndex = 0
    $script:DropAtCall = $DropAtCall
    $identity = if ($AuthMode -eq 'KeyAgent') { 'C:\keys\id_test' } else { '' }
    try { return Copy-LabTransferItemSftp 'guest.invalid' 22 'labuser' $identity $AuthMode $Direction $Source $Destination $Recurse $OnConflict $VerifyHash $DryRun $PermissionProfile 6>$null 3>$null }
    finally { $script:SftpFault = $null; $script:DropAtCall = 0 }
}
function Get-SftpBatchText { return (@($script:SftpBatches | ForEach-Object { $_ -join "`n" }) -join "`n---`n") }
function Get-SftpPayloadLineCount { return @($script:SftpBatches | ForEach-Object { $_ } | Where-Object { $_ -match '^-?(put|get|rename|rm|mkdir|rmdir|chmod) ' }).Count }
function Get-FakeTempCount { return @(Get-ChildItem -LiteralPath $script:SftpBase -Recurse -Force | Where-Object { $_.Name -like '*.labxfer-*' }).Count }
function Reset-FakeGuest {
    foreach ($dir in @($script:GuestRoot, $script:HostRoot)) {
        if ([IO.Directory]::Exists($dir)) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $dir -Recurse -Force }
    }
    $script:FakeLinks.Clear()
    [void][IO.Directory]::CreateDirectory((Join-Path $script:GuestRoot 'home\dev'))
    [void][IO.Directory]::CreateDirectory((Join-Path $script:HostRoot 'src\tree\empty'))
    [IO.File]::WriteAllText((Join-Path $script:HostRoot 'src\a.txt'), 'alpha')
    [IO.File]::WriteAllText((Join-Path $script:HostRoot 'src\tree\.hidden'), 'dot')
    [IO.File]::WriteAllText((Join-Path $script:HostRoot 'src\tree\b.txt'), 'bravo!')
    [IO.File]::WriteAllText((Join-Path $script:GuestRoot 'home\dev\g.txt'), 'guest-file')
    [void][IO.Directory]::CreateDirectory((Join-Path $script:GuestRoot 'home\dev\gtree\empty'))
    [IO.File]::WriteAllText((Join-Path $script:GuestRoot 'home\dev\gtree\.profile'), 'p')
    [IO.File]::WriteAllText((Join-Path $script:GuestRoot 'home\dev\gtree\c.txt'), 'charlie')
}
$script:HostA = Join-Path $script:HostRoot 'src\a.txt'
$script:HostTree = Join-Path $script:HostRoot 'src\tree'

Test-Case 'SFTP listing: a file listed by full path is found with mode and size' {
    $r = ConvertFrom-LabSftpListing @('sftp> ls -la "/home/dev/a.txt"', (Get-FakeLsLine '-' 5 '/home/dev/a.txt')) 0 '/home/dev/a.txt'
    Assert-Equal $r.Exists $true; Assert-Equal $r.Mode '-'; Assert-Equal $r.Size ([long]5)
}
Test-Case 'SFTP listing: a parent listing matches the exact leaf name only' {
    $lines = @((Get-FakeLsLine '-' 9 'my foo'), (Get-FakeLsLine 'd' 4096 'foo'))
    $r = ConvertFrom-LabSftpListing $lines 0 '/home/dev/foo'
    Assert-Equal $r.Mode 'd'
    Assert-Equal (ConvertFrom-LabSftpListing $lines 0 '/home/dev/oo').Exists $false
}
Test-Case 'SFTP listing: a symlink line (with or without its target) reports mode l' {
    Assert-Equal (ConvertFrom-LabSftpListing @('lrwxrwxrwx    1 dev dev 11 Jan 02  2025 key -> /etc/x') 0 '/home/dev/key').Mode 'l'
    Assert-Equal (ConvertFrom-LabSftpListing @((Get-FakeLsLine 'l' 11 'key')) 0 '/home/dev/key').Mode 'l'
}
Test-Case 'SFTP listing: not found is a missing item; any other failure is an error' {
    $missing = ConvertFrom-LabSftpListing @("Can't ls: `"/nope`" not found") 1 '/nope/x'
    Assert-Equal $missing.Exists $false; Assert-Equal $missing.Error $null
    $denied = ConvertFrom-LabSftpListing @("Couldn't read directory: Permission denied") 1 '/root/x'
    if (-not $denied.Error) { throw 'A permission failure was not reported as an error.' }
    Assert-Equal (ConvertFrom-LabSftpListing @("Can't ls: `"/nope`" not found") 1 '/nope/x' -ParentListing).ListingNotFound $true
}
Test-Case 'SFTP listing (parent): a recognized listing reports absent, or the entry it finds' {
    $lines = @((Get-FakeLsLine 'd' 4096 '.'), (Get-FakeLsLine 'd' 4096 '..'), (Get-FakeLsLine '-' 9 'other.txt'))
    $absent = ConvertFrom-LabSftpListing $lines 0 '/home/dev/a.txt' -ParentListing
    Assert-Equal $absent.Exists $false; Assert-Equal $absent.Error $null; Assert-Equal $absent.ListingNotFound $false
    $present = ConvertFrom-LabSftpListing ($lines + @((Get-FakeLsLine '-' 5 'a.txt'))) 0 '/home/dev/a.txt' -ParentListing
    Assert-Equal $present.Exists $true; Assert-Equal $present.Mode '-'; Assert-Equal $present.Size ([long]5)
}
Test-Case 'SFTP listing (parent): a missing or corrupted "." entry is an error, never absent' {
    $noSelf = ConvertFrom-LabSftpListing @((Get-FakeLsLine 'd' 4096 '..'), (Get-FakeLsLine '-' 9 'other.txt')) 0 '/home/dev/a.txt' -ParentListing
    Assert-Equal $noSelf.Exists $false
    if (-not $noSelf.Error) { throw 'A listing without a "." entry was reported as absent.' }
    # An unexpected date shape (ISO) makes every line, "." included, unparseable.
    $iso = @('drwxr-xr-x 2 dev dev 4096 2026-10-19 12:00 .', 'drwxr-xr-x 3 dev dev 4096 2026-10-19 12:00 ..')
    if (-not (ConvertFrom-LabSftpListing $iso 0 '/home/dev/a.txt' -ParentListing).Error) { throw 'An unrecognized listing format was reported as absent.' }
    if (-not (ConvertFrom-LabSftpListing @() 0 '/home/dev/a.txt' -ParentListing).Error) { throw 'An empty listing was reported as absent.' }
}
Test-Case 'SFTP listing (parent): an unparseable line ending in the target name is an error, never absent' {
    $self = @((Get-FakeLsLine 'd' 4096 '.'), (Get-FakeLsLine 'd' 4096 '..'))
    # A device node's "major, minor" size field does not match the size pattern.
    $device = ConvertFrom-LabSftpListing ($self + @('crw-rw-rw-    1 root  root    1,   3 Oct 19 12:00 a.txt')) 0 '/home/dev/a.txt' -ParentListing
    Assert-Equal $device.Exists $false
    if (-not $device.Error) { throw 'An unparseable entry named like the target was reported as absent.' }
    $isoLine = ConvertFrom-LabSftpListing ($self + @('-rw-r--r-- 1 dev dev 5 2026-10-19 12:00 a.txt')) 0 '/home/dev/a.txt' -ParentListing
    if (-not $isoLine.Error) { throw 'An unparseable entry named like the target was reported as absent.' }
    $link = ConvertFrom-LabSftpListing ($self + @('lrwxrwxrwx 1 dev dev 5 2026-10-19 12:00 a.txt -> /etc/x')) 0 '/home/dev/a.txt' -ParentListing
    if (-not $link.Error) { throw 'An unparseable link named like the target was reported as absent.' }
    # An unparseable line for a different name does not block an absent result.
    $other = ConvertFrom-LabSftpListing ($self + @('crw-rw-rw-    1 root  root    1,   3 Oct 19 12:00 null')) 0 '/home/dev/a.txt' -ParentListing
    Assert-Equal $other.Exists $false; Assert-Equal $other.Error $null
}
Test-Case 'SFTP listing (parent): a parent that is a regular file is an error' {
    $r = ConvertFrom-LabSftpListing @((Get-FakeLsLine '-' 10 '/home/dev/g.txt')) 0 '/home/dev/g.txt/a.txt' -ParentListing
    if (-not ($r.Error -match 'not a directory')) { throw "Unexpected result: $($r.Error)" }
}
try {
    Test-Case 'SFTP: an unknown auth mode throws before anything else' {
        Reset-FakeGuest
        Assert-Throws { Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -AuthMode 'Telepathy' } 'Unknown SSH auth mode'
        Assert-Equal $script:SftpBatches.Count 0
    }
    Test-Case 'SFTP: unsupported paths fail before any connection' {
        Reset-FakeGuest
        foreach ($case in @(@('ToVM', $script:HostA, 'home/dev/a.txt'), @('ToVM', $script:HostA, '/home/dev/a*.txt'),
                @('ToVM', $script:HostA, '/home/dev/../a.txt'), @('ToVM', $script:HostA, '/'), @('ToVM', $script:HostA, '/home/dev/a\b'),
                @('ToVM', (Join-Path $script:HostRoot 'src\[x].txt'), '/home/dev/x'), @('FromVM', '/home/dev/g.txt', 'relative\g.txt'))) {
            $r = Invoke-LabSftpXfer $case[0] $case[1] $case[2]
            Assert-Equal $r.Failed 1
            Assert-Equal ($script:SftpBatches.Count + $script:SshCommands.Count) 0
        }
    }
    foreach ($mode in @('KeyAgent', 'InteractivePassword')) {
        Test-Case "SFTP ($mode): single-file upload checks, then finalizes in a separate batch" {
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -AuthMode $mode
            Assert-Equal $r.Completed 1; Assert-Equal $r.Failed 0; Assert-Equal $r.BytesTransferred ([long]5)
            Assert-Equal (Get-Content -LiteralPath (ConvertTo-FakeGuestPath '/home/dev/a.txt') -Raw) 'alpha'
            Assert-Equal (Get-FakeTempCount) 0
            $put = @($script:SftpBatches | Where-Object { ($_ -join "`n") -match '^put ' })
            Assert-Equal $put.Count 1
            if (($put[0] -join "`n") -match 'rename ') { throw 'rename ran in the same batch as put.' }
            Assert-Equal (@($script:SftpBatches[$script:SftpBatches.Count - 1]) -join "`n").StartsWith('rename ') $true
            if ($mode -eq 'KeyAgent') {
                Assert-Equal ($script:SshCommands -join "`n").Contains('if [ -L') $false
                Assert-Equal @($put[0]).Count 2
            } else {
                Assert-Equal ($script:SshCommands[0]).StartsWith('if [ -L ') $true
                Assert-Equal ((Get-SftpBatchText) -match 'ls -la') $false
                if (-not ($script:SshCommands[1] -match 'stat -c %s' -and $script:SshCommands[1] -match 'sha256sum')) { throw 'Size and hash were not checked in one call.' }
            }
        }
        Test-Case "SFTP ($mode): a size mismatch on upload never reaches the destination" {
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -AuthMode $mode -Fault 'CorruptPut'
            Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0
            if (-not (($r.Errors -join ' ') -match 'size mismatch')) { throw "Unexpected error: $($r.Errors)" }
            Assert-Equal ((Get-SftpBatchText) -match 'rename ') $false
            Assert-Equal ([IO.File]::Exists((ConvertTo-FakeGuestPath '/home/dev/a.txt'))) $false
            Assert-Equal (Get-FakeTempCount) 0
        }
        Test-Case "SFTP ($mode): a hash mismatch on Overwrite leaves the original untouched (no rm, no rename)" {
            Reset-FakeGuest
            [IO.File]::WriteAllText((ConvertTo-FakeGuestPath '/home/dev/a.txt'), 'original')
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -OnConflict 'Overwrite' -AuthMode $mode -Fault 'FlipPut'
            Assert-Equal $r.Failed 1
            if (-not (($r.Errors -join ' ') -match 'SHA-256 mismatch')) { throw "Unexpected error: $($r.Errors)" }
            Assert-Equal ((Get-SftpBatchText) -match '(?m)^(rm "/home/dev/a.txt"|rename )') $false
            Assert-Equal (Get-Content -LiteralPath (ConvertTo-FakeGuestPath '/home/dev/a.txt') -Raw) 'original'
            Assert-Equal (Get-FakeTempCount) 0
        }
        Test-Case "SFTP ($mode): Overwrite replaces the file via rm then rename" {
            Reset-FakeGuest
            [IO.File]::WriteAllText((ConvertTo-FakeGuestPath '/home/dev/a.txt'), 'original')
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -OnConflict 'Overwrite' -AuthMode $mode
            Assert-Equal $r.Completed 1
            Assert-Equal (Get-Content -LiteralPath (ConvertTo-FakeGuestPath '/home/dev/a.txt') -Raw) 'alpha'
            $final = @($script:SftpBatches[$script:SftpBatches.Count - 1])
            Assert-Equal $final.Count 2
            Assert-Equal $final[0] 'rm "/home/dev/a.txt"'
        }
        Test-Case "SFTP ($mode): an existing destination under Error or Skip moves nothing" {
            Reset-FakeGuest
            [IO.File]::WriteAllText((ConvertTo-FakeGuestPath '/home/dev/a.txt'), 'original')
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -AuthMode $mode
            Assert-Equal $r.Failed 1; Assert-Equal (Get-SftpPayloadLineCount) 0
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -OnConflict 'Skip' -AuthMode $mode
            Assert-Equal $r.Skipped 1; Assert-Equal $r.Failed 0; Assert-Equal (Get-SftpPayloadLineCount) 0
            Assert-Equal (Get-Content -LiteralPath (ConvertTo-FakeGuestPath '/home/dev/a.txt') -Raw) 'original'
        }
        Test-Case "SFTP ($mode): a dry run decides like a real run but moves nothing" {
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -DryRun $true -AuthMode $mode
            Assert-Equal $r.Completed 1; Assert-Equal $r.BytesTransferred ([long]0); Assert-Equal (Get-SftpPayloadLineCount) 0
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/gtree' (Join-Path $script:HostRoot 'dl') -Recurse $true -DryRun $true -AuthMode $mode
            Assert-Equal $r.Completed 1; Assert-Equal (Get-SftpPayloadLineCount) 0
            Assert-Equal ([IO.Directory]::Exists((Join-Path $script:HostRoot 'dl'))) $false
            [IO.File]::WriteAllText((ConvertTo-FakeGuestPath '/home/dev/a.txt'), 'original')
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -DryRun $true -AuthMode $mode
            Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0
        }
        Test-Case "SFTP ($mode): a symlink destination or source is refused before any payload" {
            Reset-FakeGuest
            [IO.File]::WriteAllText((ConvertTo-FakeGuestPath '/home/dev/key'), 'target')
            $script:FakeLinks['/home/dev/key'] = $true
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/key' -OnConflict 'Overwrite' -AuthMode $mode
            Assert-Equal $r.Failed 1; Assert-Equal (Get-SftpPayloadLineCount) 0
            if (-not (($r.Errors -join ' ') -match 'symbolic link')) { throw "Unexpected error: $($r.Errors)" }
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/key' (Join-Path $script:HostRoot 'key') -AuthMode $mode
            Assert-Equal $r.Failed 1; Assert-Equal (Get-SftpPayloadLineCount) 0
        }
        Test-Case "SFTP ($mode): a file onto a directory is a type mismatch" {
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/gtree' -OnConflict 'Overwrite' -AuthMode $mode
            Assert-Equal $r.Failed 1; Assert-Equal (Get-SftpPayloadLineCount) 0
            if (-not (($r.Errors -join ' ') -match 'different type')) { throw "Unexpected error: $($r.Errors)" }
        }
        Test-Case "SFTP ($mode): single-file download verifies, then moves into place; Overwrite replaces" {
            Reset-FakeGuest
            $target = Join-Path $script:HostRoot 'g.txt'
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' $target -AuthMode $mode
            Assert-Equal $r.Completed 1; Assert-Equal $r.BytesTransferred ([long]10)
            Assert-Equal (Get-Content -LiteralPath $target -Raw) 'guest-file'
            [IO.File]::WriteAllText((ConvertTo-FakeGuestPath '/home/dev/g.txt'), 'guest-file-2')
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' $target -OnConflict 'Overwrite' -AuthMode $mode
            Assert-Equal $r.Completed 1
            Assert-Equal (Get-Content -LiteralPath $target -Raw) 'guest-file-2'
            Assert-Equal (Get-FakeTempCount) 0
        }
        Test-Case "SFTP ($mode): a corrupted download is not moved into place and its temp is removed" {
            Reset-FakeGuest
            $target = Join-Path $script:HostRoot 'g.txt'
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' $target -AuthMode $mode -Fault 'CorruptGet'
            Assert-Equal $r.Failed 1
            Assert-Equal ([IO.File]::Exists($target)) $false
            Assert-Equal (Get-FakeTempCount) 0
        }
        Test-Case "SFTP ($mode): a fresh directory upload is one put -r and one rename in one batch" {
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostTree '/home/dev/tree' -Recurse $true -AuthMode $mode
            Assert-Equal $r.Completed 1; Assert-Equal $r.Failed 0; Assert-Equal $r.BytesTransferred ([long]9)
            Assert-Equal ([IO.Directory]::Exists((ConvertTo-FakeGuestPath '/home/dev/tree/empty'))) $true
            Assert-Equal (Get-Content -LiteralPath (ConvertTo-FakeGuestPath '/home/dev/tree/.hidden') -Raw) 'dot'
            $last = @($script:SftpBatches[$script:SftpBatches.Count - 1])
            Assert-Equal $last.Count 2
            Assert-Equal $last[0].StartsWith('put -r ') $true
            Assert-Equal $last[1].StartsWith('rename ') $true
            Assert-Equal (Get-FakeTempCount) 0
        }
        Test-Case "SFTP ($mode): a directory into an existing destination fails with the documented limitation" {
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostTree '/home/dev/gtree' -Recurse $true -OnConflict 'Skip' -AuthMode $mode
            Assert-Equal $r.Failed 1; Assert-Equal $r.Skipped 0; Assert-Equal (Get-SftpPayloadLineCount) 0
            if (-not (($r.Errors -join ' ') -match 'not supported in this version')) { throw "Unexpected error: $($r.Errors)" }
            [void][IO.Directory]::CreateDirectory((Join-Path $script:HostRoot 'existing'))
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/gtree' (Join-Path $script:HostRoot 'existing') -Recurse $true -AuthMode $mode
            Assert-Equal $r.Failed 1; Assert-Equal (Get-SftpPayloadLineCount) 0
        }
        Test-Case "SFTP ($mode): a fresh directory download lands whole, with dotfiles and empty dirs" {
            Reset-FakeGuest
            $target = Join-Path $script:HostRoot 'dl'
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/gtree' $target -Recurse $true -AuthMode $mode
            Assert-Equal $r.Completed 1; Assert-Equal $r.BytesTransferred ([long]8)
            Assert-Equal ([IO.Directory]::Exists((Join-Path $target 'empty'))) $true
            Assert-Equal (Get-Content -LiteralPath (Join-Path $target '.profile') -Raw) 'p'
            Assert-Equal (Get-FakeTempCount) 0
        }
        Test-Case "SFTP ($mode): an upload creates a missing parent and grandparent, inside the payload batch" {
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/n1/n2/a.txt' -AuthMode $mode
            Assert-Equal $r.Completed 1; Assert-Equal $r.Failed 0
            Assert-Equal (Get-Content -LiteralPath (ConvertTo-FakeGuestPath '/home/dev/n1/n2/a.txt') -Raw) 'alpha'
            $put = @($script:SftpBatches | Where-Object { ($_ -join "`n") -match '(?m)^put ' })
            Assert-Equal $put.Count 1
            Assert-Equal $put[0][0] 'mkdir "/home/dev/n1"'
            Assert-Equal $put[0][1] 'mkdir "/home/dev/n1/n2"'
            Assert-Equal $put[0][2].StartsWith('put ') $true
            if ($mode -eq 'InteractivePassword') {
                # The ancestor walk rides in the probe's own ssh call: probe + size/hash check, nothing more.
                Assert-Equal $script:SshCommands.Count 2
                Assert-Equal $script:SftpBatches.Count 2
            }
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostTree '/home/dev/r1/r2/tree' -Recurse $true -AuthMode $mode
            Assert-Equal $r.Completed 1; Assert-Equal $r.Failed 0
            Assert-Equal (Get-Content -LiteralPath (ConvertTo-FakeGuestPath '/home/dev/r1/r2/tree/b.txt') -Raw) 'bravo!'
            $last = @($script:SftpBatches[$script:SftpBatches.Count - 1])
            Assert-Equal ($last -join '|') ('mkdir "/home/dev/r1"|mkdir "/home/dev/r1/r2"|' + ($last[2..3] -join '|'))
            Assert-Equal $last[2].StartsWith('put -r ') $true
            Assert-Equal (Get-FakeTempCount) 0
        }
        Test-Case "SFTP ($mode): a download creates a missing host-side parent and grandparent" {
            Reset-FakeGuest
            $target = Join-Path $script:HostRoot 'm1\m2\g.txt'
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' $target -AuthMode $mode
            Assert-Equal $r.Completed 1; Assert-Equal $r.Failed 0
            Assert-Equal (Get-Content -LiteralPath $target -Raw) 'guest-file'
            $tree = Join-Path $script:HostRoot 'd1\d2\gtree'
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/gtree' $tree -Recurse $true -AuthMode $mode
            Assert-Equal $r.Completed 1
            Assert-Equal (Get-Content -LiteralPath (Join-Path $tree 'c.txt') -Raw) 'charlie'
            Assert-Equal (Get-FakeTempCount) 0
        }
        Test-Case "SFTP ($mode): a dry run into missing parents agrees with the real run and creates nothing" {
            foreach ($case in @(@('ToVM', $script:HostA, '/home/dev/n1/n2/a.txt', $false), @('ToVM', $script:HostTree, '/home/dev/n1/n2/tree', $true),
                    @('FromVM', '/home/dev/g.txt', (Join-Path $script:HostRoot 'm1\m2\g.txt'), $false),
                    @('FromVM', '/home/dev/gtree', (Join-Path $script:HostRoot 'm1\m2\gtree'), $true))) {
                Reset-FakeGuest
                $dry = Invoke-LabSftpXfer $case[0] $case[1] $case[2] -Recurse $case[3] -DryRun $true -AuthMode $mode
                Assert-Equal $dry.Completed 1; Assert-Equal $dry.Failed 0; Assert-Equal (Get-SftpPayloadLineCount) 0
                Assert-Equal ([IO.Directory]::Exists((ConvertTo-FakeGuestPath '/home/dev/n1'))) $false
                Assert-Equal ([IO.Directory]::Exists((Join-Path $script:HostRoot 'm1'))) $false
                $real = Invoke-LabSftpXfer $case[0] $case[1] $case[2] -Recurse $case[3] -AuthMode $mode
                Assert-Equal $real.Completed $dry.Completed; Assert-Equal $real.Failed $dry.Failed
            }
        }
        Test-Case "SFTP ($mode): a parent that is a file fails before any payload, in a dry run too" {
            Reset-FakeGuest
            foreach ($dry in @($true, $false)) {
                $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/g.txt/x/a.txt' -DryRun $dry -AuthMode $mode
                Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0; Assert-Equal (Get-SftpPayloadLineCount) 0
                if (-not (($r.Errors -join ' ') -match 'not a directory')) { throw "Unexpected error: $($r.Errors)" }
                $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' (Join-Path $script:HostRoot 'src\a.txt\x\g.txt') -DryRun $dry -AuthMode $mode
                Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0; Assert-Equal (Get-SftpPayloadLineCount) 0
                if (-not (($r.Errors -join ' ') -match 'not a directory')) { throw "Unexpected error: $($r.Errors)" }
            }
        }
        Test-Case "SFTP ($mode): a failed upload removes the parents it created, never a pre-existing empty one" {
            Reset-FakeGuest
            [void][IO.Directory]::CreateDirectory((ConvertTo-FakeGuestPath '/home/dev/empty0'))
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/empty0/n1/n2/a.txt' -AuthMode $mode -Fault 'CorruptPut'
            Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0
            Assert-Equal ([IO.Directory]::Exists((ConvertTo-FakeGuestPath '/home/dev/empty0/n1'))) $false
            Assert-Equal ([IO.Directory]::Exists((ConvertTo-FakeGuestPath '/home/dev/empty0'))) $true
            Assert-Equal (Get-FakeTempCount) 0
            $cleanup = @($script:SftpBatches[$script:SftpBatches.Count - 1])
            Assert-Equal ($cleanup -join '|') '-rmdir "/home/dev/empty0/n1/n2"|-rmdir "/home/dev/empty0/n1"'
        }
        Test-Case "SFTP ($mode): a failed download removes the host parents it created, never a pre-existing empty one" {
            Reset-FakeGuest
            $existing = Join-Path $script:HostRoot 'e0'
            [void][IO.Directory]::CreateDirectory($existing)
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' (Join-Path $existing 'n1\n2\g.txt') -AuthMode $mode -Fault 'CorruptGet'
            Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0
            Assert-Equal ([IO.Directory]::Exists((Join-Path $existing 'n1'))) $false
            Assert-Equal ([IO.Directory]::Exists($existing)) $true
            Assert-Equal (Get-FakeTempCount) 0
        }
        Test-Case "SFTP ($mode): PrivateFiles on a single-file upload sets mode 600 after the rename, in the finalize batch" {
            Reset-FakeGuest
            [IO.File]::WriteAllText((ConvertTo-FakeGuestPath '/home/dev/sibling.txt'), 's')
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/n1/a.txt' -AuthMode $mode -PermissionProfile 'PrivateFiles'
            Assert-Equal $r.Completed 1; Assert-Equal $r.Failed 0; Assert-Equal $r.BytesTransferred ([long]5)
            $put = @($script:SftpBatches | Where-Object { ($_ -join "`n") -match '(?m)^put ' })
            Assert-Equal $put.Count 1
            if (($put[0] -join "`n") -match 'chmod') { throw 'chmod ran in the upload batch, before verification.' }
            Assert-Equal $put[0][0] 'mkdir "/home/dev/n1"'
            $final = @($script:SftpBatches[$script:SftpBatches.Count - 1])
            Assert-Equal $final.Count 2
            Assert-Equal $final[0].StartsWith('rename ') $true
            Assert-Equal $final[1] 'chmod 600 "/home/dev/n1/a.txt"'
            Assert-Equal $script:FakeModes.Count 1
            Assert-Equal $script:FakeModes['/home/dev/n1/a.txt'] '600'
            Assert-Equal $script:AclCalls.Count 0
            Reset-FakeGuest
            [IO.File]::WriteAllText((ConvertTo-FakeGuestPath '/home/dev/a.txt'), 'original')
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -OnConflict 'Overwrite' -AuthMode $mode -PermissionProfile 'PrivateFiles'
            Assert-Equal $r.Completed 1
            $final = @($script:SftpBatches[$script:SftpBatches.Count - 1])
            Assert-Equal ($final -join '|') ('rm "/home/dev/a.txt"|' + $final[1] + '|chmod 600 "/home/dev/a.txt"')
            Assert-Equal $final[1].StartsWith('rename ') $true
        }
        Test-Case "SFTP ($mode): PrivateFiles on a fresh directory upload sets mode 700 on the root only, after the rename" {
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostTree '/home/dev/r1/tree' -Recurse $true -AuthMode $mode -PermissionProfile 'PrivateFiles'
            Assert-Equal $r.Completed 1; Assert-Equal $r.Failed 0
            $last = @($script:SftpBatches[$script:SftpBatches.Count - 1])
            Assert-Equal $last.Count 4
            Assert-Equal $last[0] 'mkdir "/home/dev/r1"'
            Assert-Equal $last[1].StartsWith('put -r ') $true
            Assert-Equal $last[2].StartsWith('rename ') $true
            Assert-Equal $last[3] 'chmod 700 "/home/dev/r1/tree"'
            Assert-Equal ($script:FakeModes.Keys -join ',') '/home/dev/r1/tree'
        }
        Test-Case "SFTP ($mode): a failed chmod after a landed upload is Failed, keeps the file in place, rolls nothing back" {
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/n1/a.txt' -AuthMode $mode -PermissionProfile 'PrivateFiles' -Fault 'FailChmod'
            Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0; Assert-Equal $r.BytesTransferred ([long]0)
            if (-not (($r.Errors -join ' ') -match 'copied successfully but the private-file permission \(mode 600\)')) { throw "Unexpected error: $($r.Errors)" }
            Assert-Equal (Get-Content -LiteralPath (ConvertTo-FakeGuestPath '/home/dev/n1/a.txt') -Raw) 'alpha'
            Assert-Equal (Get-FakeTempCount) 0
            Assert-Equal ((Get-SftpBatchText) -match '(?m)^-?(rm|rmdir) ') $false
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostTree '/home/dev/n1/tree' -Recurse $true -AuthMode $mode -PermissionProfile 'PrivateFiles' -Fault 'FailChmod'
            Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0
            if (-not (($r.Errors -join ' ') -match 'copied successfully but the private-file permission \(mode 700 on the directory\)')) { throw "Unexpected error: $($r.Errors)" }
            Assert-Equal (Get-Content -LiteralPath (ConvertTo-FakeGuestPath '/home/dev/n1/tree/b.txt') -Raw) 'bravo!'
            Assert-Equal ((Get-SftpBatchText) -match '(?m)^-?rmdir ') $false
        }
        Test-Case "SFTP ($mode): PrivateFiles with a failed rename keeps the existing failure handling" {
            Reset-FakeGuest
            [IO.File]::WriteAllText((ConvertTo-FakeGuestPath '/home/dev/a.txt'), 'original')
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -OnConflict 'Overwrite' -AuthMode $mode -PermissionProfile 'PrivateFiles' -Fault 'FailRename'
            Assert-Equal $r.Failed 1
            if (-not (($r.Errors -join ' ') -match 'verified copy was kept')) { throw "Unexpected error: $($r.Errors)" }
            Assert-Equal (Get-FakeTempCount) 1
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -AuthMode $mode -PermissionProfile 'PrivateFiles' -Fault 'FailRename'
            Assert-Equal $r.Failed 1
            if (($r.Errors -join ' ') -match 'copied successfully') { throw "A failed rename was reported as landed: $($r.Errors)" }
            Assert-Equal (Get-FakeTempCount) 0
            Assert-Equal $script:FakeModes.Count 0
        }
        Test-Case "SFTP ($mode): PrivateFiles on a download restricts the host-side file, never with an sftp chmod" {
            Reset-FakeGuest
            $target = Join-Path $script:HostRoot 'g.txt'
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' $target -AuthMode $mode -PermissionProfile 'PrivateFiles'
            Assert-Equal $r.Completed 1; Assert-Equal $r.Failed 0
            Assert-Equal ($script:AclCalls -join ',') "$target|False"
            Assert-Equal ((Get-SftpBatchText) -match 'chmod') $false
            $script:AclFailPath = $target
            try {
                $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' $target -OnConflict 'Overwrite' -AuthMode $mode -PermissionProfile 'PrivateFiles'
            } finally { $script:AclFailPath = $null }
            Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0; Assert-Equal $r.BytesTransferred ([long]0)
            if (-not (($r.Errors -join ' ') -match 'copied successfully but the private-file permission could not be applied')) { throw "Unexpected error: $($r.Errors)" }
            Assert-Equal (Get-Content -LiteralPath $target -Raw) 'guest-file'
            Assert-Equal (Get-FakeTempCount) 0
        }
        Test-Case "SFTP ($mode): PrivateFiles on a directory download restricts every item, deepest first, root last" {
            Reset-FakeGuest
            $target = Join-Path $script:HostRoot 'dl'
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/gtree' $target -Recurse $true -AuthMode $mode -PermissionProfile 'PrivateFiles'
            Assert-Equal $r.Completed 1; Assert-Equal $r.Failed 0
            Assert-Equal $script:AclCalls.Count 4
            Assert-Equal $script:AclCalls[3] "$target|True"
            foreach ($expected in @("$(Join-Path $target 'empty')|True", "$(Join-Path $target '.profile')|False", "$(Join-Path $target 'c.txt')|False")) {
                if (-not $script:AclCalls.Contains($expected)) { throw "Missing ACL call [$expected] in [$($script:AclCalls -join ', ')]." }
            }
            Assert-Equal ((Get-SftpBatchText) -match 'chmod') $false
            Reset-FakeGuest
            $script:AclFailPath = Join-Path $target 'c.txt'
            try {
                $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/gtree' $target -Recurse $true -AuthMode $mode -PermissionProfile 'PrivateFiles'
            } finally { $script:AclFailPath = $null }
            Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0
            if (-not (($r.Errors -join ' ') -match '1 of 4 items could not be restricted')) { throw "Unexpected error: $($r.Errors)" }
            # Every other item was still restricted, and the tree stays in place.
            Assert-Equal $script:AclCalls.Count 4
            Assert-Equal (Get-Content -LiteralPath (Join-Path $target 'c.txt') -Raw) 'charlie'
        }
        Test-Case "SFTP ($mode): PrivateFiles in a dry run changes no permission" {
            Reset-FakeGuest
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -DryRun $true -AuthMode $mode -PermissionProfile 'PrivateFiles'
            Assert-Equal $r.Completed 1; Assert-Equal (Get-SftpPayloadLineCount) 0
            $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' (Join-Path $script:HostRoot 'g.txt') -DryRun $true -AuthMode $mode -PermissionProfile 'PrivateFiles'
            Assert-Equal $r.Completed 1; Assert-Equal $script:AclCalls.Count 0
        }
    }
    Test-Case 'SFTP (InteractivePassword): a stat failure during verification is reported as incomplete, not as a size mismatch' {
        Reset-FakeGuest
        $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -AuthMode 'InteractivePassword' -Fault 'StatCheckFails'
        Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0
        # The confirmed-mismatch wording is "size mismatch after copy"; this message intentionally
        # contains the words "size mismatch" too (to explicitly deny being one), so match the longer,
        # more specific phrase rather than the bare substring both messages share.
        if (($r.Errors -join ' ') -match 'size mismatch after copy') { throw "A stat failure was misreported as a confirmed size mismatch: $($r.Errors)" }
        if (-not (($r.Errors -join ' ') -match 'could not be completed')) { throw "Unexpected error: $($r.Errors)" }
        Assert-Equal ((Get-SftpBatchText) -match 'rename ') $false
        Assert-Equal ([IO.File]::Exists((ConvertTo-FakeGuestPath '/home/dev/a.txt'))) $false
        Assert-Equal (Get-FakeTempCount) 0
        # Download side goes through the same $verifyRemote size check in password mode.
        Reset-FakeGuest
        $r = Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' (Join-Path $script:HostRoot 'g.txt') -AuthMode 'InteractivePassword' -Fault 'StatCheckFails'
        Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0
        if (($r.Errors -join ' ') -match 'size mismatch after copy') { throw "A stat failure was misreported as a confirmed size mismatch: $($r.Errors)" }
        if (-not (($r.Errors -join ' ') -match 'could not be completed')) { throw "Unexpected error: $($r.Errors)" }
        Assert-Equal ([IO.File]::Exists((Join-Path $script:HostRoot 'g.txt'))) $false
    }
    Test-Case 'SFTP (KeyAgent): a setstat error line demotes the item even when sftp exits 0' {
        Reset-FakeGuest
        $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -PermissionProfile 'PrivateFiles' -Fault 'SetstatOutputOnly'
        Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0
        if (-not (($r.Errors -join ' ') -match "Couldn't setstat")) { throw "Unexpected error: $($r.Errors)" }
        Assert-Equal (Get-Content -LiteralPath (ConvertTo-FakeGuestPath '/home/dev/a.txt') -Raw) 'alpha'
        $r = Invoke-LabSftpXfer 'ToVM' $script:HostTree '/home/dev/tree' -Recurse $true -PermissionProfile 'PrivateFiles' -Fault 'SetstatOutputOnly'
        Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0
    }
    Test-Case 'SFTP: a default-profile transfer has no chmod line and no host-side ACL call' {
        Reset-FakeGuest
        Assert-Equal (Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt').Completed 1
        Assert-Equal ((Get-SftpBatchText) -match 'chmod') $false
        Assert-Equal (Invoke-LabSftpXfer 'ToVM' $script:HostTree '/home/dev/tree' -Recurse $true).Completed 1
        Assert-Equal ((Get-SftpBatchText) -match 'chmod') $false
        $null = Invoke-LabSftpXfer 'FromVM' '/home/dev/gtree' (Join-Path $script:HostRoot 'dl') -Recurse $true
        Assert-Equal $script:AclCalls.Count 0
    }
    Test-Case 'SFTP: a failed recursive upload leaves a non-empty created parent and every pre-existing one' {
        Reset-FakeGuest
        [void][IO.Directory]::CreateDirectory((ConvertTo-FakeGuestPath '/home/dev/empty0'))
        $r = Invoke-LabSftpXfer 'ToVM' $script:HostTree '/home/dev/empty0/n1/tree' -Recurse $true -Fault 'FailRename'
        Assert-Equal $r.Failed 1
        # The partial temporary tree stays (reported for removal by hand), so its parent cannot be removed.
        Assert-Equal ([IO.Directory]::Exists((ConvertTo-FakeGuestPath '/home/dev/empty0/n1'))) $true
        Assert-Equal ((Get-SftpBatchText) -match '(?m)^-rmdir "/home/dev/empty0/n1"$') $true
        Assert-Equal ((Get-SftpBatchText) -match 'rmdir "/home/dev/empty0"') $false
    }
    Test-Case 'SFTP: a connection lost mid-download into missing parents leaves no host-side directory behind' {
        Reset-FakeGuest
        Assert-Throws { Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' (Join-Path $script:HostRoot 'm1\m2\g.txt') -DropAtCall 2 } 'connection failed'
        Assert-Equal ([IO.Directory]::Exists((Join-Path $script:HostRoot 'm1'))) $false
        Assert-Equal (Get-FakeTempCount) 0
    }
    Test-Case 'SFTP (KeyAgent): an unrecognized destination listing fails closed instead of overwriting' {
        Reset-FakeGuest
        [IO.File]::WriteAllText((ConvertTo-FakeGuestPath '/home/dev/a.txt'), 'original')
        foreach ($policy in @('Error', 'Skip')) {
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -OnConflict $policy -Fault 'IsoListing'
            Assert-Equal $r.Failed 1; Assert-Equal $r.Completed 0; Assert-Equal (Get-SftpPayloadLineCount) 0
            if (-not (($r.Errors -join ' ') -match 'not recognized')) { throw "Unexpected error: $($r.Errors)" }
        }
        Assert-Equal (Get-Content -LiteralPath (ConvertTo-FakeGuestPath '/home/dev/a.txt') -Raw) 'original'
    }
    Test-Case 'SFTP: a hash check without sha256sum on the guest fails the item' {
        Reset-FakeGuest
        $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -Fault 'NoSha256sum'
        Assert-Equal $r.Failed 1
        if (-not (($r.Errors -join ' ') -match 'sha256sum is not available')) { throw "Unexpected error: $($r.Errors)" }
        Assert-Equal ([IO.File]::Exists((ConvertTo-FakeGuestPath '/home/dev/a.txt'))) $false
    }
    Test-Case 'SFTP: -VerifyHash off makes no ssh call in KeyAgent mode' {
        Reset-FakeGuest
        $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -VerifyHash $false
        Assert-Equal $r.Completed 1; Assert-Equal $script:SshCommands.Count 0
    }
    Test-Case 'SFTP: a failed finalize under Overwrite keeps the verified temp; otherwise removes it' {
        Reset-FakeGuest
        [IO.File]::WriteAllText((ConvertTo-FakeGuestPath '/home/dev/a.txt'), 'original')
        $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -OnConflict 'Overwrite' -Fault 'FailRename'
        Assert-Equal $r.Failed 1
        if (-not (($r.Errors -join ' ') -match 'verified copy was kept')) { throw "Unexpected error: $($r.Errors)" }
        Assert-Equal (Get-FakeTempCount) 1
        Reset-FakeGuest
        $r = Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -Fault 'FailRename'
        Assert-Equal $r.Failed 1
        Assert-Equal (Get-FakeTempCount) 0
    }
    Test-Case 'SFTP: a connection-level failure throws instead of reporting a per-item result' {
        Reset-FakeGuest
        Assert-Throws { Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -Fault 'Connection' } 'connection failed'
        Assert-Throws { Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a.txt' -AuthMode 'InteractivePassword' -Fault 'Connection' } 'connection failed'
    }
    Test-Case 'SFTP: a connection lost mid-download throws and leaves no host-side temp' {
        Reset-FakeGuest
        Assert-Throws { Invoke-LabSftpXfer 'FromVM' '/home/dev/g.txt' (Join-Path $script:HostRoot 'g.txt') -DropAtCall 2 } 'connection failed'
        Assert-Equal (Get-FakeTempCount) 0
        Assert-Equal ([IO.File]::Exists((Join-Path $script:HostRoot 'g.txt'))) $false
    }
    Test-Case 'SFTP: a missing source, or a directory without recursion, fails cleanly' {
        Reset-FakeGuest
        Assert-Equal (Invoke-LabSftpXfer 'FromVM' '/home/dev/none.txt' (Join-Path $script:HostRoot 'n.txt')).Failed 1
        Assert-Equal (Invoke-LabSftpXfer 'ToVM' $script:HostTree '/home/dev/tree').Failed 1
        Assert-Equal (Invoke-LabSftpXfer 'ToVM' $script:HostA '/home/dev/a2' -Recurse $true).Failed 1
        Assert-Equal (Get-SftpPayloadLineCount) 0
    }
    Test-Case 'SFTP: a junction inside a host-side tree refuses the whole upload' {
        Reset-FakeGuest
        $link = Join-Path $script:HostTree 'loop'
        $null = cmd /c mklink /J "$link" "$script:HostTree"
        try {
            if (-not [IO.Directory]::Exists($link)) { throw 'Could not create the test junction.' }
            $r = Invoke-LabSftpXfer 'ToVM' $script:HostTree '/home/dev/tree' -Recurse $true
            Assert-Equal $r.Failed 1; Assert-Equal (Get-SftpPayloadLineCount) 0
            if (-not (($r.Errors -join ' ') -match 'reparse point')) { throw "Unexpected error: $($r.Errors)" }
        } finally { $null = cmd /c rmdir "$link" }
    }
} finally {
    if ([IO.Directory]::Exists($script:SftpBase)) {
        Get-ChildItem -LiteralPath $script:SftpBase -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:SftpBase -Recurse -Force
    }
}

# --- Orchestrator (Invoke-LabFileTransfer) audit record ---
# The real orchestrator and the real Assert-LabVMRunning (over the fake Get-VM) run; the credential
# prompt, PowerShell Direct session, engine and audit writer are replaced. Defined after the engine
# tests on purpose: the Copy-LabTransferItem stand-in below replaces the real engine from here on.
foreach ($name in @('Invoke-LabFileTransfer', 'Start-LabFileTransferCli')) {
    $matches = @($definitions | Where-Object { $_.Name -ceq $name })
    if ($matches.Count -ne 1) { throw "Expected one definition of $name." }
    . ([scriptblock]::Create($matches[0].Extent.Text))
}
$script:LabReadOnly = $false
$script:LabLogFile = 'test-audit.jsonl'
$script:AuditRecords = [Collections.Generic.List[object]]::new()
$script:CredentialCalls = 0
$script:SessionsOpened = 0
$script:SessionsClosed = 0
$script:EngineOutcome = $null
$script:TestCredential = [pscredential]::new('labuser', (ConvertTo-SecureString 'S3cret-Pa55' -AsPlainText -Force))
function Write-LabAudit {
    param([string]$Action, [string]$Status, $VM = $null, [string]$Detail = '')
    $script:AuditRecords.Add([pscustomobject]@{ Action = $Action; Status = $Status
        VMId = $(if ($null -eq $VM) { $null } else { [string]$VM.Id }); Detail = $Detail })
}
function Resolve-LabWindowsCredential { param($Credential, [bool]$NonInteractive) $script:CredentialCalls++; return $script:TestCredential }
function New-LabPSDirectSession { param($VMId, $Credential) $script:SessionsOpened++; return [pscustomobject]@{ State = 'Opened' } }
function Remove-PSSession { param($Session) $script:SessionsClosed++ }
function Copy-LabTransferItem {
    if ($script:EngineOutcome -is [string]) { throw $script:EngineOutcome }
    return [pscustomobject]$script:EngineOutcome
}
function Invoke-LabXferOrchestrator {
    param($Outcome, [bool]$DryRun = $false, [bool]$ReadOnly = $false, [string]$State = 'Running')
    $script:AuditRecords.Clear()
    $script:CredentialCalls = 0; $script:SessionsOpened = 0; $script:SessionsClosed = 0
    $script:EngineOutcome = $Outcome
    $script:LabReadOnly = $ReadOnly
    $script:FakeVM.State = $State
    try {
        return Invoke-LabFileTransfer -VMId $script:FakeId -Direction 'ToVM' -SourcePath 'C:\src\id_test' `
            -DestinationPath 'C:\Users\dev\.ssh\id_test' -Recurse $false -OnConflict 'Skip' -VerifyHash $true `
            -DryRun $DryRun -Credential $null -NonInteractive $true -PermissionProfile 'PrivateFiles'
    } finally { $script:LabReadOnly = $false; $script:FakeVM.State = 'Off' }
}
function Get-LabOnlyAuditRecord {
    if ($script:AuditRecords.Count -ne 1) { throw "Expected exactly one audit record, got $($script:AuditRecords.Count)." }
    $record = $script:AuditRecords[0]
    Assert-Equal $record.Action 'file-transfer'
    Assert-Equal $record.VMId ([string]$script:FakeId)
    if ($record.Detail -match 'S3cret|labuser|Credential') { throw "Audit detail leaks credential material: $($record.Detail)" }
    return $record
}
function Assert-Contains { param([string]$Text, [string]$Expected) if (-not $Text.Contains($Expected)) { throw "Expected [$Expected] in [$Text]." } }

Test-Case 'Audit: a clean transfer is recorded as COMPLETED with paths, options and counts' {
    $r = Invoke-LabXferOrchestrator @{ Completed = 1; Skipped = 0; Failed = 0; BytesTransferred = [long]5; Errors = [string[]]@() }
    Assert-Equal $r.Completed 1
    Assert-Equal $r.VMId $script:FakeId
    $record = Get-LabOnlyAuditRecord
    Assert-Equal $record.Status 'COMPLETED'
    foreach ($part in @('Direction=ToVM', 'Source=C:\src\id_test', 'Destination=C:\Users\dev\.ssh\id_test', 'OnConflict=Skip',
            'PermissionProfile=PrivateFiles', 'VerifyHash=True', 'Completed=1; Skipped=0; Failed=0')) { Assert-Contains $record.Detail $part }
    Assert-Equal $script:SessionsClosed 1
}
Test-Case 'Orchestrator: the SFTP branch forwards -PermissionProfile to the SFTP engine' {
    # Replaces the real SFTP engine from here on (its own tests ran above).
    $script:SftpEngineArgs = $null
    function Copy-LabTransferItemSftp { $script:SftpEngineArgs = $args; return [pscustomobject]$script:EngineOutcome }
    $script:FakeSshSettings = [pscustomobject]@{ HostNameOrAddress = 'guest.invalid'; Port = 22; UserName = 'dev'; IdentityFilePath = 'C:\keys\id_test' }
    try {
        $r = Invoke-LabXferOrchestrator @{ Completed = 1; Skipped = 0; Failed = 0; BytesTransferred = [long]5; Errors = [string[]]@() }
    } finally { $script:FakeSshSettings = $null }
    Assert-Equal $r.Completed 1
    Assert-Equal $script:SessionsOpened 0
    Assert-Equal $script:SftpEngineArgs.Count 13
    Assert-Equal $script:SftpEngineArgs[12] 'PrivateFiles'
    Assert-Contains (Get-LabOnlyAuditRecord).Detail 'PermissionProfile=PrivateFiles'
}
Test-Case 'Audit: some failed, some completed is PARTIAL' {
    $null = Invoke-LabXferOrchestrator @{ Completed = 2; Skipped = 0; Failed = 1; BytesTransferred = [long]5; Errors = [string[]]@('x') }
    Assert-Equal (Get-LabOnlyAuditRecord).Status 'PARTIAL'
}
Test-Case 'Audit: failures with nothing completed is FAILED' {
    $null = Invoke-LabXferOrchestrator @{ Completed = 0; Skipped = 1; Failed = 1; BytesTransferred = [long]0; Errors = [string[]]@('x') }
    $record = Get-LabOnlyAuditRecord
    Assert-Equal $record.Status 'FAILED'
    Assert-Contains $record.Detail 'Completed=0; Skipped=1; Failed=1'
}
Test-Case 'Audit: a dry run is DRY_RUN' {
    $null = Invoke-LabXferOrchestrator @{ Completed = 1; Skipped = 0; Failed = 0; BytesTransferred = [long]0; Errors = [string[]]@() } -DryRun $true
    Assert-Equal (Get-LabOnlyAuditRecord).Status 'DRY_RUN'
}
Test-Case 'Audit: a read-only real copy is BLOCKED_READONLY and never prompts or connects' {
    $r = Invoke-LabXferOrchestrator @{ Completed = 1; Skipped = 0; Failed = 0; BytesTransferred = [long]0; Errors = [string[]]@() } -ReadOnly $true
    Assert-Equal $r.Failed 1
    Assert-Equal (Get-LabOnlyAuditRecord).Status 'BLOCKED_READONLY'
    Assert-Equal $script:CredentialCalls 0
    Assert-Equal $script:SessionsOpened 0
}
Test-Case 'Audit: a read-only dry run still resolves credentials and runs' {
    $null = Invoke-LabXferOrchestrator @{ Completed = 1; Skipped = 0; Failed = 0; BytesTransferred = [long]0; Errors = [string[]]@() } -DryRun $true -ReadOnly $true
    Assert-Equal (Get-LabOnlyAuditRecord).Status 'DRY_RUN'
    Assert-Equal $script:CredentialCalls 1
}
Test-Case 'Audit: an engine failure mid-transfer is still recorded, and rethrown' {
    Assert-Throws { Invoke-LabXferOrchestrator 'simulated connection loss' } 'simulated connection loss'
    $record = Get-LabOnlyAuditRecord
    Assert-Equal $record.Status 'FAILED_OR_UNCONFIRMED'
    Assert-Contains $record.Detail 'Error=simulated connection loss'
    Assert-Equal $script:SessionsClosed 1
}
Test-Case 'Audit: a VM that is not Running is recorded as FAILED before any prompt' {
    Assert-Throws { Invoke-LabXferOrchestrator @{ Completed = 1 } -State 'Off' } 'requires Running'
    Assert-Equal (Get-LabOnlyAuditRecord).Status 'FAILED'
    Assert-Equal $script:CredentialCalls 0
}

# --- Parameter mode (Start-LabFileTransferCli) per-VM mutex ---
# Ownership is probed from another thread: a mutex is re-entrant for the thread that holds it.
$script:CliVMId = [guid]::NewGuid()
$script:CliThrow = $false
$script:TransferCalls = 0
$script:MutexFreeDuringTransfer = $null
function Test-LabMutexFreeElsewhere {
    param([guid]$Id)
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript({
            param([string]$MutexName)
            $m = [Threading.Mutex]::new($false, $MutexName)
            try {
                $got = $false
                try { $got = $m.WaitOne(0) } catch [Threading.AbandonedMutexException] { $got = $true }
                if ($got) { $m.ReleaseMutex() }
                $got
            } finally { $m.Dispose() }
        }).AddArgument("Global\LabVmManager-$Id")
        return ([string](@($ps.EndInvoke($ps.BeginInvoke()))[0]) -eq 'True')
    } finally { $ps.Dispose() }
}
function Assert-LabHost { }
function Initialize-LabLog { param([string]$Root) }
function Resolve-LabVMByNameOrId { param([string]$VMName, $VMId) return $script:CliVMId }
function Invoke-LabFileTransfer {
    $script:TransferCalls++
    $script:MutexFreeDuringTransfer = Test-LabMutexFreeElsewhere $script:CliVMId
    if ($script:CliThrow) { throw 'simulated transfer failure' }
    return [pscustomobject]@{ VMId = $script:CliVMId; Completed = 1; Skipped = 0; Failed = 2; BytesTransferred = [long]5; Errors = [string[]]@('x', 'y') }
}
function Invoke-LabCli {
    $script:TransferCalls = 0
    $script:MutexFreeDuringTransfer = $null
    return Start-LabFileTransferCli -CopyToVM $true -CopyFromVM $false -VMName 'LAB-Test' -VMId $null -SourcePath 'C:\a' `
        -DestinationPath 'C:\b' -Recurse $false -OnConflict 'Error' -DryRun $false -NonInteractive $true -VerifyHash $false `
        -PermissionProfile 'Default' -Credential $null -RequestedLogRoot '' 6>$null 3>$null
}

Test-Case 'CLI: the per-VM mutex is held for the whole transfer, released after, and the summary survives' {
    Assert-Equal (Test-LabMutexFreeElsewhere $script:CliVMId) $true
    $failed = Invoke-LabCli
    Assert-Equal $script:TransferCalls 1
    Assert-Equal $script:MutexFreeDuringTransfer $false
    Assert-Equal $failed 2
    Assert-Equal (Test-LabMutexFreeElsewhere $script:CliVMId) $true
}
Test-Case 'CLI: the per-VM mutex is released when the transfer throws' {
    $script:CliThrow = $true
    try {
        Assert-Throws { Invoke-LabCli } 'simulated transfer failure'
        Assert-Equal $script:MutexFreeDuringTransfer $false
        Assert-Equal (Test-LabMutexFreeElsewhere $script:CliVMId) $true
    } finally { $script:CliThrow = $false }
}
Test-Case 'CLI: a VM locked by another operation is refused without transferring' {
    $ready = [Threading.ManualResetEvent]::new($false)
    $release = [Threading.ManualResetEvent]::new($false)
    $holder = [powershell]::Create()
    [void]$holder.AddScript({
        param([string]$MutexName, $Ready, $Release)
        $m = [Threading.Mutex]::new($false, $MutexName)
        [void]$m.WaitOne()
        try { [void]$Ready.Set(); [void]$Release.WaitOne(30000) }
        finally { $m.ReleaseMutex(); $m.Dispose() }
    }).AddArgument("Global\LabVmManager-$script:CliVMId").AddArgument($ready).AddArgument($release)
    $handle = $holder.BeginInvoke()
    try {
        if (-not $ready.WaitOne(30000)) { throw 'The lock-holding thread did not start.' }
        Assert-Throws { Invoke-LabCli } 'Another copy of this script is operating on this VM'
        Assert-Equal $script:TransferCalls 0
    } finally {
        [void]$release.Set()
        $null = $holder.EndInvoke($handle)
        $holder.Dispose(); $ready.Dispose(); $release.Dispose()
    }
    Assert-Equal (Test-LabMutexFreeElsewhere $script:CliVMId) $true
}

# --- Invocation gate: transfer parameters without a direction switch ---
Test-Case 'Gate: menu-only parameters are not transfer-only' {
    Assert-Equal @(Get-LabTransferOnlyParameter @('ReadOnly', 'LogRoot', 'ExportRoot', 'TimeoutSeconds')).Count 0
    Assert-Equal @(Get-LabTransferOnlyParameter @()).Count 0
}
Test-Case 'Gate: every transfer-only parameter is reported' {
    foreach ($name in @('VMName', 'VMId', 'SourcePath', 'DestinationPath', 'Recurse', 'OnConflict', 'DryRun',
            'NonInteractive', 'VerifyHash', 'PermissionProfile', 'Credential')) {
        Assert-Equal (@(Get-LabTransferOnlyParameter @('ReadOnly', $name)) -join ',') $name
    }
}
Test-Case 'Gate: the real script refuses -NonInteractive without a direction switch instead of opening the menu' {
    # Local: under 'Stop', Windows PowerShell turns the child's redirected stderr into a terminating error.
    $ErrorActionPreference = 'Continue'
    $exe = Join-Path $PSHOME 'powershell.exe'
    $output = @(& $exe -NoProfile -NonInteractive -File $resolved -VMName 'LAB-x' -NonInteractive 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    Assert-Equal $LASTEXITCODE 1
    # Whitespace-insensitive: the child may wrap the error text at its console width.
    if (-not ($output -replace '\s', '').Contains('-VMName,-NonInteractiveonlyapplytofiletransfer')) { throw "Unexpected output: $output" }
}
# --- SSH connection settings persistence ---
Test-Case 'SSH connection settings path is scoped by VM GUID' {
    $id = [guid]'11111111-1111-1111-1111-111111111111'
    $path = Get-LabSshConnectionSettingsPath $id
    Assert-Equal ($path -like "*SshConnections*$id.json") $true
}

# --- SSH value validation, settings file handling, and the real SSH helpers against fakes ---
# Safety: every test below that loads a real function which can launch ssh.exe/sftp.exe defines a fake
# ssh.exe/sftp.exe FUNCTION in the same child scope first, and asserts it resolves to that function
# before calling anything; the script-level tripwires above remain in place underneath. Nothing here can
# start a real OpenSSH process, prompt, or read or write known_hosts. Add-LabSshKnownHost is never loaded.
function Import-LabRealFunction {
    param([string[]]$Name)
    foreach ($n in $Name) {
        $found = @($definitions | Where-Object { $_.Name -ceq $n })
        if ($found.Count -ne 1) { throw "Expected one definition of $n." }
        # Returned as a scriptblock for the caller to dot-source into its own child scope.
        [scriptblock]::Create($found[0].Extent.Text)
    }
}
function Assert-FakeCommand {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction Stop
    if ($command.CommandType -ne 'Function') { throw "SAFETY: $Name does not resolve to a fake function; refusing to continue." }
}

Test-Case 'SSH host validation: ordinary names and addresses are accepted' {
    foreach ($value in @('192.168.1.50', 'lab-linux.local', 'fe80::1', 'guest')) { Assert-Equal (Test-LabSshHostName $value) $true }
}
Test-Case 'SSH host validation: a leading dash, whitespace, control characters, @ or blank are refused' {
    foreach ($value in @('-oProxyCommand=calc', '-p', 'a b', "a`tb", "a`nb", 'user@host', '', $null)) { Assert-Equal (Test-LabSshHostName $value) $false }
}
Test-Case 'SSH user validation: a leading dash, whitespace, control characters or blank are refused' {
    Assert-Equal (Test-LabSshUserName 'dev') $true
    Assert-Equal (Test-LabSshUserName 'dev@CORP') $true
    foreach ($value in @('-oProxyCommand=calc', 'a b', "a`tb", '', $null)) { Assert-Equal (Test-LabSshUserName $value) $false }
}
Test-Case 'SSH settings: saved values round-trip; invalid values are refused before anything is written' {
    $tempLocal = Join-Path ([IO.Path]::GetTempPath()) ('labssh-settings-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $tempLocal
        & {
            foreach ($sb in (Import-LabRealFunction 'Get-LabSshConnectionSettings', 'Set-LabSshConnectionSettings')) { . $sb }
            $id = [guid]'22222222-2222-2222-2222-222222222222'
            Assert-Equal (Get-LabSshConnectionSettings $id) $null
            Set-LabSshConnectionSettings -VMId $id -HostNameOrAddress '10.0.0.5' -Port 2222 -UserName 'dev' -IdentityFilePath ''
            $read = Get-LabSshConnectionSettings $id
            Assert-Equal $read.HostNameOrAddress '10.0.0.5'; Assert-Equal $read.Port 2222; Assert-Equal $read.UserName 'dev'
            $other = [guid]'33333333-3333-3333-3333-333333333333'
            Assert-Throws { Set-LabSshConnectionSettings -VMId $other -HostNameOrAddress '-oProxyCommand=calc' -Port 22 -UserName 'dev' -IdentityFilePath '' } 'Invalid SSH host'
            Assert-Throws { Set-LabSshConnectionSettings -VMId $other -HostNameOrAddress '10.0.0.5' -Port 22 -UserName '-oProxyCommand=calc' -IdentityFilePath '' } 'Invalid SSH username'
            Assert-Throws { Set-LabSshConnectionSettings -VMId $other -HostNameOrAddress '10.0.0.5' -Port 70000 -UserName 'dev' -IdentityFilePath '' } 'between 1 and 65535'
            Assert-Equal ([IO.File]::Exists((Get-LabSshConnectionSettingsPath $other))) $false
        }
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        if ([IO.Directory]::Exists($tempLocal)) { [IO.Directory]::Delete($tempLocal, $true) }
    }
}
Test-Case 'SSH settings: a corrupt, empty or hand-edited file throws naming the file, never reads as unconfigured' {
    $tempLocal = Join-Path ([IO.Path]::GetTempPath()) ('labssh-settings-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $tempLocal
        & {
            foreach ($sb in (Import-LabRealFunction 'Get-LabSshConnectionSettings')) { . $sb }
            $id = [guid]'44444444-4444-4444-4444-444444444444'
            $path = Get-LabSshConnectionSettingsPath $id
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            $cases = @('{ not json', '', '{"HostNameOrAddress":"10.0.0.5","Port":22,"UserName":"-oProxyCommand=calc","IdentityFilePath":""}',
                '{"HostNameOrAddress":"10.0.0.5","Port":0,"UserName":"dev","IdentityFilePath":""}', '{"Port":22}')
            foreach ($content in $cases) {
                [IO.File]::WriteAllText($path, $content)
                Assert-Throws { Get-LabSshConnectionSettings $id } ('cannot be used.*' + [regex]::Escape($path))
            }
        }
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        if ([IO.Directory]::Exists($tempLocal)) { [IO.Directory]::Delete($tempLocal, $true) }
    }
}
Test-Case 'Adapter selection: unreadable SSH settings throw instead of falling back to PSDirect' {
    & {
        function Get-LabSshConnectionSettings { param([guid]$VMId) throw 'The saved SSH connection settings for VM x cannot be used (bad).' }
        Assert-Throws { Get-LabTransferAdapterKind $script:FakeId } 'cannot be used'
    }
}
Test-Case 'SFTP command (InteractivePassword): stray sftp stdout stays off the return value; BatchMode=no precedes -b' {
    & {
        $script:FakeSftpArgs = $null
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        # Stands in for sftp.exe in batch mode, which echoes its batch on stdout.
        function sftp.exe { $script:FakeSftpArgs = [string[]]@($args); 'sftp> pwd'; 'Remote working directory: /home/labuser'; $global:LASTEXITCODE = 0 }
        foreach ($sb in (Import-LabRealFunction 'Invoke-LabSftpCommand')) { . $sb }
        Assert-FakeCommand 'sftp.exe'
        $result = @(Invoke-LabSftpCommand 'guest.invalid' 22 'labuser' '' 'C:\labssh-test-unused.batch' 'InteractivePassword')
        Assert-Equal $result.Count 1
        Assert-Equal $result[0].ExitCode 0
        Assert-Equal @($result[0].Output).Count 0
        $passed = $script:FakeSftpArgs
        $batchModeAt = [array]::IndexOf($passed, 'BatchMode=no')
        $batchFileAt = [array]::IndexOf($passed, '-b')
        if ($batchModeAt -lt 1 -or $passed[$batchModeAt - 1] -ne '-o') { throw "BatchMode=no was not passed as an -o option: $($passed -join ' ')" }
        if ($batchFileAt -lt 0 -or $batchModeAt -gt $batchFileAt) { throw "BatchMode=no must come before -b: $($passed -join ' ')" }
        Assert-Equal ($passed -contains 'BatchMode=yes') $false
        Assert-Equal ($passed -contains 'StrictHostKeyChecking=yes') $true
        Assert-Equal $passed[-1] 'labuser@guest.invalid'
    }
}
Test-Case 'SSH connection test (InteractivePassword): a successful login reports success, not a StrictMode failure' {
    & {
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function sftp.exe { 'sftp> pwd'; 'Remote working directory: /home/labuser'; $global:LASTEXITCODE = 0 }
        function Get-LabSshConnectionSettings { param([guid]$VMId) [pscustomobject]@{ HostNameOrAddress = 'guest.invalid'; Port = 22; UserName = 'labuser'; IdentityFilePath = '' } }
        foreach ($sb in (Import-LabRealFunction 'Invoke-LabSftpCommand', 'Test-LabSshConnection')) { . $sb }
        Assert-FakeCommand 'sftp.exe'
        $script:FakeVM.State = 'Running'
        try { $messages = @(Test-LabSshConnection $script:FakeId 3>&1 6>&1 | ForEach-Object { [string]$_ }) -join "`n" }
        finally { $script:FakeVM.State = 'Off' }
        if ($messages -notmatch 'Connection succeeded \(InteractivePassword\)') { throw "Unexpected output: $messages" }
        if ($messages -match 'failed') { throw "Unexpected failure output: $messages" }
    }
}
Test-Case 'SSH connection test (KeyAgent): a failure shows sftp''s own reason and the first-trust hint' {
    & {
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function sftp.exe { 'Host key verification failed.'; 'Connection closed'; $global:LASTEXITCODE = 255 }
        function Get-LabSshConnectionSettings { param([guid]$VMId) [pscustomobject]@{ HostNameOrAddress = 'guest.invalid'; Port = 22; UserName = 'labuser'; IdentityFilePath = 'C:\keys\id_test' } }
        foreach ($sb in (Import-LabRealFunction 'Invoke-LabSftpCommand', 'Test-LabSshConnection')) { . $sb }
        Assert-FakeCommand 'sftp.exe'
        $script:FakeVM.State = 'Running'
        try { $messages = @(Test-LabSshConnection $script:FakeId 3>&1 6>&1 | ForEach-Object { [string]$_ }) -join "`n" }
        finally { $script:FakeVM.State = 'Off' }
        if ($messages -notmatch 'sftp exit code 255\): Host key verification failed\. Connection closed') { throw "Reason not surfaced: $messages" }
        if ($messages -notmatch 'option K') { throw "First-trust hint missing: $messages" }
    }
}

# --- Linux unattended install, Task 5: ephemeral SSH key, trust-on-first-connect wait, note delivery ---
# Safety: same pattern as the SSH helper tests above -- each test loads the real function via
# Import-LabRealFunction into its own child scope, with a fake ssh-keygen.exe/ssh.exe FUNCTION already
# defined in that scope, confirmed with Assert-FakeCommand before anything is called. The script-level
# tripwires for ssh.exe/sftp.exe/ssh-keygen.exe remain active underneath. No real OpenSSH process,
# prompt, known_hosts access, or key material ever exists outside this in-memory fake.
Test-Case 'New-LabEphemeralSshKeyPair writes a stable keypair under SshConnections, not the per-VM workspace' {
    $tempLocal = Join-Path ([IO.Path]::GetTempPath()) ('labssh-keypair-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $tempLocal
        & {
            function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
            # Stands in for ssh-keygen.exe: writes a dummy keypair to the -f path it is given, exactly
            # like the real tool would, so the real function's own file-existence checks still pass.
            function ssh-keygen.exe {
                $script:KeygenArgsSeen = @($args)
                $fIndex = [array]::IndexOf($args, '-f')
                $privPath = $args[$fIndex + 1]
                [IO.File]::WriteAllText($privPath, 'FAKE-PRIVATE-KEY')
                [IO.File]::WriteAllText("$privPath.pub", 'ssh-ed25519 FAKEPUBLICKEYDATA lab-vm-manager-ephemeral')
                $global:LASTEXITCODE = 0
            }
            foreach ($sb in (Import-LabRealFunction 'New-LabEphemeralSshKeyPair')) { . $sb }
            Assert-FakeCommand 'ssh-keygen.exe'
            $id = [guid]'55555555-5555-5555-5555-555555555555'
            $result = New-LabEphemeralSshKeyPair $id
            Assert-Equal ($result.PrivateKeyPath -like "*SshConnections*$id.key") $true
            Assert-Equal ($result.PrivateKeyPath -like '*Provisioning*') $false
            Assert-Equal $result.PublicKeyContent 'ssh-ed25519 FAKEPUBLICKEYDATA lab-vm-manager-ephemeral'
            Assert-Equal ([IO.File]::Exists($result.PrivateKeyPath)) $true
            # A generic comment, never ssh-keygen's default <Windows user>@<host name>.
            $cIndex = [array]::IndexOf($script:KeygenArgsSeen, '-C')
            Assert-Equal ($cIndex -ge 0) $true
            Assert-Equal $script:KeygenArgsSeen[$cIndex + 1] "lab-vm-manager-$id"
            Assert-Equal @($script:KeygenArgsSeen | Where-Object { $_ -eq '-C' }).Count 1
        }
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        if ([IO.Directory]::Exists($tempLocal)) { [IO.Directory]::Delete($tempLocal, $true) }
    }
}
Test-Case 'New-LabEphemeralSshKeyPair throws clearly when the OpenSSH Client tooling is missing' {
    & {
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $false } }
        foreach ($sb in (Import-LabRealFunction 'New-LabEphemeralSshKeyPair')) { . $sb }
        Assert-Throws { New-LabEphemeralSshKeyPair ([guid]'66666666-6666-6666-6666-666666666666') } 'OpenSSH Client'
    }
}
# Wait-LabSshSession tests share one disposable environment: a temp %LOCALAPPDATA% holding this VM's
# ephemeral key file (the path Wait-LabSshSession derives from $VMId), and a temp file standing in for
# the operator's real known_hosts (via a fake Get-LabSshUserKnownHostsPath). The fake ssh.exe below
# behaves like accept-new does during key exchange: before any authentication result, it appends the
# answering host's key line to the FIRST UserKnownHostsFile it was given. Nothing touches the real
# profile's known_hosts or any real key.
function Resolve-FakeSshOptionPath {
    param([string]$Value)
    if ($Value.StartsWith('~/')) { return Join-Path ([Environment]::GetFolderPath('UserProfile')) $Value.Substring(2).Replace('/', '\') }
    return $Value.Replace('/', '\')
}
function Get-FakeSshKnownHostsFiles {
    param([object[]]$SshArgs)
    $options = @($SshArgs | Where-Object { ([string]$_).StartsWith('UserKnownHostsFile=') })
    if ($options.Count -ne 1) { throw 'Fake ssh.exe: expected exactly one UserKnownHostsFile option.' }
    return @(([string]$options[0]).Substring('UserKnownHostsFile='.Length) -split ' ' | ForEach-Object { Resolve-FakeSshOptionPath $_ })
}
function Invoke-FakeSshAcceptNew {
    # Records the call, then writes the answering host's key line to the scratch (first) known_hosts file.
    param([object[]]$SshArgs)
    $script:ProbeArgsSeen.Add([string[]]@($SshArgs))
    $files = @(Get-FakeSshKnownHostsFiles $SshArgs)
    $script:ScratchFilesSeen.Add($files[0])
    $address = ([string]$SshArgs[$SshArgs.Count - 2]).Split('@')[-1]
    [IO.File]::AppendAllText($files[0], "$address ssh-ed25519 AAAAFAKEHOSTKEY`n")
    $script:ScratchContentSeen.Add([IO.File]::ReadAllText($files[0]))
}
function Invoke-WithFakeSshWaitEnvironment {
    param([scriptblock]$Body)
    $root = Join-Path ([IO.Path]::GetTempPath()) ('labssh-wait-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $savedLocal = $env:LOCALAPPDATA
    try {
        [void][IO.Directory]::CreateDirectory($root)
        $env:LOCALAPPDATA = Join-Path $root 'Local'
        $script:FakeKeyPath = Join-Path $env:LOCALAPPDATA "LabVmManager\SshConnections\$($script:FakeId).key"
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $script:FakeKeyPath))
        [IO.File]::WriteAllText($script:FakeKeyPath, 'FAKE-PRIVATE-KEY')
        $script:FakeRealKnownHosts = Join-Path $root 'profile\.ssh\known_hosts'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $script:FakeRealKnownHosts))
        $script:ProbeArgsSeen = [Collections.Generic.List[string[]]]::new()
        $script:ScratchFilesSeen = [Collections.Generic.List[string]]::new()
        $script:ScratchContentSeen = [Collections.Generic.List[string]]::new()
        $script:RunningChecks = 0
        $script:SleepCalls = 0
        & $Body
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
    }
}

Test-Case 'Wait-LabSshSession no longer accepts an identity file: its parameters are exactly VMId, UserName, TimeoutSeconds' {
    & {
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession')) { . $sb }
        $names = @((Get-Command Wait-LabSshSession).Parameters.Keys | Where-Object { $_ -in @('VMId', 'UserName', 'TimeoutSeconds', 'IdentityFilePath') })
        Assert-Equal ($names -join ',') 'VMId,UserName,TimeoutSeconds'
        Assert-Equal ((Get-Command Wait-LabSshSession).Parameters.ContainsKey('IdentityFilePath')) $false
    }
}
Test-Case 'Wait-LabSshSession retries, uses only this VM''s derived key with IdentitiesOnly, and commits the verified host key only after success' {
    Invoke-WithFakeSshWaitEnvironment {
        # Pre-existing operator content without a trailing newline: the commit must not glue lines together.
        [IO.File]::WriteAllText($script:FakeRealKnownHosts, '10.0.0.1 ssh-ed25519 AAAAPRIORKEY')
        $script:AddressCallIndex = 0
        $script:ProbeCallIndex = 0
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates {
            param([guid]$VMId)
            $script:AddressCallIndex++
            if ($script:AddressCallIndex -le 1) { return @() }
            return @('192.168.1.77')
        }
        function ssh.exe {
            $script:ProbeCallIndex++
            Invoke-FakeSshAcceptNew $args
            if ($script:ProbeCallIndex -le 2) { 'Permission denied (publickey).'; $global:LASTEXITCODE = 255; return }
            $global:LASTEXITCODE = 0
        }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        Assert-FakeCommand 'Get-LabSshUserKnownHostsPath'
        $login = Wait-LabSshSession $script:FakeId 'labuser' 60 6>$null
        Assert-Equal $login.Address '192.168.1.77'
        # The verified key is returned too, so the caller can pin a later login to it.
        Assert-Equal $login.HostKey 'ssh-ed25519 AAAAFAKEHOSTKEY'
        Assert-Equal ($script:SleepCalls -ge 2) $true
        Assert-Equal $script:ProbeArgsSeen.Count 3
        # One VM-state check per loop iteration (1 no-address + 2 failed + 1 successful iteration).
        Assert-Equal $script:RunningChecks 4
        foreach ($seen in $script:ProbeArgsSeen) {
            Assert-Equal ($seen -contains 'StrictHostKeyChecking=accept-new') $true
            Assert-Equal ($seen -contains 'StrictHostKeyChecking=yes') $false
            Assert-Equal ($seen -contains 'IdentitiesOnly=yes') $true
            Assert-Equal ($seen -contains 'ConnectTimeout=10') $true
            Assert-Equal ($seen -contains 'UpdateHostKeys=no') $true
            $f = [array]::IndexOf($seen, '-F'); Assert-Equal $seen[$f + 1] 'none'
            $i = [array]::IndexOf($seen, '-i'); Assert-Equal $seen[$i + 1] $script:FakeKeyPath
            Assert-Equal @($seen | Where-Object { $_ -eq '-i' }).Count 1
            # The scratch file is listed first (where accept-new writes); the real file second, read-only.
            $files = @(Get-FakeSshKnownHostsFiles $seen)
            Assert-Equal $files.Count 2
            Assert-Equal ($files[0] -ne $script:FakeRealKnownHosts) $true
            Assert-Equal ([IO.Path]::GetFullPath($files[1])) ([IO.Path]::GetFullPath($script:FakeRealKnownHosts))
        }
        # Phase 2 appended exactly the one line OpenSSH wrote for the authenticated host, after the prior content.
        Assert-Equal ([IO.File]::ReadAllText($script:FakeRealKnownHosts)) "10.0.0.1 ssh-ed25519 AAAAPRIORKEY`n192.168.1.77 ssh-ed25519 AAAAFAKEHOSTKEY`n"
        foreach ($scratch in $script:ScratchFilesSeen) { Assert-Equal ([IO.File]::Exists($scratch)) $false }
    }
}
Test-Case 'Wait-LabSshSession: a host that answers but rejects our key never touches the real known_hosts' {
    Invoke-WithFakeSshWaitEnvironment {
        $before = 'existing.example ssh-ed25519 AAAAPRIORKEY' + "`n"
        [IO.File]::WriteAllText($script:FakeRealKnownHosts, $before)
        $beforeWrite = [IO.File]::GetLastWriteTimeUtc($script:FakeRealKnownHosts)
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('192.168.1.99') }
        # An unrelated host: it completes key exchange (so accept-new records its key in the scratch
        # file), then refuses this VM's ephemeral key.
        function ssh.exe { Invoke-FakeSshAcceptNew $args; 'Permission denied (publickey).'; $global:LASTEXITCODE = 255 }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        Assert-Throws { Wait-LabSshSession $script:FakeId 'labuser' 1 6>$null } 'Timed out.*Permission denied'
        Assert-Equal ($script:ProbeArgsSeen.Count -ge 1) $true
        # The unrelated host's key really was written -- but only to the scratch file, which is gone now.
        Assert-Equal ($script:ScratchContentSeen[0] -match '192\.168\.1\.99 ssh-ed25519 AAAAFAKEHOSTKEY') $true
        foreach ($scratch in $script:ScratchFilesSeen) {
            Assert-Equal ($scratch -ne $script:FakeRealKnownHosts) $true
            Assert-Equal ([IO.File]::Exists($scratch)) $false
        }
        Assert-Equal ([IO.File]::ReadAllText($script:FakeRealKnownHosts)) $before
        Assert-Equal ([IO.File]::GetLastWriteTimeUtc($script:FakeRealKnownHosts)) $beforeWrite
    }
}
Test-Case 'Wait-LabSshSession: a failed probe never creates a missing real known_hosts file' {
    Invoke-WithFakeSshWaitEnvironment {
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('192.168.1.99') }
        function ssh.exe { Invoke-FakeSshAcceptNew $args; 'Connection closed by 192.168.1.99 port 22'; $global:LASTEXITCODE = 255 }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        Assert-Throws { Wait-LabSshSession $script:FakeId 'labuser' 1 6>$null } 'Timed out'
        Assert-Equal ([IO.File]::Exists($script:FakeRealKnownHosts)) $false
    }
}
Test-Case 'Wait-LabSshSession skips candidate addresses that are not IP addresses; they never reach ssh.exe' {
    Invoke-WithFakeSshWaitEnvironment {
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('-oProxyCommand=calc', 'evil" -oProxyCommand=calc', 'host.example', '192.168.1.80') }
        function ssh.exe { Invoke-FakeSshAcceptNew $args; $global:LASTEXITCODE = 0 }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        Assert-Equal (Wait-LabSshSession $script:FakeId 'labuser' 60 6>$null).Address '192.168.1.80'
        Assert-Equal $script:ProbeArgsSeen.Count 1
        Assert-Equal ($script:ProbeArgsSeen[0] -contains 'labuser@192.168.1.80') $true
        foreach ($arg in $script:ProbeArgsSeen[0]) { Assert-Equal ($arg -match 'calc|host\.example|evil') $false }
    }
}
Test-Case 'Wait-LabSshSession with only non-IP candidates never calls ssh.exe and times out' {
    Invoke-WithFakeSshWaitEnvironment {
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('-oProxyCommand=calc', 'host.example') }
        function ssh.exe { $script:ProbeArgsSeen.Add([string[]]@($args)); $global:LASTEXITCODE = 0 }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        Assert-Throws { Wait-LabSshSession $script:FakeId 'labuser' 1 6>$null } 'Timed out.*usable IP address'
        Assert-Equal $script:ProbeArgsSeen.Count 0
    }
}
Test-Case 'Wait-LabSshSession validates the username with Test-LabSshUserName before anything else' {
    Invoke-WithFakeSshWaitEnvironment {
        $script:UserNameChecks = [Collections.Generic.List[string]]::new()
        function Test-LabSshUserName { param([string]$Value) $script:UserNameChecks.Add($Value); return $false }
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('192.168.1.80') }
        function ssh.exe { $script:ProbeArgsSeen.Add([string[]]@($args)); $global:LASTEXITCODE = 0 }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        Assert-Throws { Wait-LabSshSession $script:FakeId '-oProxyCommand=calc' 60 6>$null } 'Invalid SSH username'
        Assert-Equal ($script:UserNameChecks -join ',') '-oProxyCommand=calc'
        Assert-Equal $script:ProbeArgsSeen.Count 0
        Assert-Equal $script:RunningChecks 0
    }
}
Test-Case 'Wait-LabSshSession fails fast when the VM is no longer Running' {
    Invoke-WithFakeSshWaitEnvironment {
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++; throw "'LAB-Test' is Off. This operation requires Running. Start it first." }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('192.168.1.80') }
        function ssh.exe { $script:ProbeArgsSeen.Add([string[]]@($args)); $global:LASTEXITCODE = 255 }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        Assert-Throws { Wait-LabSshSession $script:FakeId 'labuser' 600 6>$null } 'is Off.*requires Running'
        Assert-Equal $script:RunningChecks 1
        Assert-Equal $script:ProbeArgsSeen.Count 0
        Assert-Equal $script:SleepCalls 0
    }
}
# A fuller stand-in for ssh.exe's host key check, used by the changed-key and pinned-mode tests below.
# It models OpenSSH's own rules: the host at the target address presents $script:FakeHostKeys[address];
# every entry for that address across ALL the given known_hosts files (UserKnownHostsFile list plus
# GlobalKnownHostsFile) is collected; any entry with the presented key means "known"; entries that all
# differ mean "changed" (refused under both accept-new and yes); no entry at all means "new" (refused
# under yes; under accept-new, written to the FIRST user file and allowed). Authentication then always
# succeeds (this VM's own key is accepted), so exit 0 here means "host key check passed".
function Get-FakeSshOptionValue {
    param([object[]]$SshArgs, [string]$Name)
    $option = @($SshArgs | Where-Object { ([string]$_).StartsWith("$Name=") })
    if ($option.Count -gt 1) { throw "Fake ssh.exe: $Name given more than once." }
    if ($option.Count -eq 0) { return $null }
    return ([string]$option[0]).Substring($Name.Length + 1)
}
function Invoke-FakeOpenSshHostKeyCheck {
    param([object[]]$SshArgs)
    $script:ProbeArgsSeen.Add([string[]]@($SshArgs))
    $address = ([string]$SshArgs[$SshArgs.Count - 2]).Split('@')[-1]
    $mode = Get-FakeSshOptionValue $SshArgs 'StrictHostKeyChecking'
    $userFiles = @(Get-FakeSshKnownHostsFiles $SshArgs)
    $globalValue = Get-FakeSshOptionValue $SshArgs 'GlobalKnownHostsFile'
    # Unset GlobalKnownHostsFile = the default system file, which in these tests holds nothing.
    $globalFiles = @(if ($null -ne $globalValue) { $globalValue -split ' ' | ForEach-Object { Resolve-FakeSshOptionPath $_ } })
    $presented = $script:FakeHostKeys[$address]
    $known = @(foreach ($file in @($userFiles + $globalFiles)) {
            if (-not [IO.File]::Exists($file)) { continue }
            foreach ($line in [IO.File]::ReadAllLines($file)) {
                $fields = @($line.Trim() -split ' ')
                if ($fields.Count -ge 3 -and $fields[0] -eq $address) { "$($fields[1]) $($fields[2])" }
            }
        })
    if ($known -contains $presented) { $global:LASTEXITCODE = 0; return }
    if ($known.Count -gt 0) {
        '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @'
        "Host key for $address has changed and you have requested strict checking."
        'Host key verification failed.'
        $global:LASTEXITCODE = 255; return
    }
    if ($mode -eq 'accept-new') {
        $script:AcceptNewWrites++
        [IO.File]::AppendAllText($userFiles[0], "$address $presented`n")
        $global:LASTEXITCODE = 0; return
    }
    "No ED25519 host key is known for $address and you have requested strict checking."
    'Host key verification failed.'
    $global:LASTEXITCODE = 255
}
function Invoke-WithFakeOpenSshEnvironment {
    # Invoke-WithFakeSshWaitEnvironment plus the state every test of the OpenSSH-semantics fake shares.
    # (Not named $Body: the inner block runs inside Invoke-WithFakeSshWaitEnvironment, whose own $Body
    # would shadow it.)
    param([scriptblock]$OpenSshBody)
    Invoke-WithFakeSshWaitEnvironment {
        $script:FakeHostKeys = @{}
        $script:AcceptNewWrites = 0
        & $OpenSshBody
    }
}
function Split-FakeWarningOutput {
    param([object[]]$Output)
    return [pscustomobject]@{
        Warnings = @($Output | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        Results = @($Output | Where-Object { $_ -isnot [Management.Automation.WarningRecord] })
    }
}

Test-Case 'Wait-LabSshSession: a stale known_hosts key warns with the literal ssh-keygen -R command and keeps polling, so the SAME run recovers once it is cleared' {
    Invoke-WithFakeOpenSshEnvironment {
        [IO.File]::WriteAllText($script:FakeRealKnownHosts, "192.168.1.77 ssh-ed25519 AAAASTALEKEY`n")
        $script:FakeHostKeys['192.168.1.77'] = 'ssh-ed25519 AAAANEWVMKEY'
        $script:ProbeCallIndex = 0
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('192.168.1.77') }
        function ssh.exe {
            $script:ProbeCallIndex++
            Invoke-FakeOpenSshHostKeyCheck $args
            # The operator runs 'ssh-keygen -R 192.168.1.77' from another window after the 2nd refusal.
            if ($script:ProbeCallIndex -eq 2) { [IO.File]::WriteAllText($script:FakeRealKnownHosts, '') }
        }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        $split = Split-FakeWarningOutput @(Wait-LabSshSession $script:FakeId 'labuser' 600 3>&1 6>$null)
        Assert-Equal $split.Results.Count 1
        Assert-Equal $split.Results[0].Address '192.168.1.77'
        Assert-Equal $split.Results[0].HostKey 'ssh-ed25519 AAAANEWVMKEY'
        Assert-Equal $script:ProbeArgsSeen.Count 3
        Assert-Equal ($script:SleepCalls -ge 2) $true
        # One warning for the address, however many refused attempts, naming the runnable command.
        Assert-Equal $split.Warnings.Count 1
        if (-not $split.Warnings[0].Contains('ssh-keygen -R 192.168.1.77')) { throw "Warning lacks the command: $($split.Warnings[0])" }
        if ($split.Warnings[0] -match 'option U') { throw "Warning still points at option U: $($split.Warnings[0])" }
        Assert-Equal ([IO.File]::ReadAllText($script:FakeRealKnownHosts)) "192.168.1.77 ssh-ed25519 AAAANEWVMKEY`n"
    }
}
Test-Case 'Wait-LabSshSession: a stale key that is never cleared times out with the ssh-keygen -R command in the error' {
    Invoke-WithFakeOpenSshEnvironment {
        $before = "192.168.1.77 ssh-ed25519 AAAASTALEKEY`n"
        [IO.File]::WriteAllText($script:FakeRealKnownHosts, $before)
        $script:FakeHostKeys['192.168.1.77'] = 'ssh-ed25519 AAAANEWVMKEY'
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('192.168.1.77') }
        function ssh.exe { Invoke-FakeOpenSshHostKeyCheck $args }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        Assert-Throws { Wait-LabSshSession $script:FakeId 'labuser' 1 3>$null 6>$null } 'Timed out.*DIFFERENT host key for 192\.168\.1\.77.*ssh-keygen -R 192\.168\.1\.77'
        Assert-Equal ($script:ProbeArgsSeen.Count -ge 2) $true
        Assert-Equal ([IO.File]::ReadAllText($script:FakeRealKnownHosts)) $before
    }
}
Test-Case 'Wait-LabSshSession pinned, SAME address: the strict pin check and the existing trust both pass; nothing new is trusted or written' {
    Invoke-WithFakeOpenSshEnvironment {
        $before = "172.20.0.11 ssh-ed25519 AAAAVMKEYA`n"
        [IO.File]::WriteAllText($script:FakeRealKnownHosts, $before)
        $script:FakeHostKeys['172.20.0.11'] = 'ssh-ed25519 AAAAVMKEYA'
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('172.20.0.11') }
        function ssh.exe { Invoke-FakeOpenSshHostKeyCheck $args }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        $login = Wait-LabSshSession $script:FakeId 'labuser' 60 -PinnedHostKey 'ssh-ed25519 AAAAVMKEYA' 6>$null
        Assert-Equal $login.Address '172.20.0.11'
        Assert-Equal $login.HostKey 'ssh-ed25519 AAAAVMKEYA'
        Assert-Equal $script:AcceptNewWrites 0
        Assert-Equal ([IO.File]::ReadAllText($script:FakeRealKnownHosts)) $before
        Assert-Equal $script:ProbeArgsSeen.Count 2
        # Probe 1 is the pin check: strict, and its only known_hosts files are the pin file.
        $pinCheck = $script:ProbeArgsSeen[0]
        Assert-Equal ($pinCheck -contains 'StrictHostKeyChecking=yes') $true
        Assert-Equal ($pinCheck -contains 'StrictHostKeyChecking=accept-new') $false
        $pinFiles = @(Get-FakeSshKnownHostsFiles $pinCheck)
        Assert-Equal $pinFiles.Count 1
        Assert-Equal ($pinFiles[0] -ne $script:FakeRealKnownHosts) $true
        Assert-Equal (Resolve-FakeSshOptionPath (Get-FakeSshOptionValue $pinCheck 'GlobalKnownHostsFile')) $pinFiles[0]
        Assert-Equal ([IO.File]::Exists($pinFiles[0])) $false
        Assert-Equal ($pinCheck -contains 'IdentitiesOnly=yes') $true
        $i = [array]::IndexOf($pinCheck, '-i'); Assert-Equal $pinCheck[$i + 1] $script:FakeKeyPath
    }
}
Test-Case 'Wait-LabSshSession pinned, DIFFERENT address, SAME key: passes via the pin and commits that same key for the new address' {
    Invoke-WithFakeOpenSshEnvironment {
        $before = "172.20.0.11 ssh-ed25519 AAAAVMKEYA`n"
        [IO.File]::WriteAllText($script:FakeRealKnownHosts, $before)
        $script:FakeHostKeys['172.20.0.12'] = 'ssh-ed25519 AAAAVMKEYA'
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('172.20.0.12') }
        function ssh.exe { Invoke-FakeOpenSshHostKeyCheck $args }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        $login = Wait-LabSshSession $script:FakeId 'labuser' 60 -PinnedHostKey 'ssh-ed25519 AAAAVMKEYA' 6>$null
        Assert-Equal $login.Address '172.20.0.12'
        Assert-Equal $login.HostKey 'ssh-ed25519 AAAAVMKEYA'
        Assert-Equal ($script:ProbeArgsSeen[0] -contains 'StrictHostKeyChecking=yes') $true
        Assert-Equal ([IO.File]::ReadAllText($script:FakeRealKnownHosts)) ($before + "172.20.0.12 ssh-ed25519 AAAAVMKEYA`n")
    }
}
Test-Case 'Wait-LabSshSession pinned, DIFFERENT address, DIFFERENT key: refused on every attempt, never trusted, never recorded' {
    Invoke-WithFakeOpenSshEnvironment {
        $before = "172.20.0.11 ssh-ed25519 AAAAVMKEYA`n"
        [IO.File]::WriteAllText($script:FakeRealKnownHosts, $before)
        $script:FakeHostKeys['172.20.0.12'] = 'ssh-ed25519 AAAAIMPOSTORKEY'
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('172.20.0.12') }
        function ssh.exe { Invoke-FakeOpenSshHostKeyCheck $args }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        Assert-Throws { Wait-LabSshSession $script:FakeId 'labuser' 1 -PinnedHostKey 'ssh-ed25519 AAAAVMKEYA' 6>$null } 'Timed out.*did not present the host key this VM proved at its first SSH login'
        Assert-Equal ($script:ProbeArgsSeen.Count -ge 1) $true
        # Only pin checks ever ran: the accept-new probe was never reached for the impostor's key.
        foreach ($seen in $script:ProbeArgsSeen) {
            Assert-Equal ($seen -contains 'StrictHostKeyChecking=yes') $true
            Assert-Equal ($seen -contains 'StrictHostKeyChecking=accept-new') $false
        }
        Assert-Equal $script:AcceptNewWrites 0
        Assert-Equal ([IO.File]::ReadAllText($script:FakeRealKnownHosts)) $before
    }
}
Test-Case 'Wait-LabSshSession pinned: a stale DIFFERENT key already in known_hosts for the new address is not trusted alongside the pin' {
    Invoke-WithFakeOpenSshEnvironment {
        # The new address's stale entry must keep blocking the commit (ssh-keygen -R guidance), so the
        # real file never ends up trusting BOTH the stale key and the VM's key for that address.
        $before = "172.20.0.11 ssh-ed25519 AAAAVMKEYA`n172.20.0.12 ssh-ed25519 AAAASTALEKEY`n"
        [IO.File]::WriteAllText($script:FakeRealKnownHosts, $before)
        $script:FakeHostKeys['172.20.0.12'] = 'ssh-ed25519 AAAAVMKEYA'
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('172.20.0.12') }
        function ssh.exe { Invoke-FakeOpenSshHostKeyCheck $args }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        Assert-Throws { Wait-LabSshSession $script:FakeId 'labuser' 1 -PinnedHostKey 'ssh-ed25519 AAAAVMKEYA' 3>$null 6>$null } 'Timed out.*ssh-keygen -R 172\.20\.0\.12'
        Assert-Equal ([IO.File]::ReadAllText($script:FakeRealKnownHosts)) $before
    }
}
Test-Case 'Wait-LabSshSession refuses a malformed -PinnedHostKey before any probe' {
    Invoke-WithFakeOpenSshEnvironment {
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('172.20.0.12') }
        function ssh.exe { Invoke-FakeOpenSshHostKeyCheck $args }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        foreach ($bad in @('ssh-ed25519', "ssh-ed25519 AAAAKEY`n* ssh-ed25519 AAAAOTHER", '@cert-authority * ssh-ed25519 AAAA', 'ssh-ed25519 AAAAKEY comment')) {
            Assert-Throws { Wait-LabSshSession $script:FakeId 'labuser' 60 -PinnedHostKey $bad 6>$null } 'Invalid pinned host key'
        }
        Assert-Equal $script:ProbeArgsSeen.Count 0
    }
}
Test-Case 'Wait-LabSshSession refuses to start without this VM''s own ephemeral key file' {
    Invoke-WithFakeSshWaitEnvironment {
        [IO.File]::Delete($script:FakeKeyPath)
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function ssh.exe { $script:ProbeArgsSeen.Add([string[]]@($args)); $global:LASTEXITCODE = 0 }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        Assert-Throws { Wait-LabSshSession $script:FakeId 'labuser' 60 6>$null } 'No ephemeral SSH key'
        Assert-Equal $script:ProbeArgsSeen.Count 0
    }
}
Test-Case 'Wait-LabSshSession times out with a clear message once its own stopwatch runs out' {
    Invoke-WithFakeSshWaitEnvironment {
        function Get-LabSshToolingInfo { [pscustomobject]@{ Available = $true } }
        function Get-LabSshUserKnownHostsPath { $script:FakeRealKnownHosts }
        function Assert-LabVMRunning { param([guid]$VMId) $script:RunningChecks++ }
        function Get-LabGuestAddressCandidates { param([guid]$VMId) return @('192.168.1.77') }
        function ssh.exe { 'Permission denied (publickey).'; $global:LASTEXITCODE = 255 }
        foreach ($sb in (Import-LabRealFunction 'Wait-LabSshSession', 'ConvertTo-LabSshOptionPath')) { . $sb }
        Assert-FakeCommand 'ssh.exe'
        $realWatch = [Diagnostics.Stopwatch]::StartNew()
        # 6>$null discards this fast-spinning fake's per-attempt Write-Host progress lines, same as the
        # Wait-LabPSDirectSession timeout test above.
        Assert-Throws { Wait-LabSshSession $script:FakeId 'labuser' 1 6>$null } 'Timed out.*Last error:.*Permission denied'
        $realElapsedSeconds = $realWatch.Elapsed.TotalSeconds
        Assert-Equal ($realElapsedSeconds -lt 15) $true
        Assert-Equal ($script:SleepCalls -ge 1) $true
    }
}
Test-Case 'ConvertTo-LabSshOptionPath rewrites profile paths as ~/, uses forward slashes, and refuses whitespace elsewhere' {
    & {
        foreach ($sb in (Import-LabRealFunction 'ConvertTo-LabSshOptionPath')) { . $sb }
        $profilePath = [Environment]::GetFolderPath('UserProfile')
        Assert-Equal (ConvertTo-LabSshOptionPath (Join-Path $profilePath '.ssh\known_hosts')) '~/.ssh/known_hosts'
        Assert-Equal (ConvertTo-LabSshOptionPath 'C:\Temp\probe.known_hosts') 'C:/Temp/probe.known_hosts'
        Assert-Throws { ConvertTo-LabSshOptionPath 'D:\has space\probe.known_hosts' } 'whitespace'
        Assert-Throws { ConvertTo-LabSshOptionPath 'D:\quote"d\probe.known_hosts' } 'quote'
    }
}
Test-Case 'Write-LabLinuxProvisioningNote delivers the exact content via a KeyAgent put batch, never relaxing host key checking' {
    & {
        $script:CapturedAuthMode = $null
        $script:CapturedBatchContent = $null
        $script:CapturedLocalContent = $null
        function Invoke-LabSftpCommand {
            param($HostNameOrAddress, $Port, $UserName, $IdentityFilePath, $BatchFilePath, $AuthMode)
            $script:CapturedAuthMode = $AuthMode
            $script:CapturedBatchContent = Get-Content -LiteralPath $BatchFilePath -Raw
            if ($script:CapturedBatchContent -match 'put\s+"([^"]+)"') {
                $script:CapturedLocalContent = Get-Content -LiteralPath $Matches[1] -Raw
            }
            return [pscustomobject]@{ ExitCode = 0; Output = [string[]]@() }
        }
        foreach ($sb in (Import-LabRealFunction 'Write-LabLinuxProvisioningNote')) { . $sb }
        Write-LabLinuxProvisioningNote 'guest.invalid' 'labuser' 'C:\keys\id_eph' 'Provisioning complete. SSH key below.'
        Assert-Equal $script:CapturedAuthMode 'KeyAgent'
        $lines = @($script:CapturedBatchContent -split "`n" | Where-Object { $_ })
        Assert-Equal $lines.Count 2
        # -mkdir first (the '-' keeps the batch going when Desktop already exists), then the put.
        Assert-Equal $lines[0] '-mkdir Desktop'
        Assert-Equal ($lines[1] -match '^put\s+"([^"]+)"\s+"Desktop/lab-vm-manager-provisioning-note\.txt"$') $true
        # sftp's batch parser treats '\' as an escape: the local path uses forward slashes only.
        Assert-Equal ($lines[1].Contains('\')) $false
        Assert-Equal $script:CapturedLocalContent 'Provisioning complete. SSH key below.'
    }
}

Test-Case 'Menu copy from an SFTP VM asks for the source type and never opens PowerShell Direct' {
    & {
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        foreach ($a in @('/home/dev/g.txt', 'C:\labxfer-test\g.txt', 'N', '', '')) { $script:Answers.Enqueue($a) }
        $script:TransferArgs = $null
        function Read-LabText { param([string]$Prompt) if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:Answers.Dequeue() }
        function Read-LabYesNoCancel { param([string]$Prompt) return 'N' }
        function Confirm-LabText { param([string]$Expected) return $true }
        function Get-LabTransferAdapterKind { param([guid]$VMId) return 'SFTP' }
        function Get-LabSshConnectionSettings { param([guid]$VMId) [pscustomobject]@{ HostNameOrAddress = 'guest.invalid'; Port = 22; UserName = 'labuser'; IdentityFilePath = '' } }
        function Resolve-LabWindowsCredential { throw 'TRIPWIRE: Windows credentials requested for an SFTP VM.' }
        function New-LabPSDirectSession { throw 'TRIPWIRE: PowerShell Direct session opened for an SFTP VM.' }
        function Invoke-LabFileTransfer {
            param($VMId, $Direction, $SourcePath, $DestinationPath, $Recurse, $OnConflict, $VerifyHash, $DryRun, $Credential, $NonInteractive, $PermissionProfile)
            $script:TransferArgs = [pscustomobject]@{ Direction = $Direction; Recurse = $Recurse; Credential = $Credential }
            return [pscustomobject]@{ Completed = 1; Skipped = 0; Failed = 0; BytesTransferred = [long]10; Errors = [string[]]@() }
        }
        foreach ($sb in (Import-LabRealFunction 'Copy-LabVMItemInteractive')) { . $sb }
        $script:FakeVM.State = 'Running'
        try { $status = Copy-LabVMItemInteractive $script:FakeId 'FromVM' 6>$null | Select-Object -Last 1 }
        finally { $script:FakeVM.State = 'Off' }
        Assert-Equal $status 'COMPLETED'
        Assert-Equal $script:Answers.Count 0
        Assert-Equal $script:TransferArgs.Direction 'FromVM'
        Assert-Equal $script:TransferArgs.Recurse $false
        Assert-Equal $script:TransferArgs.Credential $null
    }
}
Test-Case 'Menu copy from a PSDirect VM still inspects the source over PowerShell Direct' {
    & {
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        foreach ($a in @('C:\Users\dev\g.txt', 'C:\labxfer-test\out', '', '')) { $script:Answers.Enqueue($a) }
        $script:ProbeSessions = 0
        function Read-LabText { param([string]$Prompt) if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:Answers.Dequeue() }
        function Read-LabYesNoCancel { param([string]$Prompt) return 'N' }
        function Confirm-LabText { param([string]$Expected) return $true }
        function Get-LabTransferAdapterKind { param([guid]$VMId) return 'PSDirect' }
        function Resolve-LabWindowsCredential { param($Credential, [bool]$NonInteractive) return 'fake-credential' }
        function New-LabPSDirectSession { param($VMId, $Credential) $script:ProbeSessions++; return [pscustomobject]@{ State = 'Opened' } }
        function Remove-PSSession { param($Session) }
        function Invoke-LabTransferSide { param($Session, [bool]$Remote, [scriptblock]$ScriptBlock, [object[]]$ArgumentList) return $false }
        function Invoke-LabFileTransfer {
            param($VMId, $Direction, $SourcePath, $DestinationPath, $Recurse, $OnConflict, $VerifyHash, $DryRun, $Credential, $NonInteractive, $PermissionProfile)
            $script:TransferCredential = $Credential
            return [pscustomobject]@{ Completed = 1; Skipped = 0; Failed = 0; BytesTransferred = [long]10; Errors = [string[]]@() }
        }
        foreach ($sb in (Import-LabRealFunction 'Copy-LabVMItemInteractive')) { . $sb }
        $script:FakeVM.State = 'Running'
        try { $status = Copy-LabVMItemInteractive $script:FakeId 'FromVM' 6>$null | Select-Object -Last 1 }
        finally { $script:FakeVM.State = 'Off' }
        Assert-Equal $status 'COMPLETED'
        Assert-Equal $script:ProbeSessions 1
        Assert-Equal $script:TransferCredential 'fake-credential'
    }
}
Test-Case 'SSH configuration CLI: an option-like host or user is refused before any host check or write' {
    & {
        function Set-LabSshConnectionSettings { throw 'TRIPWIRE: settings written for an invalid value.' }
        function Assert-LabHost { throw 'TRIPWIRE: host checks reached for an invalid value.' }
        foreach ($sb in (Import-LabRealFunction 'Start-LabSshConfigurationCli')) { . $sb }
        Assert-Throws { Start-LabSshConfigurationCli -VMName 'LAB-Test' -VMId $null -SshHost '-oProxyCommand=calc' -SshPort 22 -SshUser 'dev' -SshIdentityFile '' -RequestedLogRoot '' } 'Invalid -SshHost'
        Assert-Throws { Start-LabSshConfigurationCli -VMName 'LAB-Test' -VMId $null -SshHost '10.0.0.5' -SshPort 22 -SshUser '-oProxyCommand=calc' -SshIdentityFile '' -RequestedLogRoot '' } 'Invalid -SshUser'
        Assert-Throws { Start-LabSshConfigurationCli -VMName 'LAB-Test' -VMId $null -SshHost '10.0.0.5' -SshPort 0 -SshUser 'dev' -SshIdentityFile '' -RequestedLogRoot '' } 'Invalid -SshPort'
    }
}
Test-Case 'Gate: the real script rejects an out-of-range -SshPort at parameter binding' {
    # Parameter binding fails before the script body runs: no host check, log, settings write or SSH call.
    $ErrorActionPreference = 'Continue'
    $exe = Join-Path $PSHOME 'powershell.exe'
    $output = @(& $exe -NoProfile -NonInteractive -File $resolved -ConfigureSsh -VMName 'LAB-x' -SshHost '10.0.0.5' -SshUser 'dev' -SshPort 70000 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    if ($LASTEXITCODE -eq 0) { throw "Expected a non-zero exit code: $output" }
    if (-not ($output -replace '\s', '').Contains('SshPort')) { throw "Unexpected output: $output" }
}

Test-Case 'Select-LabIsoPath lists candidates and returns the exact chosen path' {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('labiso-select-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $dir1 = Join-Path $tempRoot 'dir1'
    $dir2 = Join-Path $tempRoot 'dir2'
    [void][IO.Directory]::CreateDirectory($dir1)
    [void][IO.Directory]::CreateDirectory($dir2)
    # Same filename in two different folders -- selection must resolve by index/FullName, not by name.
    $path1 = Join-Path $dir1 'same.iso'
    $path2 = Join-Path $dir2 'same.iso'
    try {
        [IO.File]::WriteAllBytes($path1, [byte[]]@(1, 2, 3))
        [IO.File]::WriteAllBytes($path2, [byte[]]@(4, 5, 6, 7))
        & {
            $script:FakeIsoScan = [pscustomobject]@{
                Files     = @(
                    [pscustomobject]@{ FullName = $path1; Length = (Get-Item -LiteralPath $path1).Length; LastWriteTime = (Get-Item -LiteralPath $path1).LastWriteTime }
                    [pscustomobject]@{ FullName = $path2; Length = (Get-Item -LiteralPath $path2).Length; LastWriteTime = (Get-Item -LiteralPath $path2).LastWriteTime }
                )
                Incomplete = $false
                Errors     = @()
            }
            function Get-LabIsoCandidates { param([string]$IsoRoot) return $script:FakeIsoScan }
            $script:IsoAnswers = [Collections.Generic.Queue[string]]::new([string[]]@('2'))
            function Read-LabText { param([string]$Prompt) return $script:IsoAnswers.Dequeue() }
            foreach ($sb in (Import-LabRealFunction 'Select-LabIsoPath')) { . $sb }
            $result = Select-LabIsoPath $tempRoot
            Assert-Equal $result $path2
        }
    } finally {
        if ([IO.Directory]::Exists($tempRoot)) { [IO.Directory]::Delete($tempRoot, $true) }
    }
}
Test-Case 'Select-LabIsoPath re-validates and rejects a path that no longer exists' {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('labiso-missing-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    # $tempRoot is never created on disk -- the candidate's FullName does not exist.
    $missingPath = Join-Path $tempRoot 'ghost.iso'
    & {
        $script:FakeIsoScan = [pscustomobject]@{
            Files     = @([pscustomobject]@{ FullName = $missingPath; Length = [long]123; LastWriteTime = (Get-Date) })
            Incomplete = $false
            Errors     = @()
        }
        function Get-LabIsoCandidates { param([string]$IsoRoot) return $script:FakeIsoScan }
        # Picks the (nonexistent) candidate first, then cancels once rejected, so the test ends cleanly.
        $script:IsoAnswers = [Collections.Generic.Queue[string]]::new([string[]]@('1', 'B'))
        function Read-LabText { param([string]$Prompt) return $script:IsoAnswers.Dequeue() }
        foreach ($sb in (Import-LabRealFunction 'Select-LabIsoPath')) { . $sb }
        $result = Select-LabIsoPath $tempRoot
        Assert-Equal $result $null
    }
}

Test-Case 'Select-LabIsoPath filter always matches the full scan, not the previously narrowed view' {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('labiso-refilter-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $winPath1 = Join-Path $tempRoot 'windows-2022.iso'
    $winPath2 = Join-Path $tempRoot 'windows-2019.iso'
    $linuxPath = Join-Path $tempRoot 'linux-ubuntu.iso'
    try {
        [IO.File]::WriteAllBytes($winPath1, [byte[]]@(1, 2, 3))
        [IO.File]::WriteAllBytes($winPath2, [byte[]]@(1, 2, 3, 4))
        [IO.File]::WriteAllBytes($linuxPath, [byte[]]@(1, 2, 3, 4, 5))
        & {
            $script:FakeIsoScan = [pscustomobject]@{
                Files     = @(
                    [pscustomobject]@{ FullName = $winPath1; Length = (Get-Item -LiteralPath $winPath1).Length; LastWriteTime = (Get-Item -LiteralPath $winPath1).LastWriteTime }
                    [pscustomobject]@{ FullName = $winPath2; Length = (Get-Item -LiteralPath $winPath2).Length; LastWriteTime = (Get-Item -LiteralPath $winPath2).LastWriteTime }
                    [pscustomobject]@{ FullName = $linuxPath; Length = (Get-Item -LiteralPath $linuxPath).Length; LastWriteTime = (Get-Item -LiteralPath $linuxPath).LastWriteTime }
                )
                Incomplete = $false
                Errors     = @()
            }
            function Get-LabIsoCandidates { param([string]$IsoRoot) return $script:FakeIsoScan }
            # 'windows' narrows the full 3-item scan down to the two Windows ISOs (linux-ubuntu.iso is
            # filtered out of the view). 'linux' is then typed as a second, DIFFERENT filter: if the
            # filter wrongly matched against the already-narrowed 2-item view (the bug), this would find
            # nothing and leave the Windows-only view in place, so '1' would then wrongly select
            # windows-2022.iso. With the fix, 'linux' matches against the full retained scan and narrows
            # to linux-ubuntu.iso, so '1' selects it.
            $script:IsoAnswers = [Collections.Generic.Queue[string]]::new([string[]]@('windows', 'linux', '1'))
            function Read-LabText { param([string]$Prompt) return $script:IsoAnswers.Dequeue() }
            foreach ($sb in (Import-LabRealFunction 'Select-LabIsoPath')) { . $sb }
            $result = Select-LabIsoPath $tempRoot
            Assert-Equal $result $linuxPath
        }
    } finally {
        if ([IO.Directory]::Exists($tempRoot)) { [IO.Directory]::Delete($tempRoot, $true) }
    }
}

# --- Installation media menu action (Task 6) ---
# Read-side fakes the preview/inspect need. No real Hyper-V cmdlet is invoked. Every mutating Hyper-V
# cmdlet the apply step can reach is one of the counting fakes above, so "nothing changed" is checked by
# summing their counters rather than trusting the code under test.
$script:FakeSnapshots = @()
$script:FakeHardDisks = @()
$script:FakeVhdParents = @{}
$script:FakeTpmEnabled = $false
function Get-VMSnapshot { [CmdletBinding()] param($VM) return @($script:FakeSnapshots) }
function Get-VMHardDiskDrive { [CmdletBinding()] param($VM) return @($script:FakeHardDisks) }
function Get-VHD {
    [CmdletBinding()]
    param([string]$Path)
    return [pscustomobject]@{ Path = $Path; ParentPath = $script:FakeVhdParents[$Path] }
}
function Get-VMSecurity { [CmdletBinding()] param($VM) return [pscustomobject]@{ TpmEnabled = $script:FakeTpmEnabled } }
function Get-LabMutationCount {
    return $script:SetVMFirmwareCalls.Count + $script:SetVMFirmwareSecureBootCalls.Count + $script:SetVMFirmwareBootOrderCalls.Count +
        $script:SetVMKeyProtectorCalls + $script:EnableVMTPMCalls + $script:AddVMDvdDriveCalls + $script:SetVMDvdDriveCalls.Count
}
function Reset-LabMediaFakes {
    $script:FakeVM.State = 'Off'; $script:FakeVM.Generation = 2; $script:FakeVM.Name = 'LAB-Test'
    $script:FakeHasKeyProtector = $false
    $script:FakeKeyProtectorBytes = $null
    $script:FakeKeyProtectorThrows = $false
    $script:FakeTpmEnabled = $false
    $script:FakeFirmware.SecureBoot = 'On'
    $script:FakeFirmware.SecureBootTemplate = 'MicrosoftUEFICertificateAuthority'
    $script:FakeFirmware.BootOrder = @((New-FakeBootEntry 'Disk'), (New-FakeBootEntry 'Dvd'))
    $script:FakeDvdDrives.Clear()
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = $null })
    $script:FakeSnapshots = @()
    $script:FakeHardDisks = @()
    $script:FakeVhdParents = @{}
    $script:SetVMFirmwareCalls.Clear(); $script:SetVMFirmwareSecureBootCalls.Clear(); $script:SetVMFirmwareBootOrderCalls.Clear()
    $script:SetVMKeyProtectorCalls = 0; $script:EnableVMTPMCalls = 0
    $script:AddVMDvdDriveCalls = 0; $script:SetVMDvdDriveCalls.Clear()
    $script:AuditRecords.Clear()
    $script:LabReadOnly = $false
}
function New-LabMediaTempDir {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('labmedia-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($dir)
    return $dir
}
$script:LabIsoRoot = 'C:\labmedia-test-iso-root'

Test-Case 'Boot entry kind: the real VMBootSource{Device=DvdDrive/HardDiskDrive} shape is classified by its Device' {
    Assert-Equal (Get-LabBootEntryKind (New-FakeBootEntry 'Dvd')) 'Dvd'
    Assert-Equal (Get-LabBootEntryKind (New-FakeBootEntry 'Disk')) 'Disk'
    Assert-Equal (Get-LabBootEntryKind (New-FakeBootEntry 'Nic')) 'Other'
    # The wrapper's own type name must never be what decides it.
    Assert-Equal (Get-LabBootEntryKind ([VMBootSource]::new('File', $null))) 'Other'
}
Test-Case 'Boot entry kind: backward compatibility with bare and VM-prefixed devices' {
    Assert-Equal (Get-LabBootEntryKind ([pscustomobject]@{ BootType = 'Drive'; Device = [VMDvdDrive]::new() })) 'Dvd'
    Assert-Equal (Get-LabBootEntryKind ([pscustomobject]@{ BootType = 'Drive'; Device = [VMHardDiskDrive]::new() })) 'Disk'
    Assert-Equal (Get-LabBootEntryKind ([VMDvdDrive]::new())) 'Dvd'
    Assert-Equal (Get-LabBootEntryKind ([DvdDrive]::new())) 'Dvd'
}
Test-Case 'Set-LabVMBootOrder reorders wrapper entries and passes the original wrappers back' {
    Reset-LabMediaFakes
    $nic = [pscustomobject]@{ BootType = 'Network'; Device = [VMNetworkAdapter]::new() }
    $hdd = [pscustomobject]@{ BootType = 'Drive'; Device = [HardDiskDrive]::new() }
    $dvd = [pscustomobject]@{ BootType = 'Drive'; Device = [DvdDrive]::new() }
    $script:FakeFirmware.BootOrder = @($nic, $hdd, $dvd)
    Set-LabVMBootOrder $script:FakeId 'Dvd'
    $applied = @($script:SetVMFirmwareBootOrderCalls[-1])
    Assert-Equal $applied.Count 3
    Assert-Equal ([object]::ReferenceEquals($applied[0], $dvd)) $true
    Assert-Equal ([object]::ReferenceEquals($applied[1], $nic)) $true
    Assert-Equal ([object]::ReferenceEquals($applied[2], $hdd)) $true
}
Test-Case 'Set-LabVMBootOrder fails loudly, without writing, when no matching entry is recognized' {
    Reset-LabMediaFakes
    $script:FakeFirmware.BootOrder = @((New-FakeBootEntry 'Disk'), (New-FakeBootEntry 'Nic'))
    Assert-Throws { Set-LabVMBootOrder $script:FakeId 'Dvd' } 'no Dvd entry was recognized'
    Assert-Equal $script:SetVMFirmwareBootOrderCalls.Count 0
}
Test-Case 'Media preview: Secure Boot Off is shown as Off -> On, never as "already matches"' {
    Reset-LabMediaFakes
    $script:FakeFirmware.SecureBoot = 'Off'
    $preview = Get-LabVMInstallationMediaPreview $script:FakeId 'UbuntuDesktop' 'C:\x.iso'
    Assert-Equal $preview.SecureBootState 'Off'
    Assert-Equal $preview.BootProfileChanges.Count 1
    Assert-Equal $preview.BootProfileChanges[0] 'Secure Boot: Off -> On.'
    Assert-Equal (Get-LabMutationCount) 0
    $script:FakeFirmware.SecureBoot = 'On'
    $preview = Get-LabVMInstallationMediaPreview $script:FakeId 'UbuntuDesktop' 'C:\x.iso'
    Assert-Equal $preview.BootProfileChanges.Count 0
}
Test-Case 'Media preview: one DVD drive with no recognizable boot entry is detected up front, read-only' {
    Reset-LabMediaFakes
    $script:FakeFirmware.BootOrder = @((New-FakeBootEntry 'Disk'), (New-FakeBootEntry 'Nic'))
    $preview = Get-LabVMInstallationMediaPreview $script:FakeId 'UbuntuDesktop' 'C:\x.iso'
    Assert-Equal $preview.DvdDriveCount 1
    Assert-Equal $preview.DvdBootEntryRecognized $false
    Reset-LabMediaFakes
    $preview = Get-LabVMInstallationMediaPreview $script:FakeId 'UbuntuDesktop' 'C:\x.iso'
    Assert-Equal $preview.DvdBootEntryRecognized $true
    # No drive yet: the entry cannot exist, so it is not pre-judged; the plan says when it is checked.
    $script:FakeDvdDrives.Clear()
    $preview = Get-LabVMInstallationMediaPreview $script:FakeId 'UbuntuDesktop' 'C:\x.iso'
    Assert-Equal $preview.DvdBootEntryRecognized $null
    Assert-Equal ($preview.DvdPlan -match 'verified at the last step') $true
    Assert-Equal (Get-LabMutationCount) 0
}
Test-Case 'Media attach: one DVD drive without a recognizable boot entry is refused before any change' {
    Reset-LabMediaFakes
    $script:FakeFirmware.SecureBoot = 'Off'
    $script:FakeFirmware.BootOrder = @((New-FakeBootEntry 'Disk'), (New-FakeBootEntry 'Nic'))
    & {
        $script:Answers = [Collections.Generic.Queue[string]]::new([string[]]@('A', '1'))
        function Read-LabText { param([string]$Prompt) if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:Answers.Dequeue() }
        function Select-LabIsoPath { param([string]$IsoRoot) return 'C:\labmedia-test\win.iso' }
        function Read-LabYesNoCancel { throw 'TRIPWIRE: confirmation requested although the DVD entry is unrecognizable.' }
        foreach ($sb in (Import-LabRealFunction 'Set-LabVMInstallationMediaInteractive')) { . $sb }
        $out = @(Set-LabVMInstallationMediaInteractive $script:FakeId 6>$null 3>$null)
        Assert-Equal $out.Count 1
        Assert-Equal $out[0] 'CANCELLED'
    }
    Assert-Equal (Get-LabMutationCount) 0
    Assert-Equal $script:FakeHasKeyProtector $false
    Assert-Equal $script:FakeFirmware.SecureBoot 'Off'
    Assert-Equal $script:AuditRecords.Count 0
}
Test-Case 'Media inspect: a Get-VMKeyProtector read failure is reported, not fatal, and the boot order still prints' {
    Reset-LabMediaFakes
    $script:FakeKeyProtectorThrows = $true
    $savedLocal = $env:LOCALAPPDATA
    $dir = New-LabMediaTempDir
    try {
        $env:LOCALAPPDATA = $dir
        $text = @(Show-LabVMInstallMediaConfiguration $script:FakeId 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        Assert-Equal ($text -match 'Key protector configured: unknown') $true
        Assert-Equal ($text -match 'Firmware boot order') $true
        Assert-Equal ($text -match 'Dvd \[DvdDrive\]') $true
        Assert-Equal (Get-LabMutationCount) 0
    } finally {
        $script:FakeKeyProtectorThrows = $false
        $env:LOCALAPPDATA = $savedLocal
        [IO.Directory]::Delete($dir, $true)
    }
}
Test-Case 'Media preview: existing key protector and a checkpoint are reported without any mutation' {
    Reset-LabMediaFakes
    $script:FakeHasKeyProtector = $true
    $script:FakeSnapshots = @([pscustomobject]@{ Name = 'cp1' })
    $preview = Get-LabVMInstallationMediaPreview $script:FakeId 'Windows11' 'C:\x.iso'
    Assert-Equal $preview.HasKeyProtector $true
    Assert-Equal $preview.ExistingDataRisk $true
    Assert-Equal $preview.CheckpointCount 1
    Assert-Equal (Get-LabMutationCount) 0
}
Test-Case 'Media preview: a fresh VM with a tiny VHDX has no data risk and lists the profile changes, still without mutating' {
    Reset-LabMediaFakes
    $dir = New-LabMediaTempDir
    try {
        $vhdx = Join-Path $dir 'fresh.vhdx'
        [IO.File]::WriteAllBytes($vhdx, [byte[]]::new(4096))
        $script:FakeHardDisks = @([pscustomobject]@{ Path = $vhdx; DiskNumber = $null })
        $preview = Get-LabVMInstallationMediaPreview $script:FakeId 'Windows11' 'C:\x.iso'
        Assert-Equal $preview.ExistingDataRisk $false
        Assert-Equal $preview.HasKeyProtector $false
        Assert-Equal $preview.BootProfileChanges.Count 2
        Assert-Equal (Get-LabMutationCount) 0
        # The key-protector check must stay read-only: no protector was created by previewing.
        Assert-Equal $script:FakeHasKeyProtector $false
    } finally { [IO.Directory]::Delete($dir, $true) }
}
Test-Case 'Media preview: a small differencing disk over a large parent counts the real parent size' {
    Reset-LabMediaFakes
    $dir = New-LabMediaTempDir
    try {
        $parent = Join-Path $dir 'parent.vhdx'
        $child = Join-Path $dir 'child.avhdx'
        $fs = [IO.File]::Create($parent); try { $fs.SetLength(300MB) } finally { $fs.Close() }
        [IO.File]::WriteAllBytes($child, [byte[]]::new(4096))
        $script:FakeVhdParents = @{ $child = $parent }
        $script:FakeHardDisks = @([pscustomobject]@{ Path = $child; DiskNumber = $null })
        $preview = Get-LabVMInstallationMediaPreview $script:FakeId 'UbuntuDesktop' 'C:\x.iso'
        Assert-Equal $preview.ExistingDataRisk $true
        Assert-Equal ($preview.ExistingDataReasons[0] -match 'GiB on disk') $true
    } finally { [IO.Directory]::Delete($dir, $true) }
}
Test-Case 'Media preview: a disk that cannot be measured is treated as a data risk, not as empty' {
    Reset-LabMediaFakes
    $script:FakeHardDisks = @([pscustomobject]@{ Path = 'C:\labmedia-missing\gone.vhdx'; DiskNumber = $null })
    $preview = Get-LabVMInstallationMediaPreview $script:FakeId 'UbuntuDesktop' 'C:\x.iso'
    Assert-Equal $preview.ExistingDataRisk $true
    Assert-Equal ($preview.ExistingDataReasons[0] -match 'could not be measured') $true
}
Test-Case 'Media menu under -ReadOnly only inspects: no prompt, no mutation' {
    Reset-LabMediaFakes
    $script:FakeDvdDrives[0].Path = 'E:\ISO\a.iso'
    $savedLocal = $env:LOCALAPPDATA
    $dir = New-LabMediaTempDir
    try {
        $env:LOCALAPPDATA = $dir
        $script:LabReadOnly = $true
        & {
            function Read-LabText { param([string]$Prompt) throw "TRIPWIRE: prompted under -ReadOnly: $Prompt" }
            function Select-LabIsoPath { throw 'TRIPWIRE: ISO selection under -ReadOnly.' }
            foreach ($sb in (Import-LabRealFunction 'Set-LabVMInstallationMediaInteractive')) { . $sb }
            $out = @(Set-LabVMInstallationMediaInteractive $script:FakeId 6>$null 3>$null)
            Assert-Equal $out.Count 1
            Assert-Equal $out[0] 'NO_CHANGE'
        }
        Assert-Equal (Get-LabMutationCount) 0
    } finally {
        $script:LabReadOnly = $false
        $env:LOCALAPPDATA = $savedLocal
        [IO.Directory]::Delete($dir, $true)
    }
}
Test-Case 'Media attach: declining the confirmation leaves the VM untouched (no key protector created by the preview)' {
    Reset-LabMediaFakes
    & {
        $script:Answers = [Collections.Generic.Queue[string]]::new([string[]]@('A', '1'))
        function Read-LabText { param([string]$Prompt) if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:Answers.Dequeue() }
        function Select-LabIsoPath { param([string]$IsoRoot) $script:IsoRootSeen = $IsoRoot; return 'C:\labmedia-test\win.iso' }
        function Read-LabYesNoCancel { param([string]$Prompt) return 'N' }
        function Confirm-LabText { throw 'TRIPWIRE: extra confirmation requested without a data risk.' }
        foreach ($sb in (Import-LabRealFunction 'Set-LabVMInstallationMediaInteractive')) { . $sb }
        $out = @(Set-LabVMInstallationMediaInteractive $script:FakeId 6>$null 3>$null)
        Assert-Equal $out.Count 1
        Assert-Equal $out[0] 'CANCELLED'
        Assert-Equal $script:IsoRootSeen $script:LabIsoRoot
    }
    Assert-Equal (Get-LabMutationCount) 0
    Assert-Equal $script:FakeHasKeyProtector $false
}
Test-Case 'Media attach: existing data needs the typed confirmation; a wrong phrase cancels with no change' {
    Reset-LabMediaFakes
    $script:FakeSnapshots = @([pscustomobject]@{ Name = 'cp1' })
    & {
        $script:Answers = [Collections.Generic.Queue[string]]::new([string[]]@('A', '2'))
        $script:ConfirmPhrase = $null
        function Read-LabText { param([string]$Prompt) if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:Answers.Dequeue() }
        function Select-LabIsoPath { param([string]$IsoRoot) return 'C:\labmedia-test\ubuntu.iso' }
        function Read-LabYesNoCancel { param([string]$Prompt) return 'Y' }
        function Confirm-LabText { param([string]$Expected) $script:ConfirmPhrase = $Expected; return $false }
        foreach ($sb in (Import-LabRealFunction 'Set-LabVMInstallationMediaInteractive')) { . $sb }
        $out = @(Set-LabVMInstallationMediaInteractive $script:FakeId 6>$null 3>$null)
        Assert-Equal $out[0] 'CANCELLED'
        Assert-Equal $script:ConfirmPhrase 'INSTALL OVER LAB-Test'
    }
    Assert-Equal (Get-LabMutationCount) 0
}
Test-Case 'Media attach: a Generation 1 VM is refused before any prompt for profile or ISO' {
    Reset-LabMediaFakes
    $script:FakeVM.Generation = 1
    try {
        & {
            $script:Answers = [Collections.Generic.Queue[string]]::new([string[]]@('A'))
            function Read-LabText { param([string]$Prompt) if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:Answers.Dequeue() }
            function Select-LabIsoPath { throw 'TRIPWIRE: ISO selection for a Generation 1 VM.' }
            foreach ($sb in (Import-LabRealFunction 'Set-LabVMInstallationMediaInteractive')) { . $sb }
            $out = @(Set-LabVMInstallationMediaInteractive $script:FakeId 6>$null 3>$null)
            Assert-Equal $out[0] 'CANCELLED'
        }
        Assert-Equal (Get-LabMutationCount) 0
    } finally { $script:FakeVM.Generation = 2 }
}
Test-Case 'Media attach: after confirmation applies boot profile, then media, then DVD-first boot order' {
    Reset-LabMediaFakes
    & {
        $script:Answers = [Collections.Generic.Queue[string]]::new([string[]]@('A', '1'))
        $script:ApplyLog = [Collections.Generic.List[string]]::new()
        function Read-LabText { param([string]$Prompt) if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:Answers.Dequeue() }
        function Select-LabIsoPath { param([string]$IsoRoot) return 'C:\labmedia-test\win.iso' }
        function Read-LabYesNoCancel { param([string]$Prompt) return 'Y' }
        function Set-LabVMBootProfile { param([guid]$VMId, [string]$OsProfile) $script:ApplyLog.Add("profile:$OsProfile"); [pscustomobject]@{ SecureBootTemplateChanged = $true; SecureBootEnabled = $false; KeyProtectorAdded = $true; TpmEnabled = $true } }
        function Set-LabVMInstallMedia { param([guid]$VMId, [string]$IsoPath) $script:ApplyLog.Add("media:$IsoPath"); [pscustomobject]@{ PreviousAttachment = ''; DvdDriveAdded = $false } }
        function Set-LabVMBootOrder { param([guid]$VMId, [string]$Preference) $script:ApplyLog.Add("order:$Preference") }
        foreach ($sb in (Import-LabRealFunction 'Set-LabVMInstallationMediaInteractive')) { . $sb }
        $out = @(Set-LabVMInstallationMediaInteractive $script:FakeId 6>$null 3>$null)
        Assert-Equal $out.Count 1
        Assert-Equal $out[0] 'COMPLETED'
        Assert-Equal ($script:ApplyLog -join '|') 'profile:Windows11|media:C:\labmedia-test\win.iso|order:Dvd'
    }
}
Test-Case 'Media attach end-to-end through the real apply functions: Windows11 VM ends up configured' {
    Reset-LabMediaFakes
    $dir = New-LabMediaTempDir
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $dir
        $iso = Join-Path $dir 'win.iso'
        [IO.File]::WriteAllBytes($iso, [byte[]]@(1, 2, 3))
        & {
            $script:Answers = [Collections.Generic.Queue[string]]::new([string[]]@('A', '1'))
            $script:TestIso = $iso
            function Read-LabText { param([string]$Prompt) if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:Answers.Dequeue() }
            function Select-LabIsoPath { param([string]$IsoRoot) return $script:TestIso }
            function Read-LabYesNoCancel { param([string]$Prompt) return 'Y' }
            foreach ($sb in (Import-LabRealFunction 'Set-LabVMInstallationMediaInteractive')) { . $sb }
            $out = @(Set-LabVMInstallationMediaInteractive $script:FakeId 6>$null 3>$null)
            Assert-Equal $out[0] 'COMPLETED'
        }
        Assert-Equal $script:FakeFirmware.SecureBootTemplate 'MicrosoftWindows'
        Assert-Equal $script:FakeHasKeyProtector $true
        Assert-Equal $script:EnableVMTPMCalls 1
        Assert-Equal $script:FakeDvdDrives[0].Path $iso
        $first = (@($script:FakeFirmware.BootOrder))[0]
        Assert-Equal ($first -is [VMBootSource]) $true
        Assert-Equal ($first.Device -is [DvdDrive]) $true
        # The security-relevant key-protector creation gets its own audit record, then the full outcome.
        Assert-Equal (@($script:AuditRecords | ForEach-Object { $_.Action }) -join '|') 'add-key-protector|attach-install-media'
        Assert-Equal $script:AuditRecords[0].Status 'COMPLETED'
        Assert-Equal $script:AuditRecords[0].VMId ([string]$script:FakeId)
        Assert-Contains $script:AuditRecords[0].Detail 'NewLocalKeyProtector=True'
        Assert-Contains $script:AuditRecords[0].Detail 'VTpmEnabled=True'
        Assert-Contains $script:AuditRecords[1].Detail 'OsProfile=Windows11'
        Assert-Contains $script:AuditRecords[1].Detail "Iso=$iso"
        Assert-Contains $script:AuditRecords[1].Detail 'KeyProtectorAdded=True'
        Assert-Contains $script:AuditRecords[1].Detail 'SecureBootEnabled=False'
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        [IO.Directory]::Delete($dir, $true)
    }
}
Test-Case 'Media eject: confirmed eject clears the media; nothing attached is NO_CHANGE with no write' {
    Reset-LabMediaFakes
    $script:FakeDvdDrives[0].Path = 'E:\ISO\a.iso'
    & {
        $script:Answers = [Collections.Generic.Queue[string]]::new([string[]]@('E', 'E'))
        function Read-LabText { param([string]$Prompt) if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:Answers.Dequeue() }
        function Read-LabYesNoCancel { param([string]$Prompt) return 'Y' }
        foreach ($sb in (Import-LabRealFunction 'Remove-LabVMInstallMedia', 'Set-LabVMInstallationMediaInteractive')) { . $sb }
        $first = @(Set-LabVMInstallationMediaInteractive $script:FakeId 6>$null 3>$null)
        Assert-Equal $first[0] 'COMPLETED'
        Assert-Equal $script:FakeDvdDrives[0].Path ''
        Assert-Equal $script:SetVMDvdDriveCalls.Count 1
        $second = @(Set-LabVMInstallationMediaInteractive $script:FakeId 6>$null 3>$null)
        Assert-Equal $second[0] 'NO_CHANGE'
        Assert-Equal $script:SetVMDvdDriveCalls.Count 1
    }
    Assert-Equal $script:AuditRecords.Count 1
    Assert-Equal $script:AuditRecords[0].Action 'eject-install-media'
    Assert-Contains $script:AuditRecords[0].Detail 'Ejected=E:\ISO\a.iso'
}
Test-Case 'Media attach: Ubuntu on a VM with Secure Boot Off turns it on and audits without a key-protector record' {
    Reset-LabMediaFakes
    $script:FakeFirmware.SecureBoot = 'Off'
    $dir = New-LabMediaTempDir
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $dir
        $iso = Join-Path $dir 'ubuntu.iso'
        [IO.File]::WriteAllBytes($iso, [byte[]]@(1, 2, 3))
        & {
            $script:Answers = [Collections.Generic.Queue[string]]::new([string[]]@('A', '2'))
            $script:TestIso = $iso
            function Read-LabText { param([string]$Prompt) if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:Answers.Dequeue() }
            function Select-LabIsoPath { param([string]$IsoRoot) return $script:TestIso }
            function Read-LabYesNoCancel { param([string]$Prompt) return 'Y' }
            foreach ($sb in (Import-LabRealFunction 'Set-LabVMInstallationMediaInteractive')) { . $sb }
            $out = @(Set-LabVMInstallationMediaInteractive $script:FakeId 6>$null 3>$null)
            Assert-Equal $out[0] 'COMPLETED'
        }
        Assert-Equal $script:FakeFirmware.SecureBoot 'On'
        Assert-Equal $script:SetVMKeyProtectorCalls 0
        Assert-Equal $script:EnableVMTPMCalls 0
        Assert-Equal (@($script:AuditRecords | ForEach-Object { $_.Action }) -join '|') 'attach-install-media'
        Assert-Contains $script:AuditRecords[0].Detail 'SecureBootEnabled=True'
        Assert-Contains $script:AuditRecords[0].Detail 'KeyProtectorAdded=False'
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        [IO.Directory]::Delete($dir, $true)
    }
}
Reset-LabMediaFakes
$script:FakeDvdDrives.Clear()

# --- New-LabSeedIso $Files contract (final-review fix) ---
# The real function drives the IMAPI2FS COM object; here New-Object and Write-LabIStreamToFile are
# replaced in a child scope, so no COM object is created and nothing is written but the function's own
# staging directory under %TEMP%. The fake image records exactly what was staged, byte for byte.
function Invoke-LabSeedIsoWithFakeImage {
    param([hashtable]$Files)
    $script:SeedComCreated = 0
    $script:SeedStaged = @{}
    $script:SeedStagingDir = $null
    & {
        function New-Object {
            [CmdletBinding()]
            param([string]$ComObject)
            $script:SeedComCreated++
            $root = [pscustomobject]@{}
            $root | Add-Member -MemberType ScriptMethod -Name AddTree -Value {
                param([string]$Path, [bool]$IncludeBaseDirectory)
                $script:SeedStagingDir = $Path
                $prefix = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
                foreach ($file in [IO.Directory]::GetFiles($Path, '*', 'AllDirectories')) {
                    $script:SeedStaged[$file.Substring($prefix.Length)] = [IO.File]::ReadAllBytes($file)
                }
            }
            $image = [pscustomobject]@{ VolumeName = $null; FileSystemsToCreate = $null; Root = $root }
            $image | Add-Member -MemberType ScriptMethod -Name CreateResultImage -Value { [pscustomobject]@{ ImageStream = 'fake-stream' } }
            return $image
        }
        function Write-LabIStreamToFile { param($Stream, [string]$Path) }
        foreach ($sb in (Import-LabRealFunction 'New-LabSeedIso')) { . $sb }
        New-LabSeedIso -Files $Files -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'labseed-fake-output.iso')
    }
}
Test-Case 'New-LabSeedIso: a plain string is always literal content, even when it names an existing file' {
    $dir = New-LabMediaTempDir
    try {
        $existing = Join-Path $dir 'real-answer.xml'
        [IO.File]::WriteAllText($existing, '<real/>')
        Invoke-LabSeedIsoWithFakeImage @{ 'Autounattend.xml' = $existing; 'sub/dir/note.txt' = 'hello' }
        Assert-Equal $script:SeedComCreated 1
        Assert-Equal ([Text.Encoding]::UTF8.GetString($script:SeedStaged['Autounattend.xml'])) $existing
        Assert-Equal ([Text.Encoding]::UTF8.GetString($script:SeedStaged['sub\dir\note.txt'])) 'hello'
        Assert-Equal ([IO.Directory]::Exists($script:SeedStagingDir)) $false
    } finally { [IO.Directory]::Delete($dir, $true) }
}
Test-Case 'New-LabSeedIso: @{ SourcePath } copies the file byte for byte' {
    $dir = New-LabMediaTempDir
    try {
        $source = Join-Path $dir 'user-data'
        $bytes = [byte[]]@(35, 99, 108, 111, 117, 100, 13, 10, 0, 255)
        [IO.File]::WriteAllBytes($source, $bytes)
        Invoke-LabSeedIsoWithFakeImage @{ 'user-data' = @{ SourcePath = $source } }
        Assert-Equal ($script:SeedStaged['user-data'] -join ',') ($bytes -join ',')
    } finally { [IO.Directory]::Delete($dir, $true) }
}
Test-Case 'New-LabSeedIso: a missing SourcePath fails clearly before any COM object or staging exists' {
    $missing = Join-Path ([IO.Path]::GetTempPath()) ('labseed-missing-' + [guid]::NewGuid().ToString('N') + '.xml')
    Assert-Throws { Invoke-LabSeedIsoWithFakeImage @{ 'Autounattend.xml' = @{ SourcePath = $missing } } } 'does not exist'
    Assert-Equal $script:SeedComCreated 0
    Assert-Equal $script:SeedStagingDir $null
}
Test-Case 'New-LabSeedIso: rooted, drive, colon, empty, dot and .. keys are refused before any COM object exists' {
    foreach ($key in @('..\x.txt', 'a/../b.txt', '\x.txt', '/x.txt', 'C:\x.txt', 'C:x.txt', 'a:b.txt', 'a\\b.txt', 'a\.\b.txt', 'dir\', ' ')) {
        Assert-Throws { Invoke-LabSeedIsoWithFakeImage @{ $key = 'content' } } 'Invalid in-image path'
        Assert-Equal $script:SeedComCreated 0
    }
}
Test-Case 'New-LabSeedIso: unsupported values and duplicate in-image paths are refused' {
    $values = @($null, 42, [byte[]]@(1, 2), [IO.FileInfo]::new('C:\x.txt'), @{ Other = 'x' }, @{ SourcePath = 'C:\x'; Extra = 1 })
    foreach ($value in $values) {
        Assert-Throws { Invoke-LabSeedIsoWithFakeImage @{ 'a.txt' = $value } } 'Unsupported value'
        Assert-Equal $script:SeedComCreated 0
    }
    $files = @{ 'a/b.txt' = 'one' }
    $files['a\B.TXT'] = 'two'
    Assert-Throws { Invoke-LabSeedIsoWithFakeImage $files } 'same file'
    Assert-Equal $script:SeedComCreated 0
}

# --- Windows unattended install, Task 1: Get-LabWindowsInstallImages / Test-LabWindowsIsoInScope ---
# Fakes for Mount-DiskImage, Get-Volume, Get-WindowsImage, Dismount-DiskImage, Get-Module and
# Test-Path, standing in for the Storage/Dism cmdlets Get-LabWindowsInstallImages calls.
# Mount-DiskImage/Get-Volume pairing: -PassThru from Mount-DiskImage, piped into Get-Volume, is the
# exact pairing Plan 1 already live-verified against a real ISO (MANUAL-TESTS.md, "Seed-ISO round
# trip (verified live)": "Mount-DiskImage -ImagePath <iso> -PassThru | Get-Volume"), so the fake
# here matches that, not the untried Get-DiskImage-by-path alternative.
$script:MountDiskImageCalls = 0
$script:DismountDiskImageCalls = 0
$script:FakeDismModuleAvailable = $true
$script:FakeIsoDriveLetter = 'Z'
$script:FakeInstallWimExists = $true
$script:FakeInstallEsdExists = $false
$script:FakeWindowsImageSummaries = @()
$script:FakeWindowsImageDetailsByIndex = @{}
$script:FakeGetWindowsImageThrows = $null
$script:FakeMountDiskImageThrows = $null

function Get-Module {
    [CmdletBinding()]
    param([switch]$ListAvailable, [string]$Name)
    if ($Name -eq 'Dism' -and $ListAvailable) {
        if ($script:FakeDismModuleAvailable) { return [pscustomobject]@{ Name = 'Dism' } }
        return $null
    }
    return $null
}
function Mount-DiskImage {
    [CmdletBinding()]
    param([string]$ImagePath, [switch]$PassThru)
    $script:MountDiskImageCalls++
    if ($null -ne $script:FakeMountDiskImageThrows) { throw $script:FakeMountDiskImageThrows }
    if ($PassThru) { return [pscustomobject]@{ ImagePath = $ImagePath } }
}
function Get-Volume {
    [CmdletBinding()]
    param($DiskImage)
    return [pscustomobject]@{ DriveLetter = $script:FakeIsoDriveLetter }
}
function Dismount-DiskImage {
    # The real cmdlet emits a DiskImage-shaped object even without -PassThru (confirmed live,
    # 2026-10-20 -- it is not silent like Remove-VMDvdDrive or Set-VMDvdDrive). A caller that doesn't
    # suppress this leaks it into its own return value; this fake mirrors that so a regression here
    # fails a test instead of only surfacing on a real host, as it did before Get-LabWindowsInstallImages
    # and New-LabPatchedBootableIso were fixed to wrap the call in [void](...).
    [CmdletBinding()]
    param([string]$ImagePath)
    $script:DismountDiskImageCalls++
    return [pscustomobject]@{ ImagePath = $ImagePath; Attached = $false }
}
function Test-Path {
    # Forwards every path except the fake ISO's own sources\install.wim/.esd to the real cmdlet, so
    # the many unrelated real-filesystem Test-Path tests elsewhere in this file are unaffected.
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Path, [string]$PathType, [switch]$IsValid)
    $target = if ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } elseif ($PSBoundParameters.ContainsKey('Path')) { $Path } else { $null }
    $sourcesRoot = "$($script:FakeIsoDriveLetter):\sources"
    if ($target -eq "$sourcesRoot\install.wim") { return $script:FakeInstallWimExists }
    if ($target -eq "$sourcesRoot\install.esd") { return $script:FakeInstallEsdExists }
    return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-WindowsImage {
    [CmdletBinding()]
    param([string]$ImagePath, [int]$Index)
    if ($null -ne $script:FakeGetWindowsImageThrows) { throw $script:FakeGetWindowsImageThrows }
    if ($PSBoundParameters.ContainsKey('Index')) {
        $detail = $script:FakeWindowsImageDetailsByIndex[$Index]
        if ($null -eq $detail) { throw "No fake Get-WindowsImage detail for index $Index." }
        return $detail
    }
    return @($script:FakeWindowsImageSummaries)
}
function Reset-LabWindowsImageFakes {
    $script:MountDiskImageCalls = 0
    $script:DismountDiskImageCalls = 0
    $script:FakeDismModuleAvailable = $true
    $script:FakeInstallWimExists = $true
    $script:FakeInstallEsdExists = $false
    $script:FakeGetWindowsImageThrows = $null
    $script:FakeMountDiskImageThrows = $null
}

Test-Case 'Get-LabWindowsInstallImages: two Windows 11 client editions are both returned and in scope' {
    Reset-LabWindowsImageFakes
    $script:FakeWindowsImageSummaries = @(
        [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' }
        [pscustomobject]@{ ImageIndex = 2; ImageName = 'Windows 11 Pro' }
    )
    $script:FakeWindowsImageDetailsByIndex = @{
        1 = [pscustomobject]@{ InstallationType = 'Client'; Version = '10.0.26300.1000' }
        2 = [pscustomobject]@{ InstallationType = 'Client'; Version = '10.0.26300.1000' }
    }
    $images = @(Get-LabWindowsInstallImages 'C:\iso\win11.iso')
    Assert-Equal $images.Count 2
    Assert-Equal $images[0].Name 'Windows 11 Home'
    Assert-Equal $images[1].Name 'Windows 11 Pro'
    foreach ($image in $images) {
        Assert-Equal $image.InstallationType 'Client'
        Assert-Equal $image.BuildNumber 26300
        Assert-Equal $image.IsWindows11Client $true
    }
    Assert-Equal $script:MountDiskImageCalls 1
    Assert-Equal $script:DismountDiskImageCalls 1
}
Test-Case 'Get-LabWindowsInstallImages: a Windows 10 client edition is reported out of scope' {
    Reset-LabWindowsImageFakes
    $script:FakeWindowsImageSummaries = @([pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 10 Pro' })
    $script:FakeWindowsImageDetailsByIndex = @{ 1 = [pscustomobject]@{ InstallationType = 'Client'; Version = '10.0.19045.1' } }
    $images = @(Get-LabWindowsInstallImages 'C:\iso\win10.iso')
    Assert-Equal $images.Count 1
    Assert-Equal $images[0].BuildNumber 19045
    Assert-Equal $images[0].IsWindows11Client $false
}
Test-Case 'Get-LabWindowsInstallImages: a Server edition is out of scope even though its build number alone would pass' {
    Reset-LabWindowsImageFakes
    $script:FakeWindowsImageSummaries = @([pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows Server 2022 Standard' })
    $script:FakeWindowsImageDetailsByIndex = @{ 1 = [pscustomobject]@{ InstallationType = 'Server'; Version = '10.0.26300.1000' } }
    $images = @(Get-LabWindowsInstallImages 'C:\iso\server.iso')
    Assert-Equal $images.Count 1
    Assert-Equal $images[0].BuildNumber 26300
    Assert-Equal $images[0].IsWindows11Client $false
}
Test-Case 'Get-LabWindowsInstallImages: Dismount-DiskImage still runs, in a finally, when the image probe throws' {
    Reset-LabWindowsImageFakes
    $script:FakeGetWindowsImageThrows = 'simulated DISM probe failure'
    Assert-Throws { Get-LabWindowsInstallImages 'C:\iso\bad.iso' } 'simulated DISM probe failure'
    Assert-Equal $script:MountDiskImageCalls 1
    Assert-Equal $script:DismountDiskImageCalls 1
}
Test-Case 'Get-LabWindowsInstallImages: a missing Dism module throws a clear, specific message before any mount' {
    Reset-LabWindowsImageFakes
    $script:FakeDismModuleAvailable = $false
    Assert-Throws { Get-LabWindowsInstallImages 'C:\iso\x.iso' } 'Dism'
    Assert-Equal $script:MountDiskImageCalls 0
    Assert-Equal $script:DismountDiskImageCalls 0
}
Test-Case 'Get-LabWindowsInstallImages: a Mount-DiskImage failure propagates as itself, not masked by a dismount error' {
    Reset-LabWindowsImageFakes
    $script:FakeMountDiskImageThrows = 'simulated Mount-DiskImage failure'
    Assert-Throws { Get-LabWindowsInstallImages 'C:\iso\bad-mount.iso' } 'simulated Mount-DiskImage failure'
    Assert-Equal $script:MountDiskImageCalls 1
    Assert-Equal $script:DismountDiskImageCalls 0
}
Test-Case 'Test-LabWindowsIsoInScope: true as soon as one image in the list is a Windows 11 client edition' {
    $images = @(
        [pscustomobject]@{ IsWindows11Client = $false }
        [pscustomobject]@{ IsWindows11Client = $true }
    )
    Assert-Equal (Test-LabWindowsIsoInScope $images) $true
}
Test-Case 'Test-LabWindowsIsoInScope: false when no image qualifies, or the list is empty' {
    Assert-Equal (Test-LabWindowsIsoInScope @([pscustomobject]@{ IsWindows11Client = $false })) $false
    Assert-Equal (Test-LabWindowsIsoInScope @()) $false
}

# --- Windows unattended install, Task 2: New-LabPatchedBootableIso ---
# Mount-DiskImage/Get-Volume/Dismount-DiskImage are redefined here, overriding Task 1's versions
# above for every statement from this point on (Task 1's own Test-Case blocks already ran against
# its own fakes before this redefinition executes -- PowerShell functions take effect in the order
# their "function" statements run, not by position in the file).
#
# Unlike Task 1's fakes, these back a REAL temporary directory: New-LabPatchedBootableIso reads
# efi\microsoft\boot\efisys.bin/efisys_noprompt.bin through ordinary filesystem cmdlets
# (Test-Path/Get-Content), and the byte-for-byte comparison this task exists to prove needs their
# REAL content, not a canned value. A New-PSDrive mapping gives "<letter>:\..." a real backing
# directory without requiring Mount-DiskImage/Get-Volume themselves to be real or elevated. The El
# Torito parsing itself runs separately, against a real, hand-built fixture ISO file on disk
# (see New-LabFakeElToritoIso below), never touched by any of these fakes.
$script:BootPatchMountCalls = 0
$script:BootPatchDismountCalls = 0
$script:BootPatchMountThrows = $null
$script:BootPatchDriveName = @('Z', 'Y', 'X', 'W', 'V', 'U') | Where-Object { -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
if (-not $script:BootPatchDriveName) { throw 'No unused drive letter (Z..U) was available to stage the New-LabPatchedBootableIso fixture mount.' }

function Mount-DiskImage {
    [CmdletBinding()]
    param([string]$ImagePath, [switch]$PassThru)
    $script:BootPatchMountCalls++
    if ($null -ne $script:BootPatchMountThrows) { throw $script:BootPatchMountThrows }
    if ($PassThru) { return [pscustomobject]@{ ImagePath = $ImagePath } }
}
function Get-Volume {
    [CmdletBinding()]
    param($DiskImage)
    return [pscustomobject]@{ DriveLetter = $script:BootPatchDriveName }
}
function Dismount-DiskImage {
    # The real cmdlet emits a DiskImage-shaped object even without -PassThru (confirmed live,
    # 2026-10-20). A caller that doesn't suppress this leaks it into its own return value; this fake
    # mirrors that so a regression here fails a test instead of only surfacing on a real host.
    [CmdletBinding()]
    param([string]$ImagePath)
    $script:BootPatchDismountCalls++
    return [pscustomobject]@{ ImagePath = $ImagePath; Attached = $false }
}

function Reset-LabBootPatchFakes {
    $script:BootPatchMountCalls = 0
    $script:BootPatchDismountCalls = 0
    $script:BootPatchMountThrows = $null
    $script:CopyCalls = 0
    $script:CopyMode = 'Normal'
}

# Stages a real temp directory holding the two loose boot-loader files (or just efisys.bin, when
# $IncludeNoPrompt is $false) and maps $script:BootPatchDriveName at it, so the function's own
# "$($volume.DriveLetter):\efi\microsoft\boot\..." string concatenation resolves for real.
function New-LabBootPatchStagedMount {
    param([byte[]]$EfisysBytes, [byte[]]$NoPromptBytes, [bool]$IncludeNoPrompt = $true)
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-' + [guid]::NewGuid().ToString('N'))
    $bootDir = Join-Path $dir 'efi\microsoft\boot'
    [void][IO.Directory]::CreateDirectory($bootDir)
    if ($null -ne $EfisysBytes) { [IO.File]::WriteAllBytes((Join-Path $bootDir 'efisys.bin'), $EfisysBytes) }
    if ($IncludeNoPrompt -and $null -ne $NoPromptBytes) { [IO.File]::WriteAllBytes((Join-Path $bootDir 'efisys_noprompt.bin'), $NoPromptBytes) }
    if (Get-PSDrive -Name $script:BootPatchDriveName -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $script:BootPatchDriveName -Force -ErrorAction Stop
    }
    [void](New-PSDrive -Name $script:BootPatchDriveName -PSProvider FileSystem -Root $dir -Scope Global -ErrorAction Stop)
    return $dir
}
function Remove-LabBootPatchStagedMount {
    param([string]$Dir)
    if (Get-PSDrive -Name $script:BootPatchDriveName -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $script:BootPatchDriveName -Force -ErrorAction SilentlyContinue
    }
    if ([IO.Directory]::Exists($Dir)) { [IO.Directory]::Delete($Dir, $true) }
}

# Hand-builds a minimal, valid El Torito/ISO9660 byte layout: a Boot Record Volume Descriptor at
# sector 17 ("CD001", "EL TORITO SPECIFICATION", a catalog-sector pointer at its documented offset
# 71), and a boot catalog at $CatalogSector shaped per $Layout:
#   - 'Hybrid' (the default): mirrors a REAL Windows 11 ISO's actual boot catalog, read directly from
#     its raw bytes -- a Validation Entry naming platform id 0x00 (BIOS), an Initial/Default Entry
#     (catalog offset 32) pointing at a BIOS data sector ($BiosLoadRbaSector), then a final Section
#     Header (catalog offset 64, platform id 0xEF, one Section Entry following) whose Section Entry
#     (catalog offset 96, Load RBA at local offset 8 = catalog offset 104) points at $LoadRbaSector.
#   - 'EfiOnly': the narrower, EFI-only shape -- Validation Entry platform id 0xEF, and the
#     Initial/Default Entry (catalog offset 32, Load RBA at catalog offset 40) IS the EFI entry,
#     pointing directly at $LoadRbaSector. No Section Header is written.
#   - 'NoEfi': a BIOS Validation Entry/Initial/Default Entry exactly like 'Hybrid', but the Section
#     Header at catalog offset 64 is the final header (0x91) with platform id 0x00 (not EFI) and zero
#     Section Entries following -- there is no EFI boot catalog entry anywhere in this catalog.
# When given, $SectorContent is written at $LoadRbaSector's data sector, standing in for efisys.bin's
# own bytes (irrelevant for 'NoEfi', since that layout is refused before any content is ever read).
function New-LabFakeElToritoIso {
    param(
        [string]$Path,
        [int]$TotalSectors = 50,
        [int]$CatalogSector = 22,
        [int]$LoadRbaSector = 40,
        [byte[]]$SectorContent = $null,
        [ValidateSet('Hybrid', 'EfiOnly', 'NoEfi')][string]$Layout = 'Hybrid',
        [int]$BiosLoadRbaSector = 30
    )
    $sectorSize = 2048
    $bytes = New-Object byte[] ($TotalSectors * $sectorSize)
    $brvdOffset = 17 * $sectorSize
    $bytes[$brvdOffset] = 0
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('CD001'), 0, $bytes, $brvdOffset + 1, 5)
    $elTorito = [Text.Encoding]::ASCII.GetBytes('EL TORITO SPECIFICATION')
    [Array]::Copy($elTorito, 0, $bytes, $brvdOffset + 7, $elTorito.Length)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$CatalogSector), 0, $bytes, $brvdOffset + 71, 4)

    $catOffset = $CatalogSector * $sectorSize
    switch ($Layout) {
        'EfiOnly' {
            $bytes[$catOffset] = 0x01       # Validation Entry: header id
            $bytes[$catOffset + 1] = 0xEF   # Validation Entry: platform id (EFI)
            $bytes[$catOffset + 30] = 0x55  # Validation Entry: key bytes
            $bytes[$catOffset + 31] = 0xAA
            $bytes[$catOffset + 32] = 0x88  # Initial/Default Entry (IS the EFI entry): bootable
            $bytes[$catOffset + 33] = 0x00  # boot media type (no emulation)
            [Array]::Copy([BitConverter]::GetBytes([uint32]$LoadRbaSector), 0, $bytes, $catOffset + 40, 4)
        }
        'NoEfi' {
            $bytes[$catOffset] = 0x01       # Validation Entry: header id
            $bytes[$catOffset + 1] = 0x00   # Validation Entry: platform id (BIOS)
            $bytes[$catOffset + 30] = 0x55
            $bytes[$catOffset + 31] = 0xAA
            $bytes[$catOffset + 32] = 0x88  # BIOS Initial/Default Entry: bootable
            $bytes[$catOffset + 33] = 0x00
            [Array]::Copy([BitConverter]::GetBytes([uint32]$BiosLoadRbaSector), 0, $bytes, $catOffset + 40, 4)
            # Final Section Header, platform id NOT EFI, zero Section Entries following: the walk
            # must stop here (the 0x91 final-header flag) having found no EFI entry anywhere.
            $bytes[$catOffset + 64] = 0x91  # Section Header: final header
            $bytes[$catOffset + 65] = 0x00  # platform id: BIOS, not EFI
            [Array]::Copy([BitConverter]::GetBytes([uint16]0), 0, $bytes, $catOffset + 66, 2)
        }
        default {
            # 'Hybrid': the real Windows 11 ISO's own shape -- a BIOS Validation/Initial-Default
            # Entry pair, then a separate, final Section Header naming platform id 0xEF with exactly
            # one Section Entry following, which carries the actual EFI Load RBA.
            $bytes[$catOffset] = 0x01       # Validation Entry: header id
            $bytes[$catOffset + 1] = 0x00   # Validation Entry: platform id (BIOS)
            $bytes[$catOffset + 30] = 0x55
            $bytes[$catOffset + 31] = 0xAA
            $bytes[$catOffset + 32] = 0x88  # BIOS Initial/Default Entry: bootable
            $bytes[$catOffset + 33] = 0x00
            [Array]::Copy([BitConverter]::GetBytes([uint32]$BiosLoadRbaSector), 0, $bytes, $catOffset + 40, 4)
            $bytes[$catOffset + 64] = 0x91  # Section Header: final header (exactly one EFI section)
            $bytes[$catOffset + 65] = 0xEF  # platform id: EFI
            [Array]::Copy([BitConverter]::GetBytes([uint16]1), 0, $bytes, $catOffset + 66, 2)
            $bytes[$catOffset + 96] = 0x88  # EFI Section Entry: bootable
            $bytes[$catOffset + 97] = 0x00
            [Array]::Copy([BitConverter]::GetBytes([uint32]$LoadRbaSector), 0, $bytes, $catOffset + 104, 4)
        }
    }

    if ($null -ne $SectorContent) {
        [Array]::Copy($SectorContent, 0, $bytes, $LoadRbaSector * $sectorSize, $SectorContent.Length)
    }
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function New-LabBootPatchDistinctBytes {
    param([int]$Length, [int]$Seed)
    $bytes = New-Object byte[] $Length
    for ($i = 0; $i -lt $Length; $i++) { $bytes[$i] = [byte]((($i * $Seed) + $Seed) % 251) }
    return $bytes
}

Test-Case 'New-LabPatchedBootableIso: happy path patches only the Load-RBA bytes, everything else unchanged' {
    Reset-LabBootPatchFakes
    $efisysBytes = New-LabBootPatchDistinctBytes 80 7
    $noPromptBytes = New-LabBootPatchDistinctBytes 80 13
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    $stagedDir = $null
    try {
        New-LabFakeElToritoIso -Path $isoPath -SectorContent $efisysBytes
        $stagedDir = New-LabBootPatchStagedMount -EfisysBytes $efisysBytes -NoPromptBytes $noPromptBytes
        $sourceBytes = [IO.File]::ReadAllBytes($isoPath)

        $result = New-LabPatchedBootableIso $isoPath $outputPath

        Assert-Equal $result.Patched $true
        Assert-Equal $result.OutputPath $outputPath
        Assert-Equal (Test-Path -LiteralPath $outputPath -PathType Leaf) $true
        $outputBytes = [IO.File]::ReadAllBytes($outputPath)
        Assert-Equal $outputBytes.Length $sourceBytes.Length

        $patchOffset = 40 * 2048
        $patchedRegion = $outputBytes[$patchOffset..($patchOffset + 79)]
        Assert-Equal ([Convert]::ToBase64String($patchedRegion)) ([Convert]::ToBase64String($noPromptBytes))

        # Everything outside the patched region must be byte-identical to the original source ISO:
        # rebuild the patched region back to its original content and hash-compare the whole file.
        $reconstructed = [byte[]]$outputBytes.Clone()
        [Array]::Copy($efisysBytes, 0, $reconstructed, $patchOffset, $efisysBytes.Length)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        $beforeHash = [Convert]::ToBase64String($sha256.ComputeHash($sourceBytes))
        $afterHash = [Convert]::ToBase64String($sha256.ComputeHash($reconstructed))
        Assert-Equal $afterHash $beforeHash

        Assert-Equal $script:BootPatchMountCalls 1
        Assert-Equal $script:BootPatchDismountCalls 1
        Assert-Equal $script:CopyCalls 1
    } finally {
        if ($stagedDir) { Remove-LabBootPatchStagedMount $stagedDir }
        Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'New-LabPatchedBootableIso: a size mismatch between efisys.bin and efisys_noprompt.bin refuses, no copy made' {
    Reset-LabBootPatchFakes
    $efisysBytes = New-LabBootPatchDistinctBytes 80 7
    $noPromptBytes = New-LabBootPatchDistinctBytes 79 13
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    $stagedDir = $null
    try {
        New-LabFakeElToritoIso -Path $isoPath -SectorContent $efisysBytes
        $stagedDir = New-LabBootPatchStagedMount -EfisysBytes $efisysBytes -NoPromptBytes $noPromptBytes

        $result = New-LabPatchedBootableIso $isoPath $outputPath

        Assert-Equal $result.Patched $false
        if ($result.Reason -notmatch 'size|length|byte') { throw "Reason did not mention size/length: $($result.Reason)" }
        Assert-Equal $result.OutputPath $null
        Assert-Equal (Test-Path -LiteralPath $outputPath -PathType Leaf) $false
        Assert-Equal $script:CopyCalls 0
        Assert-Equal $script:BootPatchDismountCalls 1
    } finally {
        if ($stagedDir) { Remove-LabBootPatchStagedMount $stagedDir }
        Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'New-LabPatchedBootableIso: a boot catalog pointing at content that does not match efisys.bin refuses, no copy made' {
    Reset-LabBootPatchFakes
    $efisysBytes = New-LabBootPatchDistinctBytes 80 7
    $noPromptBytes = New-LabBootPatchDistinctBytes 80 13
    $isoSectorContent = New-LabBootPatchDistinctBytes 80 99
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    $stagedDir = $null
    try {
        New-LabFakeElToritoIso -Path $isoPath -SectorContent $isoSectorContent
        $stagedDir = New-LabBootPatchStagedMount -EfisysBytes $efisysBytes -NoPromptBytes $noPromptBytes

        $result = New-LabPatchedBootableIso $isoPath $outputPath

        Assert-Equal $result.Patched $false
        if ($result.Reason -notmatch 'boot catalog') { throw "Reason did not say the boot catalog didn't point where expected: $($result.Reason)" }
        Assert-Equal $result.OutputPath $null
        Assert-Equal (Test-Path -LiteralPath $outputPath -PathType Leaf) $false
        Assert-Equal $script:CopyCalls 0
        Assert-Equal $script:BootPatchDismountCalls 1
    } finally {
        if ($stagedDir) { Remove-LabBootPatchStagedMount $stagedDir }
        Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'New-LabPatchedBootableIso: EFI-only boot catalog (Validation Entry platform id 0xEF) still patches correctly' {
    Reset-LabBootPatchFakes
    $efisysBytes = New-LabBootPatchDistinctBytes 80 7
    $noPromptBytes = New-LabBootPatchDistinctBytes 80 13
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    $stagedDir = $null
    try {
        New-LabFakeElToritoIso -Path $isoPath -SectorContent $efisysBytes -Layout EfiOnly
        $stagedDir = New-LabBootPatchStagedMount -EfisysBytes $efisysBytes -NoPromptBytes $noPromptBytes

        $result = New-LabPatchedBootableIso $isoPath $outputPath

        Assert-Equal $result.Patched $true
        Assert-Equal $result.OutputPath $outputPath
        Assert-Equal (Test-Path -LiteralPath $outputPath -PathType Leaf) $true
        $outputBytes = [IO.File]::ReadAllBytes($outputPath)
        $patchOffset = 40 * 2048
        $patchedRegion = $outputBytes[$patchOffset..($patchOffset + 79)]
        Assert-Equal ([Convert]::ToBase64String($patchedRegion)) ([Convert]::ToBase64String($noPromptBytes))
        Assert-Equal $script:CopyCalls 1
    } finally {
        if ($stagedDir) { Remove-LabBootPatchStagedMount $stagedDir }
        Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'New-LabPatchedBootableIso: a boot catalog with a BIOS entry but no EFI section anywhere refuses, no copy made' {
    Reset-LabBootPatchFakes
    $efisysBytes = New-LabBootPatchDistinctBytes 80 7
    $noPromptBytes = New-LabBootPatchDistinctBytes 80 13
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    $stagedDir = $null
    try {
        New-LabFakeElToritoIso -Path $isoPath -SectorContent $efisysBytes -Layout NoEfi
        $stagedDir = New-LabBootPatchStagedMount -EfisysBytes $efisysBytes -NoPromptBytes $noPromptBytes

        $result = New-LabPatchedBootableIso $isoPath $outputPath

        Assert-Equal $result.Patched $false
        if ($result.Reason -notmatch 'no EFI') { throw "Reason did not say no EFI boot catalog entry was found: $($result.Reason)" }
        Assert-Equal $result.OutputPath $null
        Assert-Equal (Test-Path -LiteralPath $outputPath -PathType Leaf) $false
        Assert-Equal $script:CopyCalls 0
        Assert-Equal $script:BootPatchDismountCalls 1
    } finally {
        if ($stagedDir) { Remove-LabBootPatchStagedMount $stagedDir }
        Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'New-LabPatchedBootableIso: a missing efisys_noprompt.bin refuses immediately, no copy attempted' {
    Reset-LabBootPatchFakes
    $efisysBytes = New-LabBootPatchDistinctBytes 80 7
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    $stagedDir = $null
    try {
        New-LabFakeElToritoIso -Path $isoPath -SectorContent $efisysBytes
        $stagedDir = New-LabBootPatchStagedMount -EfisysBytes $efisysBytes -IncludeNoPrompt $false

        $result = New-LabPatchedBootableIso $isoPath $outputPath

        Assert-Equal $result.Patched $false
        if ($result.Reason -notmatch 'efisys_noprompt\.bin') { throw "Reason did not name efisys_noprompt.bin: $($result.Reason)" }
        Assert-Equal $result.OutputPath $null
        Assert-Equal (Test-Path -LiteralPath $outputPath -PathType Leaf) $false
        Assert-Equal $script:CopyCalls 0
        Assert-Equal $script:BootPatchMountCalls 1
        Assert-Equal $script:BootPatchDismountCalls 1
    } finally {
        if ($stagedDir) { Remove-LabBootPatchStagedMount $stagedDir }
        Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'New-LabPatchedBootableIso: a Mount-DiskImage failure propagates as itself, not masked by a dismount error' {
    Reset-LabBootPatchFakes
    $script:BootPatchMountThrows = 'simulated Mount-DiskImage failure'
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('labbootpatch-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    try {
        Assert-Throws { New-LabPatchedBootableIso $isoPath $outputPath } 'simulated Mount-DiskImage failure'
        Assert-Equal $script:BootPatchMountCalls 1
        Assert-Equal $script:BootPatchDismountCalls 0
    } finally {
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}

# --- Windows unattended install, Task 6: "Provision Windows VM" orchestrator ---
# End-to-end over FAKES of every function the orchestrator consumes (Tasks 1-5 and Plan 1): these
# tests prove the orchestrator's sequencing and failure behavior, not each piece's own internals,
# which their own sections above already cover. Every fake records its name into $script:ProvCalls,
# so the exact call order is asserted. Only pure helpers (Test-LabNewVMName, Test-LabVCpuCount,
# Test-LabMemorySpec, ConvertTo-LabMenuIndex) run for real. Everything runs in a child scope, so no
# fake leaks into the Hyper-V drift guard below.
$script:ProvWorkspace = Join-Path ([IO.Path]::GetTempPath()) 'labprov-test-workspace'
$script:ProvSourceIso = 'C:\labprov-test\Win11.iso'
function New-LabProvImage {
    param([int]$Index, [string]$Name, [string]$Type = 'Client', [int]$Build = 26100)
    [pscustomobject]@{ Index = $Index; Name = $Name; InstallationType = $Type; BuildNumber = $Build
        IsWindows11Client = ($Type -eq 'Client' -and $Build -ge 22000) }
}
function Invoke-LabProvisioningScenario {
    # Runs the REAL Start-LabWindowsVMProvisioning against fakes. Returns a result object with the
    # status (or the thrown message), the ordered call log, and the arguments the key fakes received.
    param(
        [hashtable]$Options,
        [object[]]$Images = @((New-LabProvImage 1 'Windows 11 Home'), (New-LabProvImage 2 'Windows 11 Education'), (New-LabProvImage 3 'Windows 11 Pro')),
        [string[]]$Answers = @(),
        [string]$ThrowIn = '',
        [bool]$Patched = $true
    )
    $script:ProvCalls = [Collections.Generic.List[string]]::new()
    $script:ProvArgs = @{}
    $script:ProvAnswers = [Collections.Generic.Queue[string]]::new([string[]]$Answers)
    $script:ProvAudit = [Collections.Generic.List[string]]::new()
    $script:ProvImages = $Images
    $script:ProvThrowIn = $ThrowIn
    $script:ProvPatched = $Patched
    $result = [pscustomobject]@{ Status = $null; Error = $null; Calls = $null; Args = $null; Audit = $null }
    & {
        function Record { param([string]$Name) $script:ProvCalls.Add($Name); if ($script:ProvThrowIn -eq $Name) { throw "simulated $Name failure" } }
        function Read-LabText { param([string]$Prompt) if ($script:ProvAnswers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:ProvAnswers.Dequeue() }
        function Read-LabYesNoCancel { param([string]$Prompt) Record 'Read-LabYesNoCancel'; return 'Y' }
        function Write-LabAudit { param([string]$Action, [string]$Status, $VM = $null, [string]$Detail = '') $script:ProvAudit.Add("$Action|$Status|$Detail") }
        function Select-LabIsoPath { param([string]$IsoRoot) Record 'Select-LabIsoPath'; return $script:ProvSourceIso }
        function Get-LabWindowsInstallImages { param([string]$IsoPath) Record 'Get-LabWindowsInstallImages'; return $script:ProvImages }
        function Test-LabWindowsIsoInScope { param([object[]]$Images) Record 'Test-LabWindowsIsoInScope'; return @($Images | Where-Object IsWindows11Client).Count -gt 0 }
        function Get-LabHostDefaults {
            Record 'Get-LabHostDefaults'
            $temp = [IO.Path]::GetTempPath()
            [pscustomobject]@{ VirtualMachinePath = $temp; VirtualHardDiskPath = $temp; LogicalProcessorCount = 8; TotalPhysicalMemoryBytes = 32GB }
        }
        function Get-LabSwitchNames { return @('Default Switch') }
        function New-LabVMCore {
            param([string]$Name, [string]$VmStoragePath, [int]$VCpuCount, [long]$MinimumBytes, [long]$StartupBytes,
                [long]$MaximumBytes, [bool]$IsDynamic, [string]$VhdxPath, [long]$VhdxMaximumBytes, [string]$SwitchName)
            Record 'New-LabVMCore'
            $script:ProvArgs['New-LabVMCore'] = $PSBoundParameters
            return [pscustomobject]@{ Id = [guid]'00000000-0000-0000-0000-00000000c0de'; Name = $Name }
        }
        function Enable-VMIntegrationService {
            param($VM, [string[]]$Name)
            Record 'Enable-VMIntegrationService'
            $script:ProvArgs['Enable-VMIntegrationService'] = $Name
        }
        function Set-VM {
            param($VM, $AutomaticStopAction)
            Record 'Set-VM'
            $script:ProvArgs['Set-VM'] = $AutomaticStopAction
        }
        function Resolve-LabWindowsCredential {
            param($Credential, [bool]$NonInteractive)
            Record 'Resolve-LabWindowsCredential'
            if ($null -ne $Credential) { return $Credential }
            return [pscredential]::new('dev', (ConvertTo-SecureString 'p@ss' -AsPlainText -Force))
        }
        function Get-LabProvisioningWorkspacePath { param([guid]$VMId) Record 'Get-LabProvisioningWorkspacePath'; return $script:ProvWorkspace }
        function New-LabPatchedBootableIso {
            param([string]$SourceIsoPath, [string]$OutputPath)
            Record 'New-LabPatchedBootableIso'
            if ($script:ProvPatched) { return [pscustomobject]@{ Patched = $true; Reason = $null; OutputPath = $OutputPath } }
            return [pscustomobject]@{ Patched = $false; Reason = 'simulated: layout not understood'; OutputPath = $null }
        }
        function New-LabWindowsAnswerFileXml {
            param([string]$ComputerName, [string]$Locale, [string]$TimeZone, [int]$ImageIndex, [string]$UserName,
                [securestring]$Password, [string]$ProductKey = '')
            Record 'New-LabWindowsAnswerFileXml'
            $script:ProvArgs['New-LabWindowsAnswerFileXml'] = $PSBoundParameters
            return '<unattend/>'
        }
        function New-LabSeedIso { param([hashtable]$Files, [string]$OutputPath) Record 'New-LabSeedIso'; $script:ProvArgs['New-LabSeedIso'] = $PSBoundParameters }
        function Set-LabVMUnattendedInstallMedia {
            param([guid]$VMId, [string]$WindowsIsoPath, [string]$SeedIsoPath)
            Record 'Set-LabVMUnattendedInstallMedia'
            $script:ProvArgs['Set-LabVMUnattendedInstallMedia'] = $PSBoundParameters
        }
        function Set-LabVMBootProfile {
            param([guid]$VMId, [string]$OsProfile)
            Record 'Set-LabVMBootProfile'
            $script:ProvArgs['Set-LabVMBootProfile'] = $OsProfile
            return [pscustomobject]@{ SecureBootTemplateChanged = $false; SecureBootEnabled = $false; KeyProtectorAdded = $true; TpmEnabled = $true }
        }
        function Start-LabVM { param([guid]$VMId) Record 'Start-LabVM'; return 'COMPLETED' }
        function Wait-LabPSDirectSession {
            param([guid]$VMId, $Credential, [int]$TimeoutSeconds)
            Record 'Wait-LabPSDirectSession'
            $script:ProvArgs['Wait-LabPSDirectSession'] = $TimeoutSeconds
            return [pscustomobject]@{ State = 'Opened' }
        }
        function Write-LabProvisioningNote { param($Session, [string]$Content) Record 'Write-LabProvisioningNote'; $script:ProvArgs['Write-LabProvisioningNote'] = $Content }
        function Remove-PSSession { [CmdletBinding()] param($Session) }
        function Request-LabVMGuestShutdown { param([guid]$VMId) Record 'Request-LabVMGuestShutdown' }
        function Wait-LabVMState {
            param([guid]$VMId, [string]$State, [int]$TimeoutSeconds = 0)
            Record "Wait-LabVMState:$State"
            $script:ProvArgs["Wait-LabVMState:$State"] = $TimeoutSeconds
        }
        function Complete-LabWindowsProvisioning {
            param([guid]$VMId, [string]$WindowsIsoPath, [string]$SeedIsoPath)
            Record 'Complete-LabWindowsProvisioning'
            $script:ProvArgs['Complete-LabWindowsProvisioning'] = $PSBoundParameters
        }
        function Remove-LabProvisioningWorkspace { param([guid]$VMId) Record 'Remove-LabProvisioningWorkspace' }
        foreach ($sb in (Import-LabRealFunction 'Start-LabWindowsVMProvisioning', 'Select-LabWindowsEdition', 'ConvertTo-LabLocalAccountName', 'Get-LabProvisioningVMHardware')) { . $sb }
        try { $result.Status = Start-LabWindowsVMProvisioning $Options 6>$null 3>$null }
        catch { $result.Error = $_.Exception.Message }
    }
    $result.Calls = @($script:ProvCalls)
    $result.Args = $script:ProvArgs
    $result.Audit = @($script:ProvAudit)
    return $result
}
$script:ProvHappyOrder = @('Select-LabIsoPath', 'Get-LabWindowsInstallImages', 'Test-LabWindowsIsoInScope', 'Get-LabHostDefaults',
    'Read-LabYesNoCancel', 'New-LabVMCore', 'Enable-VMIntegrationService', 'Set-VM', 'Resolve-LabWindowsCredential', 'Get-LabProvisioningWorkspacePath',
    'New-LabPatchedBootableIso', 'New-LabWindowsAnswerFileXml', 'New-LabSeedIso', 'Set-LabVMUnattendedInstallMedia',
    'Set-LabVMBootProfile', 'Start-LabVM', 'Wait-LabPSDirectSession', 'Write-LabProvisioningNote',
    'Request-LabVMGuestShutdown', 'Wait-LabVMState:Off', 'Complete-LabWindowsProvisioning', 'Remove-LabProvisioningWorkspace',
    'Start-LabVM', 'Wait-LabPSDirectSession')
$script:LabReadOnly = $false
# Lab-VM.ps1's own script-level default for -TimeoutSeconds (the orchestrator reads it for the Off-wait floor).
$script:LabTimeout = 180

Test-Case 'Provision: happy path runs every phase once, in the documented order, and returns COMPLETED' {
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11' } -Answers @('')
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Status 'COMPLETED'
    Assert-Equal ($r.Calls -join ' > ') ($script:ProvHappyOrder -join ' > ')
    Assert-Equal @($r.Calls | Where-Object { $_ -eq 'Remove-LabProvisioningWorkspace' }).Count 1
    Assert-Equal @($r.Calls | Where-Object { $_ -eq 'Wait-LabPSDirectSession' }).Count 2
    # Defaults: blank picker answer = Pro (index 3); dynamic memory 2/4/8 GB; 150 GB VHDX; Default Switch; 2 vCPUs.
    Assert-Equal $r.Args['New-LabWindowsAnswerFileXml'].ImageIndex 3
    Assert-Equal $r.Args['New-LabWindowsAnswerFileXml'].UserName 'dev'
    # Neither -ComputerName nor -TimeZone was supplied: both must be the literal project defaults,
    # independent of -NewVMName and of the host's own time zone.
    Assert-Equal $r.Args['New-LabWindowsAnswerFileXml'].ComputerName 'lab-agent-test'
    Assert-Equal $r.Args['New-LabWindowsAnswerFileXml'].TimeZone 'Central America Standard Time'
    # No -ProductKey was supplied: the answer-file call must get the empty "no activation" default.
    Assert-Equal $r.Args['New-LabWindowsAnswerFileXml'].ProductKey ''
    $core = $r.Args['New-LabVMCore']
    Assert-Equal $core.Name 'LAB-Win11'
    Assert-Equal $core.VCpuCount 2
    Assert-Equal $core.MinimumBytes ([long]2GB); Assert-Equal $core.StartupBytes ([long]4GB); Assert-Equal $core.MaximumBytes ([long]8GB)
    Assert-Equal $core.IsDynamic $true
    Assert-Equal $core.VhdxMaximumBytes ([long]150GB)
    Assert-Equal $core.SwitchName 'Default Switch'
    # Guest Service Interface enabled and the automatic stop action set to a graceful shutdown, right
    # after VM creation, before any Windows-specific provisioning step.
    Assert-Equal ($r.Args['Enable-VMIntegrationService'] -join ',') 'Guest Service Interface'
    Assert-Equal ([string]$r.Args['Set-VM']) 'ShutDown'
    Assert-Equal $r.Args['Set-LabVMBootProfile'] 'Windows11'
    Assert-Equal $r.Args['Wait-LabPSDirectSession'] 1800
    # The patched copy is what gets attached AND what cleanup later ejects.
    $patchedPath = Join-Path $script:ProvWorkspace 'windows-noprompt.iso'
    Assert-Equal $r.Args['Set-LabVMUnattendedInstallMedia'].WindowsIsoPath $patchedPath
    Assert-Equal $r.Args['Complete-LabWindowsProvisioning'].WindowsIsoPath $patchedPath
    Assert-Equal $r.Args['Complete-LabWindowsProvisioning'].SeedIsoPath $r.Args['Set-LabVMUnattendedInstallMedia'].SeedIsoPath
    Assert-Equal (@($r.Args['New-LabSeedIso'].Files.Keys) -join ',') 'Autounattend.xml'
    Assert-Equal ($r.Audit[0] -like 'provision-windows-vm|STARTED|*') $true
    Assert-Equal ($r.Audit[-1] -like 'provision-windows-vm|COMPLETED|*Win11.iso*Windows 11 Pro*ComputerName=lab-agent-test*ElapsedSeconds=*') $true
}
Test-Case 'Provision: a malformed -ProductKey is rejected before any VM is created' {
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; ProductKey = 'not-a-key' } -Answers @('')
    Assert-Equal $r.Status $null
    if ($r.Error -notmatch 'ProductKey') { throw "Error did not name -ProductKey: $($r.Error)" }
    Assert-Equal ($r.Calls -contains 'New-LabVMCore') $false
    Assert-Equal $r.Audit.Count 0
}
Test-Case 'Provision: a well-formed -ProductKey passes through unchanged to the answer-file call' {
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; ProductKey = '12345-ABCDE-12345-ABCDE-12345' } -Answers @('')
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Status 'COMPLETED'
    Assert-Equal $r.Args['New-LabWindowsAnswerFileXml'].ProductKey '12345-ABCDE-12345-ABCDE-12345'
}
Test-Case 'Provision: -SwitchName '''' is the documented escape hatch for a Disconnected adapter, not a fallback to Default Switch' {
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; SwitchName = '' } -Answers @('')
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Status 'COMPLETED'
    Assert-Equal $r.Args['New-LabVMCore'].SwitchName ''
}
Test-Case 'Provision: an unpatched ISO falls back to the ORIGINAL source path for attach and cleanup' {
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; OsEdition = 'Pro' } -Patched $false
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Status 'COMPLETED'
    Assert-Equal $r.Args['Set-LabVMUnattendedInstallMedia'].WindowsIsoPath $script:ProvSourceIso
    Assert-Equal $r.Args['Complete-LabWindowsProvisioning'].WindowsIsoPath $script:ProvSourceIso
}
Test-Case 'Provision: an ISO with no Windows 11 client edition is refused, listing what was found, before any VM is created' {
    $images = @((New-LabProvImage 1 'Windows Server 2025 Datacenter' 'Server' 26100), (New-LabProvImage 2 'Windows 10 Pro' 'Client' 19045))
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11' } -Images $images
    Assert-Equal $r.Status $null
    if ($r.Error -notmatch 'Windows 11' -or $r.Error -notmatch 'Windows Server 2025 Datacenter' -or $r.Error -notmatch 'Windows 10 Pro') { throw "Unclear refusal: $($r.Error)" }
    Assert-Equal ($r.Calls -contains 'New-LabVMCore') $false
    Assert-Equal $r.Audit.Count 0
}
Test-Case 'Provision: an -OsEdition not on the ISO re-prompts interactively and proceeds with the second, valid answer' {
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; OsEdition = 'Enterprise' } -Answers @('2')
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Status 'COMPLETED'
    Assert-Equal $r.Args['New-LabWindowsAnswerFileXml'].ImageIndex 2
}
Test-Case 'Provision: an -OsEdition not on the ISO throws under -NonInteractive, naming what IS available, without creating a VM' {
    $cred = [pscredential]::new('dev', (ConvertTo-SecureString 'p@ss' -AsPlainText -Force))
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; OsEdition = 'Enterprise'; NonInteractive = $true
        WindowsIsoPath = $PSCommandPath; Credential = $cred }
    if ($r.Error -notmatch 'Enterprise' -or $r.Error -notmatch 'Windows 11 Home' -or $r.Error -notmatch 'Windows 11 Pro') { throw "Unclear error: $($r.Error)" }
    Assert-Equal ($r.Calls -contains 'New-LabVMCore') $false
    Assert-Equal ($r.Calls -contains 'Select-LabIsoPath') $false
}
Test-Case 'Provision: a failure partway reports completed steps, the kept workspace and its password, and runs nothing after' {
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; OsEdition = 'Pro' } -ThrowIn 'New-LabPatchedBootableIso'
    Assert-Equal $r.Status $null
    Assert-Equal ($r.Calls -contains 'New-LabVMCore') $true
    Assert-Equal $r.Calls[-1] 'New-LabPatchedBootableIso'
    foreach ($later in @('New-LabWindowsAnswerFileXml', 'New-LabSeedIso', 'Set-LabVMUnattendedInstallMedia', 'Set-LabVMBootProfile',
            'Start-LabVM', 'Wait-LabPSDirectSession', 'Remove-LabProvisioningWorkspace')) {
        if ($r.Calls -contains $later) { throw "$later ran after the failing step." }
    }
    if ($r.Error -notmatch 'simulated New-LabPatchedBootableIso failure') { throw "Error lost the cause: $($r.Error)" }
    if ($r.Error -notmatch 'Steps already applied: .*created.*credential.*workspace') { throw "Error did not name the completed steps: $($r.Error)" }
    if (-not $r.Error.Contains($script:ProvWorkspace)) { throw "Error did not name the workspace path: $($r.Error)" }
    if ($r.Error -notmatch 'password') { throw "Error did not mention the password: $($r.Error)" }
    Assert-Equal ($r.Audit[-1] -like 'provision-windows-vm|FAILED_OR_UNCONFIRMED|*') $true
}
Test-Case 'Provision: a failure AFTER the seed ISO is built says the kept workspace contains the password in plain text' {
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; OsEdition = 'Pro' } -ThrowIn 'Set-LabVMUnattendedInstallMedia'
    Assert-Equal $r.Status $null
    Assert-Equal ($r.Calls -contains 'New-LabSeedIso') $true
    Assert-Equal $r.Calls[-1] 'Set-LabVMUnattendedInstallMedia'
    if ($r.Error -notmatch 'simulated Set-LabVMUnattendedInstallMedia failure') { throw "Error lost the cause: $($r.Error)" }
    if (-not $r.Error.Contains("The provisioning workspace was KEPT, not deleted: $($script:ProvWorkspace) -- it contains the account password in plain text")) {
        throw "Error did not name the workspace path and its plain-text password: $($r.Error)"
    }
    if ($r.Error -match 'no password had been written') { throw "Error used the pre-seed-ISO wording: $($r.Error)" }
    Assert-Equal ($r.Audit[-1] -like 'provision-windows-vm|FAILED_OR_UNCONFIRMED|*') $true
}
Test-Case 'Provision: the wait for Off between the two boots uses at least a 1800-second floor, never below the general timeout' {
    $saved = $script:LabTimeout
    try {
        $script:LabTimeout = 180
        $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; OsEdition = 'Pro' }
        if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
        Assert-Equal $r.Args['Wait-LabVMState:Off'] 1800
        # The floor never shortens a general timeout that is already longer, and leaves it unchanged.
        $script:LabTimeout = 2400
        $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; OsEdition = 'Pro' }
        if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
        Assert-Equal $r.Args['Wait-LabVMState:Off'] 2400
        Assert-Equal $script:LabTimeout 2400
    } finally { $script:LabTimeout = $saved }
}
Test-Case 'Provision: the guest-desktop note names the VM, ISO, edition, boot profile and timing' {
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; OsEdition = 'Pro' }
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    $note = [string]$r.Args['Write-LabProvisioningNote']
    foreach ($expected in @('LAB-Win11', "Windows ISO: $($script:ProvSourceIso)", 'no-prompt copy', 'Windows 11 Pro (image 3, build 26100)',
            'Computer name: lab-agent-test', 'Local administrator account: dev',
            'Boot profile: Windows11 (Secure Boot template changed: False; Secure Boot turned on: False; key protector added: True; vTPM enabled: True)')) {
        if (-not $note.Contains($expected)) { throw "Note is missing '$expected': $note" }
    }
    if ($note -notmatch 'Time from VM creation to this first sign-in: \d+ min \d+ s \(\d+ seconds\)') { throw "Note is missing the elapsed time: $note" }
    # Unpatched: the note says the ISO was booted as-is.
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; OsEdition = 'Pro' } -Patched $false
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    if (-not ([string]$r.Args['Write-LabProvisioningNote']).Contains("Windows ISO: $($script:ProvSourceIso) (booted as-is")) { throw "Unpatched note wording wrong: $($r.Args['Write-LabProvisioningNote'])" }
}
Test-Case 'Provision: -NonInteractive without -Credential is refused before any ISO is read or VM created' {
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; NonInteractive = $true; WindowsIsoPath = $PSCommandPath }
    if ($r.Error -notmatch '-Credential') { throw "Unexpected error: $($r.Error)" }
    Assert-Equal $r.Calls.Count 0
}
Test-Case 'Provision: read-only mode refuses without prompting or creating anything' {
    $script:LabReadOnly = $true
    try {
        $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11' }
        Assert-Equal $r.Status 'CANCELLED'
        Assert-Equal $r.Calls.Count 0
    } finally { $script:LabReadOnly = $false }
}
function Invoke-LabSelectVMMenu {
    param([string[]]$Answers)
    $script:SelectPrompts = [Collections.Generic.List[string]]::new()
    $script:SelectAnswers = [Collections.Generic.Queue[string]]::new([string[]]$Answers)
    $script:ProvisionMenuCalls = 0
    $script:ProvisionLinuxMenuCalls = 0
    & {
        function Clear-Host { }
        function Read-LabText { param([string]$Prompt) $script:SelectPrompts.Add($Prompt); if ($script:SelectAnswers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }; return $script:SelectAnswers.Dequeue() }
        function New-LabVM { throw 'TRIPWIRE: N was dispatched.' }
        function Start-LabWindowsVMProvisioning { param([hashtable]$Options) $script:ProvisionMenuCalls++; return 'COMPLETED' }
        function Start-LabLinuxVMProvisioning { param([hashtable]$Options) $script:ProvisionLinuxMenuCalls++; return 'COMPLETED' }
        foreach ($sb in (Import-LabRealFunction 'Select-LabVM')) { . $sb }
        $out = @(Select-LabVM 6>$null 3>$null)
        Assert-Equal $out.Count 1
        Assert-Equal $out[0] $null
    }
}
Test-Case 'Menu: W (provision Windows VM) is offered and dispatched when not read-only' {
    $script:LabReadOnly = $false
    Invoke-LabSelectVMMenu @('W', '', 'Q')
    Assert-Equal $script:ProvisionMenuCalls 1
    Assert-Equal ($script:SelectPrompts[0] -match '\bW\b') $true
}
Test-Case 'Menu: under -ReadOnly, W is neither offered nor dispatched' {
    $script:LabReadOnly = $true
    try {
        Invoke-LabSelectVMMenu @('W', 'Q')
        Assert-Equal $script:ProvisionMenuCalls 0
        Assert-Equal ($script:SelectPrompts[0] -match '\bW\b') $false
    } finally { $script:LabReadOnly = $false }
}
Test-Case 'Menu: L (provision Linux VM) is offered and dispatched when not read-only, and does not dispatch W' {
    $script:LabReadOnly = $false
    Invoke-LabSelectVMMenu @('L', '', 'Q')
    Assert-Equal $script:ProvisionLinuxMenuCalls 1
    Assert-Equal $script:ProvisionMenuCalls 0
    Assert-Equal ($script:SelectPrompts[0] -match '\bL\b') $true
}
Test-Case 'Menu: under -ReadOnly, L is neither offered nor dispatched' {
    $script:LabReadOnly = $true
    try {
        Invoke-LabSelectVMMenu @('L', 'Q')
        Assert-Equal $script:ProvisionLinuxMenuCalls 0
        Assert-Equal ($script:SelectPrompts[0] -match '\bL\b') $false
    } finally { $script:LabReadOnly = $false }
}
Test-Case 'Gate: the three provisioning parameter tiers report exactly their own names, and menu/transfer parameters are in none' {
    # Linux Task 6 split the original Windows-only list into a shared creation tier (VM hardware and
    # generic settings either OS action uses), a Windows-only tier, and a Linux-only tier. Every name
    # the original single list covered is still covered by exactly one tier.
    foreach ($sb in (Import-LabRealFunction 'Get-LabProvisioningOnlyParameter', 'Get-LabCreationOnlyParameter', 'Get-LabLinuxProvisioningOnlyParameter')) { . $sb }
    $unrelated = @('ReadOnly', 'LogRoot', 'IsoRoot', 'TimeoutSeconds', 'VMName', 'NonInteractive', 'Credential')
    Assert-Equal @(Get-LabProvisioningOnlyParameter $unrelated).Count 0
    Assert-Equal @(Get-LabCreationOnlyParameter $unrelated).Count 0
    Assert-Equal @(Get-LabLinuxProvisioningOnlyParameter $unrelated).Count 0
    $tiers = @{
        Creation = @('NewVMName', 'ComputerName', 'Locale', 'VhdxSizeGB', 'VCpuCount', 'MemoryMinimumGB', 'MemoryStartupGB',
            'MemoryMaximumGB', 'SwitchName', 'VmStorageRoot', 'VhdxStorageRoot', 'ProvisioningTimeoutSeconds')
        Windows = @('WindowsIsoPath', 'OsEdition', 'ProductKey', 'TimeZone')
        Linux = @('LinuxIsoPath', 'LinuxTimeZone')
    }
    foreach ($tier in $tiers.Keys) {
        foreach ($name in $tiers[$tier]) {
            $expected = @{ Creation = ''; Windows = ''; Linux = '' }
            $expected[$tier] = $name
            Assert-Equal (@(Get-LabCreationOnlyParameter @('ReadOnly', $name)) -join ',') $expected['Creation']
            Assert-Equal (@(Get-LabProvisioningOnlyParameter @('ReadOnly', $name)) -join ',') $expected['Windows']
            Assert-Equal (@(Get-LabLinuxProvisioningOnlyParameter @('ReadOnly', $name)) -join ',') $expected['Linux']
        }
    }
}
Test-Case 'Gate: the real script refuses a provisioning-only parameter without -ProvisionWindowsVM instead of opening the menu' {
    $ErrorActionPreference = 'Continue'
    $exe = Join-Path $PSHOME 'powershell.exe'
    $output = @(& $exe -NoProfile -NonInteractive -File $resolved -NewVMName 'LAB-x' 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    Assert-Equal $LASTEXITCODE 1
    if (-not ($output -replace '\s', '').Contains('-NewVMNameonlyapplyto-ProvisionWindowsVM')) { throw "Unexpected output: $output" }
}
Test-Case 'Gate: the real script refuses -ProvisionWindowsVM combined with another action' {
    $ErrorActionPreference = 'Continue'
    $exe = Join-Path $PSHOME 'powershell.exe'
    $output = @(& $exe -NoProfile -NonInteractive -File $resolved -ProvisionWindowsVM -ConfigureSsh 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    Assert-Equal $LASTEXITCODE 1
    if (-not ($output -replace '\s', '').Contains('oneactionperinvocation')) { throw "Unexpected output: $output" }
}
Test-Case 'Gate: the real script refuses -VMName with -ProvisionWindowsVM, pointing at -NewVMName' {
    $ErrorActionPreference = 'Continue'
    $exe = Join-Path $PSHOME 'powershell.exe'
    $output = @(& $exe -NoProfile -NonInteractive -File $resolved -ProvisionWindowsVM -VMName 'LAB-x' 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    Assert-Equal $LASTEXITCODE 1
    if (-not ($output -replace '\s', '').Contains('-VMNamedonotapplyto-ProvisionWindowsVM(namethenewVMwith-NewVMName)')) { throw "Unexpected output: $output" }
}
# Linux Task 6: the same child-process gate, for the Linux action and the three-tier parameter split.
# Every invocation below either stops at the gate or, for the "accepted" cases, at the CLI wrapper's own
# required-value check (-NonInteractive without -Credential), which runs before any host check, log or
# Hyper-V call -- so nothing here can create a VM even on an elevated Hyper-V host.
function Invoke-LabGateChild {
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $exe = Join-Path $PSHOME 'powershell.exe'
    $output = @(& $exe -NoProfile -NonInteractive -File $resolved @Arguments 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Flat = ($output -replace '\s', ''); Output = $output }
}
Test-Case 'Gate: the real script refuses a Linux-only parameter without -ProvisionLinuxVM instead of opening the menu' {
    $r = Invoke-LabGateChild @('-LinuxIsoPath', 'C:\nope.iso')
    Assert-Equal $r.ExitCode 1
    if (-not $r.Flat.Contains('-LinuxIsoPathonlyapplyto-ProvisionLinuxVM')) { throw "Unexpected output: $($r.Output)" }
}
Test-Case 'Gate: the real script refuses a Windows-only parameter with -ProvisionLinuxVM as foreign' {
    $r = Invoke-LabGateChild @('-ProvisionLinuxVM', '-WindowsIsoPath', 'C:\nope.iso')
    Assert-Equal $r.ExitCode 1
    if (-not $r.Flat.Contains('-WindowsIsoPathdonotapplyto-ProvisionLinuxVM')) { throw "Unexpected output: $($r.Output)" }
}
Test-Case 'Gate: the real script refuses a Linux-only parameter with -ProvisionWindowsVM as foreign' {
    $r = Invoke-LabGateChild @('-ProvisionWindowsVM', '-LinuxTimeZone', 'Europe/Paris')
    Assert-Equal $r.ExitCode 1
    if (-not $r.Flat.Contains('-LinuxTimeZonedonotapplyto-ProvisionWindowsVM')) { throw "Unexpected output: $($r.Output)" }
}
Test-Case 'Gate: the real script refuses -VMName with -ProvisionLinuxVM, pointing at -NewVMName' {
    $r = Invoke-LabGateChild @('-ProvisionLinuxVM', '-VMName', 'LAB-x')
    Assert-Equal $r.ExitCode 1
    if (-not $r.Flat.Contains('-VMNamedonotapplyto-ProvisionLinuxVM(namethenewVMwith-NewVMName)')) { throw "Unexpected output: $($r.Output)" }
}
Test-Case 'Gate: the real script refuses -ProvisionLinuxVM combined with -ProvisionWindowsVM (four-way one-action check)' {
    $r = Invoke-LabGateChild @('-ProvisionLinuxVM', '-ProvisionWindowsVM')
    Assert-Equal $r.ExitCode 1
    if (-not $r.Flat.Contains('oneactionperinvocation')) { throw "Unexpected output: $($r.Output)" }
}
Test-Case 'Gate: shared creation parameters (-NewVMName, -VCpuCount) pass the gate with EITHER provisioning switch' {
    # Regression guard for the shared-tier refactor: both runs get past every gate check and stop only
    # at the CLI wrapper's own "Supply -Credential" requirement.
    $r = Invoke-LabGateChild @('-ProvisionWindowsVM', '-NewVMName', 'LAB-x', '-VCpuCount', '2', '-WindowsIsoPath', 'C:\nope.iso', '-NonInteractive')
    Assert-Equal $r.ExitCode 1
    if (-not $r.Flat.Contains('Supply-Credentialwith-ProvisionWindowsVM-NonInteractive')) { throw "Windows run did not reach the CLI wrapper: $($r.Output)" }
    $r = Invoke-LabGateChild @('-ProvisionLinuxVM', '-NewVMName', 'LAB-x', '-VCpuCount', '2', '-LinuxIsoPath', 'C:\nope.iso', '-NonInteractive')
    Assert-Equal $r.ExitCode 1
    if (-not $r.Flat.Contains('Supply-Credentialwith-ProvisionLinuxVM-NonInteractive')) { throw "Linux run did not reach the CLI wrapper: $($r.Output)" }
}
Test-Case 'Gate: a shared creation parameter alone names both provisioning switches' {
    $r = Invoke-LabGateChild @('-VCpuCount', '2')
    Assert-Equal $r.ExitCode 1
    if (-not $r.Flat.Contains('-VCpuCountonlyapplyto-ProvisionWindowsVMor-ProvisionLinuxVM')) { throw "Unexpected output: $($r.Output)" }
}

# --- Hyper-V shape drift guard (final-review fix) ---
# Every fake above stands in for a real Hyper-V cmdlet, and once a fake invented an output shape
# (Get-VMKeyProtector returning a RawKeyProtector wrapper) that no real host produces, so every test
# passed against output that cannot exist. This guard compares the fakes and the production code's
# Hyper-V calls with the INSTALLED Hyper-V module's own type metadata, read by .NET reflection in a
# child powershell.exe. Reflection needs no elevation and touches no VM: the child only imports the
# module and inspects types and IL; it never calls a Hyper-V cmdlet. This process never imports
# Hyper-V. Skipped (not counted as a pass) when the Hyper-V module is not installed.
$script:HyperVReflectionScript = @'
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name Hyper-V)) { '{"Skip":true}'; return }
Import-Module Hyper-V
$cmdlets = @{}
foreach ($c in (Get-Command -Module Hyper-V -CommandType Cmdlet)) {
    $names = [Collections.Generic.List[string]]::new()
    foreach ($p in $c.Parameters.Values) { $names.Add($p.Name); foreach ($a in $p.Aliases) { $names.Add($a) } }
    $cmdlets[$c.Name] = $names.ToArray()
}
$assemblies = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -like 'Microsoft.HyperV.PowerShell*' -or $_.GetName().Name -like 'Microsoft.Vhd.PowerShell*' })
$allTypes = foreach ($a in $assemblies) { try { $a.GetTypes() } catch { $_.Exception.Types | Where-Object { $_ } } }
$types = @{}
foreach ($t in $allTypes) {
    if (-not $t.IsPublic) { continue }
    $props = @{}
    foreach ($p in $t.GetProperties()) { $props[$p.Name] = $p.PropertyType.FullName }
    $types[$t.FullName] = @{ Properties = $props; EnumNames = $(if ($t.IsEnum) { [Enum]::GetNames($t) } else { @() }) }
}
$bf = [Reflection.BindingFlags]'Public,NonPublic,Instance,Static,DeclaredOnly'
$cmdType = (Get-Command Get-VMKeyProtector).ImplementingType
$calls = [Collections.Generic.List[string]]::new()
foreach ($m in $cmdType.GetMethods($bf)) {
    $body = $m.GetMethodBody(); if (-not $body) { continue }
    $il = $body.GetILAsByteArray()
    for ($i = 0; $i -lt $il.Length - 4; $i++) {
        if ($il[$i] -in 0x28, 0x6F) {
            try {
                $mm = $m.Module.ResolveMethod([BitConverter]::ToInt32($il, $i + 1), $cmdType.BaseType.GetGenericArguments(), $null)
                $ret = if ($mm -is [Reflection.MethodInfo]) { $mm.ReturnType.FullName } else { '' }
                $calls.Add("$($m.Name)|$($mm.DeclaringType.Name)::$($mm.Name)|$ret")
            } catch { }
        }
    }
}
$writeOverloads = [Collections.Generic.List[string]]::new()
$x = $cmdType
while ($x -and $x -ne [Management.Automation.PSCmdlet]) {
    foreach ($m in ($x.GetMethods($bf) | Where-Object { $_.Name -like '*WriteObject' })) {
        $body = $m.GetMethodBody(); if (-not $body) { continue }
        $il = $body.GetILAsByteArray()
        for ($i = 0; $i -lt $il.Length - 4; $i++) {
            if ($il[$i] -in 0x28, 0x6F) {
                try {
                    $mm = $m.Module.ResolveMethod([BitConverter]::ToInt32($il, $i + 1))
                    if ($mm.DeclaringType -eq [Management.Automation.Cmdlet] -and $mm.Name -eq 'WriteObject') {
                        $writeOverloads.Add((@($mm.GetParameters() | ForEach-Object { $_.ParameterType.Name }) -join ','))
                    }
                } catch { }
            }
        }
    }
    $x = $x.BaseType
}
$rawProps = @(foreach ($t in $allTypes) { foreach ($p in $t.GetProperties($bf)) { if ($p.Name -in 'RawKeyProtector', 'RawData') { "$($t.FullName).$($p.Name)" } } })
@{ Skip = $false; ModuleVersion = [string](Get-Module Hyper-V).Version; Cmdlets = $cmdlets; Types = $types
   KeyProtectorCalls = $calls.ToArray(); CmdletWriteObjectOverloads = $writeOverloads.ToArray()
   RawKeyProtectorProperties = $rawProps } | ConvertTo-Json -Depth 5 -Compress
'@
$script:HyperVFacts = $null
$script:HyperVFactsError = $null
try {
    $exe = Join-Path $PSHOME 'powershell.exe'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:HyperVReflectionScript))
    $json = (& $exe -NoProfile -NonInteractive -EncodedCommand $encoded) -join ''
    if ($LASTEXITCODE -ne 0) { throw "reflection child exited $LASTEXITCODE" }
    $script:HyperVFacts = $json | ConvertFrom-Json
} catch { $script:HyperVFactsError = $_.Exception.Message }
function Get-HyperVType {
    param([string]$FullName)
    $entry = $script:HyperVFacts.Types.PSObject.Properties[$FullName]
    if ($null -eq $entry) { throw "The installed Hyper-V module has no public type '$FullName'." }
    return $entry.Value
}
function Get-HyperVTypeProperties { param([string]$FullName) return @((Get-HyperVType $FullName).Properties.PSObject.Properties | ForEach-Object { $_.Name }) }
function Test-HyperVDriftCase {
    param([string]$Name, [scriptblock]$Body)
    if ($null -ne $script:HyperVFactsError) { Test-Case $Name { throw "Hyper-V reflection child failed: $script:HyperVFactsError" }; return }
    if ($script:HyperVFacts.Skip) { Write-Host "SKIP: $Name -- the Hyper-V PowerShell module is not installed on this machine."; return }
    Test-Case $Name $Body
}
$hp = 'Microsoft.HyperV.PowerShell'

Test-HyperVDriftCase 'Drift guard: real Get-VMKeyProtector writes one bare, un-enumerated byte[] (no wrapper)' {
    $calls = @($script:HyperVFacts.KeyProtectorCalls)
    Assert-Equal ($calls -contains 'ProcessOneOperand|VMSecurity::GetKeyProtector|System.Byte[]') $true
    Assert-Equal (@($calls | Where-Object { $_ -like 'ProcessOneOperand|IOperationWatcher::WriteObject|*' }).Count -gt 0) $true
    # Cmdlet.WriteObject(object) writes the array as ONE object; WriteObject(object, bool) would enumerate.
    Assert-Equal (@($script:HyperVFacts.CmdletWriteObjectOverloads) -join ';') 'Object'
    Assert-Equal @($script:HyperVFacts.RawKeyProtectorProperties).Count 0
    # ...and the fake matches: one byte[] object, no invented property.
    $fake = Get-VMKeyProtector -VM $script:FakeVM
    Assert-Equal ($fake -is [byte[]]) $true
}
Test-HyperVDriftCase 'Drift guard: real BootOrder is VMBootSource[] wrapping unprefixed DvdDrive/HardDiskDrive devices' {
    $firmware = (Get-HyperVType "$hp.VMFirmware").Properties
    Assert-Equal $firmware.BootOrder "$hp.VMBootSource[]"
    Assert-Equal $firmware.SecureBoot "$hp.OnOffState"
    Assert-Equal ((Get-HyperVType "$hp.OnOffState").EnumNames -join ',') 'On,Off'
    Assert-Equal ((Get-HyperVTypeProperties "$hp.VMBootSource") -contains 'Device') $true
    # The fixture classes must carry the real short type names and only real properties.
    foreach ($fixture in @([DvdDrive], [HardDiskDrive], [VMNetworkAdapter], [VMBootSource])) {
        $real = Get-HyperVTypeProperties "$hp.$($fixture.Name)"
        foreach ($property in $fixture.GetProperties()) {
            if ($real -notcontains $property.Name) { throw "Fixture [$($fixture.Name)] invents property '$($property.Name)'." }
        }
    }
    # The VM-prefixed fixture names are backward-compatibility cases only: no such real types exist.
    foreach ($name in @('VMDvdDrive', 'VMHardDiskDrive')) {
        if ($null -ne $script:HyperVFacts.Types.PSObject.Properties["$hp.$name"]) { throw "Unexpected real type $hp.${name}; re-check the boot-order fixtures." }
    }
}
Test-HyperVDriftCase 'Drift guard: every property a fake returns, or the code reads, exists on the real output type' {
    $savedDrives = @($script:FakeDvdDrives)
    $savedAddCalls = $script:AddVMDvdDriveCalls
    try {
        $script:FakeDvdDrives.Clear()
        Add-VMDvdDrive -VM $script:FakeVM
        $fakeDrive = @(Get-VMDvdDrive -VM $script:FakeVM)[0]
    } finally {
        $script:FakeDvdDrives.Clear(); foreach ($d in $savedDrives) { $script:FakeDvdDrives.Add($d) }
        $script:AddVMDvdDriveCalls = $savedAddCalls
    }
    $cases = @(
        @{ Type = "$hp.VirtualMachine"; Names = @($script:FakeVM.PSObject.Properties.Name) },
        @{ Type = "$hp.VMFirmware"; Names = @((Get-VMFirmware -VM $script:FakeVM).PSObject.Properties.Name) },
        @{ Type = "$hp.VMSecurity"; Names = @((Get-VMSecurity -VM $script:FakeVM).PSObject.Properties.Name) },
        @{ Type = "$hp.DvdDrive"; Names = @($fakeDrive.PSObject.Properties.Name) + @('ControllerType', 'ControllerNumber', 'ControllerLocation') },
        @{ Type = "$hp.HardDiskDrive"; Names = @('Path', 'DiskNumber') },
        @{ Type = "$hp.VMSnapshot"; Names = @('Name') },
        @{ Type = 'Microsoft.Vhd.PowerShell.VirtualHardDisk'; Names = @((Get-VHD -Path 'C:\x.vhdx').PSObject.Properties.Name) },
        @{ Type = "$hp.VMBootSource"; Names = @('BootType', 'Description', 'Device') }
    )
    foreach ($case in $cases) {
        $real = Get-HyperVTypeProperties $case.Type
        foreach ($name in $case.Names) {
            if ($real -notcontains $name) { throw "'$name' is not a property of the real $($case.Type)." }
        }
    }
}
Test-HyperVDriftCase 'Drift guard: every Hyper-V cmdlet this file fakes declares only parameters the real cmdlet has' {
    $faked = @($script:HyperVFacts.Cmdlets.PSObject.Properties | Where-Object { Get-Command $_.Name -CommandType Function -ErrorAction SilentlyContinue })
    if ($faked.Count -lt 10) { throw "Expected the Hyper-V fakes of this file to be visible; found $($faked.Count)." }
    # Only the always-present common parameters are skipped. -Confirm/-WhatIf exist on a real cmdlet only
    # when it supports ShouldProcess, so a fake declaring them is checked like any other parameter.
    $common = [Management.Automation.Cmdlet]::CommonParameters
    foreach ($cmdlet in $faked) {
        $real = @($cmdlet.Value)
        foreach ($parameter in (Get-Command $cmdlet.Name -CommandType Function).Parameters.Keys) {
            if ($common -contains $parameter) { continue }
            if ($real -notcontains $parameter) { throw "The fake $($cmdlet.Name) declares -$parameter, which the real cmdlet does not have." }
        }
    }
}
Test-HyperVDriftCase 'Drift guard: every Hyper-V cmdlet call in Lab-VM.ps1 uses parameter names the real cmdlet has' {
    $cmdlets = $script:HyperVFacts.Cmdlets
    $checked = 0
    foreach ($command in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if (-not $name) { continue }
        $entry = $cmdlets.PSObject.Properties[$name]
        if ($null -eq $entry) { continue }
        $checked++
        foreach ($element in $command.CommandElements) {
            if ($element -is [Management.Automation.Language.CommandParameterAst] -and @($entry.Value) -notcontains $element.ParameterName) {
                throw "Lab-VM.ps1 line $($element.Extent.StartLineNumber): $name has no -$($element.ParameterName)."
            }
        }
    }
    if ($checked -lt 20) { throw "Expected to check many Hyper-V calls in Lab-VM.ps1; checked $checked." }
}

# --- Linux unattended install, Task 1: Get-LabLinuxIsoInfo ---
# Fakes for Mount-DiskImage, Get-Volume, Dismount-DiskImage, Test-Path and Get-Content, standing in
# for the cmdlets Get-LabLinuxIsoInfo calls. Same Mount-DiskImage -PassThru | Get-Volume pairing as
# Get-LabWindowsInstallImages. Defined last in this file so nothing after this section sees them.
$script:LinuxMountCalls = 0
$script:LinuxDismountCalls = 0
$script:FakeLinuxDriveLetter = 'Y'
$script:FakeLinuxInfoExists = $true
$script:FakeLinuxInfoText = ''
$script:FakeLinuxInfoReadThrows = $null

function Mount-DiskImage {
    [CmdletBinding()]
    param([string]$ImagePath, [switch]$PassThru)
    $script:LinuxMountCalls++
    if ($PassThru) { return [pscustomobject]@{ ImagePath = $ImagePath } }
}
function Get-Volume {
    [CmdletBinding()]
    param($DiskImage)
    return [pscustomobject]@{ DriveLetter = $script:FakeLinuxDriveLetter }
}
function Dismount-DiskImage {
    [CmdletBinding()]
    param([string]$ImagePath)
    $script:LinuxDismountCalls++
    return [pscustomobject]@{ ImagePath = $ImagePath; Attached = $false }
}
function Test-Path {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Path, [string]$PathType, [switch]$IsValid)
    $target = if ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } elseif ($PSBoundParameters.ContainsKey('Path')) { $Path } else { $null }
    if ($target -eq "$($script:FakeLinuxDriveLetter):\.disk\info") { return $script:FakeLinuxInfoExists }
    return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-Content {
    [CmdletBinding()]
    param([string]$LiteralPath, [switch]$Raw)
    if ($LiteralPath -eq "$($script:FakeLinuxDriveLetter):\.disk\info") {
        if ($null -ne $script:FakeLinuxInfoReadThrows) { throw $script:FakeLinuxInfoReadThrows }
        return $script:FakeLinuxInfoText
    }
    return Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
}
function Reset-LabLinuxIsoFakes {
    $script:LinuxMountCalls = 0
    $script:LinuxDismountCalls = 0
    $script:FakeLinuxInfoExists = $true
    $script:FakeLinuxInfoText = ''
    $script:FakeLinuxInfoReadThrows = $null
}

Test-Case 'Get-LabLinuxIsoInfo: an Ubuntu 26.04 Desktop release is in scope and ReleaseText is the exact .disk/info text' {
    Reset-LabLinuxIsoFakes
    $script:FakeLinuxInfoText = 'Ubuntu 26.04.1 LTS "Example" - Release amd64'
    $info = Get-LabLinuxIsoInfo 'C:\iso\ubuntu.iso'
    Assert-Equal $info.ReleaseText 'Ubuntu 26.04.1 LTS "Example" - Release amd64'
    Assert-Equal $info.IsUbuntuDesktopInScope $true
    Assert-Equal $script:LinuxMountCalls 1
    Assert-Equal $script:LinuxDismountCalls 1
}
Test-Case 'Get-LabLinuxIsoInfo: an Ubuntu Server 26.04 release is out of scope' {
    Reset-LabLinuxIsoFakes
    $script:FakeLinuxInfoText = 'Ubuntu-Server 26.04.1 LTS "Example" - Release amd64'
    $info = Get-LabLinuxIsoInfo 'C:\iso\server.iso'
    Assert-Equal $info.IsUbuntuDesktopInScope $false
    Assert-Equal $script:LinuxDismountCalls 1
}
Test-Case 'Get-LabLinuxIsoInfo: an Ubuntu 24.04 Desktop release is out of scope' {
    Reset-LabLinuxIsoFakes
    $script:FakeLinuxInfoText = 'Ubuntu 24.04.1 LTS "Example" - Release amd64'
    $info = Get-LabLinuxIsoInfo 'C:\iso\ubuntu2404.iso'
    Assert-Equal $info.ReleaseText 'Ubuntu 24.04.1 LTS "Example" - Release amd64'
    Assert-Equal $info.IsUbuntuDesktopInScope $false
}
Test-Case 'Get-LabLinuxIsoInfo: Kubuntu, Xubuntu and Lubuntu 26.04 releases are out of scope (anchored, case-sensitive match)' {
    foreach ($text in @('Kubuntu 26.04.1 LTS "Example" - Release amd64', 'Xubuntu 26.04 LTS "Example" - Release amd64',
            'Lubuntu 26.04.1 LTS "Example" - Release amd64', 'ubuntu 26.04.1 LTS "Example" - Release amd64')) {
        Reset-LabLinuxIsoFakes
        $script:FakeLinuxInfoText = $text
        $info = Get-LabLinuxIsoInfo 'C:\iso\flavor.iso'
        Assert-Equal $info.ReleaseText $text
        Assert-Equal $info.IsUbuntuDesktopInScope $false
    }
    Reset-LabLinuxIsoFakes
    $script:FakeLinuxInfoText = 'Ubuntu 26.04 LTS "Example" - Release amd64'
    Assert-Equal (Get-LabLinuxIsoInfo 'C:\iso\ubuntu.iso').IsUbuntuDesktopInScope $true
}
Test-Case 'Get-LabLinuxIsoInfo: Ubuntu-Server 26.04.x is in scope for Server, not Desktop' {
    Reset-LabLinuxIsoFakes
    $script:FakeLinuxInfoText = 'Ubuntu-Server 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)'
    $info = Get-LabLinuxIsoInfo 'C:\iso\server.iso'
    Assert-Equal $info.IsUbuntuServerInScope $true
    Assert-Equal $info.IsUbuntuDesktopInScope $false
}
Test-Case 'Get-LabLinuxIsoInfo: Ubuntu Desktop 26.04.x is NOT in scope for Server' {
    Reset-LabLinuxIsoFakes
    $script:FakeLinuxInfoText = 'Ubuntu 26.04.1 LTS "Example" - Release amd64'
    $info = Get-LabLinuxIsoInfo 'C:\iso\ubuntu.iso'
    Assert-Equal $info.IsUbuntuServerInScope $false
}
Test-Case 'Get-LabLinuxIsoInfo: Kubuntu/Xubuntu/Lubuntu-Server-ish strings are never in scope for Server (anchored, case-sensitive match)' {
    foreach ($text in @('Kubuntu-Server 26.04.1 LTS "Example" - Release amd64', 'Xubuntu-Server 26.04 LTS "Example" - Release amd64',
            'Lubuntu-Server 26.04.1 LTS "Example" - Release amd64', 'ubuntu-server 26.04.1 LTS "Example" - Release amd64')) {
        Reset-LabLinuxIsoFakes
        $script:FakeLinuxInfoText = $text
        $info = Get-LabLinuxIsoInfo 'C:\iso\flavor.iso'
        Assert-Equal $info.IsUbuntuServerInScope $false
    }
    Reset-LabLinuxIsoFakes
    $script:FakeLinuxInfoText = 'Ubuntu-Server 26.04 LTS "Example" - Release amd64'
    Assert-Equal (Get-LabLinuxIsoInfo 'C:\iso\server.iso').IsUbuntuServerInScope $true
}
Test-Case 'Get-LabLinuxIsoInfo: a mounted ISO with no .disk/info returns empty ReleaseText and no error' {
    Reset-LabLinuxIsoFakes
    $script:FakeLinuxInfoExists = $false
    $info = Get-LabLinuxIsoInfo 'C:\iso\not-ubuntu.iso'
    Assert-Equal $info.ReleaseText ''
    Assert-Equal $info.IsUbuntuDesktopInScope $false
    Assert-Equal $script:LinuxDismountCalls 1
}
Test-Case 'Get-LabLinuxIsoInfo: Dismount-DiskImage still runs, in a finally, when reading .disk/info throws' {
    Reset-LabLinuxIsoFakes
    $script:FakeLinuxInfoReadThrows = 'simulated .disk/info read failure'
    Assert-Throws { Get-LabLinuxIsoInfo 'C:\iso\bad.iso' } 'simulated .disk/info read failure'
    Assert-Equal $script:LinuxMountCalls 1
    Assert-Equal $script:LinuxDismountCalls 1
}

# --- Linux unattended install, Task 2: New-LabPatchedBootableLinuxIso ---
# Pure byte-array math over a hand-built synthetic ISO9660+Joliet fixture -- no Mount-DiskImage, no
# Hyper-V, matching this function's own "parse directly from the file on disk" discipline. Copy-Item
# is the SAME global fake already defined above (around line 1073): a real local copy that
# increments $script:CopyCalls, asserted against here exactly like the New-LabPatchedBootableIso
# tests above do.

# Builds one ISO9660 directory record (ECMA-119 9.1): LEN_DR (byte 0), extent location and data
# length each in ISO9660's both-byte-order (LSB_MSB) 8-byte encoding, file flags (bit 0x02 =
# directory), and a variable-length file identifier with a padding byte when its own length is
# even (keeps the whole record an even number of bytes, per the standard).
function New-LabIso9660DirRecordBytes {
    param([uint32]$ExtentSector, [uint32]$DataLength, [byte]$FileFlags, [byte[]]$FileIdBytes)
    $lenFi = $FileIdBytes.Length
    $needsPad = (($lenFi % 2) -eq 0)
    $lenDr = 33 + $lenFi + [int]$needsPad
    $record = New-Object byte[] $lenDr
    $record[0] = [byte]$lenDr
    $record[1] = 0
    [Array]::Copy([BitConverter]::GetBytes([uint32]$ExtentSector), 0, $record, 2, 4)
    $extentMsb = [BitConverter]::GetBytes([uint32]$ExtentSector); [Array]::Reverse($extentMsb)
    [Array]::Copy($extentMsb, 0, $record, 6, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$DataLength), 0, $record, 10, 4)
    $lengthMsb = [BitConverter]::GetBytes([uint32]$DataLength); [Array]::Reverse($lengthMsb)
    [Array]::Copy($lengthMsb, 0, $record, 14, 4)
    $record[25] = $FileFlags
    [Array]::Copy([BitConverter]::GetBytes([uint16]1), 0, $record, 28, 2)
    $seqMsb = [BitConverter]::GetBytes([uint16]1); [Array]::Reverse($seqMsb)
    [Array]::Copy($seqMsb, 0, $record, 30, 2)
    $record[32] = [byte]$lenFi
    [Array]::Copy($FileIdBytes, 0, $record, 33, $lenFi)
    return $record
}
# Packs directory records back-to-back into a single 2048-byte sector -- the remaining bytes stay
# zero, which IS the "no more records in this sector" signal this fixture's own records rely on.
function New-LabIso9660DirectorySectorBytes {
    param([object[]]$Records)
    $sector = New-Object byte[] 2048
    $pos = 0
    foreach ($record in $Records) {
        [Array]::Copy($record, 0, $sector, $pos, $record.Length)
        $pos += $record.Length
    }
    return $sector
}

# Hand-builds a minimal, valid-shaped ISO9660+Joliet fixture file: a Primary Volume Descriptor
# (sector 16), a Boot Record Volume Descriptor (sector 17, type 0 -- El Torito's own sector, just
# present with type byte 0 so the real function's volume-descriptor-set scan has to walk past a
# non-SVD descriptor, exactly like a real Hyper-V-bootable Ubuntu ISO), a Joliet Supplementary
# Volume Descriptor (sector 18, identified by the UCS-2 Level 3 "%/E" escape sequence at byte
# offset 88 -- deliberately NOT at the brief's originally-assumed fixed sector 17, which is where
# the BRVD lives instead), and a Volume Descriptor Set Terminator (sector 19, type 255) so the scan
# has a real stopping condition to prove against. The PVD and Joliet SVD each carry their own root
# directory record (offset 156, 34 bytes -- fixed, since the root's own file identifier is a single
# NUL byte) pointing at a parallel root -> boot -> grub -> grub.cfg chain of single-sector directory
# extents (sectors 20/21 root, 22/23 boot, 24/25 grub; primary/Joliet respectively), with grub.cfg's
# own content at sector 26 in BOTH trees -- a real ISO keeps ONE copy of a file's data referenced by
# both namespaces, which is exactly what this fixture mirrors. The primary tree's directory names
# are uppercase-only with a trailing ";<version>" on the file name ('BOOT', 'GRUB', 'GRUB.CFG;1'),
# matching real xorriso/libisofs output; the Joliet tree keeps the "nice" lowercase names but still
# versions its leaf ('boot', 'grub', 'grub.cfg;1'), so the patch function's identifier normalization
# is genuinely exercised by this fixture, not assumed away. $GrubCfgContent becomes grub.cfg's exact
# recorded data length -- it is written at sector 26 verbatim, with the sector's remainder left zero
# (real slack space to grow into, unless $GrubCfgContent itself is already a full 2048 bytes).
# $IncludeGrubCfgEntry=$false omits grub.cfg's own entry from the 'GRUB'/'grub' directory extent in
# both trees (simulating an ISO layout this technique's fixed root/boot/grub/grub.cfg path doesn't
# find).
function New-LabFakeLinuxIso9660 {
    param([string]$Path, [string]$GrubCfgContent, [bool]$IncludeGrubCfgEntry = $true)
    $sectorSize = 2048
    $totalSectors = 30
    $rootExtentPrimary = 20; $rootExtentJoliet = 21
    $bootExtentPrimary = 22; $bootExtentJoliet = 23
    $grubExtentPrimary = 24; $grubExtentJoliet = 25
    $grubCfgExtent = 26

    $bytes = New-Object byte[] ($totalSectors * $sectorSize)

    $grubCfgBytes = [Text.Encoding]::ASCII.GetBytes($GrubCfgContent)
    if ($grubCfgBytes.Length -gt $sectorSize) { throw "Fixture GrubCfgContent must fit in this fixture's single-sector extent." }
    [Array]::Copy($grubCfgBytes, 0, $bytes, ($grubCfgExtent * $sectorSize), $grubCfgBytes.Length)

    $dot = [byte[]]@(0)
    $dotDot = [byte[]]@(1)

    # 'grub'/'GRUB' directory extents: '.', '..', and (unless suppressed) grub.cfg itself. Primary
    # tree: uppercase, versioned leaf ('GRUB.CFG;1'). Joliet tree: lowercase, versioned leaf
    # ('grub.cfg;1') -- real tools version Joliet file leaves too, just not the directory names.
    $grubRecordsPrimary = [Collections.Generic.List[object]]::new()
    $grubRecordsPrimary.Add((New-LabIso9660DirRecordBytes -ExtentSector $grubExtentPrimary -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dot))
    $grubRecordsPrimary.Add((New-LabIso9660DirRecordBytes -ExtentSector $bootExtentPrimary -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dotDot))
    $grubRecordsJoliet = [Collections.Generic.List[object]]::new()
    $grubRecordsJoliet.Add((New-LabIso9660DirRecordBytes -ExtentSector $grubExtentJoliet -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dot))
    $grubRecordsJoliet.Add((New-LabIso9660DirRecordBytes -ExtentSector $bootExtentJoliet -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dotDot))
    if ($IncludeGrubCfgEntry) {
        $grubRecordsPrimary.Add((New-LabIso9660DirRecordBytes -ExtentSector $grubCfgExtent -DataLength $grubCfgBytes.Length -FileFlags 0x00 -FileIdBytes ([Text.Encoding]::ASCII.GetBytes('GRUB.CFG;1'))))
        $grubRecordsJoliet.Add((New-LabIso9660DirRecordBytes -ExtentSector $grubCfgExtent -DataLength $grubCfgBytes.Length -FileFlags 0x00 -FileIdBytes ([Text.Encoding]::BigEndianUnicode.GetBytes('grub.cfg;1'))))
    }
    [Array]::Copy((New-LabIso9660DirectorySectorBytes $grubRecordsPrimary.ToArray()), 0, $bytes, ($grubExtentPrimary * $sectorSize), $sectorSize)
    [Array]::Copy((New-LabIso9660DirectorySectorBytes $grubRecordsJoliet.ToArray()), 0, $bytes, ($grubExtentJoliet * $sectorSize), $sectorSize)

    # 'boot'/'BOOT' directory extents: '.', '..', and 'grub'/'GRUB'. Primary tree names are
    # uppercase, unversioned (directories don't carry a ";<version>" suffix).
    $bootRecordsPrimary = @(
        (New-LabIso9660DirRecordBytes -ExtentSector $bootExtentPrimary -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dot),
        (New-LabIso9660DirRecordBytes -ExtentSector $rootExtentPrimary -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dotDot),
        (New-LabIso9660DirRecordBytes -ExtentSector $grubExtentPrimary -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes ([Text.Encoding]::ASCII.GetBytes('GRUB')))
    )
    $bootRecordsJoliet = @(
        (New-LabIso9660DirRecordBytes -ExtentSector $bootExtentJoliet -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dot),
        (New-LabIso9660DirRecordBytes -ExtentSector $rootExtentJoliet -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dotDot),
        (New-LabIso9660DirRecordBytes -ExtentSector $grubExtentJoliet -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes ([Text.Encoding]::BigEndianUnicode.GetBytes('grub')))
    )
    [Array]::Copy((New-LabIso9660DirectorySectorBytes $bootRecordsPrimary), 0, $bytes, ($bootExtentPrimary * $sectorSize), $sectorSize)
    [Array]::Copy((New-LabIso9660DirectorySectorBytes $bootRecordsJoliet), 0, $bytes, ($bootExtentJoliet * $sectorSize), $sectorSize)

    # Root directory extents: '.', '..', and 'boot'/'BOOT'.
    $rootRecordsPrimary = @(
        (New-LabIso9660DirRecordBytes -ExtentSector $rootExtentPrimary -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dot),
        (New-LabIso9660DirRecordBytes -ExtentSector $rootExtentPrimary -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dotDot),
        (New-LabIso9660DirRecordBytes -ExtentSector $bootExtentPrimary -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes ([Text.Encoding]::ASCII.GetBytes('BOOT')))
    )
    $rootRecordsJoliet = @(
        (New-LabIso9660DirRecordBytes -ExtentSector $rootExtentJoliet -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dot),
        (New-LabIso9660DirRecordBytes -ExtentSector $rootExtentJoliet -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dotDot),
        (New-LabIso9660DirRecordBytes -ExtentSector $bootExtentJoliet -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes ([Text.Encoding]::BigEndianUnicode.GetBytes('boot')))
    )
    [Array]::Copy((New-LabIso9660DirectorySectorBytes $rootRecordsPrimary), 0, $bytes, ($rootExtentPrimary * $sectorSize), $sectorSize)
    [Array]::Copy((New-LabIso9660DirectorySectorBytes $rootRecordsJoliet), 0, $bytes, ($rootExtentJoliet * $sectorSize), $sectorSize)

    # Primary Volume Descriptor (sector 16): type 1, 'CD001', root directory record at offset 156.
    $pvd = New-Object byte[] $sectorSize
    $pvd[0] = 1
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('CD001'), 0, $pvd, 1, 5)
    $pvd[6] = 1
    $rootRecordPvd = New-LabIso9660DirRecordBytes -ExtentSector $rootExtentPrimary -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dot
    [Array]::Copy($rootRecordPvd, 0, $pvd, 156, $rootRecordPvd.Length)
    [Array]::Copy($pvd, 0, $bytes, (16 * $sectorSize), $sectorSize)

    # Boot Record Volume Descriptor (sector 17): type 0, 'CD001'. Doesn't need to be a fully
    # valid/bootable El Torito BRVD -- just present with type byte 0, so the real function's
    # volume-descriptor-set scan has to walk past a non-SVD, non-terminator descriptor to reach the
    # Joliet SVD one sector later, exactly as a real El-Torito-bootable ISO forces it to.
    $brvd = New-Object byte[] $sectorSize
    $brvd[0] = 0
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('CD001'), 0, $brvd, 1, 5)
    [Array]::Copy($brvd, 0, $bytes, (17 * $sectorSize), $sectorSize)

    # Supplementary (Joliet) Volume Descriptor (sector 18, NOT 17 -- that's the BRVD above): type 2,
    # 'CD001', the UCS-2 Level 3 escape sequence (0x25 0x2F 0x45, "%/E") at byte offset 88, root
    # directory record at offset 156.
    $svd = New-Object byte[] $sectorSize
    $svd[0] = 2
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('CD001'), 0, $svd, 1, 5)
    $svd[6] = 1
    $svd[88] = 0x25; $svd[89] = 0x2F; $svd[90] = 0x45
    $rootRecordSvd = New-LabIso9660DirRecordBytes -ExtentSector $rootExtentJoliet -DataLength $sectorSize -FileFlags 0x02 -FileIdBytes $dot
    [Array]::Copy($rootRecordSvd, 0, $svd, 156, $rootRecordSvd.Length)
    [Array]::Copy($svd, 0, $bytes, (18 * $sectorSize), $sectorSize)

    # Volume Descriptor Set Terminator (sector 19): type 255, 'CD001' -- the scan's real stopping
    # condition.
    $terminator = New-Object byte[] $sectorSize
    $terminator[0] = 255
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('CD001'), 0, $terminator, 1, 5)
    [Array]::Copy($terminator, 0, $bytes, (19 * $sectorSize), $sectorSize)

    [IO.File]::WriteAllBytes($Path, $bytes)
}

# Independent re-derivation (NOT a call into New-LabPatchedBootableLinuxIso) of grub.cfg's own
# directory record in one tree, by walking root -> boot -> grub -> grub.cfg from raw bytes per
# ECMA-119 9.1, the same way the real function is expected to. Used to read back and verify the
# patched output without just trusting the function's own internal offsets.
function Find-LabFakeDirRecord {
    param([byte[]]$Bytes, [int]$ExtentSector, [int]$DataLength, [string]$Name, [bool]$Joliet)
    $sectorSize = 2048
    $offset = $ExtentSector * $sectorSize
    $pos = 0
    while ($pos -lt $DataLength) {
        $lenDr = [int]$Bytes[$offset + $pos]
        if ($lenDr -eq 0) { break }
        $lenFi = [int]$Bytes[$offset + $pos + 32]
        $fileIdBytes = $Bytes[($offset + $pos + 33)..($offset + $pos + 33 + $lenFi - 1)]
        $isDotEntry = ($lenFi -eq 1 -and ($fileIdBytes[0] -eq 0 -or $fileIdBytes[0] -eq 1))
        if (-not $isDotEntry) {
            $fileName = if ($Joliet) { [Text.Encoding]::BigEndianUnicode.GetString($fileIdBytes) } else { [Text.Encoding]::ASCII.GetString($fileIdBytes) }
            # Mirrors the real function's own normalization: strip a trailing ";<version>" suffix in
            # either tree, then compare the primary tree case-insensitively (real uppercase d-chars)
            # and the Joliet tree case-sensitively (real tools preserve Joliet's original case).
            $normalizedFileName = $fileName -replace ';\d+$', ''
            $isNameMatch = if ($Joliet) { $normalizedFileName -ceq $Name } else { $normalizedFileName -ieq $Name }
            if ($isNameMatch) {
                return [pscustomobject]@{
                    ExtentSector = [int][BitConverter]::ToUInt32($Bytes, $offset + $pos + 2)
                    DataLength = [int][BitConverter]::ToUInt32($Bytes, $offset + $pos + 10)
                    DataLengthFieldOffset = [int]($offset + $pos + 10)
                }
            }
        }
        $pos += $lenDr
    }
    return $null
}
function Get-LabFakeLinuxGrubCfgInfo {
    param([string]$Path, [bool]$Joliet)
    $sectorSize = 2048
    $bytes = [IO.File]::ReadAllBytes($Path)
    # Sector 18, not 17 -- sector 17 in this fixture is the Boot Record Volume Descriptor (El
    # Torito), exactly like a real El-Torito-bootable ISO; see New-LabFakeLinuxIso9660.
    $vdOffset = $(if ($Joliet) { 18 } else { 16 }) * $sectorSize
    $extent = [int][BitConverter]::ToUInt32($bytes, $vdOffset + 156 + 2)
    $length = [int][BitConverter]::ToUInt32($bytes, $vdOffset + 156 + 10)
    $record = $null
    foreach ($name in @('boot', 'grub', 'grub.cfg')) {
        $record = Find-LabFakeDirRecord -Bytes $bytes -ExtentSector $extent -DataLength $length -Name $name -Joliet $Joliet
        if ($null -eq $record) { return $null }
        $extent = $record.ExtentSector
        $length = $record.DataLength
    }
    $contentStart = $record.ExtentSector * $sectorSize
    $contentBytes = $bytes[$contentStart..($contentStart + $record.DataLength - 1)]
    return [pscustomobject]@{
        ExtentSector = $record.ExtentSector
        DataLength = $record.DataLength
        DataLengthFieldOffset = $record.DataLengthFieldOffset
        Content = [Text.Encoding]::ASCII.GetString($contentBytes)
    }
}

Test-Case 'New-LabPatchedBootableLinuxIso: happy path inserts autoinstall and updates both trees, everything else unchanged' {
    $script:CopyCalls = 0; $script:CopyMode = 'Normal'
    $kernelLine = "`tlinux`t/casper/vmlinuz quiet splash ---"
    $grubCfgContent = "menuentry 'Try or Install Ubuntu' {`n$kernelLine`n`tinitrd`t/casper/initrd`n}`n"
    $expectedPatchedLine = "`tlinux`t/casper/vmlinuz quiet splash autoinstall ---"
    $expectedContent = "menuentry 'Try or Install Ubuntu' {`n$expectedPatchedLine`n`tinitrd`t/casper/initrd`n}`n"
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('lablinuxiso-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('lablinuxiso-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    try {
        New-LabFakeLinuxIso9660 -Path $isoPath -GrubCfgContent $grubCfgContent
        $sourceBytes = [IO.File]::ReadAllBytes($isoPath)
        $beforePrimary = Get-LabFakeLinuxGrubCfgInfo -Path $isoPath -Joliet $false
        $beforeJoliet = Get-LabFakeLinuxGrubCfgInfo -Path $isoPath -Joliet $true
        Assert-Equal $beforePrimary.Content $grubCfgContent
        Assert-Equal $beforeJoliet.Content $grubCfgContent

        $result = New-LabPatchedBootableLinuxIso $isoPath $outputPath

        Assert-Equal $result.Patched $true
        Assert-Equal $result.OutputPath $outputPath
        Assert-Equal (Test-Path -LiteralPath $outputPath -PathType Leaf) $true

        $afterPrimary = Get-LabFakeLinuxGrubCfgInfo -Path $outputPath -Joliet $false
        $afterJoliet = Get-LabFakeLinuxGrubCfgInfo -Path $outputPath -Joliet $true
        Assert-Equal $afterPrimary.Content $expectedContent
        Assert-Equal $afterJoliet.Content $expectedContent
        Assert-Equal $afterPrimary.DataLength ([Text.Encoding]::ASCII.GetByteCount($expectedContent))
        Assert-Equal $afterJoliet.DataLength $afterPrimary.DataLength
        Assert-Equal $afterPrimary.ExtentSector $beforePrimary.ExtentSector
        Assert-Equal $afterJoliet.ExtentSector $beforeJoliet.ExtentSector

        # Everything outside the touched regions (grub.cfg's content sector, plus both trees' own
        # 8-byte data-length fields) must be byte-identical to the original source ISO: rebuild
        # those regions back to their original content and hash-compare the whole file.
        $outputBytes = [IO.File]::ReadAllBytes($outputPath)
        Assert-Equal $outputBytes.Length $sourceBytes.Length
        $reconstructed = [byte[]]$outputBytes.Clone()
        $sectorSize = 2048
        $contentSectorStart = $beforePrimary.ExtentSector * $sectorSize
        [Array]::Copy($sourceBytes, $contentSectorStart, $reconstructed, $contentSectorStart, $sectorSize)
        [Array]::Copy($sourceBytes, $beforePrimary.DataLengthFieldOffset, $reconstructed, $beforePrimary.DataLengthFieldOffset, 8)
        [Array]::Copy($sourceBytes, $beforeJoliet.DataLengthFieldOffset, $reconstructed, $beforeJoliet.DataLengthFieldOffset, 8)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        $beforeHash = [Convert]::ToBase64String($sha256.ComputeHash($sourceBytes))
        $afterHash = [Convert]::ToBase64String($sha256.ComputeHash($reconstructed))
        Assert-Equal $afterHash $beforeHash

        Assert-Equal $script:CopyCalls 1
    } finally {
        Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'New-LabPatchedBootableLinuxIso: a mid-line --- (casper''s marker) gets autoinstall inserted BEFORE it, not appended after it' {
    $script:CopyCalls = 0; $script:CopyMode = 'Normal'
    $grubCfgContent = "menuentry 'Try or Install Ubuntu' {`n`tlinux`t/casper/vmlinuz --- quiet splash`n`tinitrd`t/casper/initrd`n}`n"
    $expectedContent = "menuentry 'Try or Install Ubuntu' {`n`tlinux`t/casper/vmlinuz autoinstall --- quiet splash`n`tinitrd`t/casper/initrd`n}`n"
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('lablinuxiso-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('lablinuxiso-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    try {
        New-LabFakeLinuxIso9660 -Path $isoPath -GrubCfgContent $grubCfgContent
        $result = New-LabPatchedBootableLinuxIso $isoPath $outputPath
        Assert-Equal $result.Patched $true
        $afterPrimary = Get-LabFakeLinuxGrubCfgInfo -Path $outputPath -Joliet $false
        $afterJoliet = Get-LabFakeLinuxGrubCfgInfo -Path $outputPath -Joliet $true
        Assert-Equal $afterPrimary.Content $expectedContent
        Assert-Equal $afterJoliet.Content $expectedContent
        $kernelLine = @($afterPrimary.Content -split "`n" | Where-Object { $_ -match '/casper/vmlinuz' })[0]
        Assert-Equal ($kernelLine.IndexOf('autoinstall') -lt $kernelLine.IndexOf('---')) $true
    } finally {
        Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'New-LabPatchedBootableLinuxIso: insufficient slack space refuses, no output file created' {
    $script:CopyCalls = 0; $script:CopyMode = 'Normal'
    $kernelLine = "`tlinux`t/casper/vmlinuz quiet splash ---`n"
    $padLength = 2048 - $kernelLine.Length
    $grubCfgContent = $kernelLine + ('#' * $padLength)
    if ($grubCfgContent.Length -ne 2048) { throw "Fixture content is $($grubCfgContent.Length) byte(s), expected exactly 2048 to leave no slack." }
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('lablinuxiso-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('lablinuxiso-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    try {
        New-LabFakeLinuxIso9660 -Path $isoPath -GrubCfgContent $grubCfgContent

        $result = New-LabPatchedBootableLinuxIso $isoPath $outputPath

        Assert-Equal $result.Patched $false
        if ($result.Reason -notmatch 'slack|space') { throw "Reason did not mention space/slack: $($result.Reason)" }
        Assert-Equal $result.OutputPath $null
        Assert-Equal (Test-Path -LiteralPath $outputPath -PathType Leaf) $false
        Assert-Equal $script:CopyCalls 0
    } finally {
        Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'New-LabPatchedBootableLinuxIso: no recognizable linux/kernel line refuses, no output file created' {
    $script:CopyCalls = 0; $script:CopyMode = 'Normal'
    $grubCfgContent = "menuentry 'Nothing recognizable' {`n`techo nope`n}`n"
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('lablinuxiso-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('lablinuxiso-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    try {
        New-LabFakeLinuxIso9660 -Path $isoPath -GrubCfgContent $grubCfgContent

        $result = New-LabPatchedBootableLinuxIso $isoPath $outputPath

        Assert-Equal $result.Patched $false
        if ($result.Reason -notmatch 'linux|kernel') { throw "Reason did not say no recognizable kernel line was found: $($result.Reason)" }
        Assert-Equal $result.OutputPath $null
        Assert-Equal (Test-Path -LiteralPath $outputPath -PathType Leaf) $false
        Assert-Equal $script:CopyCalls 0
    } finally {
        Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'New-LabPatchedBootableLinuxIso: grub.cfg not found at the expected path refuses, no output file created' {
    $script:CopyCalls = 0; $script:CopyMode = 'Normal'
    $isoPath = Join-Path ([IO.Path]::GetTempPath()) ('lablinuxiso-src-' + [guid]::NewGuid().ToString('N') + '.iso')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('lablinuxiso-out-' + [guid]::NewGuid().ToString('N') + '.iso')
    try {
        New-LabFakeLinuxIso9660 -Path $isoPath -GrubCfgContent 'unused' -IncludeGrubCfgEntry $false

        $result = New-LabPatchedBootableLinuxIso $isoPath $outputPath

        Assert-Equal $result.Patched $false
        if ($result.Reason -notmatch 'grub\.cfg') { throw "Reason did not name grub.cfg: $($result.Reason)" }
        if ($result.Reason -notmatch 'not found') { throw "Reason did not say grub.cfg was not found: $($result.Reason)" }
        Assert-Equal $result.OutputPath $null
        Assert-Equal (Test-Path -LiteralPath $outputPath -PathType Leaf) $false
        Assert-Equal $script:CopyCalls 0
    } finally {
        Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}

# --- Linux unattended install, Task 3: NoCloud user-data content builder ---
# All three functions are pure -- no fakes needed, call them directly.
Test-Case 'ConvertTo-LabPosixShellSingleQuoted escapes an embedded single quote via close-escape-reopen' {
    Assert-Equal (ConvertTo-LabPosixShellSingleQuoted "it's") "'it'\''s'"
}
Test-Case 'ConvertTo-LabPosixShellSingleQuoted wraps a value with no special characters unchanged' {
    Assert-Equal (ConvertTo-LabPosixShellSingleQuoted 'value') "'value'"
}
Test-Case 'ConvertTo-LabPosixShellSingleQuoted on the empty string returns an empty quoted literal' {
    Assert-Equal (ConvertTo-LabPosixShellSingleQuoted '') "''"
}

Test-Case 'Test-LabLinuxUserName accepts adduser-compatible names' {
    Assert-Equal (Test-LabLinuxUserName 'dev') $true
    Assert-Equal (Test-LabLinuxUserName 'lab_agent') $true
}
Test-Case 'Test-LabLinuxUserName rejects uppercase, a leading digit, empty, and over-length names' {
    Assert-Equal (Test-LabLinuxUserName 'Dev') $false
    Assert-Equal (Test-LabLinuxUserName '1dev') $false
    Assert-Equal (Test-LabLinuxUserName '') $false
    Assert-Equal (Test-LabLinuxUserName ('a' * 33)) $false
}

Test-Case 'New-LabLinuxAutoinstallUserData returns a well-formed autoinstall document carrying the given identity and ssh values' {
    $securePassword = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    $sshKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZ6K3K2exampleKey labagent'
    $result = New-LabLinuxAutoinstallUserData 'lab-agent-test' 'en_US.UTF-8' 'America/Belize' 'labagent' $securePassword $sshKey
    Assert-Equal ($result.Contains('autoinstall:')) $true
    Assert-Equal ($result.Contains('identity:')) $true
    Assert-Equal ($result.Contains('hostname: lab-agent-test')) $true
    Assert-Equal ($result.Contains('username: labagent')) $true
    Assert-Equal ($result.Contains('locale: en_US.UTF-8')) $true
    Assert-Equal ($result.Contains('ssh:')) $true
    Assert-Equal ($result.Contains('install-server: true')) $true
    Assert-Equal ($result.Contains('authorized-keys:')) $true
    Assert-Equal ($result.Contains("      - $sshKey")) $true
}
Test-Case 'New-LabLinuxAutoinstallUserData starts with the #cloud-config header NoCloud requires before autoinstall:' {
    # cloud-init only treats a NoCloud user-data file as cloud-config when its first line is exactly
    # '#cloud-config'; without it Subiquity never sees the autoinstall: key at all.
    $securePassword = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    $result = New-LabLinuxAutoinstallUserData 'lab-agent-test' 'en_US.UTF-8' 'America/Belize' 'labagent' $securePassword 'ssh-ed25519 AAAA k'
    $lines = @($result -split "`r?`n")
    Assert-Equal $lines[0] '#cloud-config'
    Assert-Equal $lines[1] 'autoinstall:'
}
Test-Case 'New-LabLinuxAutoinstallUserData ships a real SHA-512-crypt placeholder hash, not an invented string' {
    $securePassword = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    $result = New-LabLinuxAutoinstallUserData 'lab-agent-test' 'en_US.UTF-8' 'America/Belize' 'labagent' $securePassword 'ssh-ed25519 AAAA k'
    # The value generated by `openssl passwd -6` (see the function's own comment for the exact command).
    Assert-Equal ($result.Contains('password: "$6$rXrbP3d6DiE8gBnS$')) $true
}
Test-Case 'New-LabLinuxAutoinstallUserData output varies with its inputs, with no hardcoded leftover from a first draft' {
    $securePasswordA = ConvertTo-SecureString 'SecretA1!' -AsPlainText -Force
    $securePasswordB = ConvertTo-SecureString 'SecretB2!' -AsPlainText -Force
    $resultA = New-LabLinuxAutoinstallUserData 'lab-one' 'en_US.UTF-8' 'America/Belize' 'alice' $securePasswordA 'ssh-ed25519 AAAA-key-one alice'
    $resultB = New-LabLinuxAutoinstallUserData 'lab-two' 'fr_FR.UTF-8' 'Europe/Paris' 'bob' $securePasswordB 'ssh-ed25519 AAAA-key-two bob'
    Assert-Equal ($resultA -eq $resultB) $false
    Assert-Equal ($resultA.Contains('hostname: lab-one')) $true
    Assert-Equal ($resultB.Contains('hostname: lab-two')) $true
    Assert-Equal ($resultA.Contains('username: alice')) $true
    Assert-Equal ($resultB.Contains('username: bob')) $true
    Assert-Equal ($resultA.Contains('locale: en_US.UTF-8')) $true
    Assert-Equal ($resultB.Contains('locale: fr_FR.UTF-8')) $true
    Assert-Equal ($resultA.Contains('timezone: America/Belize')) $true
    Assert-Equal ($resultB.Contains('timezone: Europe/Paris')) $true
    Assert-Equal ($resultA.Contains('ssh-ed25519 AAAA-key-one alice')) $true
    Assert-Equal ($resultB.Contains('ssh-ed25519 AAAA-key-two bob')) $true
}
Test-Case 'New-LabLinuxAutoinstallUserData: identity.password is a $6$ hash shape, and the real password appears nowhere except inside late-commands' {
    $plainPassword = 'Secret123!'
    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    $result = New-LabLinuxAutoinstallUserData 'lab-agent-test' 'en_US.UTF-8' 'America/Belize' 'labagent' $securePassword 'ssh-ed25519 AAAAexampleKey labagent'
    $lines = $result -split "`r?`n"
    $identityPasswordLine = @($lines | Where-Object { $_ -match '^\s*password:' })
    if ($identityPasswordLine.Count -ne 1) { throw "Expected exactly one identity.password line, found $($identityPasswordLine.Count)." }
    if ($identityPasswordLine[0] -notmatch '\$6\$[^"]+\$[^"]+') { throw "identity.password is not a `$6`$ hash shape: $($identityPasswordLine[0])" }
    Assert-Equal ($identityPasswordLine[0].Contains($plainPassword)) $false
    $curtinLines = @($lines | Where-Object { $_ -match 'curtin' })
    if ($curtinLines.Count -ne 1) { throw "Expected exactly one late-commands curtin line, found $($curtinLines.Count)." }
    Assert-Equal ($curtinLines[0].Contains($plainPassword)) $true
    foreach ($line in $lines) {
        if ($line -eq $curtinLines[0]) { continue }
        if ($line.Contains($plainPassword)) { throw "Plaintext password leaked outside late-commands: $line" }
    }
}
function Get-LabRecoveredChpasswdInput {
    # Reverses every syntax layer between New-LabLinuxAutoinstallUserData's output and the bytes chpasswd
    # reads on stdin, returning that "user:password" text. Layers: YAML double-quoted scalar, then the
    # POSIX shell single-quoted argument, then the command that prints it. That last layer is required
    # to be exactly printf '%s\n' <arg>, which prints <arg> verbatim (unlike dash's echo, which would
    # rewrite backslash escapes), so recovering <arg> is recovering chpasswd's input.
    param([string]$UserData)
    $curtinLine = @(($UserData -split "`r?`n") | Where-Object { $_ -match 'curtin' })
    if ($curtinLine.Count -ne 1) { throw "Expected exactly one late-commands curtin line, found $($curtinLine.Count)." }
    $curtinLine = $curtinLine[0]

    # Pull out the sole double-quoted YAML scalar on that line -- the escaped shell command.
    $firstQuote = $curtinLine.IndexOf('"')
    $lastQuote = $curtinLine.LastIndexOf('"')
    if ($firstQuote -lt 0 -or $lastQuote -le $firstQuote) { throw "Could not find the double-quoted shell-command scalar in: $curtinLine" }
    $yamlScalar = $curtinLine.Substring($firstQuote, $lastQuote - $firstQuote + 1)

    # Layer 1 reversal: a YAML double-quoted scalar is unescaped the same way a JSON string literal
    # is -- ConvertFrom-Json on the exact text ConvertTo-Json -Compress produced in the implementation.
    $shellCommand = $yamlScalar | ConvertFrom-Json

    # Layer 2 reversal: simulate what a POSIX shell does with a '...'-quoted argument -- strip the
    # surrounding "printf '%s\n' "/' | chpasswd', then mechanically undo the single-quote escape
    # (close-quote, escaped literal quote, reopen-quote -- '\'' -- becomes one literal '). Inside
    # single quotes a POSIX shell treats every other character, backslash included, literally.
    $prefix = "printf '%s\n' "
    $suffix = ' | chpasswd'
    if (-not $shellCommand.StartsWith($prefix)) { throw "Unexpected shell command prefix (must be printf '%s\n', never echo): $shellCommand" }
    if (-not $shellCommand.EndsWith($suffix)) { throw "Unexpected shell command suffix: $shellCommand" }
    $quotedLiteral = $shellCommand.Substring($prefix.Length, $shellCommand.Length - $prefix.Length - $suffix.Length)
    if (-not ($quotedLiteral.StartsWith("'") -and $quotedLiteral.EndsWith("'"))) { throw "Not a single-quoted literal: $quotedLiteral" }
    $inner = $quotedLiteral.Substring(1, $quotedLiteral.Length - 2)
    # Every ' inside must be part of a '\'' sequence; anything else would end the quoting early.
    if ($inner.Replace("'\''", '').Contains("'")) { throw "Unescaped single quote inside the quoted literal: $quotedLiteral" }
    return $inner.Replace("'\''", "'")
}
Test-Case 'New-LabLinuxAutoinstallUserData: a password containing a single quote, double quote, backslash and dollar sign reaches chpasswd unchanged (Review Focus #4)' {
    # P@ss'"\$word -- built as a single-quoted PowerShell literal so none of ' " \ $ are PowerShell-special here.
    $plainPassword = 'P@ss''"\$word'
    $userName = 'labagent'
    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    $result = New-LabLinuxAutoinstallUserData 'lab-agent-test' 'en_US.UTF-8' 'America/Belize' $userName $securePassword 'ssh-ed25519 AAAAexampleKey labagent'
    $unescaped = Get-LabRecoveredChpasswdInput $result

    $colonIndex = $unescaped.IndexOf(':')
    if ($colonIndex -lt 0) { throw "No ':' separator found in recovered 'user:password': $unescaped" }
    $recoveredUserName = $unescaped.Substring(0, $colonIndex)
    $recoveredPassword = $unescaped.Substring($colonIndex + 1)

    Assert-Equal $recoveredUserName $userName
    Assert-Equal $recoveredPassword $plainPassword
}
Test-Case 'New-LabLinuxAutoinstallUserData: a password with backslash escape sequences (\\, \c, \t, \n, \0) reaches chpasswd exactly, via printf, never echo' {
    # dash's builtin echo would turn \\ into \, \t into a tab and stop printing at \c; printf '%s\n'
    # passes all of them through. Single-quoted PowerShell literal: every backslash below is literal.
    $plainPassword = 'P@ss''"\$wo\\rd\cTail\t\n\0end\'
    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    $result = New-LabLinuxAutoinstallUserData 'lab-agent-test' 'en_US.UTF-8' 'America/Belize' 'labagent' $securePassword 'ssh-ed25519 AAAAexampleKey labagent'
    $recovered = Get-LabRecoveredChpasswdInput $result
    Assert-Equal $recovered "labagent:$plainPassword"
    Assert-Equal ($recovered.Contains('\\rd\cTail\t\n\0end\')) $true
    $curtinLine = @(($result -split "`r?`n") | Where-Object { $_ -match 'curtin' })[0]
    Assert-Equal ($curtinLine -match '\becho\b') $false
}

# --- Two-drive unattended-install media attach and post-install cleanup, Linux (Task 4) ---
# Mirrors the Windows Task 3 cases above, retargeted at the Linux functions.
Test-Case 'Set-LabVMUnattendedLinuxInstallMedia attaches both drives in order and sets DVD boot order' {
    $script:FakeDvdDrives.Clear()
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $script:SetVMFirmwareBootOrderCalls.Clear()
    $linuxIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-linux-' + [guid]::NewGuid().ToString('N') + '.iso')
    $seedIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-seed-' + [guid]::NewGuid().ToString('N') + '.iso')
    # The entries the two new drives would get on a live VM: the seed drive's listed first, so the
    # Linux-drive check must look past it rather than only at the very first entry.
    $script:FakeFirmware.BootOrder = @((New-FakeBootEntry 'Disk'), (New-FakeBootEntry 'Dvd' $seedIso), (New-FakeBootEntry 'Dvd' $linuxIso))
    [IO.File]::WriteAllBytes($linuxIso, [byte[]]@(1, 2, 3))
    [IO.File]::WriteAllBytes($seedIso, [byte[]]@(4, 5, 6))
    try {
        Set-LabVMUnattendedLinuxInstallMedia $script:FakeId $linuxIso $seedIso
        Assert-Equal $script:AddVMDvdDriveCalls 2
        Assert-Equal $script:FakeDvdDrives.Count 2
        Assert-Equal $script:FakeDvdDrives[0].Path $linuxIso
        Assert-Equal $script:FakeDvdDrives[1].Path $seedIso
        Assert-Equal ($script:SetVMDvdDriveCalls -join '|') "$linuxIso|$seedIso"
        Assert-Equal $script:SetVMFirmwareBootOrderCalls.Count 1
        $applied = @($script:SetVMFirmwareBootOrderCalls[0])
        Assert-Equal (Get-LabBootEntryKind $applied[0]) 'Dvd'
        Assert-Equal (Get-LabBootEntryKind $applied[1]) 'Dvd'
        Assert-Equal (Get-LabBootEntryKind $applied[2]) 'Disk'
    } finally {
        [IO.File]::Delete($linuxIso)
        [IO.File]::Delete($seedIso)
        $script:FakeDvdDrives.Clear()
    }
}
Test-Case 'Set-LabVMUnattendedLinuxInstallMedia throws when only the SEED drive has a recognized boot entry, not the Linux installer drive' {
    $script:FakeDvdDrives.Clear()
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $script:SetVMFirmwareBootOrderCalls.Clear()
    $linuxIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-linux-' + [guid]::NewGuid().ToString('N') + '.iso')
    $seedIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-seed-' + [guid]::NewGuid().ToString('N') + '.iso')
    # Only the seed drive's entry is recognizable: Set-LabVMBootOrder itself succeeds (some DVD
    # entry exists and is moved first), so only the new Linux-drive check can catch this.
    $script:FakeFirmware.BootOrder = @((New-FakeBootEntry 'Disk'), (New-FakeBootEntry 'Nic'), (New-FakeBootEntry 'Dvd' $seedIso))
    [IO.File]::WriteAllBytes($linuxIso, [byte[]]@(1, 2, 3))
    [IO.File]::WriteAllBytes($seedIso, [byte[]]@(4, 5, 6))
    try {
        Assert-Throws { Set-LabVMUnattendedLinuxInstallMedia $script:FakeId $linuxIso $seedIso } "Linux installer drive's own boot entry"
        # The reorder really did succeed first: this is the specific post-reorder check, not
        # Set-LabVMBootOrder's own generic "no Dvd entry was recognized" refusal.
        Assert-Equal $script:SetVMFirmwareBootOrderCalls.Count 1
        Assert-Equal (Get-LabBootEntryKind @($script:SetVMFirmwareBootOrderCalls[0])[0]) 'Dvd'
        Assert-Equal $script:FakeDvdDrives.Count 2
    } finally {
        [IO.File]::Delete($linuxIso)
        [IO.File]::Delete($seedIso)
        $script:FakeDvdDrives.Clear()
    }
}
Test-Case 'Set-LabVMUnattendedLinuxInstallMedia refuses a VM that already has a DVD drive, before any mutation' {
    $script:FakeDvdDrives.Clear()
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = $null })
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $linuxIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-linux-' + [guid]::NewGuid().ToString('N') + '.iso')
    $seedIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-seed-' + [guid]::NewGuid().ToString('N') + '.iso')
    [IO.File]::WriteAllBytes($linuxIso, [byte[]]@(1, 2, 3))
    [IO.File]::WriteAllBytes($seedIso, [byte[]]@(4, 5, 6))
    try {
        Assert-Throws { Set-LabVMUnattendedLinuxInstallMedia $script:FakeId $linuxIso $seedIso } 'DVD drive'
        Assert-Equal $script:AddVMDvdDriveCalls 0
        Assert-Equal $script:SetVMDvdDriveCalls.Count 0
    } finally {
        [IO.File]::Delete($linuxIso)
        [IO.File]::Delete($seedIso)
        $script:FakeDvdDrives.Clear()
    }
}
Test-Case 'Set-LabVMUnattendedLinuxInstallMedia refuses a Generation 1 VM, before any mutation' {
    $script:FakeVM.Generation = 1
    $script:FakeDvdDrives.Clear()
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $linuxIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-linux-' + [guid]::NewGuid().ToString('N') + '.iso')
    $seedIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-seed-' + [guid]::NewGuid().ToString('N') + '.iso')
    [IO.File]::WriteAllBytes($linuxIso, [byte[]]@(1, 2, 3))
    [IO.File]::WriteAllBytes($seedIso, [byte[]]@(4, 5, 6))
    try {
        Assert-Throws { Set-LabVMUnattendedLinuxInstallMedia $script:FakeId $linuxIso $seedIso } 'Generation'
        Assert-Equal $script:AddVMDvdDriveCalls 0
        Assert-Equal $script:SetVMDvdDriveCalls.Count 0
    } finally {
        $script:FakeVM.Generation = 2
        [IO.File]::Delete($linuxIso)
        [IO.File]::Delete($seedIso)
    }
}
Test-Case 'Set-LabVMUnattendedLinuxInstallMedia leaves the Linux drive attached, unrolled back, when the seed ISO fails re-validation' {
    $script:FakeDvdDrives.Clear()
    $script:AddVMDvdDriveCalls = 0
    $script:SetVMDvdDriveCalls.Clear()
    $linuxIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-linux-' + [guid]::NewGuid().ToString('N') + '.iso')
    [IO.File]::WriteAllBytes($linuxIso, [byte[]]@(1, 2, 3))
    $missingSeedIso = Join-Path ([IO.Path]::GetTempPath()) ('labiso-seed-missing-' + [guid]::NewGuid().ToString('N') + '.iso')
    try {
        Assert-Throws { Set-LabVMUnattendedLinuxInstallMedia $script:FakeId $linuxIso $missingSeedIso } 'no longer exists'
        # Proves the ordering: the Linux drive (drive 1) was already added and attached before the
        # seed ISO's re-validation ran and threw -- so no cleanup/rollback happens here.
        Assert-Equal $script:AddVMDvdDriveCalls 1
        Assert-Equal $script:FakeDvdDrives.Count 1
        Assert-Equal $script:FakeDvdDrives[0].Path $linuxIso
        Assert-Equal $script:SetVMDvdDriveCalls.Count 1
        Assert-Equal $script:SetVMDvdDriveCalls[0] $linuxIso
    } finally {
        [IO.File]::Delete($linuxIso)
        $script:FakeDvdDrives.Clear()
    }
}
Test-Case 'Complete-LabLinuxProvisioning removes the seed drive and ejects (not removes) the installer drive' {
    $linuxIso = 'D:\iso\linux.iso'
    $seedIso = 'D:\iso\seed.iso'
    $script:FakeDvdDrives.Clear()
    $linuxDrive = [pscustomobject]@{ Path = $linuxIso }
    $seedDrive = [pscustomobject]@{ Path = $seedIso }
    $script:FakeDvdDrives.Add($linuxDrive)
    $script:FakeDvdDrives.Add($seedDrive)
    $script:SetVMDvdDriveCalls.Clear()
    $script:RemoveVMDvdDriveCalls.Clear()
    $script:SetVMFirmwareBootOrderCalls.Clear()
    $script:FakeFirmware.BootOrder = @((New-FakeBootEntry 'Dvd'), (New-FakeBootEntry 'Disk'))
    Complete-LabLinuxProvisioning $script:FakeId $linuxIso $seedIso
    Assert-Equal $script:RemoveVMDvdDriveCalls.Count 1
    Assert-Equal ([object]::ReferenceEquals($script:RemoveVMDvdDriveCalls[0], $seedDrive)) $true
    Assert-Equal $script:FakeDvdDrives.Count 1
    Assert-Equal $script:SetVMDvdDriveCalls.Count 1
    Assert-Equal $script:SetVMDvdDriveCalls[0] ''
    Assert-Equal $linuxDrive.Path ''
    Assert-Equal $script:SetVMFirmwareBootOrderCalls.Count 1
    $applied = @($script:SetVMFirmwareBootOrderCalls[0])
    Assert-Equal (Get-LabBootEntryKind $applied[0]) 'Disk'
}
Test-Case 'Complete-LabLinuxProvisioning finds the Linux drive by elimination when the installer already self-ejected it' {
    $linuxIso = 'D:\iso\linux.iso'
    $seedIso = 'D:\iso\seed.iso'
    $script:FakeDvdDrives.Clear()
    $linuxDrive = [pscustomobject]@{ Path = '' }
    $seedDrive = [pscustomobject]@{ Path = $seedIso }
    $script:FakeDvdDrives.Add($linuxDrive)
    $script:FakeDvdDrives.Add($seedDrive)
    $script:SetVMDvdDriveCalls.Clear()
    $script:RemoveVMDvdDriveCalls.Clear()
    $script:SetVMFirmwareBootOrderCalls.Clear()
    $script:FakeFirmware.BootOrder = @((New-FakeBootEntry 'Dvd'), (New-FakeBootEntry 'Disk'))
    Complete-LabLinuxProvisioning $script:FakeId $linuxIso $seedIso
    Assert-Equal $script:RemoveVMDvdDriveCalls.Count 1
    Assert-Equal ([object]::ReferenceEquals($script:RemoveVMDvdDriveCalls[0], $seedDrive)) $true
    Assert-Equal $script:FakeDvdDrives.Count 1
    Assert-Equal $script:SetVMDvdDriveCalls.Count 1
    Assert-Equal $linuxDrive.Path ''
    Assert-Equal $script:SetVMFirmwareBootOrderCalls.Count 1
}
Test-Case 'Complete-LabLinuxProvisioning throws when the non-seed drive has an unexpected path' {
    $script:FakeDvdDrives.Clear()
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = 'D:\iso\unexpected.iso' })
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = 'D:\iso\seed.iso' })
    $script:SetVMDvdDriveCalls.Clear()
    $script:RemoveVMDvdDriveCalls.Clear()
    try {
        Assert-Throws { Complete-LabLinuxProvisioning $script:FakeId 'D:\iso\linux.iso' 'D:\iso\seed.iso' } 'unexpected path'
        Assert-Equal $script:SetVMDvdDriveCalls.Count 0
        Assert-Equal $script:RemoveVMDvdDriveCalls.Count 0
    } finally {
        $script:FakeDvdDrives.Clear()
    }
}
Test-Case 'Complete-LabLinuxProvisioning throws clearly when neither known ISO path matches an attached drive' {
    $script:FakeDvdDrives.Clear()
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = 'D:\iso\other1.iso' })
    $script:FakeDvdDrives.Add([pscustomobject]@{ Path = 'D:\iso\other2.iso' })
    $script:SetVMDvdDriveCalls.Clear()
    $script:RemoveVMDvdDriveCalls.Clear()
    try {
        Assert-Throws { Complete-LabLinuxProvisioning $script:FakeId 'D:\iso\linux.iso' 'D:\iso\seed.iso' } 'could not find'
        Assert-Equal $script:SetVMDvdDriveCalls.Count 0
        Assert-Equal $script:RemoveVMDvdDriveCalls.Count 0
    } finally {
        $script:FakeDvdDrives.Clear()
    }
}

# --- Linux unattended install, Task 6: "Provision Linux VM" orchestrator ---
# Same shape as the Windows orchestrator's scenario harness above: the REAL Start-LabLinuxVMProvisioning
# (plus the real shared Get-LabProvisioningVMHardware and pure validators) runs against FAKES of every
# function it consumes, each recording its name, so the exact sequence and failure behavior are asserted.
# Everything runs in a child scope, so no fake leaks into any other test.
$script:LinuxProvWorkspace = Join-Path ([IO.Path]::GetTempPath()) 'labprov-linux-test-workspace'
$script:LinuxProvSourceIso = 'C:\labprov-test\ubuntu-26.04.1-desktop-amd64.iso'
$script:LinuxProvKeyPath = 'C:\labprov-test\SshConnections\00000000-0000-0000-0000-00000000c0de.key'
$script:LinuxProvPassword = 'Sup3r-S3cret-Pa55'
function Invoke-LabLinuxProvisioningScenario {
    param(
        [hashtable]$Options,
        [bool]$InScope = $true,
        [string]$ThrowIn = '',
        [int]$ThrowOnWaitNumber = 0,
        [bool]$Patched = $true,
        [AllowNull()][string]$FirstHostKey = 'ssh-ed25519 AAAAFIRSTBOOTHOSTKEY'
    )
    $script:LProvFirstHostKey = $FirstHostKey
    $script:LProvWarnings = @()
    $script:LProvCalls = [Collections.Generic.List[string]]::new()
    $script:LProvArgs = @{}
    $script:LProvAudit = [Collections.Generic.List[string]]::new()
    $script:LProvInScope = $InScope
    $script:LProvThrowIn = $ThrowIn
    $script:LProvThrowOnWait = $ThrowOnWaitNumber
    $script:LProvWaitCount = 0
    $script:LProvPatched = $Patched
    $result = [pscustomobject]@{ Status = $null; Error = $null; Calls = $null; Args = $null; Audit = $null }
    & {
        function Record { param([string]$Name) $script:LProvCalls.Add($Name); if ($script:LProvThrowIn -eq $Name) { throw "simulated $Name failure" } }
        function Read-LabText { param([string]$Prompt) throw "Unexpected prompt: $Prompt" }
        function Read-LabYesNoCancel { param([string]$Prompt) Record 'Read-LabYesNoCancel'; return 'Y' }
        function Write-LabAudit { param([string]$Action, [string]$Status, $VM = $null, [string]$Detail = '') $script:LProvAudit.Add("$Action|$Status|$Detail") }
        function Select-LabIsoPath { param([string]$IsoRoot) Record 'Select-LabIsoPath'; return $script:LinuxProvSourceIso }
        function Get-LabLinuxIsoInfo {
            param([string]$IsoPath)
            Record 'Get-LabLinuxIsoInfo'
            if ($script:LProvInScope) { return [pscustomobject]@{ ReleaseText = 'Ubuntu 26.04.1 LTS "Resolute Raccoon" - Release amd64'; IsUbuntuDesktopInScope = $true } }
            return [pscustomobject]@{ ReleaseText = 'Ubuntu-Server 26.04.1 LTS "Resolute Raccoon" - Release amd64'; IsUbuntuDesktopInScope = $false }
        }
        function Get-LabHostDefaults {
            Record 'Get-LabHostDefaults'
            $temp = [IO.Path]::GetTempPath()
            [pscustomobject]@{ VirtualMachinePath = $temp; VirtualHardDiskPath = $temp; LogicalProcessorCount = 8; TotalPhysicalMemoryBytes = 32GB }
        }
        function Get-LabSwitchNames { return @('Default Switch') }
        function New-LabVMCore {
            param([string]$Name, [string]$VmStoragePath, [int]$VCpuCount, [long]$MinimumBytes, [long]$StartupBytes,
                [long]$MaximumBytes, [bool]$IsDynamic, [string]$VhdxPath, [long]$VhdxMaximumBytes, [string]$SwitchName)
            Record 'New-LabVMCore'
            $script:LProvArgs['New-LabVMCore'] = $PSBoundParameters
            return [pscustomobject]@{ Id = [guid]'00000000-0000-0000-0000-00000000c0de'; Name = $Name }
        }
        function Enable-VMIntegrationService { param($VM, [string[]]$Name) Record 'Enable-VMIntegrationService' }
        function Set-VM { param($VM, $AutomaticStopAction) Record 'Set-VM' }
        function Resolve-LabLinuxCredential {
            param($Credential, [bool]$NonInteractive)
            Record 'Resolve-LabLinuxCredential'
            if ($null -ne $Credential) { return $Credential }
            return [pscredential]::new('dev', (ConvertTo-SecureString $script:LinuxProvPassword -AsPlainText -Force))
        }
        function Get-LabProvisioningWorkspacePath { param([guid]$VMId) Record 'Get-LabProvisioningWorkspacePath'; return $script:LinuxProvWorkspace }
        function New-LabPatchedBootableLinuxIso {
            param([string]$SourceIsoPath, [string]$OutputPath)
            Record 'New-LabPatchedBootableLinuxIso'
            if ($script:LProvPatched) { return [pscustomobject]@{ Patched = $true; Reason = $null; OutputPath = $OutputPath } }
            return [pscustomobject]@{ Patched = $false; Reason = 'simulated: not enough slack'; OutputPath = $null }
        }
        function New-LabEphemeralSshKeyPair {
            param([guid]$VMId)
            Record 'New-LabEphemeralSshKeyPair'
            return [pscustomobject]@{ PrivateKeyPath = $script:LinuxProvKeyPath; PublicKeyContent = 'ssh-ed25519 AAAAfakekey lab' }
        }
        function New-LabLinuxAutoinstallUserData {
            param([string]$ComputerName, [string]$Locale, [string]$TimeZone, [string]$UserName, [securestring]$Password, [string]$SshPublicKey)
            Record 'New-LabLinuxAutoinstallUserData'
            $script:LProvArgs['New-LabLinuxAutoinstallUserData'] = $PSBoundParameters
            return "#cloud-config`nautoinstall:`n  version: 1`n"
        }
        function New-LabSeedIso {
            param([hashtable]$Files, [string]$OutputPath, [string]$VolumeLabel = 'LAB_SEED')
            Record 'New-LabSeedIso'
            $script:LProvArgs['New-LabSeedIso'] = @{ Files = $Files; OutputPath = $OutputPath; VolumeLabel = $VolumeLabel }
        }
        function Set-LabVMUnattendedLinuxInstallMedia {
            param([guid]$VMId, [string]$LinuxIsoPath, [string]$SeedIsoPath)
            Record 'Set-LabVMUnattendedLinuxInstallMedia'
            $script:LProvArgs['Set-LabVMUnattendedLinuxInstallMedia'] = $PSBoundParameters
        }
        function Set-LabVMBootProfile {
            param([guid]$VMId, [string]$OsProfile)
            Record 'Set-LabVMBootProfile'
            $script:LProvArgs['Set-LabVMBootProfile'] = $OsProfile
            return [pscustomobject]@{ SecureBootTemplateChanged = $true; SecureBootEnabled = $false; KeyProtectorAdded = $false; TpmEnabled = $false }
        }
        function Start-LabVM { param([guid]$VMId) Record 'Start-LabVM'; return 'COMPLETED' }
        function Wait-LabSshSession {
            param([guid]$VMId, [string]$UserName, [int]$TimeoutSeconds, [string]$PinnedHostKey = '')
            $script:LProvWaitCount++
            Record 'Wait-LabSshSession'
            $script:LProvArgs["Wait-LabSshSession:$($script:LProvWaitCount)"] = $PSBoundParameters
            if ($script:LProvThrowOnWait -eq $script:LProvWaitCount) { throw "simulated Wait-LabSshSession #$($script:LProvWaitCount) failure" }
            # A different address each time: the clean second boot may get a new DHCP lease.
            $hostKey = if ($PinnedHostKey -ne '') { $PinnedHostKey } else { $script:LProvFirstHostKey }
            return [pscustomobject]@{ Address = "172.20.0.$(10 + $script:LProvWaitCount)"; HostKey = $hostKey }
        }
        function Write-LabLinuxProvisioningNote {
            param([string]$HostNameOrAddress, [string]$UserName, [string]$IdentityFilePath, [string]$Content)
            Record 'Write-LabLinuxProvisioningNote'
            $script:LProvArgs['Write-LabLinuxProvisioningNote'] = $PSBoundParameters
        }
        function Request-LabVMGuestShutdown { param([guid]$VMId, [string]$Reason) Record 'Request-LabVMGuestShutdown' }
        function Wait-LabVMState {
            param([guid]$VMId, [string]$State, [int]$TimeoutSeconds = 0)
            Record "Wait-LabVMState:$State"
            $script:LProvArgs["Wait-LabVMState:$State"] = $TimeoutSeconds
        }
        function Complete-LabLinuxProvisioning {
            param([guid]$VMId, [string]$LinuxIsoPath, [string]$SeedIsoPath)
            Record 'Complete-LabLinuxProvisioning'
            $script:LProvArgs['Complete-LabLinuxProvisioning'] = $PSBoundParameters
        }
        function Remove-LabProvisioningWorkspace {
            param([guid]$VMId)
            Record 'Remove-LabProvisioningWorkspace'
            $script:LProvArgs['Remove-LabProvisioningWorkspace'] = @($args) + @($PSBoundParameters.Values | ForEach-Object { [string]$_ })
        }
        function Set-LabSshConnectionSettings {
            param([guid]$VMId, [string]$HostNameOrAddress, [int]$Port, [string]$UserName, [string]$IdentityFilePath)
            Record 'Set-LabSshConnectionSettings'
            $script:LProvArgs['Set-LabSshConnectionSettings'] = $PSBoundParameters
        }
        foreach ($sb in (Import-LabRealFunction 'Start-LabLinuxVMProvisioning', 'ConvertTo-LabLinuxAccountName', 'Get-LabProvisioningVMHardware')) { . $sb }
        try {
            $output = @(Start-LabLinuxVMProvisioning $Options 6>$null 3>&1)
            $script:LProvWarnings = @($output | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
            $result.Status = @($output | Where-Object { $_ -isnot [Management.Automation.WarningRecord] }) | Select-Object -Last 1
        }
        catch { $result.Error = $_.Exception.Message }
    }
    $result | Add-Member -NotePropertyName Warnings -NotePropertyValue @($script:LProvWarnings)
    $result.Calls = @($script:LProvCalls)
    $result.Args = $script:LProvArgs
    $result.Audit = @($script:LProvAudit)
    return $result
}
$script:LinuxProvHappyOrder = @('Select-LabIsoPath', 'Get-LabLinuxIsoInfo', 'Get-LabHostDefaults', 'Read-LabYesNoCancel', 'New-LabVMCore',
    'Enable-VMIntegrationService', 'Set-VM', 'Resolve-LabLinuxCredential', 'Get-LabProvisioningWorkspacePath', 'New-LabPatchedBootableLinuxIso',
    'New-LabEphemeralSshKeyPair', 'New-LabLinuxAutoinstallUserData', 'New-LabSeedIso', 'Set-LabVMUnattendedLinuxInstallMedia',
    'Set-LabVMBootProfile', 'Start-LabVM', 'Wait-LabSshSession', 'Write-LabLinuxProvisioningNote', 'Request-LabVMGuestShutdown',
    'Wait-LabVMState:Off', 'Complete-LabLinuxProvisioning', 'Remove-LabProvisioningWorkspace', 'Start-LabVM', 'Wait-LabSshSession',
    'Set-LabSshConnectionSettings')
$script:LabReadOnly = $false
$script:LabTimeout = 180

Test-Case 'Provision Linux: happy path runs every phase once, in the documented order, and returns COMPLETED' {
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu' }
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Status 'COMPLETED'
    Assert-Equal ($r.Calls -join ' > ') ($script:LinuxProvHappyOrder -join ' > ')
    Assert-Equal @($r.Calls | Where-Object { $_ -eq 'Wait-LabSshSession' }).Count 2
    Assert-Equal @($r.Calls | Where-Object { $_ -eq 'Set-LabSshConnectionSettings' }).Count 1
    # Saved exactly once, after the SECOND wait, with the SECOND wait's address and this VM's own key.
    Assert-Equal ([array]::LastIndexOf([string[]]$r.Calls, 'Wait-LabSshSession') -lt [array]::IndexOf([string[]]$r.Calls, 'Set-LabSshConnectionSettings')) $true
    $saved = $r.Args['Set-LabSshConnectionSettings']
    Assert-Equal $saved.HostNameOrAddress '172.20.0.12'
    Assert-Equal $saved.Port 22
    Assert-Equal $saved.UserName 'dev'
    Assert-Equal $saved.IdentityFilePath $script:LinuxProvKeyPath
    Assert-Equal $saved.VMId ([guid]'00000000-0000-0000-0000-00000000c0de')
    # The note goes to the FIRST wait's address, authenticated with the same key.
    Assert-Equal $r.Args['Write-LabLinuxProvisioningNote'].HostNameOrAddress '172.20.0.11'
    Assert-Equal $r.Args['Write-LabLinuxProvisioningNote'].IdentityFilePath $script:LinuxProvKeyPath
    Assert-Equal $r.Args['Wait-LabSshSession:1'].UserName 'dev'
    Assert-Equal $r.Args['Wait-LabSshSession:1'].TimeoutSeconds 1800
    # The ephemeral key is minted before the workspace is removed, and its path never reaches that removal.
    Assert-Equal ([array]::IndexOf([string[]]$r.Calls, 'New-LabEphemeralSshKeyPair') -lt [array]::IndexOf([string[]]$r.Calls, 'Remove-LabProvisioningWorkspace')) $true
    Assert-Equal (@($r.Args['Remove-LabProvisioningWorkspace']) -contains $script:LinuxProvKeyPath) $false
    # Defaults: Linux locale/time zone defaults, the shared computer name default, the generated public key.
    $userData = $r.Args['New-LabLinuxAutoinstallUserData']
    Assert-Equal $userData.ComputerName 'lab-agent-test'
    Assert-Equal $userData.Locale 'en_US.UTF-8'
    Assert-Equal $userData.TimeZone 'America/Guatemala'
    Assert-Equal $userData.UserName 'dev'
    Assert-Equal $userData.SshPublicKey 'ssh-ed25519 AAAAfakekey lab'
    # The NoCloud seed: cidata label, user-data and meta-data at its root.
    $seed = $r.Args['New-LabSeedIso']
    Assert-Equal $seed.VolumeLabel 'cidata'
    Assert-Equal ((@($seed.Files.Keys) | Sort-Object) -join ',') 'meta-data,user-data'
    if ([string]$seed.Files['meta-data'] -notmatch 'instance-id: ' -or [string]$seed.Files['meta-data'] -notmatch 'local-hostname: lab-agent-test') {
        throw "Unexpected meta-data: $($seed.Files['meta-data'])"
    }
    # Shared VM hardware defaults, identical to the Windows action's.
    $core = $r.Args['New-LabVMCore']
    Assert-Equal $core.Name 'LAB-Ubuntu'
    Assert-Equal $core.VCpuCount 2
    Assert-Equal $core.MinimumBytes ([long]2GB); Assert-Equal $core.StartupBytes ([long]4GB); Assert-Equal $core.MaximumBytes ([long]8GB)
    Assert-Equal $core.VhdxMaximumBytes ([long]150GB)
    Assert-Equal $core.SwitchName 'Default Switch'
    Assert-Equal $r.Args['Set-LabVMBootProfile'] 'UbuntuDesktop'
    # The patched copy is what gets attached AND what cleanup later ejects; same seed path both times.
    $patchedPath = Join-Path $script:LinuxProvWorkspace 'ubuntu-autoinstall.iso'
    Assert-Equal $r.Args['Set-LabVMUnattendedLinuxInstallMedia'].LinuxIsoPath $patchedPath
    Assert-Equal $r.Args['Complete-LabLinuxProvisioning'].LinuxIsoPath $patchedPath
    Assert-Equal $r.Args['Complete-LabLinuxProvisioning'].SeedIsoPath $r.Args['Set-LabVMUnattendedLinuxInstallMedia'].SeedIsoPath
    Assert-Equal $r.Args['Wait-LabVMState:Off'] 1800
    Assert-Equal ($r.Audit[0] -like 'provision-linux-vm|STARTED|*') $true
    Assert-Equal ($r.Audit[-1] -like 'provision-linux-vm|COMPLETED|*ubuntu-26.04.1-desktop-amd64.iso*ComputerName=lab-agent-test*ElapsedSeconds=*') $true
}
Test-Case 'Provision Linux: the guest-desktop note names the VM, ISO, release, computer name and account, and NEVER the password' {
    $cred = [pscredential]::new('labagent', (ConvertTo-SecureString $script:LinuxProvPassword -AsPlainText -Force))
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu'; Credential = $cred }
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    $note = [string]$r.Args['Write-LabLinuxProvisioningNote'].Content
    foreach ($expected in @('LAB-Ubuntu', "Ubuntu ISO: $($script:LinuxProvSourceIso)", 'Ubuntu 26.04.1 LTS', 'Computer name: lab-agent-test', 'Account: labagent')) {
        if (-not $note.Contains($expected)) { throw "Note is missing '$expected': $note" }
    }
    if ($note -notmatch 'Time from VM creation to this first SSH login: \d+ min \d+ s \(\d+ seconds\)') { throw "Note is missing the elapsed time: $note" }
    if ($note.Contains($script:LinuxProvPassword)) { throw 'The note contains the account password.' }
    foreach ($line in $r.Audit) { if ($line.Contains($script:LinuxProvPassword)) { throw "An audit record contains the account password: $line" } }
    Assert-Equal $r.Args['Write-LabLinuxProvisioningNote'].UserName 'labagent'
}
Test-Case 'Provision Linux: an out-of-scope ISO is refused, naming what was found, before any VM is created' {
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu' } -InScope $false
    Assert-Equal $r.Status $null
    if ($r.Error -notmatch 'Ubuntu Desktop 26\.04' -or $r.Error -notmatch 'Ubuntu-Server 26\.04\.1' -or $r.Error -notmatch 'No VM was created') { throw "Unclear refusal: $($r.Error)" }
    Assert-Equal ($r.Calls -contains 'New-LabVMCore') $false
    Assert-Equal ($r.Calls -contains 'Get-LabHostDefaults') $false
    Assert-Equal $r.Audit.Count 0
}
Test-Case 'Provision Linux: a failure partway reports completed steps, the kept workspace and its password, and runs nothing after' {
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu' } -ThrowIn 'New-LabPatchedBootableLinuxIso'
    Assert-Equal $r.Status $null
    Assert-Equal ($r.Calls -contains 'New-LabVMCore') $true
    Assert-Equal $r.Calls[-1] 'New-LabPatchedBootableLinuxIso'
    foreach ($later in @('New-LabEphemeralSshKeyPair', 'New-LabLinuxAutoinstallUserData', 'New-LabSeedIso', 'Set-LabVMUnattendedLinuxInstallMedia',
            'Set-LabVMBootProfile', 'Start-LabVM', 'Wait-LabSshSession', 'Remove-LabProvisioningWorkspace', 'Set-LabSshConnectionSettings')) {
        if ($r.Calls -contains $later) { throw "$later ran after the failing step." }
    }
    if ($r.Error -notmatch 'simulated New-LabPatchedBootableLinuxIso failure') { throw "Error lost the cause: $($r.Error)" }
    if ($r.Error -notmatch 'Steps already applied: .*created.*credential.*workspace') { throw "Error did not name the completed steps: $($r.Error)" }
    if (-not $r.Error.Contains($script:LinuxProvWorkspace)) { throw "Error did not name the workspace path: $($r.Error)" }
    if ($r.Error -notmatch 'password') { throw "Error did not mention the password: $($r.Error)" }
    if ($r.Error -notmatch 'No SSH connection settings were saved') { throw "Error did not say no settings were saved: $($r.Error)" }
    Assert-Equal ($r.Audit[-1] -like 'provision-linux-vm|FAILED_OR_UNCONFIRMED|*') $true
}
Test-Case 'Provision Linux: a failure AFTER the seed ISO is built says the kept workspace holds the password, and names the kept key' {
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu' } -ThrowIn 'Set-LabVMUnattendedLinuxInstallMedia'
    Assert-Equal $r.Status $null
    Assert-Equal $r.Calls[-1] 'Set-LabVMUnattendedLinuxInstallMedia'
    if (-not $r.Error.Contains("The provisioning workspace was KEPT, not deleted: $($script:LinuxProvWorkspace) -- it contains the account password in plain text")) {
        throw "Error did not name the workspace path and its plain-text password: $($r.Error)"
    }
    if (-not $r.Error.Contains($script:LinuxProvKeyPath)) { throw "Error did not name the kept SSH key: $($r.Error)" }
    Assert-Equal ($r.Calls -contains 'Set-LabSshConnectionSettings') $false
}
Test-Case 'Provision Linux: a failure after the FIRST SSH wait but at the SECOND never saves SSH connection settings' {
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu' } -ThrowOnWaitNumber 2
    Assert-Equal $r.Status $null
    Assert-Equal @($r.Calls | Where-Object { $_ -eq 'Wait-LabSshSession' }).Count 2
    Assert-Equal ($r.Calls -contains 'Remove-LabProvisioningWorkspace') $true
    Assert-Equal ($r.Calls -contains 'Set-LabSshConnectionSettings') $false
    if ($r.Error -notmatch 'simulated Wait-LabSshSession #2 failure') { throw "Error lost the cause: $($r.Error)" }
    if ($r.Error -notmatch 'already deleted') { throw "Error did not say the workspace was already deleted: $($r.Error)" }
    if ($r.Error -notmatch 'No SSH connection settings were saved') { throw "Error did not say no settings were saved: $($r.Error)" }
    Assert-Equal ($r.Audit[-1] -like 'provision-linux-vm|FAILED_OR_UNCONFIRMED|*') $true
}
Test-Case 'Provision Linux: a failure at the FIRST SSH wait runs no note, cleanup or settings save' {
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu' } -ThrowOnWaitNumber 1
    Assert-Equal $r.Status $null
    Assert-Equal $r.Calls[-1] 'Wait-LabSshSession'
    foreach ($later in @('Write-LabLinuxProvisioningNote', 'Remove-LabProvisioningWorkspace', 'Set-LabSshConnectionSettings')) {
        if ($r.Calls -contains $later) { throw "$later ran after the failing step." }
    }
}
Test-Case 'Provision Linux: an unpatched ISO falls back to the ORIGINAL source path for attach and cleanup' {
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu' } -Patched $false
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Args['Set-LabVMUnattendedLinuxInstallMedia'].LinuxIsoPath $script:LinuxProvSourceIso
    Assert-Equal $r.Args['Complete-LabLinuxProvisioning'].LinuxIsoPath $script:LinuxProvSourceIso
}
Test-Case 'Provision Linux: an invalid -ComputerName, -LinuxTimeZone or -Locale is rejected before any VM is created' {
    foreach ($case in @(
            @{ Options = @{ NewVMName = 'LAB-Ubuntu'; ComputerName = 'lab-agent-test-linux' }; Pattern = 'Computer name' },
            @{ Options = @{ NewVMName = 'LAB-Ubuntu'; ComputerName = '12345' }; Pattern = 'Computer name' },
            @{ Options = @{ NewVMName = 'LAB-Ubuntu'; LinuxTimeZone = 'Central America Standard Time' }; Pattern = 'LinuxTimeZone' },
            @{ Options = @{ NewVMName = 'LAB-Ubuntu'; LinuxTimeZone = 'UTC; reboot' }; Pattern = 'LinuxTimeZone' },
            @{ Options = @{ NewVMName = 'LAB-Ubuntu'; Locale = 'en_US: x' }; Pattern = 'Locale' })) {
        $r = Invoke-LabLinuxProvisioningScenario $case.Options
        Assert-Equal $r.Status $null
        if ($r.Error -notmatch $case.Pattern) { throw "Error did not name $($case.Pattern): $($r.Error)" }
        Assert-Equal ($r.Calls -contains 'New-LabVMCore') $false
    }
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu'; LinuxTimeZone = 'America/Argentina/Buenos_Aires'; Locale = 'es_GT.UTF-8' }
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Args['New-LabLinuxAutoinstallUserData'].TimeZone 'America/Argentina/Buenos_Aires'
    Assert-Equal $r.Args['New-LabLinuxAutoinstallUserData'].Locale 'es_GT.UTF-8'
}
Test-Case 'Provision Linux: the second SSH wait is pinned to the host key the first wait verified; the first is not pinned' {
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu' }
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Args['Wait-LabSshSession:1'].ContainsKey('PinnedHostKey') $false
    Assert-Equal $r.Args['Wait-LabSshSession:2'].PinnedHostKey 'ssh-ed25519 AAAAFIRSTBOOTHOSTKEY'
    Assert-Equal $r.Args['Set-LabSshConnectionSettings'].HostNameOrAddress '172.20.0.12'
    Assert-Equal $r.Warnings.Count 1   # the workspace warning in the preview only
}
Test-Case 'Provision Linux: when the first wait recorded no host key, the second wait runs unpinned with a warning' {
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu' } -FirstHostKey ''
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Args['Wait-LabSshSession:2'].PinnedHostKey ''
    if (@($r.Warnings | Where-Object { $_ -match 'did not record a host key to pin' }).Count -ne 1) { throw "Missing the unpinned warning: $($r.Warnings -join ' | ')" }
}
Test-Case 'Provision Linux: -SwitchName '''' (Disconnected) is refused clearly before any VM is created' {
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu'; SwitchName = '' }
    Assert-Equal $r.Status $null
    if ($r.Error -notmatch 'Disconnected' -or $r.Error -notmatch 'SSH' -or $r.Error -notmatch "-SwitchName 'Default Switch'" -or $r.Error -notmatch 'No VM was created') {
        throw "Unclear refusal: $($r.Error)"
    }
    Assert-Equal ($r.Calls -contains 'New-LabVMCore') $false
    Assert-Equal ($r.Calls -contains 'Read-LabYesNoCancel') $false
    Assert-Equal $r.Audit.Count 0
}
Test-Case 'Provision Linux: a computer name with a leading or trailing hyphen is refused before any VM is created (Linux-only rule)' {
    foreach ($bad in @('-lab', 'lab-', '-')) {
        $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu'; ComputerName = $bad }
        Assert-Equal $r.Status $null
        if ($r.Error -notmatch 'hyphen' -or -not $r.Error.Contains("'$bad'")) { throw "Unclear refusal for '$bad': $($r.Error)" }
        Assert-Equal ($r.Calls -contains 'New-LabVMCore') $false
    }
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu'; ComputerName = 'lab-agent-2' }
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Args['New-LabLinuxAutoinstallUserData'].ComputerName 'lab-agent-2'
}
Test-Case 'Provision Linux: -Locale accepts the C locale (C.UTF-8, C) and still refuses malformed values' {
    foreach ($good in @('C.UTF-8', 'C', 'en_US.UTF-8', 'sr_RS@latin')) {
        $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu'; Locale = $good }
        if ($null -ne $r.Error) { throw "Unexpected failure for '$good': $($r.Error)" }
        Assert-Equal $r.Args['New-LabLinuxAutoinstallUserData'].Locale $good
    }
    foreach ($bad in @('c.UTF-8', 'C_US.UTF-8', 'C.UTF-8: x', 'X.UTF-8')) {
        $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu'; Locale = $bad }
        if ($r.Error -notmatch 'Locale') { throw "'$bad' was not refused: $($r.Error)" }
        Assert-Equal ($r.Calls -contains 'New-LabVMCore') $false
    }
}
Test-Case 'Provision Linux: a supplied credential with a non-Linux username or empty password is refused before any ISO is read' {
    $bad = [pscredential]::new('Dev', (ConvertTo-SecureString 'x' -AsPlainText -Force))
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu'; Credential = $bad }
    if ($r.Error -notmatch 'Dev') { throw "Unexpected error: $($r.Error)" }
    Assert-Equal $r.Calls.Count 0
}
Test-Case 'Provision Linux: -NonInteractive without -Credential is refused before any ISO is read or VM created' {
    $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu'; NonInteractive = $true; LinuxIsoPath = $PSCommandPath }
    if ($r.Error -notmatch '-Credential') { throw "Unexpected error: $($r.Error)" }
    Assert-Equal $r.Calls.Count 0
}
Test-Case 'Provision Linux: read-only mode refuses without prompting or creating anything' {
    $script:LabReadOnly = $true
    try {
        $r = Invoke-LabLinuxProvisioningScenario @{ NewVMName = 'LAB-Ubuntu' }
        Assert-Equal $r.Status 'CANCELLED'
        Assert-Equal $r.Calls.Count 0
    } finally { $script:LabReadOnly = $false }
}

Write-Host "`nHelper tests: $script:Passed passed; $script:Failed failed."
Write-Host 'These are parser/helper tests, NOT Hyper-V lifecycle or restore tests.'
if ($script:Failed -gt 0) { exit 1 }
