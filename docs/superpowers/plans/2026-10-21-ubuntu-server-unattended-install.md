# Ubuntu Server Unattended Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `-ProvisionLinuxServerVM` action (menu + CLI) that creates a VM and drives it, unattended, to a running Ubuntu Server with a known account and working SSH — the Server peer of the already-shipped `-ProvisionLinuxVM` (Desktop) action.

**Architecture:** Reuse every piece of the Desktop flow's machinery that has no Desktop-specific logic in it (confirmed by reading each function's body: `New-LabPatchedBootableLinuxIso`, `Set-LabVMUnattendedLinuxInstallMedia`, `Complete-LabLinuxProvisioning`, `New-LabEphemeralSshKeyPair`, `Wait-LabSshSession`, `New-LabLinuxAutoinstallUserData`, `Get-LabGuestAddressCandidates`, `Set-LabVMBootOrder`) directly, unchanged. Add a small amount of genuinely new surface: a Server scope check, a Server boot-profile value, a generalized note-delivery path, and a new orchestrator + CLI/menu wiring that mirrors `Start-LabLinuxVMProvisioning`'s shape with Server-specific defaults and messages.

**Tech Stack:** Windows PowerShell 5.1, Hyper-V cmdlets, Ubuntu Server 26.04.x autoinstall (Subiquity), OpenSSH client.

**Spec:** `docs/superpowers/specs/2026-10-21-ubuntu-server-unattended-install-design.md`

## Global Constraints

