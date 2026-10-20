# ISO/Installer Provisioning — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the operator a real, standalone way to browse the ISO library, and to prepare a Generation 2 VM for installation — Secure Boot template, vTPM where required, DVD media attached, boot order correct — plus the reusable, dependency-free plumbing (a native seed-ISO builder, a generated-artifacts workspace) that the Windows and Linux unattended-install plans will build on next. This plan does not boot anything or install an OS; it ends with a VM that is `Off`, fully prepared, with media attached.

**Architecture:** New functions follow this codebase's existing conventions exactly: `[guid]$VMId`-keyed operations through `Get-LabVM`, mutations gated by `Assert-LabVMOff` and routed through `Invoke-LabAction` (per-VM mutex, audit, confirm), read-only inspection available under `-ReadOnly`, no wildcard path expansion, per-VM host-side state files under `%LOCALAPPDATA%\LabVmManager\...` mirroring the existing SSH-connection-settings pattern. ISO discovery and seed-ISO building introduce no new Hyper-V surface at all — they're filesystem/COM-object operations, independently testable without touching a VM.

**Tech Stack:** Windows PowerShell 5.1, the `Hyper-V` module's existing cmdlets (`Get-VMDvdDrive`, `Add-VMDvdDrive`, `Set-VMFirmware`, `Set-VMKeyProtector`, `Enable-VMTPM`), the `IMAPI2FS.MsftFileSystemImage` COM object (ships with Windows; builds non-bootable ISO9660 images with no external dependency). `python test_static.py` and `Test-LabVM.ps1` for tests, following this repo's existing split exactly.

**Spec:** GitHub issue #2 (https://github.com/CtrlCarlitos/lab-vm-manager/issues/2), Parts A and B specifically, as reprioritized and refined in `docs/superpowers/specs/2026-10-20-iso-installer-provisioning-design.md` — read both; the design doc is the authority on sequencing (this is the first of three plans: foundation, then Windows unattended install, then Linux unattended install) and on several settled calls (native, ADK-free seed-ISO building; a new menu action rather than extending the existing `N` VM-creation wizard; Part C, the manual interactive installer launcher, deliberately deprioritized and out of this plan's scope).

## Global Constraints

- Windows PowerShell 5.1 only (`#requires -Version 5.1`, already at the top of `Lab-VM.ps1`); no new external tool or module dependency beyond what Windows already ships — confirmed via research that `IMAPI2FS` needs nothing from the Windows ADK for a non-bootable image.
- Media/firmware changes require the VM to be `Off` (existing Global Constraint from the merged plans; enforce via `Assert-LabVMOff`, same as every other Off-gated operation in this file).
- Generation 2 only. Reject a Generation 1 VM cleanly with a clear message; never silently apply Generation 2 firmware commands to it, and never recreate a VM to change its generation.
- Never rotate an existing key protector, clear/disable TPM, or reset encryption-related state silently. Detect what's already present and leave it alone; only add what's missing.
- The configured ISO root (default `E:\ISO`, overridable via `-IsoRoot`) is strictly read-only: never modified, renamed, deleted, or used as VM/temporary storage. Every generated artifact (seed ISOs, per-VM provisioning state) lives in a separate, dedicated workspace under `%LOCALAPPDATA%\LabVmManager\...`, never under the ISO root.
- Resolve a selected ISO by its exact path only, never a wildcard. Re-validate it (exists, readable, nonzero size) immediately before attaching it — a selection can go stale between browse time and attach time.
- Preserve the existing lock/audit/confirmation/`-ReadOnly` guarantees: mutating actions go through `Invoke-LabAction`; this plan's one new inspect-only capability (showing current DVD/boot configuration) stays available under `-ReadOnly`, same as menu item `1`.

## Review Focus

- A missing/inaccessible ISO root (the configured drive isn't present, or the folder doesn't exist) must be reported as a clear, distinct failure — never shown as an empty-but-"complete" listing.
- Duplicate filenames in different subfolders must stay distinguishable (full path always shown; selection and attachment always by exact path, never by filename alone).
- A VM that already has a key protector/vTPM configured (from a previous run of this same feature, or from anything else) must be left untouched, not silently re-provisioned or rotated.
- A Generation 1 VM selected for this feature must be rejected with a clear, specific message, not a cryptic Hyper-V cmdlet error or a silent generation change.
- An ISO that's deleted, moved, or truncated between being browsed and being attached must fail the attach cleanly, not silently attach a stale or now-invalid reference.
- Pointing this feature at a VM that already has real data (an existing checkpoint, or a VHDX with non-trivial on-disk size) must warn and require extra confirmation before attaching installer media, never silently assume the disk is empty because of a name or because it's the common case.

