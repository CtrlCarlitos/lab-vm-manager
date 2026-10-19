#requires -Version 5.1
<#
.SYNOPSIS
    Parse Lab-VM.ps1 and test its small input/selection helpers without Hyper-V.
.DESCRIPTION
    This does NOT run the UI, dot-source the whole manager, or import Hyper-V.
    Only explicitly allowlisted function definitions are evaluated from its AST.
    Get-VM is replaced with an in-memory function for VM-ID/state guard tests.
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
    'Get-LabTransferConflictKind', 'Resolve-LabConflictAction', 'Get-LabSettingsDiff')
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
Write-Host "`nHelper tests: $script:Passed passed; $script:Failed failed."
Write-Host 'These are parser/helper tests, NOT Hyper-V lifecycle or restore tests.'
if ($script:Failed -gt 0) { exit 1 }