- Ubuntu Server 26.04.x only, matching `ubuntu-26.04.1-live-server-amd64.iso` — any other release/distro/edition is refused before any VM is created, same fail-loud pattern as Desktop/Windows.
- Bare system: no `packages:` list in autoinstall. No attempt to fix Hyper-V Manager's own KVP-based IP display (confirmed not fixable from the guest side — see spec's "Non-goals").
- Completion note goes in the account's home directory, not `~/Desktop` (Server has no desktop environment).
- `-ProvisionLinuxServerVM` gets its own parameter names, `-LinuxServerIsoPath` / `-LinuxServerTimeZone` — never shared with `-LinuxIsoPath`/`-LinuxTimeZone` (Desktop's own parameters stay untouched).
- `-SwitchName ''` (Disconnected) is refused for Server provisioning before any VM is created — same reasoning as Desktop: completion is proven by an SSH login over the network.
- Every configurable value is a parameter with a default, same convention as Plans 2 and 3.
- Reuse, never fork, any function with no Desktop-specific logic in its body. Only write new code where the spec's "Decided"/"What's left to the builder" sections actually call for something new.

## Review Focus

- A non-Server-26.04.x ISO (Desktop, Windows, an older Server release, a non-Ubuntu ISO) must be refused clearly, before any VM is created, naming what `.disk/info` actually held (or that it's missing) — Task 1's own test, exercised again through the full orchestrator in Task 3.
- `-SwitchName ''` must be refused for Server provisioning before any VM is created, with the same "SSH-over-network completion check" reasoning as Desktop — Task 3.
- Generalizing `Write-LabLinuxProvisioningNote`'s destination path must not change Desktop's own already-shipped behavior — Task 2's test asserts the exact SFTP batch Desktop's call site now produces is byte-for-byte what it produced before this plan touched the function.
- `-LinuxServerIsoPath`/`-LinuxServerTimeZone` must be refused without `-ProvisionLinuxServerVM`, and refused as foreign to `-ProvisionWindowsVM`/`-ProvisionLinuxVM` — mirroring the existing Windows/Desktop gating tests exactly — Task 3.
- The Linux-only computer-name rule (no leading/trailing hyphen) must still apply to Server, reusing Desktop's exact validation rather than a re-typed copy that could silently drift — Task 3.

---

### Task 1: Server scope detection and boot profile

**Files:**
- Modify: `Lab-VM.ps1` — `Get-LabLinuxIsoInfo` (around line 1855), `Set-LabVMBootProfile` (around line 2478)
- Test: `Test-LabVM.ps1`, `test_static.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Get-LabLinuxIsoInfo([string]$IsoPath) -> [pscustomobject]{ReleaseText, IsUbuntuDesktopInScope, IsUbuntuServerInScope}` (one new field, added to the existing object — existing callers reading `IsUbuntuDesktopInScope` are unaffected). `Set-LabVMBootProfile` accepts `'UbuntuServer'` in its `[ValidateSet('Windows11', 'UbuntuDesktop', 'UbuntuServer')]` parameter, with identical behavior to `'UbuntuDesktop'` (same `MicrosoftUEFICertificateAuthority` Secure Boot template, no key protector/vTPM touched).

- [ ] **Step 1: Write the failing tests**

In `Test-LabVM.ps1`, add fake-based tests for the new field (follow the existing `Get-LabLinuxIsoInfo` test pattern in the file — fake the mounted `.disk\info` content):

```powershell
Test-Case 'Get-LabLinuxIsoInfo: Ubuntu-Server 26.04.x is in scope for Server, not Desktop' {
    # Fake .disk/info content: "Ubuntu-Server 26.04.1 LTS `"Resolute Raccoon`" - Release amd64 (20260826)"
    # ... (use this file's existing Mount-DiskImage/Get-Volume fakes)
    Assert-Equal $info.IsUbuntuServerInScope $true
    Assert-Equal $info.IsUbuntuDesktopInScope $false
}
Test-Case 'Get-LabLinuxIsoInfo: Ubuntu Desktop 26.04.x is NOT in scope for Server' {
    Assert-Equal $info.IsUbuntuServerInScope $false
}
Test-Case 'Get-LabLinuxIsoInfo: Kubuntu/Xubuntu/Lubuntu Server-ish strings are never in scope for Server' {
    # Same anchor/case-sensitivity discipline as the existing Desktop scope test.
}
Test-Case 'Set-LabVMBootProfile UbuntuServer applies the same Secure Boot template as UbuntuDesktop, touches no key protector' {
    # Reuse this file's existing Set-LabVMBootProfile fakes/tests as the template.
}
```

In `test_static.py`, add a source-contract test confirming `IsUbuntuServerInScope`'s regex is anchored and case-sensitive, mirroring the existing Desktop test:

```python
def test_server_scope_regex_excludes_variants_and_desktop(self):
    body = self._body('Get-LabLinuxIsoInfo')
    self.assertIn("IsUbuntuServerInScope", body)
    self.assertIn(r"-cmatch '^Ubuntu-Server 26\.04(\.\d+)? LTS'", body)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` and `python -I test_static.py`
Expected: FAIL (field/value not recognized yet)

- [ ] **Step 3: Implement**

In `Get-LabLinuxIsoInfo`, add `IsUbuntuServerInScope` to the returned object, computed from the same already-read `$releaseText`:
```powershell
IsUbuntuServerInScope = ($releaseText -cmatch '^Ubuntu-Server 26\.04(\.\d+)? LTS')
```
(No `-notmatch 'Server'` exclusion needed here — the hyphenated `Ubuntu-Server` prefix is already unambiguous and distinct from Desktop's `Ubuntu 26.04` prefix.)

In `Set-LabVMBootProfile`, add a `'UbuntuServer'` case to the `switch ($OsProfile)` block, identical in body to the existing `'UbuntuDesktop'` case (same template check/set), and add `'UbuntuServer'` to the `[ValidateSet(...)]` attribute.

- [ ] **Step 4: Run tests to verify they pass**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` and `python -I test_static.py`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1 test_static.py
git commit -m "feat: Ubuntu Server ISO scope detection and boot profile"
```

---

### Task 2: Generalize completion-note delivery path

**Files:**
- Modify: `Lab-VM.ps1` — `Write-LabLinuxProvisioningNote` (around line 2999), its one existing call site in `Start-LabLinuxVMProvisioning`
- Test: `Test-LabVM.ps1`, `test_static.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Write-LabLinuxProvisioningNote([string]$HostNameOrAddress, [string]$UserName, [string]$IdentityFilePath, [string]$RemoteRelativePath, [string]$Content) -> [void]` — one new required parameter, inserted before `$Content` (every existing call site must be updated in the same commit; there is exactly one). `-mkdir` is only issued for the path's directory component when it has one (`Split-Path -Parent $RemoteRelativePath` non-empty); a bare filename with no directory component skips `-mkdir` entirely.

- [ ] **Step 1: Write the failing test**

In `Test-LabVM.ps1`, extend the existing `Write-LabLinuxProvisioningNote` test(s):

```powershell
Test-Case 'Write-LabLinuxProvisioningNote: a bare filename (no directory) skips -mkdir' {
    # Call with -RemoteRelativePath 'lab-vm-manager-provisioning-note.txt'
    # Assert the captured sftp batch file contains no '-mkdir' line, and its 'put' line's remote
    # path is exactly 'lab-vm-manager-provisioning-note.txt' (no directory prefix).
}
Test-Case 'Write-LabLinuxProvisioningNote: a path with a directory still issues -mkdir for that directory only' {
    # Call with -RemoteRelativePath 'Desktop/lab-vm-manager-provisioning-note.txt'
    # Assert the batch's '-mkdir' line names exactly 'Desktop', and 'put' writes to
    # 'Desktop/lab-vm-manager-provisioning-note.txt' -- i.e. Desktop's own call site's exact
    # pre-existing behavior, byte for byte.
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL ("parameter cannot be found" / wrong batch content)

- [ ] **Step 3: Implement**

Add `[string]$RemoteRelativePath` to `Write-LabLinuxProvisioningNote`'s param block. Replace the hardcoded `-mkdir Desktop` / `Desktop/lab-vm-manager-provisioning-note.txt` construction with:
```powershell
$remoteDir = Split-Path -Parent $RemoteRelativePath
$remoteDir = $remoteDir -replace '\\', '/'
$mkdirLine = if ($remoteDir -ne '') { "-mkdir `"$remoteDir`"`n" } else { '' }
$batch = "$mkdirLine" + "put `"$($localPath.Replace('\', '/'))`" `"$RemoteRelativePath`"`n"
```
Update `Start-LabLinuxVMProvisioning`'s one call site to pass `-RemoteRelativePath 'Desktop/lab-vm-manager-provisioning-note.txt'` explicitly (its exact pre-existing behavior, now spelled out instead of hardcoded inside the function).

- [ ] **Step 4: Run tests to verify they pass**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` and `python -I test_static.py`
Expected: PASS, including every pre-existing `Write-LabLinuxProvisioningNote`/Desktop-orchestrator test still green (regression proof).

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1 test_static.py
git commit -m "refactor: generalize the Linux provisioning note's destination path"
```

---

### Task 3: Server orchestrator, CLI/menu wiring

**Files:**
- Modify: `Lab-VM.ps1` — new functions near `Start-LabLinuxVMProvisioning`/`Start-LabLinuxVMProvisioningCli`/`Get-LabLinuxProvisioningOnlyParameter`; the three-way dispatch gate at the bottom of the script (`$osTiers`, the mutual-exclusion check, the `$provisionSwitch`/dispatch block); the menu's action list
- Test: `Test-LabVM.ps1`, `test_static.py`

**Interfaces:**
- Consumes: `Get-LabLinuxIsoInfo` (Task 1's `IsUbuntuServerInScope`), `Set-LabVMBootProfile 'UbuntuServer'` (Task 1), `Write-LabLinuxProvisioningNote` with `-RemoteRelativePath 'lab-vm-manager-provisioning-note.txt'` (Task 2), and unchanged: `Get-LabProvisioningVMHardware`, `New-LabVMCore`, `New-LabPatchedBootableLinuxIso`, `Set-LabVMUnattendedLinuxInstallMedia`, `Complete-LabLinuxProvisioning`, `New-LabEphemeralSshKeyPair`, `New-LabLinuxAutoinstallUserData`, `New-LabSeedIso`, `Wait-LabSshSession`, `Set-LabSshConnectionSettings`, `Set-LabVMBootOrder @('Dvd', 'Disk')`, `Resolve-LabLinuxCredential`, `ConvertTo-LabLinuxAccountName`.
- Produces: `Start-LabLinuxServerVMProvisioning([hashtable]$Options) -> [string]` (`'COMPLETED'`/`'CANCELLED'`, throws on failure — same contract as `Start-LabLinuxVMProvisioning`). `Start-LabLinuxServerVMProvisioningCli([hashtable]$Options, [string]$RequestedLogRoot) -> [string]`. `Get-LabLinuxServerProvisioningOnlyParameter([string[]]$BoundParameterNames) -> [string[]]` returning `@('LinuxServerIsoPath', 'LinuxServerTimeZone')` filtered to bound names (mirrors `Get-LabLinuxProvisioningOnlyParameter` exactly). New top-level params: `[switch]$ProvisionLinuxServerVM`, `[string]$LinuxServerIsoPath = ''`, `[string]$LinuxServerTimeZone = 'America/Guatemala'`.

- [ ] **Step 1: Write the failing tests**

In `Test-LabVM.ps1`, mirror the existing Desktop orchestrator test suite (fake every dependency the same way the Desktop happy-path test does — same fakes, same `Record`/`$script:LProvArgs` capture pattern) for:

```powershell
# Happy path, in the exact call order Start-LabLinuxVMProvisioning's own happy-path test asserts,
# substituting Get-LabLinuxServerProvisioningOnlyParameter / IsUbuntuServerInScope / 'UbuntuServer' /
# the home-directory RemoteRelativePath.
$script:LinuxServerProvHappyOrder = @('Select-LabIsoPath', 'Get-LabLinuxIsoInfo', 'Get-LabHostDefaults',
    'Read-LabYesNoCancel', 'New-LabVMCore', 'Enable-VMIntegrationService', 'Set-VM', 'Resolve-LabLinuxCredential',
    'Get-LabProvisioningWorkspacePath', 'New-LabPatchedBootableLinuxIso', 'New-LabEphemeralSshKeyPair',
    'New-LabLinuxAutoinstallUserData', 'New-LabSeedIso', 'Set-LabVMUnattendedLinuxInstallMedia',
    'Set-LabVMBootProfile', 'Start-LabVM', 'Wait-LabSshSession', 'Write-LabLinuxProvisioningNote',
    'Request-LabVMGuestShutdown', 'Wait-LabVMState:Off', 'Complete-LabLinuxProvisioning',
    'Remove-LabProvisioningWorkspace', 'Start-LabVM', 'Wait-LabSshSession', 'Set-LabSshConnectionSettings')

Test-Case 'Start-LabLinuxServerVMProvisioning happy path calls everything in order, UbuntuServer profile, home-dir note' {
    # Assert $core... same shape as the Desktop test's own $core assertions.
    # Assert the Set-LabVMBootProfile call received 'UbuntuServer', not 'UbuntuDesktop'.
    # Assert the Write-LabLinuxProvisioningNote call received RemoteRelativePath =
    #   'lab-vm-manager-provisioning-note.txt' (no 'Desktop/' prefix).
}
Test-Case 'Start-LabLinuxServerVMProvisioning refuses a non-Server-26.04.x ISO before any VM exists' {
    # IsUbuntuServerInScope = $false; assert New-LabVMCore never called.
}
Test-Case 'Start-LabLinuxServerVMProvisioning refuses -SwitchName (Disconnected) before any VM exists' {
    # Mirrors the Desktop test exactly.
}
Test-Case 'Start-LabLinuxServerVMProvisioning keeps the Linux-only hostname hyphen rule' {
    # Mirrors the Desktop test exactly.
}
```

In `test_static.py`, mirror the Desktop CLI-gating tests for the new switch/parameters:

```python
def test_provision_linux_server_vm_cli_gates(self):
    # -LinuxServerIsoPath without -ProvisionLinuxServerVM: exit 1 naming it.
    # -ProvisionLinuxServerVM -WindowsIsoPath / -LinuxIsoPath: exit 1, "do not apply to -ProvisionLinuxServerVM".
    # -ProvisionLinuxServerVM -ProvisionLinuxVM / -ProvisionWindowsVM: exit 1, "one action per invocation".
    # -ProvisionLinuxServerVM -ReadOnly: creates nothing.
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` and `python -I test_static.py`
Expected: FAIL (functions/parameters don't exist yet)

- [ ] **Step 3: Implement**

`Start-LabLinuxServerVMProvisioning([hashtable]$Options) -> [string]`: copy `Start-LabLinuxVMProvisioning`'s structure (it is the template; this is a parallel, not-shared orchestrator, matching this codebase's existing Windows-vs-Desktop-Linux precedent), with these exact deltas:
- Read `-LinuxServerIsoPath` (not `-LinuxIsoPath`) and `-LinuxServerTimeZone` (not `-LinuxTimeZone`, default `'America/Guatemala'`).
- Scope check: `$isoInfo.IsUbuntuServerInScope`; refusal message: `"Refusing '$isoPath': it is not an Ubuntu Server 26.04.x installer ISO, which is the only thing this action installs. Found: $found. No VM was created."`
- `$computerName` default: `'lab-agent-srv'` (distinct from Desktop's `'lab-agent-test'`, so the two don't collide if both are created with defaults). Same validation rules (1-15 chars, Linux hyphen rule) — reuse the identical regex/checks, not a re-typed copy.
- `Set-LabVMBootProfile $vmId 'UbuntuServer'` (not `'UbuntuDesktop'`).
- Preview object: `BootProfile = 'UbuntuServer: Secure Boot (MicrosoftUEFICertificateAuthority template); no key protector or vTPM'`; drop the `GuestAccount`/note preview line's "desktop" wording in favor of "home directory"; preview header/warning text says "Ubuntu Server" and "boots twice" the same way, but "a note on the account's desktop" becomes "a note in the account's home directory".
- `Write-LabLinuxProvisioningNote` call: `-RemoteRelativePath 'lab-vm-manager-provisioning-note.txt'` (Task 2's new parameter).
- `-SwitchName ''` refusal message: same reasoning, "provision a Linux Server VM" instead of "provision a Linux VM".
- Audit action names: `'provision-linux-server-vm'` instead of `'provision-linux-vm'`.
- Everything else — mutexes, workspace helpers, `New-LabPatchedBootableLinuxIso`, seed ISO, `Set-LabVMUnattendedLinuxInstallMedia`/`Complete-LabLinuxProvisioning`, `Set-LabVMBootOrder @('Dvd', 'Disk')`, ephemeral key, both `Wait-LabSshSession` calls (unpinned then pinned), `Set-LabSshConnectionSettings` — calls the exact same shared functions Desktop's orchestrator calls, unchanged.

`Start-LabLinuxServerVMProvisioningCli([hashtable]$Options, [string]$RequestedLogRoot) -> [string]`: copy `Start-LabLinuxVMProvisioningCli`'s structure exactly, substituting the required-parameter check to `@('NewVMName', 'LinuxServerIsoPath', 'Credential')` and its error message's switch name.

`Get-LabLinuxServerProvisioningOnlyParameter`: copy `Get-LabLinuxProvisioningOnlyParameter`'s structure, returning `@('LinuxServerIsoPath', 'LinuxServerTimeZone')`.

New top-level parameters (same block as the existing `-ProvisionLinuxVM`/`-LinuxIsoPath`/`-LinuxTimeZone`): `[switch]$ProvisionLinuxServerVM`, `[string]$LinuxServerIsoPath = ''`, `[string]$LinuxServerTimeZone = 'America/Guatemala'`.

Dispatch gate updates (bottom of the script):
- Mutual-exclusion check: add `[bool]$ProvisionLinuxServerVM` to the list being counted; update the error message to name `-ProvisionLinuxServerVM`.
- The "no provisioning switch supplied but a creation-only parameter was" check: add `-or $ProvisionLinuxServerVM` to the guard.
- `$osTiers`: add a third entry, `@{ Switch = 'ProvisionLinuxServerVM'; Supplied = [bool]$ProvisionLinuxServerVM; Names = @(Get-LabLinuxServerProvisioningOnlyParameter $boundParameterNames) }`. The `foreach ($tier in $osTiers)` loop body needs no changes — it already finds "the other supplied tier" generically regardless of how many tiers exist (verified by reading the loop: `$otherTier = @($osTiers | Where-Object { $_.Supplied })`, and the earlier mutual-exclusion check already guarantees at most one tier is ever `Supplied`).
- The three-way dispatch: change the `if ($ProvisionWindowsVM -or $ProvisionLinuxVM)` block's condition to `if ($ProvisionWindowsVM -or $ProvisionLinuxVM -or $ProvisionLinuxServerVM)`, and its internal `$provisionSwitch`/`$osSpecificNames`/final dispatch ternaries to three-way (Windows / Desktop-Linux / Server-Linux), calling `Start-LabLinuxServerVMProvisioningCli` for the new case.

Menu: add an entry (pick an unused letter, e.g. `S`) mirroring `L`'s wiring exactly, calling `Start-LabLinuxServerVMProvisioning` with no options (all defaults/prompts).

- [ ] **Step 4: Run tests to verify they pass**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` and `python -I test_static.py`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1 test_static.py
git commit -m "feat: add Ubuntu Server unattended-install orchestrator, menu/CLI wiring"
```

---

### Task 4: Docs and live test

**Files:**
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: everything above.
- Produces: no new code.

- [ ] **Step 1: Document `-ProvisionLinuxServerVM`**

In `README.md`, add a "Parameter mode: Linux Server unattended install" section mirroring the existing Desktop one exactly (same structure: switch, parameters with defaults, exit codes, audit records), and document the new menu letter. Note the home-directory note-delivery difference explicitly.

- [ ] **Step 2: Add the manual-test section**

In `MANUAL-TESTS.md`, add a "Linux Server unattended install" section mirroring Desktop's exactly: the GRUB-patch/release-string checks already proven read-only in this plan's design doc (cite them as already-done, not to re-prove), then the end-to-end `-ProvisionLinuxServerVM` live run — same structure as Desktop's own end-to-end section (interactive run, verification steps, failure-mode checks, refusals-before-any-VM-exists, CLI gates).

- [ ] **Step 3: Run the live test**

Follow MANUAL-TESTS.md's new section against the real host: `E:\ISO\ubuntu-26.04.1-live-server-amd64.iso`, a fresh `LAB-` name, `-VCpuCount 4` (matching the project owner's current VM fleet convention). Confirm both SSH logins succeed, the note lands at `~/lab-vm-manager-provisioning-note.txt` (not under `Desktop/`), and `Get-VMIntegrationService`'s Key-Value Pair Exchange status is irrelevant to success (address discovery falls back to ARP, same as Desktop). Fix anything this surfaces that the earlier tasks' fakes couldn't catch, following the exact same live-fix discipline Plan 3 used (ledger every finding and ruling if run under subagent-driven-development).

- [ ] **Step 4: Commit**

```bash
git add README.md MANUAL-TESTS.md
git commit -m "docs: document the Ubuntu Server unattended-install action"
```