---

### Task 1: ISO discovery

**Files:**
- Modify: `Lab-VM.ps1` (add `-IsoRoot` to the top `param()` block; add `Get-LabIsoCandidates`)
- Test: `test_static.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Get-LabIsoCandidates([string]$IsoRoot)` → `[pscustomobject]@{ Files = [pscustomobject[]]; Incomplete = [bool]; Errors = [string[]] }`, where each entry of `Files` is `[pscustomobject]@{ FullName; Length; LastWriteTime }`. `Files` is empty (not thrown) when the root is missing — `Incomplete` is `$true` and `Errors` names the missing root in that case, so a caller can tell "nothing found" from "couldn't look." Any subfolder that can't be enumerated (permission error, etc.) is skipped and recorded in `Errors`, with `Incomplete` set `$true` — the scan never silently presents a partial result as complete. Never follows a reparse point/symlink into a subfolder (avoids loops, and avoids silently expanding the search outside the chosen root). Matches `.iso` case-insensitively.

- [ ] **Step 1: Write failing tests**

```python
def test_iso_root_parameter_exists(self):
    body = self.s.split('param(', 1)[1].split(')\n\n', 1)[0]
    self.assertIn('$IsoRoot', body)
def test_iso_discovery_function_exists(self):
    self.assertIn('function Get-LabIsoCandidates', self.s)
def test_iso_discovery_never_follows_reparse_points(self):
    body = self.s.split('function Get-LabIsoCandidates {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('ReparsePoint', body)
def test_iso_discovery_reports_incomplete_not_silent_partial(self):
    body = self.s.split('function Get-LabIsoCandidates {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Incomplete', body)
```

