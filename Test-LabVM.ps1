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
    'Assert-LabVMRunning', 'Get-LabTransferOnlyParameter')
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
$script:FakeVM = [pscustomobject]@{ Id = $script:FakeId; Name = 'LAB-Test'; State = 'Off' }
function Get-VM {
    [CmdletBinding()]
    param([guid]$Id)
    if ($Id -eq $script:FakeId) { return $script:FakeVM }
    return @()
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
Write-Host "`nHelper tests: $script:Passed passed; $script:Failed failed."
Write-Host 'These are parser/helper tests, NOT Hyper-V lifecycle or restore tests.'
if ($script:Failed -gt 0) { exit 1 }
