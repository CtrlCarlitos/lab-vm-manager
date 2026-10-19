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
    'Get-LabSettingsDiff')
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
Write-Host "`nHelper tests: $script:Passed passed; $script:Failed failed."
Write-Host 'These are parser/helper tests, NOT Hyper-V lifecycle or restore tests.'
if ($script:Failed -gt 0) { exit 1 }