Run: `python test_static.py` — expect FAIL on all four (the function/parameter don't exist yet).

- [ ] **Step 2: Implement**

Add `[string]$IsoRoot = 'E:\ISO'` to the top-level `param()` block, with a matching `.PARAMETER IsoRoot` comment-based-help entry (same convention as `-ExportRoot`'s existing entry). Implement `Get-LabIsoCandidates` as a manual stack-based walker — the same shape as the existing recursive scan in this file's file-transfer engine (a `[Collections.Generic.Stack[string]]` of pending directories, one `Get-ChildItem -LiteralPath ... -ErrorAction Stop` per directory inside a `try`/`catch` that records the path in `Errors` and sets `Incomplete` on failure, and that never pushes a reparse-point directory onto the stack) rather than a single `Get-ChildItem -Recurse`, which would silently swallow a mid-tree permission error instead of surfacing it.

- [ ] **Step 3: Run tests, confirm pass**

Run: `python test_static.py` — expect PASS on all four.

- [ ] **Step 4: Commit**

```bash
git add Lab-VM.ps1 test_static.py
git commit -m "feat: add recursive ISO library discovery"
```

---

### Task 2: ISO browse/select

**Files:**
- Modify: `Lab-VM.ps1` (add `Select-LabIsoPath`)
- Test: `Test-LabVM.ps1`, `test_static.py`

**Interfaces:**
- Consumes: `Get-LabIsoCandidates` (Task 1).
- Produces: `Select-LabIsoPath([string]$IsoRoot)` → the selected ISO's full path (`string`), or `$null` on cancel/no selection. Interactive: shows a numbered list (index, filename, full path, formatted size, last-write time — distinguishing same-named files in different folders), accepts a plain-text substring filter against the shown list (not a new scan) typed instead of a number, `'R'` to refresh (re-run `Get-LabIsoCandidates`), `'B'` to cancel. If the underlying scan came back `Incomplete`, says so plainly before showing the list, rather than presenting it as complete. Re-validates the chosen path immediately before returning it (exists, readable via `[IO.File]::OpenRead` succeeding and immediately closing, nonzero `Length`) — on failure, reports why and returns to the list rather than returning a bad path.

- [ ] **Step 1: Write failing tests**

```python
def test_iso_selection_function_exists(self):
    self.assertIn('function Select-LabIsoPath', self.s)
def test_iso_selection_revalidates_before_returning(self):
    body = self.s.split('function Select-LabIsoPath {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('OpenRead', body)
```

Run: `python test_static.py` — expect FAIL on both.

```powershell
# Test-LabVM.ps1 — follow the existing fake-cmdlet pattern used for Get-VM/Get-LabSshConnectionSettings
Test-Case 'Select-LabIsoPath lists candidates and returns the exact chosen path' {
    # Fake Get-LabIsoCandidates to return two entries with the SAME filename in different
    # folders; drive the function's Read-LabText fake to pick the second by its numbered index;
    # assert the returned path is the second entry's FullName, not a filename-only match.
}
Test-Case 'Select-LabIsoPath re-validates and rejects a path that no longer exists' {
    # Fake Get-LabIsoCandidates to return one entry whose FullName does not actually exist on
    # the fake filesystem; selecting it must not return that path -- it must report the problem
    # and return to the list (simulate a subsequent cancel to end the test case cleanly).
}
```

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` — expect FAIL (function doesn't exist).

- [ ] **Step 2: Implement `Select-LabIsoPath`**

Follow the existing menu-prompt style (`Read-LabText`, `ConvertTo-LabMenuIndex`) used by `Select-LabVM`/`New-LabVM` rather than inventing a new interaction pattern.

- [ ] **Step 3: Run tests, confirm pass**

Run both suites; expect PASS.

- [ ] **Step 4: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1 test_static.py
git commit -m "feat: add interactive ISO browse/select"
```

---

### Task 3: VM boot profile (Secure Boot + vTPM)

**Files:**
- Modify: `Lab-VM.ps1` (add `Test-LabVMHasKeyProtector`, `Set-LabVMBootProfile`)
- Test: `Test-LabVM.ps1`, `test_static.py`

**Interfaces:**
- Consumes: `Get-LabVM`, `Assert-LabVMOff` (existing).
- Produces:
  - `Test-LabVMHasKeyProtector([guid]$VMId)` → `[bool]`, a pure read-only check (no mutation, no `Off` requirement — safe to call for a preview before any confirmation). `Set-LabVMBootProfile` below calls this itself to decide whether to add one; Task 6's preview calls it standalone to decide whether to show the existing-encryption warning, **without triggering any mutation just to find that out.**
  - `Set-LabVMBootProfile([guid]$VMId, [ValidateSet('Windows11','UbuntuDesktop')][string]$OsProfile)` → `[pscustomobject]@{ SecureBootTemplateChanged = [bool]; KeyProtectorAdded = [bool]; TpmEnabled = [bool] }`, reporting exactly what changed versus what was already present, for an accurate audit detail. Throws clearly, before changing anything, if the VM's `Generation` is not `2`. For `'Windows11'`: sets `SecureBootTemplate` to `MicrosoftWindows` (no-op, reported as unchanged, if already set); if `Test-LabVMHasKeyProtector` is `$false`, adds a local one (`Set-VMKeyProtector -NewLocalKeyProtector`) and enables vTPM (`Enable-VMTPM`) — if one already exists, does not touch it, and reports `KeyProtectorAdded = $false`. For `'UbuntuDesktop'`: sets `SecureBootTemplate` to `MicrosoftUEFICertificateAuthority`; never touches key protector/vTPM at all for this profile.

- [ ] **Step 1: Write failing tests**

```python
def test_key_protector_check_is_read_only(self):
    self.assertIn('function Test-LabVMHasKeyProtector', self.s)
    body = self.s.split('function Test-LabVMHasKeyProtector {', 1)[1].split('\nfunction ', 1)[0]
    self.assertNotIn('Set-VMKeyProtector', body)
    self.assertNotIn('Enable-VMTPM', body)
def test_boot_profile_function_exists(self):
    self.assertIn('function Set-LabVMBootProfile', self.s)
def test_boot_profile_rejects_generation_1(self):
    body = self.s.split('function Set-LabVMBootProfile {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Generation', body)
def test_boot_profile_never_rotates_existing_key_protector(self):
    body = self.s.split('function Set-LabVMBootProfile {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('KeyProtectorAdded', body)
def test_boot_profile_linux_never_touches_tpm(self):
    body = self.s.split('function Set-LabVMBootProfile {', 1)[1].split('\nfunction ', 1)[0]
    # rindex, not index: the [ValidateSet('Windows11','UbuntuDesktop')] parameter
    # declaration contains both literal strings before either branch body does, so the
    # FIRST occurrence of each is always inside that declaration, not inside the actual
    # branch logic -- using the LAST occurrence of each is what actually lands inside
    # each branch's own code, regardless of switch/if-elseif/hashtable-dispatch style.
    idx_ubuntu = body.rindex("'UbuntuDesktop'")
    idx_windows = body.rindex("'Windows11'")
    ubuntu_branch = body[idx_ubuntu:idx_windows] if idx_ubuntu < idx_windows else body[idx_ubuntu:]
    self.assertNotIn('Enable-VMTPM', ubuntu_branch)
    self.assertNotIn('Set-VMKeyProtector', ubuntu_branch)
```

Run: `python test_static.py` — expect FAIL on all five.

```powershell
Test-Case 'Test-LabVMHasKeyProtector reads existing state without calling any mutating cmdlet' {
    # Fake the VM as already having a key protector; call it; assert it returns $true and
    # that neither the Set-VMKeyProtector nor Enable-VMTPM fakes were ever invoked.
}
Test-Case 'Set-LabVMBootProfile rejects a Generation 1 VM before changing anything' {
    # Fake Get-LabVM to return Generation=1; assert it throws and that the fakes for
    # Set-VMFirmware/Set-VMKeyProtector/Enable-VMTPM were never invoked.
}
Test-Case 'Set-LabVMBootProfile leaves an existing key protector alone' {
    # Fake the VM's key-protector state as already present; call with Windows11; assert
    # Set-VMKeyProtector/Enable-VMTPM fakes were never invoked and KeyProtectorAdded is $false.
}
Test-Case 'Set-LabVMBootProfile adds a key protector and vTPM when absent' {
    # Fake no existing key protector; call with Windows11; assert both fakes were invoked
    # exactly once each, and KeyProtectorAdded/TpmEnabled report $true.
}
Test-Case 'Set-LabVMBootProfile applies the Ubuntu Secure Boot template without touching vTPM' {
    # Call with UbuntuDesktop; assert the Set-VMFirmware fake received
    # MicrosoftUEFICertificateAuthority and that no vTPM-related fake was invoked.
}
```

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` — expect FAIL.

- [ ] **Step 2: Implement `Test-LabVMHasKeyProtector` and `Set-LabVMBootProfile`**

`Test-LabVMHasKeyProtector` uses `Get-VMSecurity`/`Get-VMKeyProtector`-equivalent inspection (confirm the exact read-side cmdlet during implementation — this codebase hasn't needed to *read back* key-protector presence before, only set it). `Set-LabVMBootProfile` calls it to decide whether to add one.

- [ ] **Step 3: Run tests, confirm pass**

- [ ] **Step 4: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1 test_static.py
git commit -m "feat: add Secure Boot and vTPM boot-profile preparation"
```

---

### Task 4: DVD media and boot order

**Files:**
- Modify: `Lab-VM.ps1` (add `Set-LabVMInstallMedia`, `Remove-LabVMInstallMedia`, `Set-LabVMBootOrder`, `Get-LabVMInstallMediaPath` helper for the host-side previous-attachment record)
- Test: `Test-LabVM.ps1`, `test_static.py`

**Interfaces:**
- Consumes: `Get-LabVM`, `Assert-LabVMOff` (existing).
- Produces:
  - `Get-LabVMInstallMediaPath([guid]$VMId)` → the per-VM state file path (`%LOCALAPPDATA%\LabVmManager\InstallMedia\<VMId>.json`), same JSON-per-VM-GUID convention and same role as `Get-LabSshConnectionSettingsPath`.
  - `Set-LabVMInstallMedia([guid]$VMId, [string]$IsoPath)` → `[pscustomobject]@{ PreviousAttachment = [string]; DvdDriveAdded = [bool] }`. Reuses the VM's existing DVD drive if exactly one is present; adds one if none exist; throws a clear "more than one DVD drive exists; this version doesn't choose among them" error if more than one exists. **Disclosed v1 limitation, not a stub to fill in later in this plan:** the issue asks for drive selection among several; a freshly-created VM (this plan's primary case) only ever has zero or one, so this is deliberately deferred rather than built now — document it plainly in Task 6's README update as a known limitation, not silently. Before changing anything, records the drive's current `Path` (which may be `$null`/empty) to the `Get-LabVMInstallMediaPath` file, so a later "show previous attachment" or restore can use it. Re-validates `$IsoPath` immediately before attaching (exists, readable, nonzero size), per the Global Constraints.
  - `Remove-LabVMInstallMedia([guid]$VMId)` → ejects the attached ISO (`Set-VMDvdDrive -Path $null`), leaving the drive itself in place.
  - `Set-LabVMBootOrder([guid]$VMId, [ValidateSet('Dvd','Disk')][string]$Preference)` → puts the chosen device class first in the firmware boot order **without deleting any other existing entry** (read the current `Get-VMFirmware ... | Select BootOrder`, reorder it, reapply via `Set-VMFirmware -BootOrder`) — this is deliberately generic so the Windows/Linux unattended-install plans can reuse it for the "swap back to disk-first after the installer's first reboot" step the design doc calls for, not just this plan's "DVD first" need.

- [ ] **Step 1: Write failing tests**

```python
def test_install_media_function_exists(self):
    self.assertIn('function Set-LabVMInstallMedia', self.s)
def test_install_media_records_previous_attachment(self):
    body = self.s.split('function Set-LabVMInstallMedia {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('PreviousAttachment', body)
def test_install_media_revalidates_iso_before_attach(self):
    body = self.s.split('function Set-LabVMInstallMedia {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Length', body)
def test_boot_order_preserves_other_entries(self):
    self.assertIn('function Set-LabVMBootOrder', self.s)
    body = self.s.split('function Set-LabVMBootOrder {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('BootOrder', body)
def test_eject_install_media_function_exists(self):
    self.assertIn('function Remove-LabVMInstallMedia', self.s)
```

Run: `python test_static.py` — expect FAIL on all five.

```powershell
Test-Case 'Set-LabVMInstallMedia reuses a single existing DVD drive' {
    # Fake exactly one DVD drive already present; assert Add-VMDvdDrive fake is never invoked.
}
Test-Case 'Set-LabVMInstallMedia adds a drive when none exists' {
    # Fake zero DVD drives; assert the Add-VMDvdDrive fake is invoked exactly once, and
    # DvdDriveAdded is $true.
}
Test-Case 'Set-LabVMInstallMedia throws when multiple drives exist' {
    # Fake two DVD drives; assert it throws before touching either.
}
Test-Case 'Set-LabVMInstallMedia rejects a since-deleted ISO path' {
    # Pass a path the fake filesystem reports as non-existent; assert it throws and that the
    # Set-VMDvdDrive fake (the actual attach) is never invoked.
}
Test-Case 'Set-LabVMBootOrder reorders without dropping entries' {
    # Fake a current boot order of [NetworkAdapter, HardDrive, DvdDrive]; call with -Preference
    # Dvd; assert the Set-VMFirmware fake received all three entries, with DvdDrive first and
    # the other two preserved in their relative order.
}
```

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` — expect FAIL.

- [ ] **Step 2: Implement all four functions**

- [ ] **Step 3: Run tests, confirm pass**

- [ ] **Step 4: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1 test_static.py
git commit -m "feat: add DVD media attach/eject and generic boot-order control"
```

---

### Task 5: Native seed-ISO builder and provisioning workspace

**Files:**
- Modify: `Lab-VM.ps1` (add `New-LabSeedIso`, `Get-LabProvisioningWorkspacePath`, `Remove-LabProvisioningWorkspace`)
- Test: `test_static.py`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Get-LabProvisioningWorkspacePath([guid]$VMId)` → the per-VM workspace path (`%LOCALAPPDATA%\LabVmManager\Provisioning\<VMId>`), created on demand. Never resolves to anything under the configured `-IsoRoot`.
  - `Remove-LabProvisioningWorkspace([guid]$VMId)` → deletes that workspace and its contents, if present; a no-op if absent.
  - `New-LabSeedIso([hashtable]$Files, [string]$OutputPath, [string]$VolumeLabel)` → builds a plain, non-bootable ISO9660 image at `$OutputPath` via the `IMAPI2FS.MsftFileSystemImage` COM object, where `$Files` keys are relative in-image paths and values are either a literal `[string]` of content or a local source file path to copy in. This is deliberately generic — the Windows and Linux unattended-install plans each decide their own answer-file content and pass it through this one function, rather than this function knowing anything about Autounattend.xml or cloud-init. Throws a clear error naming the COM object if `IMAPI2FS` can't be instantiated (so a stripped-down Windows install fails clearly rather than crashing obscurely).

- [ ] **Step 1: Write failing tests**

```python
def test_seed_iso_builder_function_exists(self):
    self.assertIn('function New-LabSeedIso', self.s)
    self.assertIn('IMAPI2FS', self.s)
def test_provisioning_workspace_never_under_iso_root(self):
    self.assertIn('function Get-LabProvisioningWorkspacePath', self.s)
    body = self.s.split('function Get-LabProvisioningWorkspacePath {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('LOCALAPPDATA', body)
    self.assertNotIn('$IsoRoot', body)
def test_provisioning_workspace_cleanup_function_exists(self):
    self.assertIn('function Remove-LabProvisioningWorkspace', self.s)
```

Run: `python test_static.py` — expect FAIL on all three.

- [ ] **Step 2: Implement**

This is the one piece of this plan not independently unit-testable through this codebase's existing fake-cmdlet harness, since it instantiates a real COM object rather than calling a mockable PowerShell cmdlet — follow the brief's own precedent elsewhere in this project for genuinely-interactive/non-fakeable code (document it as not covered by `Test-LabVM.ps1`'s fakes, and verify it with a real, safe, non-Hyper-V round-trip instead, in Step 3 below).

- [ ] **Step 3: Verify for real, safely (no Hyper-V involved — this is a plain Windows disk-image operation)**

Build a tiny seed ISO with one known text file, then `Mount-DiskImage` it, confirm the file's content round-trips exactly, then `Dismount-DiskImage`. This is non-destructive and touches no VM — safe to actually run. Record the result in `MANUAL-TESTS.md` under a new "ISO/installer provisioning" section as the first verified step (the Windows/Linux unattended-install plans will add to this same section).

- [ ] **Step 4: Run `test_static.py`, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py MANUAL-TESTS.md
git commit -m "feat: add native seed-ISO builder and provisioning workspace"
```

---

### Task 6: "Installation media" menu action

**Files:**
- Modify: `Lab-VM.ps1` (add `Set-LabVMInstallationMediaInteractive`; wire a new menu entry into `Show-LabVMMenu`)
- Test: `test_static.py`, `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: `Select-LabIsoPath` (Task 2), `Test-LabVMHasKeyProtector`/`Set-LabVMBootProfile` (Task 3), `Set-LabVMInstallMedia`/`Remove-LabVMInstallMedia`/`Set-LabVMBootOrder` (Task 4), `Assert-LabVMOff`, `Invoke-LabAction`, `Read-LabYesNoCancel` (existing).
- Produces: `Set-LabVMInstallationMediaInteractive([guid]$VMId)` → no return value. Prompts for the OS profile (`Windows11`/`UbuntuDesktop`), then `Select-LabIsoPath`, shows a preview (chosen ISO, target VM, DVD drive that will be used or added, the Secure Boot/vTPM changes `Set-LabVMBootProfile` would make, the boot-order change — stated plainly as a **persistent firmware preference, not a one-time boot setting**, since `Set-VMFirmware -FirstBootDevice` is checked on every subsequent boot, not just the next one), asks a `Read-LabYesNoCancel` confirmation (not a typed `Confirm-LabText` phrase — same reasoning as menu `C`: this writes local VM configuration, not an irreversible destination mutation, and it requires `Off` already, which is its own safety gate), then applies `Set-LabVMBootProfile` → `Set-LabVMInstallMedia` → `Set-LabVMBootOrder -Preference Dvd` in that order. Also offers "eject current media" and "inspect current DVD/boot configuration" (read-only, available under `-ReadOnly`) from the same entry point, per the issue's own framing of this as one media menu.
  - **Two safety checks in the preview itself, both read-only — nothing here may mutate the VM before the operator confirms:** (1) call `Test-LabVMHasKeyProtector` directly (never `Set-LabVMBootProfile`, which would mutate the VM to find this out) — if it returns `$true`, the preview says plainly that this VM already has encryption-related state configured and that security/firmware changes on an already-encrypted guest can require recovery material — the issue's own explicit warning, not something to skip because this plan's main case is fresh VMs. (2) if the VM already has at least one checkpoint, or its attached VHDX's actual on-disk size is non-trivial (a few hundred MB or more — a real check against the file, never an inference from its name or the VM's name), warn that booting installer media can overwrite an existing OS/data, suggest the existing checkpoint/export workflow first, and require an explicit extra confirmation beyond the normal one — defaulting to cancel, never silently proceeding, per the issue's own "do not inspect a disk's filename and assume it is empty." Only after both checks and the normal confirmation does the apply step run `Set-LabVMBootProfile` → `Set-LabVMInstallMedia` → `Set-LabVMBootOrder`.

- [ ] **Step 1: Write failing tests**

```python
def test_installation_media_function_exists(self):
    self.assertIn('function Set-LabVMInstallationMediaInteractive', self.s)
def test_installation_media_requires_confirmation(self):
    body = self.s.split('function Set-LabVMInstallationMediaInteractive {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Read-LabYesNoCancel', body)
def test_installation_media_menu_entry_exists(self):
    body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Set-LabVMInstallationMediaInteractive', body)
def test_installation_media_routed_through_invoke_lab_action(self):
    body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
    idx = body.index('Set-LabVMInstallationMediaInteractive')
    nearby = body[max(0, idx - 200):idx]
    self.assertIn('Invoke-LabAction', nearby)
def test_installation_media_warns_on_existing_key_protector(self):
    body = self.s.split('function Set-LabVMInstallationMediaInteractive {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('recovery', body.lower())
def test_installation_media_warns_before_overwriting_existing_data(self):
    body = self.s.split('function Set-LabVMInstallationMediaInteractive {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Checkpoint', body)
def test_installation_media_gates_mutation_internally_under_readonly(self):
    body = self.s.split('function Set-LabVMInstallationMediaInteractive {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('$script:LabReadOnly', body)
```

Run: `python test_static.py` — expect FAIL on all seven.

- [ ] **Step 2: Implement and wire the menu entry**

Add a new letter (not already used by `T`/`C`/`K`/`U`/`X`/`R`/`B`/`Q` — e.g. `M`) to **both** menu-text blocks in `Show-LabVMMenu` (it has a real read-only-safe capability, so it belongs in the read-only block too, same as `T`/`C`/`K`/`U`), wired the same way menu items `13`/`14` are: `Invoke-LabAction $VMId 'install-media-menu' -AllowReadOnly { param($id) Set-LabVMInstallationMediaInteractive $id }`. Follow the established convention for a function with both a read-only-safe path and a mutating one (`New-LabVM`'s own `if ($script:LabReadOnly) { ...; return 'CANCELLED' }` pattern, but scoped narrower): at the top of `Set-LabVMInstallationMediaInteractive`, when `$script:LabReadOnly` is set, offer only the "inspect current configuration" sub-action and refuse to even prompt for OS profile/ISO/attach — never let the read-only gate be enforced only by the menu wrapper.

- [ ] **Step 3: Run tests, confirm pass**

- [ ] **Step 4: Update `README.md` and `MANUAL-TESTS.md`**

Document the new `M` menu entry, the `-IsoRoot` parameter, the disclosed v1 limitation that selecting among several existing DVD drives isn't supported yet, and what this plan does and does NOT yet do (no OS actually gets installed by this plan — that's next). Add to `MANUAL-TESTS.md`'s new "ISO/installer provisioning" section: browsing the real `E:\ISO` library and confirming duplicate filenames in different folders stay distinguishable; preparing a real disposable Gen2 VM for each profile (Windows11, UbuntuDesktop) and confirming via `Get-VMFirmware`/`Get-VMSecurity` that the Secure Boot template and (for Windows11) vTPM landed correctly; confirming a Generation 1 VM is cleanly rejected; confirming ejecting media and re-attaching a different ISO both work and the previous-attachment record is accurate; confirming the existing-key-protector recovery-material warning actually appears when re-running this feature against a VM it already configured; confirming the existing-data warning and extra confirmation appear when pointed at a VM with a checkpoint or a non-trivial VHDX, and that cancelling there leaves the VM untouched.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py README.md MANUAL-TESTS.md
git commit -m "feat: add installation media menu action"
```
