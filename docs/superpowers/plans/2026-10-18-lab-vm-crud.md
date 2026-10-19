# LAB VM CRUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `Lab-VM.ps1` with Create VM, Edit VM settings, and Delete VM (retain virtual disks) for `LAB-*` VMs, preserving the existing local-host, GUID-resolution, audit, confirmation, mutex-locking, and `-ReadOnly` guarantees.

**Architecture:** Add new functions to the existing single-file script following its established patterns: a pure, unit-testable validation/diff helper per risky decision, a `*Core` function that performs the Hyper-V mutation and verifies it by GUID, and an interactive wrapper that collects input, previews, and confirms before calling the core function through `Invoke-LabAction` (or a new equivalent for pre-GUID creation). Wire each into the existing menus (`Select-LabVM` top level for Create; `Show-LabVMMenu` for Edit/Delete as new numbered options), hiding/blocking all three under `-ReadOnly`.

**Tech Stack:** Windows PowerShell 5.1, Hyper-V module cmdlets (`New-VM`, `New-VHD`, `Add-VMHardDiskDrive`, `Set-VMProcessor`, `Set-VMMemory`, `Rename-VM`, `Connect-VMNetworkAdapter`, `Disconnect-VMNetworkAdapter`, `Remove-VM`), CIM (`Win32_ComputerSystem`) for host capability display, existing AST-based `Test-LabVM.ps1` harness, `test_static.py` source-contract checks.

**Spec:** GitHub issue #1 — "feat: basic LAB-* VM CRUD — create, inspect, edit settings, and safely delete" (https://github.com/CtrlCarlitos/lab-vm-manager/issues/1)

## Global Constraints

- Windows PowerShell 5.1 (Desktop edition) only; no new third-party dependencies.
- Every mutation re-resolves the VM by GUID and rechecks the `LAB-` prefix immediately before acting (`Get-LabVM`), never trusts a name captured earlier in the flow.
- Every mutating menu path is blocked entirely when `$script:LabReadOnly` is `$true`, including Create VM at the top-level menu.
- Every mutation is wrapped so a host audit record (`Write-LabAudit`) is written for STARTED and the final status (`COMPLETED` / `CANCELLED` / `NO_CHANGE` / `FAILED_OR_UNCONFIRMED`); a later provider failure after a partial change must report `FAILED_OR_UNCONFIRMED`, never a false "nothing changed."
- Every destructive or hard-to-reverse action requires a typed exact-text confirmation via `Confirm-LabText`, shown together with a preview of what will change.
- No wildcard/bulk VM selection; no recursive filesystem deletion; never manually touch `.vhdx`/`.avhdx` files; never call `Remove-VM`/`New-VM`/etc. without `-Confirm:$false -ErrorAction Stop` and an explicit VM/path object, matching the existing cmdlet-call style.
- `E:\ISO` (or any ISO library) is never treated as VM/VHDX storage; this plan's Create flow must discover/collect a separate VM storage location and VHDX location.
- Generation 2 is the default and only generation this plan creates; existing Generation 1 inspection/edit must not regress. Generation is immutable once created.
- Disk purging on delete is explicitly out of scope; `Remove-VM` retains virtual hard disks per Microsoft's documented semantics, and the tool must say so, not promise checkpoint-history preservation.

## Review Focus

