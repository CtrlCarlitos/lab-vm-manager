# Windows Unattended Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One new menu action/CLI mode creates a `LAB-` VM and drives it, unattended, to a logged-in Windows 11 desktop with a known local admin account, with zero console interaction anywhere in the flow — including the Hyper-V Gen2 "Press any key to boot from CD or DVD" prompt — then leaves a completion note on the desktop and cleans up every trace of the install media and the password.

**Architecture:** Five small, independently testable functions (Windows-edition/scope detection, the no-prompt boot-loader byte-patch, two-drive media attach/cleanup, the `Autounattend.xml` content builder, and the PowerShell-Direct completion wait + note delivery) feed one top-level orchestrator that creates the VM, drives it through install, and wires into the existing menu/CLI as a new action — mirroring how Plan 1's `Set-LabVMInstallationMediaInteractive` ties its own small functions together.

**Tech Stack:** Windows PowerShell 5.1, the in-box Hyper-V module, the in-box `Dism` module (`Get-WindowsImage`), `IMAPI2FS` (already used by Plan 1's `New-LabSeedIso`), PowerShell Direct (`New-PSSession -VMId`) — no ADK, no `oscdimg`, nothing beyond what Windows ships.

**Spec:** `docs/superpowers/specs/2026-10-20-windows-unattended-install-design.md` (and, for the shared ISO/VM/media/boot building blocks this plan reuses, `docs/superpowers/specs/2026-10-20-iso-installer-provisioning-design.md`, already implemented in Plan 1 / merged to `main`).

## Global Constraints

- PowerShell 5.1 (`#requires -Version 5.1`); `Set-StrictMode -Version Latest` already in effect script-wide.
- Nothing beyond what Windows ships — no ADK, no `oscdimg.exe`, no new external dependency. `Get-WindowsImage` comes from the in-box `Dism` module; guard its absence the same way `Assert-LabHost` already guards the Hyper-V module's absence.
- **Windows 11 client ISOs only are in scope.** Anything else (Windows 10, Server, a non-installer ISO) must be detected and refused clearly, before anything is built or attached — not failed into deep in the flow.
- Every configurable value is its own parameter with a sensible default; nothing hardcoded: `-ComputerName` (`lab-agent-test`), `-Locale` (`en-US`), `-TimeZone` (`Central America Standard Time`), `-OsEdition` (`Pro`, picked interactively from what the ISO actually offers when not given), `-VhdxSizeGB` (`150`, dynamically-expanding), plus VM-hardware parameters below. The already-shipped `-Credential`/`-NonInteractive` are reused unchanged for the account's credentials (`Resolve-LabWindowsCredential`).
- Media/firmware changes require the VM `Off` (`Assert-LabVMOff`), matching every existing mutating function in this file.
- **No live elevated Hyper-V access in this development session.** PowerShell-cmdlet-level correctness is proven via `Test-LabVM.ps1` fakes and, where a cmdlet's real output shape matters, the same .NET-reflection drift-guard technique Plan 1 already built (no elevation, no VM touched). Genuine end-to-end behavior — does the patched ISO really skip the prompt and really avoid a reboot loop, does Setup really finish, does PowerShell Direct really connect — is proven by the operator in `MANUAL-TESTS.md`, never assumed from this session alone.
- The provisioning workspace (`Get-LabProvisioningWorkspacePath`/`Remove-LabProvisioningWorkspace`, from Plan 1) holds the password-bearing seed ISO/answer file and the multi-gigabyte patched installer ISO. It is deleted promptly on success; on failure it is left in place, with the failure message explicitly naming its path and stating that it contains the password.
- DVD/firmware reordering reuses Plan 1's `Set-LabVMBootOrder`/`Get-LabBootEntryKind` **unmodified** — both are already documented there as deliberately generic for exactly this reuse (`-Preference Dvd` and `-Preference Disk` both already exist).
- Fail loud, not silent — matching this codebase everywhere else: an unrecognized state, a missing boot entry, a boot-loader size mismatch, a timeout, all throw with a clear message naming what was tried, never silently no-op or silently "succeed" with the wrong outcome.

## Review Focus

1. **The source ISO doesn't ship the no-prompt boot-loader variant** (not every Windows ISO carries both). Must warn clearly and fall back to the unpatched ISO, never throw, and never silently claim success while still producing a prompting ISO. Task 2 tests this.
2. **The source ISO isn't Windows 11 client** (Windows 10, Server, or a non-installer ISO entirely). Must refuse clearly, before anything is built or attached, listing what was actually found. Task 1 and Task 6 test this.
3. **`-OsEdition` doesn't match anything the chosen ISO actually offers** (typo, or an edition this particular ISO doesn't carry). Must list the real available editions and let the operator choose again interactively, or fail clearly (naming what's actually available) in `-NonInteractive` mode — never silently fall back to image index 1. Task 1 and Task 6 test this.
4. **PowerShell Direct never becomes reachable within the timeout** (wrong credentials, a genuinely hung install, something waiting on input this flow didn't anticipate). Must time out with a clear message naming how long it waited and what it tried, never hang forever and never declare success without a real, successful session. Task 5 tests this.
5. **The orchestrator fails partway** (VM created but the boot-loader patch throws; media attached but the seed ISO build fails; etc.). Must report exactly which steps already completed, matching Plan 1's "Steps already applied" pattern, and must never delete the provisioning workspace out from under a failure the operator needs to debug. Task 6 tests this.

---

### Task 1: Windows edition enumeration and version-scope check

**Files:**
- Modify: `Lab-VM.ps1` (new function, placed after Plan 1's `New-LabSeedIso`/`Get-LabProvisioningWorkspacePath` block)
- Test: `test_static.py`, `Test-LabVM.ps1`

**Interfaces:**
- Produces: `Get-LabWindowsInstallImages([string]$IsoPath) -> [pscustomobject[]]`, each with `Index` (`[int]`), `Name` (`[string]`, the edition's own display name, e.g. `"Windows 11 Pro"`), `InstallationType` (`[string]`), `BuildNumber` (`[int]`, parsed from the image's `Version`), `IsWindows11Client` (`[bool]`, `InstallationType -eq 'Client' -and BuildNumber -ge 22000`).
- Consumes: nothing new — mounts `$IsoPath` itself (read-only, always dismounted in `finally`, matching Plan 1's own live-tested `Mount-DiskImage`/dismount pattern from `New-LabSeedIso`'s MANUAL-TESTS).
- Consumed by: Task 6's orchestrator, for both the version-scope refusal and the edition picker.

- [ ] **Step 1: Write the failing tests**

In `test_static.py`, add to `SourceContract`:
```python
def test_windows_image_enumeration_function_exists(self):
    self.assertIn('function Get-LabWindowsInstallImages', self.s)
def test_windows_image_enumeration_guards_dism_module(self):
    body = self.s.split('function Get-LabWindowsInstallImages {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("Get-Module -ListAvailable -Name Dism", body)
def test_windows_image_enumeration_always_dismounts(self):
    body = self.s.split('function Get-LabWindowsInstallImages {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('finally', body)
    self.assertIn('Dismount-DiskImage', body)
def test_windows_image_enumeration_scope_rule(self):
    body = self.s.split('function Get-LabWindowsInstallImages {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("-eq 'Client'", body)
    self.assertIn('22000', body)
```

In `Test-LabVM.ps1`, add `Get-LabWindowsInstallImages` and `Test-LabWindowsIsoInScope` to the AST allowlist near the top (same list Plan 1 added `Get-LabVMInstallationMediaPreview` etc. to), then add these `Test-Case` blocks, faking `Mount-DiskImage` (returns a fake `DevicePath`/drive-letter object), `Get-Volume` or however the real mount result's drive letter is read (match whatever `Get-LabWindowsInstallImages`'s own implementation uses — decide this in Step 3 and keep the fake consistent with it), `Get-WindowsImage`, and `Dismount-DiskImage`:
  - a two-edition Windows 11 client image (`InstallationType='Client'`, `Version='10.0.26300.1000'` for one entry, same for the other with a different `EditionId`/`ImageName`) returns both, both `IsWindows11Client = $true`;
  - a Windows 10 image (`Version='10.0.19045.1'`, `InstallationType='Client'`) returns `IsWindows11Client = $false`;
  - a Windows Server image (`InstallationType='Server'`, high build) returns `IsWindows11Client = $false` even though the build number alone would pass;
  - `Dismount-DiskImage` is called even when the faked `Get-WindowsImage` throws (wrap the probe in a deliberately-throwing fake and assert the dismount fake still ran — same "always dismounts" proof style as Plan 1's workspace-cleanup tests);
  - the Dism-module guard: fake `Get-Module -ListAvailable -Name Dism` to return nothing and assert a clear, specific thrown message (not a raw `Get-WindowsImage: command not found`-style error).

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL — function not defined / tests reference code that doesn't exist yet.

- [ ] **Step 3: Implement `Get-LabWindowsInstallImages` in `Lab-VM.ps1`**

Guard `Get-Module -ListAvailable -Name Dism` first, throwing a clear message if absent (mirror `Assert-LabHost`'s Hyper-V-module guard's wording style). Mount `$IsoPath` with `Mount-DiskImage -ImagePath $IsoPath -ErrorAction Stop`, resolve its drive letter (via `Get-Volume -DiskImage (Get-DiskImage -ImagePath $IsoPath)` or `Get-Volume` on the mount result — pick whichever the real `Mount-DiskImage`/`Get-Volume` pairing this codebase hasn't used yet makes cleanest; there is no existing precedent to match here, so document the choice in a one-line comment), locate `sources\install.wim` first and `sources\install.esd` second (use whichever exists; throw clearly if neither does — "this doesn't look like a Windows installer ISO"), call `Get-WindowsImage -ImagePath <that file> -ErrorAction Stop` with no `-Index` to enumerate, then `Get-WindowsImage -ImagePath <that file> -Index $_.ImageIndex` per entry to read `InstallationType` and `Version` (the index-less call doesn't carry them). Parse `BuildNumber` from `Version`'s second dot-separated component (`10.0.26300.1000` → `26300`). Always `Dismount-DiskImage -ImagePath $IsoPath` in a `finally`, even on a thrown error from any step above.

Add a second, trivial pure function `Test-LabWindowsIsoInScope([object[]]$Images) -> [bool]`: returns `@($Images | Where-Object IsWindows11Client).Count -gt 0`. Keep this separate from the enumeration function so Task 6 can call it on an already-fetched list without re-mounting.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, including every pre-existing test (no regressions).

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add Windows edition enumeration and version-scope check"
```

---

### Task 2: No-prompt boot-loader patch

**Files:**
- Modify: `Lab-VM.ps1` (new function, placed near Task 1's)
- Test: `test_static.py`, `Test-LabVM.ps1`
- Modify: `MANUAL-TESTS.md` (new live-verification section — see Step 6)

**Interfaces:**
- Produces: `New-LabPatchedBootableIso([string]$SourceIsoPath, [string]$OutputPath) -> [pscustomobject]` with `Patched` (`[bool]`), `Reason` (`[string]`, populated whenever `Patched` is `$false`), `OutputPath` (`[string]`, the new file's path when `Patched` is `$true`; `$null` when `$false` — the caller falls back to `$SourceIsoPath` itself in that case, so a multi-gigabyte copy is never made for nothing).
- Consumed by: Task 6's orchestrator, which passes its result into Task 3's media-attach function.

This is the riskiest function in this plan — raw byte-level ISO9660/El Torito parsing, with no live elevated host to boot-test against in this development session. Unlike `New-LabSeedIso` (which instantiates real COM and so has no fake-able surface), this function's parsing logic is pure byte-array math and **is** independently unit-testable: build a small synthetic fixture with a valid El Torito structure by hand, rather than needing a real Windows ISO.

- [ ] **Step 1: Write the failing tests**

In `test_static.py`:
```python
def test_boot_patch_function_exists(self):
    self.assertIn('function New-LabPatchedBootableIso', self.s)
def test_boot_patch_verifies_before_writing(self):
    body = self.s.split('function New-LabPatchedBootableIso {', 1)[1].split('\nfunction ', 1)[0]
    # Must compare the catalog-pointed-at bytes against efisys.bin's own bytes before patching, not patch blind.
    self.assertIn('efisys.bin', body)
    self.assertIn('efisys_noprompt.bin', body)
def test_boot_patch_refuses_size_mismatch(self):
    body = self.s.split('function New-LabPatchedBootableIso {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('.Length', body)
```

In `Test-LabVM.ps1`, add a helper that builds a minimal synthetic ISO byte layout in a temp file: a 2048-byte sector 17 holding a Boot Record Volume Descriptor (type byte `0`, `"CD001"` at the standard offset, `"EL TORITO SPECIFICATION"` boot system identifier, a 4-byte little-endian catalog-sector pointer at its documented offset pointing at, say, sector 22), a 2048-byte sector 22 holding one 32-byte EFI ("no emulation", platform id `0xEF`) entry whose Load RBA field points at a chosen data sector (say sector 40), and real, distinguishable byte content at sector 40 (standing in for `efisys.bin`'s bytes). Then:
  - **happy path:** given a staged mount directory containing that fixture ISO (as `$SourceIsoPath`) plus loose files `efi\microsoft\boot\efisys.bin` (bytes matching sector 40's content exactly) and `efi\microsoft\boot\efisys_noprompt.bin` (different bytes, same length) — since the real function mounts the ISO to read these loose files, fake `Mount-DiskImage`/`Get-Volume`/`Dismount-DiskImage` to point at a real temp directory holding those two loose files, while the byte-parsing itself runs against the real fixture ISO file on disk — confirm the function copies the source to `$OutputPath`, returns `Patched = $true`, and the output file's bytes at sector 40 now equal `efisys_noprompt.bin`'s content with every other byte in the file unchanged (hash the rest of the file before/after and compare, matching Task 5's own "confirm nothing else changed" style);
  - **size mismatch:** `efisys_noprompt.bin` is a different length than `efisys.bin` → `Patched = $false`, a `Reason` mentioning size, `OutputPath = $null`, and no output file is created;
  - **catalog doesn't point where expected:** sector 40's content does NOT match `efisys.bin`'s bytes (simulating a layout this technique doesn't understand) → `Patched = $false`, a `Reason` saying the boot catalog didn't point where expected, no output file created — this must never patch blind;
  - **no-prompt variant absent:** the loose `efisys_noprompt.bin` file doesn't exist → `Patched = $false`, a `Reason` saying so, `OutputPath = $null`, no multi-gigabyte copy attempted (assert the copy-cmdlet fake was never called).

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement `New-LabPatchedBootableIso` in `Lab-VM.ps1`**

Mount `$SourceIsoPath` read-only (same mount/dismount pairing chosen in Task 1, reused here); check `efi\microsoft\boot\efisys_noprompt.bin` exists on the mounted volume — if not, dismount and return `Patched=$false` immediately, no copy made. Otherwise read `efisys.bin`'s and `efisys_noprompt.bin`'s raw bytes from the mounted volume; if their lengths differ, dismount and return `Patched=$false` with a size-mismatch `Reason`, no copy made. Parse the El Torito structure directly from the **source ISO file on disk** (not the mounted volume) exactly as the research did: read the 2048-byte sector at offset `17*2048`, confirm it's a Boot Record Volume Descriptor with `"EL TORITO SPECIFICATION"`, read its catalog-sector pointer, read that catalog sector, find the EFI (platform id `0xEF`) entry, read its Load RBA, compute `$offset = $loadRba * 2048`. Read `efisys.bin`'s own length worth of bytes from the source file at `$offset` and compare byte-for-byte against `efisys.bin`'s own content (read from the mount) — if they don't match, dismount and return `Patched=$false` with a clear "boot catalog did not point where expected" `Reason`, no copy made. Only once all of that holds: dismount, copy the whole source file to `$OutputPath` (`[IO.File]::Copy`), open the copy and overwrite exactly `efisys.bin`'s-length bytes at `$offset` with `efisys_noprompt.bin`'s content, close it, and return `Patched=$true; OutputPath=$OutputPath`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add no-prompt boot-loader patch for unattended Windows installs"
```

- [ ] **Step 6: Add the live verification to `MANUAL-TESTS.md`**

Add a new "Windows unattended install" section's first entry: build a real patched ISO from a real Windows 11 ISO in `-IsoRoot`, confirm `Patched=$true`, then **actually boot it** on a Gen2 VM with DVD first in boot order through to a completed install with no console interaction at all — this single live test is the proof for both this task's byte patch AND the "DVD stays first the whole time, no reboot loop" design decision (see the design doc's "Decided, round 2" section). Record what you saw at every reboot. This is the plan's single most important manual-test gate; nothing else in this plan proves it.

---

### Task 3: Two-drive media attach and post-install cleanup

**Files:**
- Modify: `Lab-VM.ps1` (new functions, placed after Plan 1's `Set-LabVMBootOrder`/`Get-LabBootEntryKind`)
- Test: `test_static.py`, `Test-LabVM.ps1`

**Interfaces:**
- Consumes: Plan 1's `Assert-LabVMOff`, `Get-LabVM`, `Set-LabVMBootOrder` (unmodified, both `-Preference Dvd` and `-Preference Disk`).
- Produces:
  - `Set-LabVMUnattendedInstallMedia([guid]$VMId, [string]$WindowsIsoPath, [string]$SeedIsoPath) -> [void]` — asserts Off, asserts Generation 2, **asserts zero existing DVD drives** (this plan only ever calls this against a VM it just created, so there is no "choose among several drives" case to handle — unlike Plan 1's `Set-LabVMInstallMedia`, which stays untouched and single-drive-guarded for its own, different, manual-install use case). Re-validates each ISO path (exists, openable, nonzero length — same checks as `Select-LabIsoPath`/`Set-LabVMInstallMedia`) immediately before attaching it, not after. Adds drive 1 (`Add-VMDvdDrive` + `Set-VMDvdDrive -Path $WindowsIsoPath`), then drive 2 the same way with `$SeedIsoPath`, then calls `Set-LabVMBootOrder $VMId 'Dvd'` once (both new drives are DVD-kind; which specific one ends up first doesn't matter — UEFI firmware skips a non-bootable disc and falls through, so the seed drive being tried first, if that's how it lands, costs nothing).
  - `Complete-LabWindowsProvisioning([guid]$VMId, [string]$WindowsIsoPath, [string]$SeedIsoPath) -> [void]` — asserts Off. Finds the DVD drive whose current `.Path` equals `$SeedIsoPath` and removes it entirely (`Remove-VMDvdDrive`); finds the one whose `.Path` equals `$WindowsIsoPath` and ejects it, keeping the drive (`Set-VMDvdDrive -Path $null`, matching Plan 1's `Remove-LabVMInstallMedia`'s own "the drive itself stays" behavior). Then `Set-LabVMBootOrder $VMId 'Disk'`.
- Consumed by: Task 6's orchestrator (attach before first boot, complete after the first successful login).

- [ ] **Step 1: Write the failing tests**

In `test_static.py`:
```python
def test_unattended_media_functions_exist(self):
    for name in ['Set-LabVMUnattendedInstallMedia', 'Complete-LabWindowsProvisioning']:
        self.assertIn('function ' + name + ' {', self.s)
def test_unattended_media_refuses_existing_drives(self):
    body = self.s.split('function Set-LabVMUnattendedInstallMedia {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Get-VMDvdDrive', body)
    self.assertIn('throw', body)
def test_unattended_media_revalidates_before_attach(self):
    body = self.s.split('function Set-LabVMUnattendedInstallMedia {', 1)[1].split('\nfunction ', 1)[0]
    self.assertLess(body.index('OpenRead'), body.index('Add-VMDvdDrive'))
def test_unattended_cleanup_keeps_installer_drive(self):
    body = self.s.split('function Complete-LabWindowsProvisioning {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("-Path $null", body)
    self.assertIn('Remove-VMDvdDrive', body)
```

In `Test-LabVM.ps1` (add both function names to the allowlist):
  - attach: a Gen2 VM with zero DVD drives → both drives added in order, both ISOs validated before each `Add-VMDvdDrive` call (assert the validation fake ran before the add fake, same ordering-proof style Plan 1 used for its own re-validation fix), `Set-LabVMBootOrder`'s fake called once with `'Dvd'`;
  - attach: a VM that already has one DVD drive → throws before any mutation (assert no `Add-VMDvdDrive`/`Set-VMDvdDrive` fake call happened);
  - attach: a Generation 1 VM → throws before any mutation;
  - attach: the seed ISO fails re-validation (deleted after selection, before this call) → throws, and drive 1 (already added for the Windows ISO) is left as the error reports it, not silently cleaned up (matches Plan 1's "Steps already applied" philosophy — this function doesn't roll back, the orchestrator's error message is what reports partial state);
  - cleanup: two drives present, one attached to each known path → the seed-path drive is removed, the installer-path drive is ejected but not removed, `Set-LabVMBootOrder`'s fake called once with `'Disk'`;
  - cleanup: neither drive matches either known path (defensive case, shouldn't happen in practice) → throws clearly rather than guessing which drive is which.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement both functions in `Lab-VM.ps1`**

Follow the signatures above exactly. Reuse the exact re-validation snippet style already in `Set-LabVMInstallMedia` (exists/openable/nonzero-length) for each ISO, immediately before its own `Add-VMDvdDrive` call — not once up front for both, so a problem with the seed ISO is caught before the Windows ISO's drive is even touched, and a problem with the Windows ISO is caught before anything is touched at all.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add two-drive unattended install media attach and post-install cleanup"
```

---

### Task 4: Autounattend.xml content builder

**Files:**
- Modify: `Lab-VM.ps1` (new function, placed after Task 3's)
- Test: `test_static.py`, `Test-LabVM.ps1`

**Interfaces:**
- Produces: `New-LabWindowsAnswerFileXml([string]$ComputerName, [string]$Locale, [string]$TimeZone, [int]$ImageIndex, [string]$UserName, [securestring]$Password) -> [string]` — a pure string builder, no I/O, no COM, no Hyper-V. Converts `$Password` to plain text only inside this function's own body, for exactly as long as it takes to interpolate it into the returned string; never logs it, never writes it anywhere itself.
- Consumed by: Task 6's orchestrator, which passes the returned string straight into Plan 1's `New-LabSeedIso -Files @{ 'Autounattend.xml' = $xmlString }`.

- [ ] **Step 1: Write the failing tests**

In `test_static.py`:
```python
def test_answer_file_builder_exists(self):
    self.assertIn('function New-LabWindowsAnswerFileXml', self.s)
def test_answer_file_no_product_key(self):
    body = self.s.split('function New-LabWindowsAnswerFileXml {', 1)[1].split('\nfunction ', 1)[0]
    self.assertNotIn('ProductKey', body)
def test_answer_file_single_logon(self):
    body = self.s.split('function New-LabWindowsAnswerFileXml {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('LogonCount', body)
def test_answer_file_password_scoped(self):
    body = self.s.split('function New-LabWindowsAnswerFileXml {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('[Runtime.InteropServices.Marshal]', body)
```

In `Test-LabVM.ps1` (pure function — no fakes needed, call it directly):
  - returns a well-formed XML document (`[xml]$result` doesn't throw) containing the exact computer name, locale, timezone, and username passed in;
  - the `<InstallFrom>` metadata names the passed `$ImageIndex`;
  - `AutoLogon`'s `LogonCount` is exactly `1`, and `Enabled` is `true`;
  - the password appears as plain text in the account-creation and AutoLogon sections (confirm both reference the *same* plaintext value derived from the same `SecureString`, since a typo here would quietly break the very completion check this plan depends on);
  - different `$ComputerName`/`$Locale`/`$TimeZone`/`$UserName` inputs produce correspondingly different output (no hardcoded leftover from a first draft);
  - the OOBE-skip settings this plan's design doc implies are present (EULA, OEM registration, wireless setup, network location, privacy/protect-PC prompts) — list each by its real unattend element name and assert it appears.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement `New-LabWindowsAnswerFileXml`**

Build the three-pass `unattend.xml` (windowsPE: disk configuration across the whole disk, `<InstallFrom>` metadata selecting `$ImageIndex`, no product key, `UserData`/`AcceptEula`; specialize: `ComputerName`, `TimeZone`; oobeSystem: `UserAccounts/LocalAccounts/LocalAccount` for `$UserName` as Administrator with the plaintext password, `AutoLogon` with `LogonCount=1` using the same credentials, `OOBE` settings to skip every prompt, `InputLocale`/`SystemLocale`/`UILanguage`/`UserLocale` all set to `$Locale`). Convert `$Password` via `[Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password))`, immediately `ZeroFreeGlobalAllocUnicode` the pointer in a `finally` once the string has been interpolated into the XML, matching the care this codebase already takes around credential material elsewhere (`Resolve-LabWindowsCredential`, the file-transfer code's `PSCredential` handling).

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add Autounattend.xml content builder"
```

---

### Task 5: PowerShell Direct completion wait and note delivery

**Files:**
- Modify: `Lab-VM.ps1` (new functions, placed after Task 4's)
- Test: `test_static.py`, `Test-LabVM.ps1`

**Interfaces:**
- Consumes: the already-shipped `Assert-LabVMRunning`, `Get-LabVM`.
- Produces:
  - `Wait-LabPSDirectSession([guid]$VMId, [PSCredential]$Credential, [int]$TimeoutSeconds) -> [System.Management.Automation.Runspaces.PSSession]` — polls `New-PSSession -VMId $VMId -Credential $Credential` every few seconds (swallowing connection/credential-not-ready errors), printing elapsed-time progress each attempt, until one succeeds; returns the open session. Throws a clear timeout message (naming the elapsed time) if `$TimeoutSeconds` passes with no success — the caller is responsible for `Remove-PSSession` once done with it.
  - `Write-LabProvisioningNote([PSSession]$Session, [string]$Content) -> [void]` — `Invoke-Command -Session $Session` writes `$Content` to a fixed file name on the connected account's own Desktop (`[Environment]::GetFolderPath('Desktop')`, read inside the session so it resolves to the guest account's own Desktop, not the host's).
- Consumed by: Task 6's orchestrator (called once after the first boot to prove completion and deliver the note, and again after the final cleanup reboot to confirm a clean standalone boot).

- [ ] **Step 1: Write the failing tests**

In `test_static.py`:
```python
def test_psdirect_wait_functions_exist(self):
    for name in ['Wait-LabPSDirectSession', 'Write-LabProvisioningNote']:
        self.assertIn('function ' + name + ' {', self.s)
def test_psdirect_wait_has_bounded_timeout(self):
    body = self.s.split('function Wait-LabPSDirectSession {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Stopwatch', body)
    self.assertIn('throw', body)
def test_provisioning_note_reads_guest_desktop(self):
    body = self.s.split('function Write-LabProvisioningNote {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("GetFolderPath('Desktop')", body)
```

In `Test-LabVM.ps1` (add both to the allowlist; fake `New-PSSession`/`Remove-PSSession`/`Invoke-Command`/`Start-Sleep`):
  - `Wait-LabPSDirectSession`: the fake `New-PSSession` throws twice then succeeds → the function retries and returns the session, having slept between attempts (assert the sleep fake was called at least twice);
  - `Wait-LabPSDirectSession`: the fake always throws → the function throws its own clear timeout message once the stopwatch (faked via a controllable clock, matching how `Wait-LabVMState`'s existing timeout test — if one exists — is tested, or a fresh equivalent pattern if not) exceeds `$TimeoutSeconds`, and `New-PSSession` is never called again after that point;
  - `Write-LabProvisioningNote`: the fake `Invoke-Command` is called with a script block that reads `[Environment]::GetFolderPath('Desktop')` and the exact `$Content` passed in reaches it (assert via the fake's captured arguments, same style as other `Invoke-Command`-based tests already in this suite for the file-transfer code).

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement both functions**

`Wait-LabPSDirectSession`: `$watch = [Diagnostics.Stopwatch]::StartNew()`; loop while `$watch.Elapsed.TotalSeconds -lt $TimeoutSeconds`, try `New-PSSession -VMId $VMId -Credential $Credential -ErrorAction Stop` and return it on success, catch-and-continue (printing `Write-Host` progress with elapsed time) on failure, `Start-Sleep` between attempts (pick a fixed interval, e.g. 10 seconds — short enough not to feel hung, long enough not to spam). After the loop, throw a clear message naming the elapsed time and that no session could be opened.

`Write-LabProvisioningNote`: `Invoke-Command -Session $Session -ScriptBlock { param($Text) $path = Join-Path ([Environment]::GetFolderPath('Desktop')) 'lab-vm-manager-provisioning-note.txt'; Set-Content -LiteralPath $path -Value $Text -Encoding UTF8 } -ArgumentList $Content`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add PowerShell Direct completion wait and desktop note delivery"
```

---

### Task 6: "Provision Windows VM" orchestrator, menu/CLI wiring, docs

**Files:**
- Modify: `Lab-VM.ps1` (new orchestrator function; new top-level `param()` entries; new `-ProvisionWindowsVM` dispatch branch; new `W` entry in `Select-LabVM`)
- Test: `test_static.py`, `Test-LabVM.ps1`
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: every function from Tasks 1–5, plus Plan 1's `Select-LabIsoPath`, `New-LabVMCore`, `Set-LabVMBootProfile`, `New-LabSeedIso`, `Get-LabProvisioningWorkspacePath`/`Remove-LabProvisioningWorkspace`, `Resolve-LabWindowsCredential`, `Get-LabHostDefaults`, `Get-LabSwitchNames`, `Write-LabAudit`, `Confirm-LabText`, `Read-LabYesNoCancel`.
- Produces: `Start-LabWindowsVMProvisioning([hashtable]$Options) -> [string]` (`COMPLETED`/`CANCELLED`) — the interactive entry point, called directly from `Select-LabVM`'s menu switch (same pattern as `N`/`New-LabVM`, not wrapped in `Invoke-LabAction`, since the VM doesn't exist yet when this starts). A second, thin wrapper `Start-LabWindowsVMProvisioningCli` (mirroring `Start-LabSshConfigurationCli`/`Start-LabFileTransferCli`) handles the `-NonInteractive`/parameter-driven path from the bottom dispatcher.

**Design decisions settled here, not left ambiguous:**
- **VM-hardware inputs are defaults-with-one-preview, not `N`'s per-field interactive wizard.** `New-LabVM`'s wizard has no parameter-driven counterpart at all (it's pure `Read-LabText` prompts), so reusing it verbatim would make a `-NonInteractive` scripted path impossible without rebuilding it anyway. Instead: `-VCpuCount` (default `2`, capped to the host's logical processor count), `-MemoryMinimumGB`/`-MemoryStartupGB`/`-MemoryMaximumGB` (defaults `2`/`4`/`8`, dynamic memory), `-VhdxSizeGB` (default `150`, dynamic), `-SwitchName` (default `''`/Disconnected — matching `New-LabVMCore`'s own existing default exactly, since PowerShell Direct needs no network), `-VmStorageRoot`/`-VhdxStorageRoot` (default `''` → `Get-LabHostDefaults`'s paths, same resolution `New-LabVM` already does). All of it is shown in one combined preview (VM hardware **and** the Windows-specific settings together) before the single `Read-LabYesNoCancel` confirmation that creates anything — no 12-question wizard. This is a deliberate deviation from the design doc's earlier "reuses `N`'s existing prompts... unchanged" phrasing, made here because that phrasing cannot coexist with the design doc's own `-NonInteractive`/scripted-caller requirement; it does not change any security or cleanup behavior the design doc committed to.
- **New top-level parameters** (added to the existing `param()` block): `-ProvisionWindowsVM` (switch, gates this whole mode, same pattern as `-CopyToVM`/`-ConfigureSsh`), `-NewVMName` (string — the name of the VM to create; distinct from the existing `-VMName`, which means "an existing VM to operate on" everywhere else in this file), `-ComputerName`, `-Locale`, `-TimeZone`, `-OsEdition`, `-VhdxSizeGB`, `-VCpuCount`, `-MemoryMinimumGB`, `-MemoryStartupGB`, `-MemoryMaximumGB`, `-SwitchName`, `-VmStorageRoot`, `-VhdxStorageRoot`, `-ProvisioningTimeoutSeconds` (default `1800`, range `300`–`7200` — the existing `-TimeoutSeconds`/`$script:LabTimeout` is sized for short VM-state waits like `Wait-LabVMState` and must not be silently repurposed for a multi-reboot OS install). `-Credential`/`-NonInteractive` are reused as-is.
- **Version-scope and edition-selection order:** select the ISO first (`Select-LabIsoPath`), enumerate its images (Task 1), refuse immediately with the full list of what was actually found if `Test-LabWindowsIsoInScope` is `$false` — **before any VM is created**. Then resolve the edition: if `-OsEdition` names one of the enumerated Windows-11-client images, use it; if it names something not present, list what IS available and either re-prompt (interactive) or throw naming the available choices (`-NonInteractive`); if `-OsEdition` wasn't given at all, show the numbered picker (same shape as `Select-LabIsoPath`) defaulting the highlighted choice to "Pro" when present.
- **Overall sequence:** select ISO → enumerate/scope-check/pick edition → gather VM-hardware settings → combined preview → confirm → create VM (`New-LabVMCore`, under the existing `Global\LabVmManager-Create-<NAME>` mutex, same as `New-LabVM`) → acquire that VM's own `Global\LabVmManager-<VMId>` mutex for everything else → resolve credential (`Resolve-LabWindowsCredential`) → build the provisioning workspace → patch the ISO (Task 2) → build `Autounattend.xml` (Task 4) → build the seed ISO (`New-LabSeedIso`) → attach both drives (Task 3's `Set-LabVMUnattendedInstallMedia`) → `Set-LabVMBootProfile $VMId 'Windows11'` → start the VM → `Wait-LabPSDirectSession` (first proof of completion) → `Write-LabProvisioningNote` → shut down → `Complete-LabWindowsProvisioning` (Task 3) → `Remove-LabProvisioningWorkspace` → start the VM again → `Wait-LabPSDirectSession` a second time (proves a clean standalone boot) → release the mutex → report done.
- **Failure handling:** any throw after VM creation is caught once, at the top of the post-creation sequence; the error names every step already completed (same "Steps already applied" sentence style as Plan 1's `Set-LabVMInstallationMediaInteractive`) and explicitly states the provisioning workspace's path and that it contains the account password, rather than deleting it. The VM itself is left exactly as it is — no automatic power-off, no automatic deletion.
- **Audit records**, written directly (this orchestrator is not wrapped by `Invoke-LabAction`, same as `New-LabVM`): `provision-windows-vm` `STARTED` right after VM creation; one `COMPLETED` or `FAILED_OR_UNCONFIRMED` record at the very end, with a detail string naming the ISO, edition, computer name, and total elapsed time.

- [ ] **Step 1: Write the failing tests**

In `test_static.py`:
```python
def test_provisioning_orchestrator_exists(self):
    self.assertIn('function Start-LabWindowsVMProvisioning {', self.s)
def test_provisioning_scope_check_before_vm_creation(self):
    body = self.s.split('function Start-LabWindowsVMProvisioning {', 1)[1].split('\nfunction ', 1)[0]
    self.assertLess(body.index('Test-LabWindowsIsoInScope'), body.index('New-LabVMCore'))
def test_provisioning_uses_create_mutex(self):
    body = self.s.split('function Start-LabWindowsVMProvisioning {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('LabVmManager-Create-', body)
def test_provisioning_failure_names_workspace_and_password(self):
    body = self.s.split('function Start-LabWindowsVMProvisioning {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('password', body.lower())
def test_new_vm_name_is_distinct_param(self):
    self.assertIn('[string]$NewVMName', self.s)
def test_provision_switch_wired_in_dispatcher(self):
    self.assertIn('[switch]$ProvisionWindowsVM', self.s)
def test_provisioning_timeout_is_its_own_param(self):
    self.assertIn('$ProvisioningTimeoutSeconds', self.s)
def test_w_menu_entry_wired(self):
    body = self.s.split('function Select-LabVM {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("-ieq 'W'", body)
```

In `Test-LabVM.ps1`: an end-to-end test faking every consumed function (Tasks 1–5 plus Plan 1's) to prove the **sequence and failure behavior**, not re-prove each piece's own internals:
  - happy path: every fake succeeds in order → returns `COMPLETED`, every phase's fake was called exactly once, in the documented order, `Remove-LabProvisioningWorkspace`'s fake was called exactly once, `Wait-LabPSDirectSession`'s fake was called exactly twice (first proof + post-cleanup proof);
  - version-scope refusal: the ISO's enumerated images are all non-Windows-11-client → returns a clear refusal, `New-LabVMCore`'s fake was never called (no VM created for a refused ISO);
  - `-OsEdition` names something not present: the picker/']-Interactive path re-prompts (simulate a second, valid answer) and proceeds; the `-NonInteractive` path throws naming what IS available, without ever calling `New-LabVMCore`;
  - a failure partway (fake the boot-loader patch step to throw) → the VM creation fake WAS called (so a VM now exists) but every step after the throwing one was not, the returned/thrown message names the already-completed steps and the workspace path plus the word "password", and `Remove-LabProvisioningWorkspace`'s fake was never called;
  - read-only mode: `$script:LabReadOnly` set → `Select-LabVM`'s `W` entry is not offered (mirror the existing `N`-under-read-only test style exactly).

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement**

Add the new `param()` entries (Global Constraints / design-decisions section above has the exact list and defaults). Implement `Start-LabWindowsVMProvisioning` and `Start-LabWindowsVMProvisioningCli` per the sequence above. Wire `W` into both branches of `Select-LabVM`'s prompt text and `if` dispatch, gated the same way `N` already is (`-not $script:LabReadOnly`). Add the orphan-parameter guard for the new Windows-only parameters, mirroring `Get-LabTransferOnlyParameter`/its dispatcher check exactly (a new `Get-LabProvisioningOnlyParameter` + a check in the bottom dispatcher next to the existing transfer-only one), and the mutually-exclusive-mode check alongside the existing `-ConfigureSsh`/`-CopyToVM`/`-CopyFromVM` one.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add Windows unattended-install orchestrator and menu/CLI wiring"
```

- [ ] **Step 6: Update `README.md` and `MANUAL-TESTS.md`**

README: document `-ProvisionWindowsVM` and every new parameter with its default, the `W` menu entry, what the flow does end-to-end, the two-boot-cycle cleanup behavior, the Windows-11-client-only scope restriction, and a pointer to the "press any key" note Plan 1's README already carries (this plan is what actually removes it, not just documents around it).

MANUAL-TESTS.md: the full end-to-end live run — real ISO, real provisioning, confirm the completion note actually appears on the real desktop, confirm the VM boots cleanly standalone after cleanup with no media attached, confirm the provisioning workspace is actually gone afterward, and (failure path) deliberately interrupt a run partway and confirm the workspace survives with a clear warning. Cross-reference Task 2's Step 6 entry rather than duplicating it.

```bash
git add README.md MANUAL-TESTS.md
git commit -m "docs: document the Windows unattended-install action"
```
