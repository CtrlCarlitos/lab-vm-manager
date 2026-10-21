# Fix: Start-LabWindowsVMProvisioning's `-SwitchName ''` escape hatch was silently swallowed

Standalone fix on top of `0691a01` (feat: default provisioned Windows VMs to Default Switch, Guest
Services on, graceful stop). Addresses the one confirmed Critical finding and both Minor findings
from the review of that commit.

## Critical finding (fixed)

`Start-LabWindowsVMProvisioning`'s generic `$getOption` helper treats a bound-but-empty-string value
the same as "not supplied" and falls back to `$Default`. That is correct for every other option in
this function, but it broke `-SwitchName` once `0691a01` changed that option's default from `''` to
`'Default Switch'`: `-ProvisionWindowsVM ... -SwitchName ''` silently resolved to `'Default Switch'`
instead of Disconnected, even though that same commit's own comment-based help, error message, and
README line all document `-SwitchName ''` as the documented way to get a Disconnected adapter.

### Fix

In `Lab-VM.ps1` (~line 2830), `$switchName` is now resolved directly against `$Options`, bypassing
`$getOption` for this one setting, since an explicit empty string is itself a meaningful, distinct
value here (Disconnected), not an omission:

```powershell
# $getOption treats a bound-but-empty string as "not supplied" and falls back to Default, which is
# correct for every other option here -- but -SwitchName '' is itself a meaningful, distinct value
# (Disconnected), not an omission, so it is resolved directly against $Options instead.
$switchName = if ($Options.ContainsKey('SwitchName')) { [string]$Options['SwitchName'] } else { 'Default Switch' }
```

`$getOption` itself was NOT changed -- every other option correctly relies on its current
"bound-empty counts as not-given" behavior, so the fix is scoped to just `SwitchName`.

### New test (Test-LabVM.ps1)

Added alongside the existing happy-path provisioning tests, right before the "unpatched ISO falls
back" test:

```powershell
Test-Case 'Provision: -SwitchName '''' is the documented escape hatch for a Disconnected adapter, not a fallback to Default Switch' {
    $r = Invoke-LabProvisioningScenario @{ NewVMName = 'LAB-Win11'; SwitchName = '' } -Answers @('')
    if ($null -ne $r.Error) { throw "Unexpected failure: $($r.Error)" }
    Assert-Equal $r.Status 'COMPLETED'
    Assert-Equal $r.Args['New-LabVMCore'].SwitchName ''
}
```

This passes `SwitchName = ''` in `$Options` and asserts the value `New-LabVMCore`'s fake actually
received is the empty string, not `'Default Switch'`.

The existing happy-path test (`Test-Case 'Provision: happy path runs every phase once...'`) already
covers, and continues to pass, the "omit `-SwitchName` entirely -> defaults to `'Default Switch'`"
case (`Assert-Equal $core.SwitchName 'Default Switch'`), confirming the fix did not regress that
default.

### Existing static test updated (test_static.py)

`test_provisioning_switch_defaults_to_default_switch` asserted the literal (now-removed) substring
`"& $getOption 'SwitchName' 'Default Switch'"`. Updated to assert the new resolution line verbatim,
plus a negative assertion that the old `$getOption`-based form is gone:

```python
def test_provisioning_switch_defaults_to_default_switch(self):
    body = self.s.split('function Start-LabWindowsVMProvisioning {', 1)[1].split('\nfunction ', 1)[0]
    # SwitchName is resolved directly against $Options, bypassing the generic $getOption helper:
    # $getOption treats a bound-but-empty string as "not supplied," which would defeat the documented
    # -SwitchName '' escape hatch for a Disconnected adapter if used here.
    self.assertIn("$switchName = if ($Options.ContainsKey('SwitchName')) { [string]$Options['SwitchName'] } else { 'Default Switch' }", body)
    self.assertNotIn("$switchName = [string](& $getOption 'SwitchName'", body)
```

## Minor finding 1 (addressed): unconfirmed `'Guest Service Interface'` display name

Added one bullet to `MANUAL-TESTS.md`'s "Windows unattended install" section (right before the
"First post-OOBE shutdown..." bullet), noting the string should be confirmed on the next live run and
corrected if wrong:

```
- **`'Guest Service Interface'` display-name string not yet confirmed live.** Provisioning calls
  `Enable-VMIntegrationService -Name 'Guest Service Interface'`. Strong indirect evidence backs that
  exact string (the real .NET type `Microsoft.HyperV.PowerShell.GuestServiceInterfaceComponent` and
  the real WMI class `Msvm_GuestServiceInterfaceComponent`), but the class-name-to-display-string
  mapping is not a strict rule in general, and no live VM has confirmed it yet. On the next live run,
  check `Get-VMIntegrationService -VMName <name> | Select-Object Name` and correct the string here
  and in `Lab-VM.ps1` if it is ever wrong.
```

No code/string change was made (per instructions -- not resolvable without a live VM in this
session).

## Minor finding 2 (no action needed)

The review noted (informational only, not a defect) that the OTHER drift-guard test in
`Test-LabVM.ps1` doesn't see the new `Enable-VMIntegrationService`/`Set-VM` fakes, because they're
defined in a call-scoped block that's gone by the time that test runs. This matches every other fake
in that same scriptblock. No change made.

## Commands run and output

### `python test_static.py`

Result: `Ran 187 tests in 0.172s` / `OK` -- 187/187 passing (one existing test updated in place to
match the new resolution code; no new Python test was needed since the new Lab-VM.ps1 line is
exercised structurally, and behaviorally by the new Test-LabVM.ps1 test).

### `powershell.exe -NoProfile -File .\Test-LabVM.ps1` (Windows PowerShell 5.1)

Result: `Helper tests: 306 passed; 0 failed.` -- 305 baseline + 1 new test (`Provision: -SwitchName ''
is the documented escape hatch for a Disconnected adapter, not a fallback to Default Switch`), all
passing, no regressions. All 5 drift-guard tests also passed.

## Files changed

- `Lab-VM.ps1` -- `$switchName` resolution fix (~line 2830).
- `Test-LabVM.ps1` -- new escape-hatch test.
- `test_static.py` -- updated `test_provisioning_switch_defaults_to_default_switch` to match the new
  code.
- `MANUAL-TESTS.md` -- new bullet noting the `'Guest Service Interface'` string needs live
  confirmation.