- Case-insensitive duplicate `LAB-...` name at creation time, including a second concurrent creation attempt with the same name before either has a GUID — must be rejected without creating a partial VM. Covered in Task 2 (name-collision mutex) and its unit test on `Test-LabNewVMName`.
- vCPU count of `0`, negative, non-integer, or greater than the host's logical processor count — must be rejected before any `New-VM`/`Set-VMProcessor` call. Covered in Task 1 (`Test-LabVCpuCount` unit tests).
- Memory values violating `minimum <= startup <= maximum`, non-positive, or not a multiple of 2 MB (Hyper-V's `Set-VMMemory` requirement) — must be rejected before creation/edit proceeds. Covered in Task 1 (`Test-LabMemorySpec` unit tests).
- Edit or Delete requested while the VM is `Running`/`Saved`/`Paused` — must stop with the existing "requires Off" message, not auto-shutdown. Covered in Task 3 and Task 4 by reusing `Assert-LabVMOff` and asserting it in `test_static.py`.
- Delete requested while non-`Standard` (backup/recovery) checkpoints exist on the VM — must stop rather than force removal, since `Remove-VM` merges/deletes checkpoints as a side effect. Covered in Task 4 (`Get-LabVMRemovalPreview` / `Remove-LabVM` precondition and its test).

---

## File Structure

All changes land in the existing single-file script and its existing test/doc files — the project is explicitly a standalone script with no module split, and both test harnesses parse/grep `Lab-VM.ps1` by name:

- Modify: `Lab-VM.ps1` — add new functions in the same style as existing ones (grouped near related existing functions: discovery helpers near `Get-LabVM`, create near `New-LabCheckpoint`, edit/delete near `Set-LabCheckpointPolicy`); wire into `Select-LabVM` and `Show-LabVMMenu`.
- Modify: `Test-LabVM.ps1` — extend the `$allowlist` array and add `Test-Case` blocks for each new pure function.
- Modify: `test_static.py` — add `SourceContract` methods for the new safety properties.
- Modify: `README.md` — document the new menu entries and parameter-free workflow; move Create/Edit/Delete out of "Intentionally not included."
- Modify: `MANUAL-TESTS.md` — add live acceptance sections for create, edit, and delete.

---

### Task 1: Host discovery and input-validation helpers

**Files:**
- Modify: `Lab-VM.ps1` (add functions after `Get-LabVM`/before `Assert-LabVMOff`, around line 165)
- Modify: `Test-LabVM.ps1`
- Modify: `test_static.py`
- Test: `Test-LabVM.ps1`, `test_static.py`

**Interfaces:**
- Produces:
  - `Get-LabHostDefaults` → `[pscustomobject]@{ VirtualMachinePath; VirtualHardDiskPath; LogicalProcessorCount; TotalPhysicalMemoryBytes }` (reads `Get-VMHost` and `Get-CimInstance Win32_ComputerSystem`; not unit-testable without Hyper-V, so it is covered only by a `test_static.py` presence check, not `Test-LabVM.ps1`).
  - `Get-LabSwitchNames` → `string[]` of existing virtual switch names from `Get-VMSwitch` (same testability note as above).
  - `Test-LabNewVMName(string $Name, string[] $ExistingNames)` → `bool`: `$true` only if `$Name` passes `Test-LabVMName` (starts with `LAB-`, case-insensitive) **and** no entry in `$ExistingNames` matches `$Name` case-insensitively.
  - `Test-LabVCpuCount(int $Count, int $MaxLogicalProcessors)` → `bool`: `$true` only if `1 <= $Count <= $MaxLogicalProcessors`.
  - `Test-LabMemorySpec(long $MinimumBytes, long $StartupBytes, long $MaximumBytes, bool $IsDynamic)` → `bool`: for dynamic, `$true` only if all three values are positive multiples of `2MB` and `$MinimumBytes <= $StartupBytes <= $MaximumBytes`; for static, `$true` only if `$StartupBytes` is a positive multiple of `2MB` (ignore min/max).
- Consumes: `Test-LabVMName` (existing, `Lab-VM.ps1:49`).

- [ ] **Step 1: Write failing `Test-LabVM.ps1` cases for the three pure validators**

```powershell
Test-Case 'New VM name must start with LAB-' { Assert-Equal (Test-LabNewVMName 'OTHER-Test' @()) $false }
Test-Case 'New VM name rejects case-insensitive duplicate' { Assert-Equal (Test-LabNewVMName 'lab-test' @('LAB-Test')) $false }
Test-Case 'New VM name accepts unique name' { Assert-Equal (Test-LabNewVMName 'LAB-New' @('LAB-Test')) $true }
Test-Case 'vCPU count zero rejected' { Assert-Equal (Test-LabVCpuCount 0 8) $false }
Test-Case 'vCPU count above host max rejected' { Assert-Equal (Test-LabVCpuCount 9 8) $false }
Test-Case 'vCPU count within range accepted' { Assert-Equal (Test-LabVCpuCount 4 8) $true }
Test-Case 'Dynamic memory requires minimum <= startup <= maximum' { Assert-Equal (Test-LabMemorySpec 1GB 512MB 4GB $true) $false }
Test-Case 'Dynamic memory rejects non-multiple-of-2MB value' { Assert-Equal (Test-LabMemorySpec 512MB (1GB+1MB) 4GB $true) $false }
Test-Case 'Dynamic memory accepts valid ordered range' { Assert-Equal (Test-LabMemorySpec 512MB 1GB 4GB $true) $true }
Test-Case 'Static memory ignores min/max and checks startup only' { Assert-Equal (Test-LabMemorySpec 0 2GB 0 $false) $true }
Test-Case 'Static memory rejects non-positive startup' { Assert-Equal (Test-LabMemorySpec 0 0 0 $false) $false }
```

Add `'Test-LabNewVMName', 'Test-LabVCpuCount', 'Test-LabMemorySpec'` to the `$allowlist` array in `Test-LabVM.ps1:46`.

- [ ] **Step 2: Run `Test-LabVM.ps1` and confirm the new cases fail**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL — "Expected one definition of Test-LabNewVMName." (functions don't exist yet)

- [ ] **Step 3: Implement the four functions in `Lab-VM.ps1`**

Implement `Get-LabHostDefaults`, `Get-LabSwitchNames`, `Test-LabNewVMName`, `Test-LabVCpuCount`, `Test-LabMemorySpec` with the exact signatures above. `Test-LabMemorySpec`'s multiple-of-2MB check and ordering check are the only logic a reader must choose; everything else follows from the signature.

- [ ] **Step 4: Run `Test-LabVM.ps1` and confirm all cases pass**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS — "Helper tests: N passed; 0 failed." for all cases including the new ones.

- [ ] **Step 5: Write and run `test_static.py` presence checks for the two Hyper-V-backed discovery functions**

```python
def test_host_discovery_functions_exist(self):
    self.assertIn('function Get-LabHostDefaults', self.s)
    self.assertIn('function Get-LabSwitchNames', self.s)
```

Run: `python -m pytest test_static.py -v`
Expected: PASS (both functions were already implemented in Step 3).

- [ ] **Step 6: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1 test_static.py
git commit -m "feat: add host discovery and VM input-validation helpers"
```

---

### Task 2: Create VM

**Files:**
- Modify: `Lab-VM.ps1` (add functions near `New-LabCheckpoint`/`New-LabCheckpointCore`, around line 357; modify `Select-LabVM` at line 234)
- Modify: `test_static.py`
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: `Get-LabHostDefaults`, `Get-LabSwitchNames`, `Test-LabNewVMName`, `Test-LabVCpuCount`, `Test-LabMemorySpec` (Task 1); `Get-LabVM`, `Write-LabAudit`, `Confirm-LabText`, `Read-LabText`, `Read-LabYesNoCancel`, `Set-LabCheckpointPolicy` (existing).
- Produces:
  - `New-LabVMCore(string $Name, string $VmStoragePath, int $VCpuCount, long $MinimumBytes, long $StartupBytes, long $MaximumBytes, bool $IsDynamic, string $VhdxPath, long $VhdxMaximumBytes, [AllowNull()]string $SwitchName)` → the created `[Microsoft.HyperV.PowerShell.VirtualMachine]`, verified by re-fetching via `Get-VM -Id`. Throws on any precondition failure (destination exists, name taken) without calling `New-VM`.
  - `New-LabVM()` → interactive collector/preview/confirm; returns `'COMPLETED'` / `'CANCELLED'` (matches the `Invoke-LabAction` status contract). No `$VMId` parameter — it doesn't exist yet.
  - Later tasks' menu wiring pattern: Task 3/4 add their own numbered options to the same `Show-LabVMMenu` switch this task extends in `Select-LabVM`.

- [ ] **Step 1: Write the failing `test_static.py` source-contract checks**

```python
def test_create_vm_blocked_in_readonly(self):
    body = self.s.split('function Select-LabVM {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('LabReadOnly', body)
def test_create_vm_uses_dedicated_directory(self):
    self.assertIn('function New-LabVMCore', self.s)
    self.assertRegex(self.s, r'New-VM[^\r\n]*-Path ')
def test_create_vm_rejects_existing_destination(self):
    body = self.s.split('function New-LabVMCore {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Test-Path', body)
def test_create_vm_generation_2_default(self):
    self.assertRegex(self.s, r'New-VM[^\r\n]*-Generation 2')
def test_create_vm_name_collision_lock(self):
    self.assertIn('LabVmManager-Create-', self.s)
```

- [ ] **Step 2: Run `test_static.py` and confirm it fails**

Run: `python -m pytest test_static.py -v` (or `python test_static.py`)
Expected: FAIL on all five new cases — none of the referenced strings exist yet.

- [ ] **Step 3: Implement `New-LabVMCore`**

Sequence: verify `$VmStoragePath` and `$VhdxPath`'s directory do not already exist (`Test-Path`) — throw before any Hyper-V call if they do; when `$SwitchName` is not null/empty, verify it still appears in `Get-LabSwitchNames` (it may have been deleted between selection and confirmation) — throw naming the missing switch rather than let `New-VM` fail opaquely; `New-VM -Name $Name -Generation 2 -Path $VmStoragePath -NoVHD -MemoryStartupBytes $StartupBytes -SwitchName $SwitchName -Confirm:$false -ErrorAction Stop` (omit `-SwitchName` when `$SwitchName` is `$null`/empty, leaving the adapter disconnected); `New-VHD -Path $VhdxPath -Dynamic -SizeBytes $VhdxMaximumBytes -Confirm:$false -ErrorAction Stop`; `Add-VMHardDiskDrive -VM $vm -Path $VhdxPath -Confirm:$false -ErrorAction Stop`; `Set-VMProcessor -VM $vm -Count $VCpuCount -Confirm:$false -ErrorAction Stop`; `Set-VMMemory -VM $vm -DynamicMemoryEnabled $IsDynamic -MinimumBytes $MinimumBytes -StartupBytes $StartupBytes -MaximumBytes $MaximumBytes -Confirm:$false -ErrorAction Stop`; then `Set-VM -VM $vm -CheckpointType Standard -AutomaticCheckpointsEnabled $false -Confirm:$false -ErrorAction Stop` (same policy `Set-LabCheckpointPolicy` applies, applied directly here since there's no prior VM to re-fetch under `Assert-LabVMOff`). Re-fetch with `Get-LabVM $vm.Id` to verify and return it.

- [ ] **Step 4: Implement `New-LabVM` interactive wrapper**

Collect, in order: name (validate with `Test-LabNewVMName` against `(Get-VM -ErrorAction Stop).Name`, re-prompt or cancel on blank); VM storage path (default from `Get-LabHostDefaults`, explain `E:\ISO` is not valid storage, reject if it resolves under any configured ISO root — none is configured yet in this plan, so just reject a path that doesn't exist or isn't a directory); vCPU count (validate with `Test-LabVCpuCount` against `Get-LabHostDefaults`); startup RAM and static/dynamic choice with min/max when dynamic (validate with `Test-LabMemorySpec`); VHDX path and maximum capacity; switch choice from `Get-LabSwitchNames` plus an explicit "Disconnected" option. Show a full preview (name, paths, vCPU, memory, switch, Generation 2, checkpoint policy) and require `Confirm-LabText "CREATE $Name"`. On confirm, acquire a dedicated creation mutex named `"Global\LabVmManager-Create-$($Name.ToUpperInvariant())"`, write a `'create-vm'` `STARTED` audit record (`$VM = $null`), call `New-LabVMCore`, write the `COMPLETED`/`FAILED_OR_UNCONFIRMED` record, release the mutex in `finally`. Return `'CANCELLED'` on any cancel.

- [ ] **Step 5: Wire into `Select-LabVM`**

Add an `'N'` choice to the prompt and switch in `Select-LabVM` (`Lab-VM.ps1:234`), shown only when `-not $script:LabReadOnly` (including when `$items.Count -eq 0`); calls `New-LabVM` directly (not through `Invoke-LabAction`, which requires an existing `$VMId`) and then `continue`s the loop to refresh the list.

- [ ] **Step 6: Run `test_static.py` and confirm it passes**

Run: `python -m pytest test_static.py -v`
Expected: PASS on all five new cases plus all pre-existing ones.

- [ ] **Step 7: Update `README.md` and `MANUAL-TESTS.md`**

In `README.md`: add "Create VM" to the top-level menu description (`README.md:64`) and remove "VM creation" from "Intentionally not included" (`README.md:142`), noting Generation 2 default, `E:\ISO` exclusion, and read-only blocking. In `MANUAL-TESTS.md`: add a "Create VM" section under "Before mutation" covering empty-inventory creation, duplicate-name rejection, invalid vCPU/memory rejection, and read-only blocking, per the issue's acceptance criteria.

- [ ] **Step 8: Commit**

```bash
git add Lab-VM.ps1 test_static.py README.md MANUAL-TESTS.md
git commit -m "feat: add Create VM workflow"
```

---

### Task 3: Edit VM settings

**Files:**
- Modify: `Lab-VM.ps1` (add functions near `Set-LabCheckpointPolicy`, around line 525; modify `Show-LabVMMenu` at line 576)
- Modify: `Test-LabVM.ps1`, `test_static.py`
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: `Get-LabVM`, `Assert-LabVMOff`, `Invoke-LabAction`, `Confirm-LabText`, `Read-LabText`, `Test-LabNewVMName`, `Test-LabVCpuCount`, `Test-LabMemorySpec`, `Get-LabSwitchNames` (Task 1/existing).
- Produces:
  - `Get-LabSettingsDiff([pscustomobject] $Current, [pscustomobject] $Proposed)` → `[pscustomobject[]]` of `@{ Field; OldValue; NewValue }`, one entry per field where `$Proposed.$Field -ne $Current.$Field`, comparing only the fields both objects share: `Name, Notes, VCpuCount, StartupBytes, MinimumBytes, MaximumBytes, DynamicMemoryEnabled, SwitchName`. Pure function — no Hyper-V calls, fully unit-testable.
  - `Set-LabVMSettingsCore(guid $VMId, [pscustomobject[]] $Diff)` → applies only the fields present in `$Diff` (rename via `Rename-VM`, `Set-VMProcessor`, `Set-VMMemory`, `Connect-VMNetworkAdapter -SwitchName` or `Disconnect-VMNetworkAdapter` for the `SwitchName` field, `Set-VM -Notes`), re-fetches and verifies each changed field, returns the updated VM. Throws, reporting which fields applied, on first verification mismatch.
  - `Edit-LabVMSettings(guid $VMId)` → interactive wrapper matching the `Invoke-LabAction` status contract (`'COMPLETED'`/`'CANCELLED'`/`'NO_CHANGE'`).

- [ ] **Step 1: Write the failing `Test-LabVM.ps1` cases for `Get-LabSettingsDiff`**

```powershell
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
```

Add `'Get-LabSettingsDiff'` to the `$allowlist` array.

- [ ] **Step 2: Run `Test-LabVM.ps1` and confirm it fails**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL — "Expected one definition of Get-LabSettingsDiff."

- [ ] **Step 3: Implement `Get-LabSettingsDiff`**

Iterate the fixed field list above; compare with `-ne` (use `-cne` where PowerShell's loose equality would misfire on booleans — `DynamicMemoryEnabled` is a `bool`, compare directly); build and return the diff array.

- [ ] **Step 4: Run `Test-LabVM.ps1` and confirm it passes**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS — all cases including the two new ones.

- [ ] **Step 5: Write failing `test_static.py` cases**

```python
def test_edit_requires_off(self):
    body = self.s.split('function Edit-LabVMSettings {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Assert-LabVMOff', body)
def test_edit_rename_preserves_lab_prefix(self):
    body = self.s.split('function Set-LabVMSettingsCore {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Test-LabNewVMName', body)
def test_edit_no_generation_change(self):
    body = self.s.split('function Set-LabVMSettingsCore {', 1)[1].split('\nfunction ', 1)[0]
    self.assertNotIn('-Generation', body)
```

- [ ] **Step 6: Run `test_static.py` and confirm it fails**

Run: `python -m pytest test_static.py -v`
Expected: FAIL on the three new cases.

- [ ] **Step 7: Implement `Set-LabVMSettingsCore` and `Edit-LabVMSettings`**

`Set-LabVMSettingsCore`: `$vm = Assert-LabVMOff $VMId` first; for the `Name` field, validate with `Test-LabNewVMName $NewValue (@(Get-VM -ErrorAction Stop).Name | Where-Object { $_ -ne $vm.Name })` before calling `Rename-VM`; apply remaining changed fields with their respective cmdlets; re-fetch via `Get-LabVM $VMId` after each and compare to the diff's `NewValue`, throwing with the field name on mismatch. `Edit-LabVMSettings`: `$vm = Assert-LabVMOff $VMId`; build `$current` from `$vm` plus `Get-VMNetworkAdapter -VM $vm` (first adapter — note when several exist, per spec, and let the operator pick which one); prompt for each field with the current value shown, blank preserves it; build `$proposed`; compute diff via `Get-LabSettingsDiff`; if empty, return `'NO_CHANGE'`; show the diff and require `Confirm-LabText "EDIT $($vm.Name)"`; call `Set-LabVMSettingsCore`; return `'COMPLETED'`.

- [ ] **Step 8: Run `test_static.py` and confirm it passes**

Run: `python -m pytest test_static.py -v`
Expected: PASS on all cases.

- [ ] **Step 9: Wire into `Show-LabVMMenu`**

Add option `11  Edit VM settings [requires Off]` to the non-read-only menu text and `'11' { Invoke-LabAction $VMId 'edit-settings-menu' { param($id) Edit-LabVMSettings $id } }` to the switch (`Lab-VM.ps1:576`).

- [ ] **Step 10: Update `README.md` and `MANUAL-TESTS.md`**

Add row `11` to the menu table (`README.md:66`) and remove "CPU/RAM tuning, network/firewall changes" from "Intentionally not included" (`README.md:142`). Add an "Edit VM settings" section to `MANUAL-TESTS.md` covering prepopulated values, no-change cancel, rename collision rejection, and the requires-Off guard.

- [ ] **Step 11: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1 test_static.py README.md MANUAL-TESTS.md
git commit -m "feat: add Edit VM settings workflow"
```

---

### Task 4: Delete VM (retain virtual disks)

**Files:**
- Modify: `Lab-VM.ps1` (add functions near `Export-LabVM`, around line 509; modify `Show-LabVMMenu` at line 576)
- Modify: `Test-LabVM.ps1`, `test_static.py`
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: `Get-LabVM`, `Assert-LabVMOff`, `Get-LabSnapshots`, `Export-LabVM`, `Invoke-LabAction`, `Confirm-LabText`, `Read-LabYesNoCancel`, `Write-LabAudit` (existing).
- Produces:
  - `Get-LabVMRemovalPreview(guid $VMId)` → `[pscustomobject]@{ Name; Id; Path; DiskPaths; CheckpointCount; HasNonStandardCheckpoints }`, built from `Get-LabVM`, `Get-VMHardDiskDrive -VM`, and `Get-LabSnapshots`.
  - `Remove-LabVM(guid $VMId)` → interactive wrapper matching the `Invoke-LabAction` status contract.

`Get-LabVMRemovalPreview` needs live `Get-VMHardDiskDrive`/`Get-VMSnapshot` data the existing `Test-LabVM.ps1` fakes don't provide, so — matching how `Export-LabVM` is tested today — it is covered by `test_static.py` source-contract checks and `MANUAL-TESTS.md` live steps, not a `Test-LabVM.ps1` unit test.

- [ ] **Step 1: Write failing `test_static.py` cases**

```python
def test_delete_requires_off(self):
    body = self.s.split('function Remove-LabVM {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Assert-LabVMOff', body)
def test_delete_stops_on_nonstandard_checkpoints(self):
    body = self.s.split('function Remove-LabVM {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('HasNonStandardCheckpoints', body)
def test_delete_offers_export_first(self):
    body = self.s.split('function Remove-LabVM {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Export-LabVM', body)
def test_delete_uses_remove_vm_object(self):
    self.assertRegex(self.s, r'Remove-VM -VM ')
def test_delete_strong_confirmation(self):
    self.assertIn('DELETE VM ', self.s)
def test_delete_manifest_before_removal(self):
    body = self.s.split('function Remove-LabVM {', 1)[1].split('\nfunction ', 1)[0]
    idx_manifest = body.index("'removal-manifest.json'")
    idx_remove = body.index('Remove-VM -VM ')
    self.assertLess(idx_manifest, idx_remove)
```

- [ ] **Step 2: Run `test_static.py` and confirm it fails**

Run: `python -m pytest test_static.py -v`
Expected: FAIL on all six new cases.

- [ ] **Step 3: Implement `Get-LabVMRemovalPreview`**

`$vm = Get-LabVM $VMId`; `$disks = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop | Select-Object -ExpandProperty Path)`; `$snapshots = @(Get-LabSnapshots $VMId)`; `$nonStandard = @($snapshots | Where-Object { [string]$_.SnapshotType -ne 'Standard' })`; return `[pscustomobject]@{ Name = $vm.Name; Id = $vm.Id; Path = $vm.Path; DiskPaths = $disks; CheckpointCount = $snapshots.Count; HasNonStandardCheckpoints = ($nonStandard.Count -gt 0) }`.

- [ ] **Step 4: Implement `Remove-LabVM`**

`$vm = Assert-LabVMOff $VMId`; `$preview = Get-LabVMRemovalPreview $VMId`; display name/GUID/path/disk paths/checkpoint count; if `$preview.HasNonStandardCheckpoints`, `throw` explaining unresolved backup/recovery checkpoints block removal; ask `Read-LabYesNoCancel 'Export this VM before deletion?'` — cancel returns `'CANCELLED'`; on Yes, call `Export-LabVM $VMId` and require its result to be `'COMPLETED'` before continuing (treat `'CANCELLED'` from the export sub-flow as "skip export" only when the operator explicitly declined the *outer* prompt, not when the export itself failed — so re-check: if `Export-LabVM` throws or returns anything other than `'COMPLETED'`, stop here and do not proceed to removal); re-run `Assert-LabVMOff $VMId` and `Get-LabVMRemovalPreview $VMId` (state may have changed during export); require `Confirm-LabText "DELETE VM $($vm.Name) $($vm.Id.ToString().Substring(0,8))"`; write a host-side manifest file (pattern matches `Export-LabVM`'s manifest) to `Join-Path (Split-Path $script:LabLogFile) "$($vm.Id)-removal-manifest.json"` containing `{ VMName, VMId, Path, DiskPaths, CheckpointCount, ExportPerformed, RemovedUtc = $null }` before calling `Remove-VM`; `$vm = Assert-LabVMOff $VMId` once more under the lock; `Remove-VM -VM $vm -Confirm:$false -ErrorAction Stop`; verify with `@(Get-VM -Id $VMId -ErrorAction SilentlyContinue).Count -eq 0`, throwing if not; update the manifest's `RemovedUtc`; report the retained disk paths from the preview; return `'COMPLETED'`.

- [ ] **Step 5: Run `test_static.py` and confirm it passes**

Run: `python -m pytest test_static.py -v`
Expected: PASS on all cases.

- [ ] **Step 6: Wire into `Show-LabVMMenu`**

Add option `12  Delete VM (retain virtual disks)       [requires Off]` to the non-read-only menu text and `'12' { Invoke-LabAction $VMId 'delete-vm-menu' { param($id) Remove-LabVM $id } }` to the switch. Note `Invoke-LabAction` re-fetches `$VMId` into `Remove-LabVM` for its own audit wrapper — `Remove-LabVM` must not assume the mutex is already held a second time; it relies on `Invoke-LabAction`'s existing per-VM mutex, same as every other option.

- [ ] **Step 7: Update `README.md` and `MANUAL-TESTS.md`**

Add row `12` to the menu table, document `Remove-VM`'s actual disk-retention/checkpoint-merge semantics (link already present in README's primary references), and remove "VM/disk deletion" from "Intentionally not included," replacing it with an explicit note that disk purging is still out of scope. Add a "Delete VM" section to `MANUAL-TESTS.md` covering: cancel at each prompt leaves the VM untouched, export-then-delete, skip-export delete, blocked delete with a non-Standard checkpoint present, and verifying retained disk files after removal.

- [ ] **Step 8: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1 test_static.py README.md MANUAL-TESTS.md
git commit -m "feat: add Delete VM (retain virtual disks) workflow"
```

---

### Task 5: Full regression pass and script help update

**Files:**
- Modify: `Lab-VM.ps1` (`.SYNOPSIS`/`.DESCRIPTION` comment-based help, lines 2-32)
- Modify: `test_static.py` (`test_all_named_operations_exist`, line 60)

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: no new functions; this task only verifies the assembled whole and keeps the one function-name allowlist in `test_static.py` honest.

- [ ] **Step 1: Add the four new function names to `test_all_named_operations_exist`**

Add `'New-LabVM', 'Edit-LabVMSettings', 'Remove-LabVM'` to the list at `test_static.py:61` (the `*Core` functions are intentionally left out of this particular check, matching how `New-LabCheckpointCore` is already omitted from it today).

- [ ] **Step 2: Update comment-based help**

Remove the `.DESCRIPTION` sentence "No VM creation/deletion... is implemented" (`Lab-VM.ps1:10-12`) and replace with an accurate one-line summary that creation/edit/delete now exist for `LAB-*` VMs, retain the existing warning that this is not a security boundary.

- [ ] **Step 3: Run the complete test suite**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` then `python -m pytest test_static.py -v`
Expected: PASS — every case from the original suite plus every case added in Tasks 1-4.

- [ ] **Step 4: Commit**

```bash
git add Lab-VM.ps1 test_static.py
git commit -m "docs: update help and static checks for VM CRUD"
```

---

## Out of Scope (unchanged from the issue)

OS installation, cloning/import, disk resizing/guest partition changes, disk purge, switch creation, remote hosts, guest provisioning/dotfiles execution. Live Hyper-V acceptance testing (actually creating/editing/deleting a real `LAB-*` VM end to end) happens by walking the updated `MANUAL-TESTS.md`, which this plan's tasks extend but which only Carlos, on the real host, can execute and sign off.
