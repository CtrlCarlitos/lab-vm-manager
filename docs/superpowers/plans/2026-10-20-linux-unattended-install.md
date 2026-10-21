# Linux Unattended Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new menu action/CLI mode creates a `LAB-` VM and drives it, unattended, to a logged-in Ubuntu 26.04.x Desktop with a known local account and a working, already-trusted SSH connection, with zero console interaction anywhere in the flow — including GRUB's boot menu — then leaves a completion note on the account's desktop, auto-saves the VM's SSH connection settings, and cleans up every trace of the install media and the placeholder credential material.

**Architecture:** Five small, independently testable functions (Ubuntu-release scope detection, the `autoinstall`-parameter GRUB patch, two-drive media attach/cleanup, the NoCloud `user-data` content builder, and the SSH completion wait + note delivery + connection-settings handoff) feed one top-level orchestrator that creates the VM, drives it through install, and wires into the existing menu/CLI as a new action — mirroring exactly how Plan 2's `Start-LabWindowsVMProvisioning` ties its own small functions together, and reusing Plan 1's shared building blocks and issue #3's SSH tooling throughout.

**Tech Stack:** Windows PowerShell 5.1, the in-box Hyper-V module, `IMAPI2FS` (`New-LabSeedIso`, already shipped), the Windows OpenSSH Client (`ssh.exe`/`ssh-keygen.exe`/`sftp.exe`, already a dependency of issue #3's SSH tooling) — no new external dependency.

**Spec:** `docs/superpowers/specs/2026-10-20-linux-unattended-install-design.md` (and, for the shared ISO/VM/media/boot building blocks this plan reuses, `docs/superpowers/specs/2026-10-20-iso-installer-provisioning-design.md` / Plan 1, and `docs/superpowers/specs/2026-10-20-windows-unattended-install-design.md` / Plan 2, both already implemented and merged).

## Global Constraints

- PowerShell 5.1 (`#requires -Version 5.1`); `Set-StrictMode -Version Latest` already in effect script-wide.
- **Ubuntu Desktop 26.04.x only is in scope.** Anything else must be detected and refused clearly, before anything is built or attached — not failed into deep in the flow. Matches `E:\ISO\ubuntu-26.04.1-desktop-amd64.iso` on this host.
- **`Set-LabVMBootProfile` already has a `'UbuntuDesktop'` case** (shipped in Plan 1: `MicrosoftUEFICertificateAuthority` Secure Boot template, no key protector/vTPM touched). This plan calls it unmodified; it is not a new function.
- **Password-based SSH automation is out of bounds.** `Invoke-LabSshCommand`/`Invoke-LabSftpCommand`'s `InteractivePassword` branch deliberately leaves OpenSSH's password prompt attached to the real console (see their own code comments) and must never be driven by this plan's unattended retry loop. All automation in this plan uses key-based auth with a plan-generated ephemeral keypair.
- **Host-key trust during the completion poll uses `StrictHostKeyChecking=accept-new`, scoped to a brand-new, narrowly-purposed function (Task 5) — `Invoke-LabSshCommand`/`Invoke-LabSftpCommand`/`Test-LabSshConnection`/`Add-LabSshKnownHost` are not modified and keep `StrictHostKeyChecking=yes`/`=ask` exactly as shipped.** `accept-new` writes to OpenSSH's own default `known_hosts` (the same file those existing, unmodified functions already check), so by the time this plan hands off to `Set-LabSshConnectionSettings`, ordinary post-provisioning SSH use already trusts the guest with no separate `Add-LabSshKnownHost` run needed.
- **Every configurable value is its own parameter with a sensible default; nothing hardcoded.** New top-level parameters introduced by this plan: `-ProvisionLinuxVM` (switch), `-LinuxIsoPath` (default `''`, interactive picker when omitted), `-LinuxTimeZone` (default `'America/Guatemala'`, an IANA zone ID — kept separate from `-TimeZone`, since that parameter's values are Windows registry time-zone IDs, a different namespace entirely). VM-hardware and generic-credential parameters are **shared, unchanged, with Windows provisioning** (same meaning for either OS, and PowerShell parameter names must be unique across the whole script regardless): `-NewVMName`, `-ComputerName`, `-Locale`, `-Credential`, `-NonInteractive`, `-VhdxSizeGB`, `-VCpuCount`, `-MemoryMinimumGB`/`-MemoryStartupGB`/`-MemoryMaximumGB`, `-SwitchName`, `-VmStorageRoot`, `-VhdxStorageRoot`, `-ProvisioningTimeoutSeconds`. `-ComputerName`'s existing Windows-hostname regex (`^[A-Za-z0-9-]{1,15}$`, not digits-only) is reused as-is for Linux too — it is already a strict subset of valid Linux hostnames, so nothing new is needed there. `-Locale`'s existing empty-string "not supplied" convention (see `Start-LabWindowsVMProvisioning`'s own `$getOption`) is reused unchanged; the Linux orchestrator applies its own default (`en_US.UTF-8`) when empty, exactly the way the Windows orchestrator applies `en-US`.
- Media/firmware changes require the VM `Off` (`Assert-LabVMOff`), matching every existing mutating function in this file.
- **No live elevated Hyper-V access in this development session.** Cmdlet-level and byte-level correctness is proven via `Test-LabVM.ps1` fakes and synthetic fixtures, the same way Plan 2 proved its boot-catalog patch without booting anything. Genuine end-to-end behavior — does the patched ISO really reach Subiquity with zero interaction, does the account's password really get set, does the guest's SSH host key really get trusted on first connect, does the completion note really land on the real desktop, is proven by the operator in `MANUAL-TESTS.md`, never assumed from this session alone.
- The provisioning workspace (`Get-LabProvisioningWorkspacePath`/`Remove-LabProvisioningWorkspace`, from Plan 1) holds the placeholder-hash-bearing seed ISO/user-data and the multi-gigabyte patched installer ISO. It is deleted promptly on success; on failure it is left in place, with the failure message explicitly naming its path and stating that it contains sensitive material. **The ephemeral SSH private key is explicitly NOT part of this workspace** — it lives at its own stable path (`%LOCALAPPDATA%\LabVmManager\SshConnections\<VMId>.key`, sibling to `Get-LabSshConnectionSettingsPath`'s own file) from the moment it's generated, so the workspace cleanup step never touches it.
- DVD/firmware reordering reuses Plan 1's `Set-LabVMBootOrder`/`Get-LabBootEntryKind` **unmodified**, exactly as Plan 2 already does.
- The real password reaching the guest (via the placeholder-hash + `late-commands`/`chpasswd` workaround, since `identity.password` needs a crypt(3) hash .NET cannot produce) must be escaped correctly through **two** real syntax layers, not guessed at: the YAML double-quoted-scalar layer the password string sits in, and the POSIX shell single-quoted-argument layer `sh -c` parses it through. Task 3 pins both mechanically (not with ad hoc character replacement).
- Fail loud, not silent — matching this codebase everywhere else: an unrecognized state, a missing boot entry, a patch-slack-space shortfall, a timeout, all throw with a clear message naming what was tried, never silently no-op or silently "succeed" with the wrong outcome.

## Review Focus

1. **The source ISO isn't Ubuntu Desktop 26.04.x** (a different release, Ubuntu Server, or a non-installer ISO entirely). Must refuse clearly, before anything is built or attached, naming what was actually found. Task 1 and Task 6 test this.
2. **`grub.cfg`'s sector doesn't have enough slack space for the inserted ` autoinstall` parameter**, or the directory-record length fields can't be located the way this plan expects. Must warn clearly and fall back to the unpatched ISO (mirroring Plan 2's no-prompt-variant-absent fallback), never silently claim success while still producing an ISO that boots to Subiquity's interactive installer. Task 2 tests this.
3. **The guest's SSH completion check never becomes reachable within the timeout** (the install genuinely hangs, the KVP-reported address never appears, the guest's `sshd`/`ssh.install-server` never came up because package access failed). Must time out with a clear message naming how long it waited and what it tried, never hang forever and never declare success without a real, successful SSH session. Task 5 tests this.
4. **The real account password contains characters that would break naive shell/YAML embedding** (a single quote, a double quote, a backslash, a `$`). Must reach `chpasswd` as the literal password, not a truncated or shell-reinterpreted value, and must never be logged or left in a form a reviewer could mistake for safe. Task 3 tests this explicitly with such a password.
5. **The orchestrator fails partway** (VM created but the GRUB patch throws; media attached but the seed ISO build fails; the ephemeral key was generated but the VM never connects; etc.). Must report exactly which steps already completed, matching Plan 2's "Steps already applied" pattern, must never delete the provisioning workspace out from under a failure the operator needs to debug, and must never leave stale/incomplete SSH connection settings pointing at a VM that never finished provisioning. Task 6 tests this.

---

### Task 1: Ubuntu release/scope check

**Files:**
- Modify: `Lab-VM.ps1` (new function, placed after Plan 2's `Test-LabWindowsIsoInScope`)
- Test: `test_static.py`, `Test-LabVM.ps1`

**Interfaces:**
- Produces: `Get-LabLinuxIsoInfo([string]$IsoPath) -> [pscustomobject]` with `ReleaseText` (`[string]`, the raw content of `.disk/info` at the mounted volume's root, or `''` if the file is absent) and `IsUbuntuDesktopInScope` (`[bool]`, `$true` only when `ReleaseText` matches Ubuntu 26.04.x Desktop).
- Consumes: nothing new — mounts `$IsoPath` read-only (`Mount-DiskImage`/`Get-Volume`, the same pairing Task 1 of Plan 2 already chose and documented; reuse that exact pairing here, not a new one) and always dismounts in a `finally`.
- Consumed by: Task 6's orchestrator, for the version-scope refusal before any VM is created.

Unlike Plan 2's Windows edition enumeration (which needs the `Dism` module to read a multi-edition `install.wim`), Ubuntu's `.disk/info` is a single plain-text file directly on the mounted ISO9660 volume — read it like any other mounted file, no DISM, no multi-edition picker (Ubuntu Desktop ships one edition).

- [ ] **Step 1: Write the failing tests**

In `test_static.py`, add to `SourceContract`:
```python
def test_linux_iso_info_function_exists(self):
    self.assertIn('function Get-LabLinuxIsoInfo', self.s)
def test_linux_iso_info_always_dismounts(self):
    body = self.s.split('function Get-LabLinuxIsoInfo {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('finally', body)
    self.assertIn('Dismount-DiskImage', body)
def test_linux_iso_info_scope_rule(self):
    body = self.s.split('function Get-LabLinuxIsoInfo {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('26.04', body)
    self.assertIn('Desktop', body)
```

In `Test-LabVM.ps1`, add `Get-LabLinuxIsoInfo` to the AST allowlist, then fake `Mount-DiskImage`/`Get-Volume`/`Dismount-DiskImage` (same pairing already faked for Plan 2's Task 1) plus `Test-Path`/`Get-Content` against the mounted drive letter:
  - `.disk/info` reads `"Ubuntu 26.04.1 LTS \"...\" - Release amd64"` → `IsUbuntuDesktopInScope = $true`, `ReleaseText` equals that exact string;
  - `.disk/info` reads an Ubuntu **Server** release string (e.g. containing `"Ubuntu-Server 26.04"`) → `IsUbuntuDesktopInScope = $false`;
  - `.disk/info` reads a different release (`"Ubuntu 24.04.1 LTS"`) → `IsUbuntuDesktopInScope = $false`;
  - `.disk/info` does not exist on the mounted volume → `ReleaseText = ''`, `IsUbuntuDesktopInScope = $false`, no thrown error;
  - `Dismount-DiskImage` is called even when the `Get-Content` fake throws mid-read (same "always dismounts" proof style as Plan 2's Task 1).

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL — function not defined.

- [ ] **Step 3: Implement `Get-LabLinuxIsoInfo` in `Lab-VM.ps1`**

Mount `$IsoPath` (same `Mount-DiskImage`/`Get-Volume` pairing as Plan 2's Task 1), in a `try`/`finally` that always `Dismount-DiskImage`s. Build the mounted root path, check `Test-Path (Join-Path $root '.disk\info')`; if absent, return `ReleaseText=''; IsUbuntuDesktopInScope=$false`. Otherwise read it with `Get-Content -Raw`, and set `IsUbuntuDesktopInScope = $ReleaseText -match 'Ubuntu 26\.04(\.\d+)? LTS' -and $ReleaseText -notmatch 'Server'` (Ubuntu's own `.disk/info` convention names Desktop releases plainly as `"Ubuntu ..."` and Server releases as `"Ubuntu-Server ..."`; match on the absence of `Server` rather than requiring the literal word `Desktop`, which `.disk/info` does not actually contain).

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add Ubuntu Desktop release/scope check"
```

---

### Task 2: `autoinstall`-parameter GRUB patch

**Files:**
- Modify: `Lab-VM.ps1` (new function, placed near Task 1's)
- Test: `test_static.py`, `Test-LabVM.ps1`
- Modify: `MANUAL-TESTS.md` (new live-verification section — see Step 6)

**Interfaces:**
- Produces: `New-LabPatchedBootableLinuxIso([string]$SourceIsoPath, [string]$OutputPath) -> [pscustomobject]` with `Patched` (`[bool]`), `Reason` (`[string]`, populated whenever `Patched` is `$false`), `OutputPath` (`[string]`, the new file's path when `Patched` is `$true`; `$null` when `$false` — the caller falls back to `$SourceIsoPath` itself, exactly mirroring Plan 2's Task 2 fallback contract).
- Consumed by: Task 6's orchestrator, which passes its result into Task 4's media-attach function.

This is the riskiest function in this plan, same category as Plan 2's Task 2 — raw byte-level ISO9660 parsing, no live elevated host to boot-test against in this development session. The parsing logic is pure byte-array math and independently unit-testable against a hand-built synthetic ISO9660 fixture, not a real Ubuntu ISO — the real ISO's exact `grub.cfg` sector layout is confirmed only by the live boot test in Step 6, not assumed here.

- [ ] **Step 1: Write the failing tests**

In `test_static.py`:
```python
def test_linux_boot_patch_function_exists(self):
    self.assertIn('function New-LabPatchedBootableLinuxIso', self.s)
def test_linux_boot_patch_inserts_autoinstall(self):
    body = self.s.split('function New-LabPatchedBootableLinuxIso {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('autoinstall', body)
def test_linux_boot_patch_updates_both_trees(self):
    body = self.s.split('function New-LabPatchedBootableLinuxIso {', 1)[1].split('\nfunction ', 1)[0]
    # Must locate and patch the directory-record length field in BOTH the plain ISO9660 tree and
    # the Joliet tree, not just overwrite file content in place -- the file's length changes.
    self.assertIn('Joliet', body)
```

In `Test-LabVM.ps1`, add a helper that builds a minimal synthetic ISO9660+Joliet byte layout in a temp file by hand: a Primary Volume Descriptor (sector 16) and a Supplementary (Joliet) Volume Descriptor (sector 17) each with a root directory record pointing at a small root directory extent containing one file entry named `grub.cfg` (primary tree: plain ASCII name; Joliet tree: the same name in UCS-2BE), each file entry's own directory record carrying its extent location and current data length, and real, distinguishable byte content at that extent (a short fake `grub.cfg` body containing one `linux /casper/vmlinuz ... quiet splash ---` line, with deliberate trailing padding bytes after the content within its own sector so there is real slack space to grow into). Then:
  - **happy path:** the function copies the source to `$OutputPath`, returns `Patched = $true`, and the output file's `grub.cfg` content (read back by mounting the copy, or by re-parsing the same way the function itself locates it) now contains ` autoinstall` inserted into the `linux` line, with the primary tree's directory record's data-length field AND the Joliet tree's directory record's data-length field both updated to the new, longer length, and every other byte in the file unchanged outside the touched region (hash-compare the rest, same style as Plan 2's Task 2 happy-path test);
  - **insufficient slack space:** the fixture's `grub.cfg` sector has no padding left (content fills the sector exactly) → `Patched = $false`, a `Reason` mentioning space/slack, `OutputPath = $null`, no output file created;
  - **no recognizable `linux`/kernel line:** the fixture's `grub.cfg` content doesn't contain a line this plan's pattern recognizes → `Patched = $false`, a `Reason` saying so, no output file created — this must never patch blind;
  - **`grub.cfg` not found at the expected path:** the fixture's root directory has no `grub.cfg` entry at all (simulating an ISO layout this technique doesn't understand) → `Patched = $false`, a `Reason` saying so, no output file created.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement `New-LabPatchedBootableLinuxIso` in `Lab-VM.ps1`**

Parse directly from `$SourceIsoPath` on disk (never the mounted volume, for the byte-level work — same discipline as Plan 2's Task 2): read the Primary Volume Descriptor at `16*2048` and the Supplementary (Joliet) Volume Descriptor at `17*2048` (identify Joliet by its escape-sequence bytes, standard UCS-2 Level 3 `%/E`), each giving a root directory record with an extent location and length. Walk each tree's directory records (root → `boot` → `grub` → `grub.cfg`, matching path components case-sensitively against the primary tree's plain names and against the Joliet tree's UCS-2BE-decoded names) to find `grub.cfg`'s own directory record in **both** trees, each carrying that record's own extent location, current data length, and (needed to patch the length field in place) the record's own byte offset within its parent directory's extent. Read the file's current content from its extent; locate the `linux` (kernel) boot line via the fixture's own test pattern (e.g. a line containing `/casper/vmlinuz`); if not found, return `Patched=$false` with a clear `Reason`. Compute the new content with ` autoinstall` inserted right after that line's existing boot parameters; if the new content's length exceeds the sector(s) backing the extent's remaining slack (round up to the next 2048-byte boundary and compare), return `Patched=$false` with a `Reason` naming the shortfall — never grow the file across a sector boundary this function doesn't also account for in both trees' extents. Only once all of that holds: copy the whole source file to `$OutputPath`, write the new content at the extent's offset (padding the remainder of its last sector with zero bytes, matching ISO9660 convention), and patch both trees' own directory-record data-length fields (a 4-byte little-endian + 4-byte big-endian pair per the ISO9660 spec) to the new length. Return `Patched=$true; OutputPath=$OutputPath`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add autoinstall-parameter GRUB patch for unattended Linux installs"
```

- [ ] **Step 6: Add the live verification to `MANUAL-TESTS.md`**

Add a new "Linux unattended install" section's first entry: build a real patched ISO from the real Ubuntu Desktop ISO in `-IsoRoot` (`E:\ISO\ubuntu-26.04.1-desktop-amd64.iso`), confirm `Patched=$true`, then **actually boot it** on a Gen2 VM with the `UbuntuDesktop` boot profile through to Subiquity starting the autoinstall with no console interaction at all. Record what you saw at GRUB's menu specifically (whether it appeared at all, or flashed and auto-booted). This is this plan's single most important manual-test gate, the Linux-flavored sibling of Plan 2's Task 2 Step 6.

---

### Task 3: NoCloud `user-data` content builder

**Files:**
- Modify: `Lab-VM.ps1` (new functions, placed after Task 2's)
- Test: `test_static.py`, `Test-LabVM.ps1`

**Interfaces:**
- Produces:
  - `ConvertTo-LabPosixShellSingleQuoted([string]$Value) -> [string]` — the standard, mechanical POSIX-shell single-quoted-literal escape: replaces every `'` in `$Value` with `'\''` and wraps the whole result in `'...'`. A small, independently-testable primitive, not folded into the YAML builder below.
  - `New-LabLinuxAutoinstallUserData([string]$ComputerName, [string]$Locale, [string]$TimeZone, [string]$UserName, [securestring]$Password, [string]$SshPublicKey) -> [string]` — a pure string builder, no I/O, no COM, no Hyper-V. Converts `$Password` to plain text only inside this function's own body, for exactly as long as it takes to build the escaped `late-commands` string, then zeroes it, matching Plan 2's Task 4 care around `[Runtime.InteropServices.Marshal]`.
  - `Test-LabLinuxUserName([string]$Value) -> [bool]` — Linux `adduser`-compatible username rule: `^[a-z_][a-z0-9_-]{0,31}$`.
- Consumed by: Task 6's orchestrator, which passes the returned string into `New-LabSeedIso -Files @{ 'user-data' = $userData; 'meta-data' = $metaData } -VolumeLabel 'cidata'` (the orchestrator builds `meta-data` itself inline — `"instance-id: $vmId`nlocal-hostname: $ComputerName`n"` — it is too trivial to need its own function or test here).

- [ ] **Step 1: Write the failing tests**

In `test_static.py`:
```python
def test_posix_shell_quote_function_exists(self):
    self.assertIn('function ConvertTo-LabPosixShellSingleQuoted', self.s)
def test_linux_user_data_builder_exists(self):
    self.assertIn('function New-LabLinuxAutoinstallUserData', self.s)
def test_linux_user_data_requires_autoinstall_server(self):
    body = self.s.split('function New-LabLinuxAutoinstallUserData {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('install-server', body)
def test_linux_user_data_password_scoped(self):
    body = self.s.split('function New-LabLinuxAutoinstallUserData {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('[Runtime.InteropServices.Marshal]', body)
def test_linux_user_data_uses_posix_quote_helper(self):
    body = self.s.split('function New-LabLinuxAutoinstallUserData {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('ConvertTo-LabPosixShellSingleQuoted', body)
```

In `Test-LabVM.ps1` (pure functions — no fakes needed, call directly):
  - `ConvertTo-LabPosixShellSingleQuoted`: `"it's"` → `'it'\''s'`; a value with no special characters round-trips as `'value'`; the empty string returns `''`;
  - `Test-LabLinuxUserName`: `'dev'`/`'lab_agent'` → `$true`; `'Dev'` (uppercase), `'1dev'` (leading digit), `''`, a 33-character name → `$false`;
  - `New-LabLinuxAutoinstallUserData`: returns a well-formed YAML document (`[string]$result` parses — since no YAML parser ships in-box, assert via structural string checks matching the style already used for `New-LabWindowsAnswerFileXml`'s tests rather than requiring an actual YAML module) containing `autoinstall:`, `identity:` with the exact `$ComputerName`/`$UserName`/`$Locale` values, `ssh:` with `install-server: true` and an `authorized-keys:` entry containing the exact `$SshPublicKey` string;
  - **the escaping-correctness test (Review Focus #4):** given a password containing a single quote, a double quote, a backslash, and a `$` (e.g. `` P@ss'"\$word ``), the returned `late-commands` entry, when the same single-quote-unescaping algorithm is applied to it in reverse inside the test (simulating what a POSIX shell would do), reconstructs the exact original password — proving the literal reaches `chpasswd` unchanged, not truncated or reinterpreted;
  - different `$ComputerName`/`$Locale`/`$TimeZone`/`$UserName`/`$SshPublicKey` inputs produce correspondingly different output (no hardcoded leftover from a first draft);
  - `identity.password` contains a hash shape (`$6$...`), never the real plaintext password, anywhere else in the returned string except inside the escaped `late-commands` entry.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement all three functions**

`ConvertTo-LabPosixShellSingleQuoted`: `"'" + $Value.Replace("'", "'\''") + "'"`.

`Test-LabLinuxUserName`: `$Value -cmatch '^[a-z_][a-z0-9_-]{0,31}$'`.

`New-LabLinuxAutoinstallUserData`: convert `$Password` via `[Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password))`, immediately `ZeroFreeGlobalAllocUnicode` the pointer in a `finally` once used. Build the `chpasswd`-feeding shell command as `"echo " + (ConvertTo-LabPosixShellSingleQuoted "${UserName}:${plainPassword}") + " | chpasswd"`, then wrap it for embedding as a single opaque argv element to `sh -c` via YAML double-quoted-scalar escaping — reuse `($shellCommand | ConvertTo-Json -Compress)` for this (a JSON double-quoted string literal is also a valid YAML double-quoted scalar; this plan does not write a second, separate escaping routine for a mechanically identical job). Emit:
```yaml
autoinstall:
  version: 1
  identity:
    hostname: <ComputerName>
    username: <UserName>
    password: "$6$<placeholder-salt>$<placeholder-hash>"   # replaced by late-commands below; see Already Proven in the spec
  locale: <Locale>
  timezone: <TimeZone>
  ssh:
    install-server: true
    authorized-keys:
      - <SshPublicKey>
  late-commands:
    - [curtin, in-target, --, sh, -c, <json-escaped shell command from above>]
  storage:
    layout:
      name: direct
```
(The exact placeholder hash value is pinned from Canonical's own documented autoinstall example, sourced live rather than invented — see Task 6's Step 3 note.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add NoCloud autoinstall user-data content builder"
```

---

### Task 4: Two-drive media attach and post-install cleanup

**Files:**
- Modify: `Lab-VM.ps1` (new functions, placed after Task 3's)
- Test: `test_static.py`, `Test-LabVM.ps1`

**Interfaces:**
- Consumes: Plan 1's `Assert-LabVMOff`, `Get-LabVM`, `Set-LabVMBootOrder` (unmodified).
- Produces:
  - `Set-LabVMUnattendedLinuxInstallMedia([guid]$VMId, [string]$LinuxIsoPath, [string]$SeedIsoPath) -> [void]`
  - `Complete-LabLinuxProvisioning([guid]$VMId, [string]$LinuxIsoPath, [string]$SeedIsoPath) -> [void]`

Both are near-verbatim mirrors of Plan 2's Task 3 functions (`Set-LabVMUnattendedInstallMedia`/`Complete-LabWindowsProvisioning`) with the Windows ISO parameter renamed to the Linux one — same zero-existing-drives assertion, same Generation-2 assertion, same re-validate-immediately-before-attach discipline, same "seed drive removed entirely, installer drive ejected but kept, boot order reset" cleanup shape. Follow those two functions' existing implementation directly as the template; do not invent a different shape for equivalent behavior.

- [ ] **Step 1: Write the failing tests**

In `test_static.py`:
```python
def test_linux_unattended_media_functions_exist(self):
    for name in ['Set-LabVMUnattendedLinuxInstallMedia', 'Complete-LabLinuxProvisioning']:
        self.assertIn('function ' + name + ' {', self.s)
def test_linux_unattended_media_refuses_existing_drives(self):
    body = self.s.split('function Set-LabVMUnattendedLinuxInstallMedia {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Get-VMDvdDrive', body)
    self.assertIn('throw', body)
def test_linux_unattended_cleanup_keeps_installer_drive(self):
    body = self.s.split('function Complete-LabLinuxProvisioning {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('-Path $null', body)
    self.assertIn('Remove-VMDvdDrive', body)
```

In `Test-LabVM.ps1` (add both function names to the allowlist), reuse the exact same six test cases Plan 2's Task 3 already wrote for its own two functions, retargeted at these two (attach with zero drives succeeds; attach with an existing drive throws before mutation; attach on Generation 1 throws before mutation; attach with a failing seed-ISO re-validation leaves the installer drive as reported; cleanup removes the seed drive and ejects-but-keeps the installer drive; cleanup with neither drive matching throws rather than guessing).

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement both functions in `Lab-VM.ps1`**

Copy Plan 2's Task 3 implementation shape exactly, renaming `$WindowsIsoPath` to `$LinuxIsoPath` throughout.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add two-drive unattended Linux install media attach and post-install cleanup"
```

---

### Task 5: Ephemeral SSH key, host-key-trusting completion wait, and note delivery

**Files:**
- Modify: `Lab-VM.ps1` (new functions, placed after Task 4's)
- Test: `test_static.py`, `Test-LabVM.ps1`

**Interfaces:**
- Consumes: the already-shipped `Get-LabSshToolingInfo`, `Get-LabGuestAddressCandidates`, `Invoke-LabSftpCommand` (called here only in its already-shipped `KeyAgent` branch, unmodified), `Get-LabSshConnectionSettingsPath` (for deriving the ephemeral key's sibling stable path, not for reading/writing connection settings themselves — that happens in Task 6).
- Produces:
  - `New-LabEphemeralSshKeyPair([guid]$VMId) -> [pscustomobject]` with `PrivateKeyPath` (`[string]`, `%LOCALAPPDATA%\LabVmManager\SshConnections\<VMId>.key` — created immediately at this stable path, never inside the provisioning workspace) and `PublicKeyContent` (`[string]`, the matching `.pub` file's content, trimmed). Calls `ssh-keygen.exe -t ed25519 -N '""' -f $PrivateKeyPath -q` (empty passphrase: this key authenticates a fully unattended process with no human present to type one; its file alone is the secret, matching the trust model `Get-LabSshConnectionSettingsPath`'s own stored `IdentityFilePath` already assumes for every other VM). Throws clearly if `ssh-keygen.exe` is missing (reuse `Get-LabSshToolingInfo`'s availability check) or exits non-zero.
  - `Wait-LabSshSession([guid]$VMId, [string]$UserName, [string]$IdentityFilePath, [int]$TimeoutSeconds) -> [string]` — polls `Get-LabGuestAddressCandidates $VMId` and, for each candidate address, attempts a trust-on-first-connect probe directly via `ssh.exe` (not through `Invoke-LabSshCommand`, which hardcodes `StrictHostKeyChecking=yes`): `ssh.exe -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i $IdentityFilePath "$UserName@$address" exit`, swallowing connection/auth/no-address-yet failures, printing elapsed-time progress each attempt, `Start-Sleep`ing between attempts, until one succeeds — then returns that address (the orchestrator needs it for `Set-LabSshConnectionSettings`). Throws a clear timeout message (naming elapsed time) if `$TimeoutSeconds` passes with no success.
  - `Write-LabLinuxProvisioningNote([string]$HostNameOrAddress, [string]$UserName, [string]$IdentityFilePath, [string]$Content) -> [void]` — writes `$Content` to a local temp file, then delivers it via `Invoke-LabSftpCommand` (`KeyAgent` mode — by this point the address is already trusted via the probe above, so the already-shipped `StrictHostKeyChecking=yes` in that function succeeds) with a batch script `put`ting it to `~/Desktop/lab-vm-manager-provisioning-note.txt` on the guest.
- Consumed by: Task 6's orchestrator (key generated before first boot; wait called once after first boot to prove completion; note delivered once connected; wait called again after the final cleanup reboot).

- [ ] **Step 1: Write the failing tests**

In `test_static.py`:
```python
def test_ephemeral_ssh_key_function_exists(self):
    self.assertIn('function New-LabEphemeralSshKeyPair', self.s)
def test_ephemeral_ssh_key_not_in_provisioning_workspace(self):
    body = self.s.split('function New-LabEphemeralSshKeyPair {', 1)[1].split('\nfunction ', 1)[0]
    self.assertNotIn('Provisioning', body)
    self.assertIn('SshConnections', body)
def test_ssh_wait_functions_exist(self):
    for name in ['Wait-LabSshSession', 'Write-LabLinuxProvisioningNote']:
        self.assertIn('function ' + name + ' {', self.s)
def test_ssh_wait_uses_accept_new_not_yes(self):
    body = self.s.split('function Wait-LabSshSession {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('accept-new', body)
    self.assertNotIn('StrictHostKeyChecking=yes', body)
def test_ssh_wait_has_bounded_timeout(self):
    body = self.s.split('function Wait-LabSshSession {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Stopwatch', body)
    self.assertIn('throw', body)
```

In `Test-LabVM.ps1` (add all three to the allowlist):
  - `New-LabEphemeralSshKeyPair`: fake `ssh-keygen.exe`'s call (via the same native-command-faking approach already used for `ssh.exe`/`sftp.exe` fakes elsewhere in this suite) to write a dummy keypair to the path it's given; assert the returned `PrivateKeyPath` is under `SshConnections`, not under the per-VM `Provisioning` workspace path; assert the tooling-missing case throws clearly;
  - `Wait-LabSshSession`: fake `Get-LabGuestAddressCandidates` to return no addresses at first, then one address; fake the `ssh.exe` probe to fail twice then succeed → returns the address, having slept between attempts (assert the sleep fake ran at least twice) and assert the probe's own arguments included `accept-new`, never `StrictHostKeyChecking=yes`;
  - `Wait-LabSshSession`: the fake probe always fails → throws a clear timeout message once the stopwatch exceeds `$TimeoutSeconds`, matching `Wait-LabPSDirectSession`'s own timeout-test style;
  - `Write-LabLinuxProvisioningNote`: fake `Invoke-LabSftpCommand` and assert it is called with `AuthMode='KeyAgent'` and a batch file whose content includes a `put` line, and that the exact `$Content` passed in was written to the local temp file referenced by that `put` line.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement all three functions**

Follow the signatures and behavior above exactly. For `Wait-LabSshSession`'s stopwatch/retry loop, mirror `Wait-LabPSDirectSession`'s structure directly (`[Diagnostics.Stopwatch]::StartNew()`, loop while elapsed `< $TimeoutSeconds`, `Write-Host` progress with elapsed time each attempt, fixed sleep interval between attempts, throw naming elapsed time after the loop).

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add ephemeral SSH key, trust-on-first-connect completion wait, and note delivery"
```

---

### Task 6: "Provision Linux VM" orchestrator, menu/CLI wiring, dispatcher refactor, docs

**Files:**
- Modify: `Lab-VM.ps1` (new orchestrator function; new top-level `param()` entries; new `-ProvisionLinuxVM` dispatch branch; new `L` entry in `Select-LabVM`; refactor of `Get-LabProvisioningOnlyParameter`/the dispatcher's orphan-parameter checks into three tiers)
- Test: `test_static.py`, `Test-LabVM.ps1`
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: every function from Tasks 1–5, plus Plan 1's `Select-LabIsoPath`, `New-LabVMCore`, `Set-LabVMBootProfile` (`'UbuntuDesktop'`), `New-LabSeedIso`, `Get-LabProvisioningWorkspacePath`/`Remove-LabProvisioningWorkspace`, `Get-LabHostDefaults`, `Get-LabSwitchNames`, `Write-LabAudit`, `Read-LabYesNoCancel`, `Set-LabSshConnectionSettings`, `Resolve-LabWindowsCredential`'s general shape (a new `Resolve-LabLinuxCredential` is added — same structure, Linux-flavored wording, reusing `[PSCredential]` as the carrier type).
- Produces: `Start-LabLinuxVMProvisioning([hashtable]$Options) -> [string]` (`COMPLETED`/`CANCELLED`), called directly from `Select-LabVM`'s menu switch (same pattern as `W`). A thin `Start-LabLinuxVMProvisioningCli` wrapper mirrors `Start-LabWindowsVMProvisioningCli`.

**Parameter-gating refactor (three tiers, replacing the current two-list Windows-only scheme):**
- `Get-LabCreationOnlyParameter` (new): the VM-hardware/generic parameters shared by both OS provisioning actions — `NewVMName`, `ComputerName`, `Locale`, `VhdxSizeGB`, `VCpuCount`, `MemoryMinimumGB`, `MemoryStartupGB`, `MemoryMaximumGB`, `SwitchName`, `VmStorageRoot`, `VhdxStorageRoot`, `ProvisioningTimeoutSeconds`. Rejected (orphaned) unless **either** `-ProvisionWindowsVM` **or** `-ProvisionLinuxVM` is supplied.
- `Get-LabProvisioningOnlyParameter` (existing, narrowed): now only the genuinely Windows-specific set — `WindowsIsoPath`, `OsEdition`, `ProductKey`, `TimeZone`. Rejected unless `-ProvisionWindowsVM` is supplied. (`NewVMName`/`ComputerName`/etc. move OUT of this list into the new shared one above — this is a real behavior change to already-shipped code, not additive-only, and is covered by updated tests, not just new ones.)
- `Get-LabLinuxProvisioningOnlyParameter` (new): `LinuxIsoPath`, `LinuxTimeZone`. Rejected unless `-ProvisionLinuxVM` is supplied.
- The dispatcher's mutual-exclusivity check becomes 4-way: `@([bool]$ConfigureSsh, [bool]($CopyToVM -or $CopyFromVM), [bool]$ProvisionWindowsVM, [bool]$ProvisionLinuxVM)`.
- When `-ProvisionWindowsVM` is supplied, `Get-LabLinuxProvisioningOnlyParameter`'s bound names are now also foreign and rejected (and vice versa for `-ProvisionLinuxVM` against the Windows-only list) — each provisioning mode accepts the shared creation parameters, its own OS-specific parameters, and `-NonInteractive`/`-Credential`, and rejects everything else.

**Design decisions settled here, not left ambiguous:**
- **New top-level parameters:** `-ProvisionLinuxVM` (switch), `-LinuxIsoPath` (default `''`), `-LinuxTimeZone` (default `'America/Guatemala'`, documented as an IANA zone ID, e.g. from `timedatectl list-timezones`, explicitly distinct from `-TimeZone`'s Windows registry IDs).
- **Overall sequence:** select ISO (`-LinuxIsoPath` or `Select-LabIsoPath`) → `Get-LabLinuxIsoInfo`/scope refusal **before any VM is created** → gather VM-hardware settings (shared code path with Windows provisioning where the values are genuinely the same concern — do not duplicate `Test-LabVCpuCount`/`Test-LabMemorySpec`/`Test-LabNewVMName`'s call sites, call the same validators Windows provisioning already calls) → combined preview → confirm → create VM (`New-LabVMCore`, create-name mutex, then the VM's own mutex, same as Windows) → resolve credential (`Resolve-LabLinuxCredential`, `Test-LabLinuxUserName`-validated) → build provisioning workspace → patch the ISO (Task 2) → generate the ephemeral SSH keypair at its **stable** path (Task 5, before anything else touches the workspace) → build `user-data`/`meta-data` (Task 3, with the keypair's public half) → build the seed ISO (`New-LabSeedIso -VolumeLabel 'cidata'`) → attach both drives (Task 4) → `Set-LabVMBootProfile $vmId 'UbuntuDesktop'` → start the VM → `Wait-LabSshSession` (first proof of completion; returns the trusted address) → `Write-LabLinuxProvisioningNote` → shut down → `Complete-LabLinuxProvisioning` (Task 4) → `Remove-LabProvisioningWorkspace` (the ephemeral key is NOT inside it, so this step cannot touch it) → start the VM again → `Wait-LabSshSession` a second time (proves a clean standalone boot, and re-confirms the address, which may have changed) → `Set-LabSshConnectionSettings -VMId $vmId -HostNameOrAddress <address> -Port 22 -UserName $accountName -IdentityFilePath $keyPair.PrivateKeyPath` → report done.
- **Failure handling:** identical shape to Plan 2's — one catch after VM creation, names every step already completed, states the workspace path and that it holds sensitive material, never auto-deletes or auto-powers-off the VM. Additionally: **`Set-LabSshConnectionSettings` is called only once, at the very end, after the second `Wait-LabSshSession` succeeds** — a partial/failed run never leaves stale SSH connection settings pointing at a VM that isn't actually ready (Review Focus #5).
- **Audit records:** `provision-linux-vm` `STARTED` right after VM creation; one `COMPLETED` or `FAILED_OR_UNCONFIRMED` record at the end, naming the ISO, computer name, and elapsed time — same shape as `provision-windows-vm`.

- [ ] **Step 1: Write the failing tests**

In `test_static.py`:
```python
def test_linux_provisioning_orchestrator_exists(self):
    self.assertIn('function Start-LabLinuxVMProvisioning {', self.s)
def test_linux_provisioning_scope_check_before_vm_creation(self):
    body = self.s.split('function Start-LabLinuxVMProvisioning {', 1)[1].split('\nfunction ', 1)[0]
    self.assertLess(body.index('IsUbuntuDesktopInScope'), body.index('New-LabVMCore -Name'))
def test_linux_provisioning_settings_saved_only_at_the_end(self):
    body = self.s.split('function Start-LabLinuxVMProvisioning {', 1)[1].split('\nfunction ', 1)[0]
    self.assertEqual(body.count('Set-LabSshConnectionSettings'), 1)
def test_linux_provisioning_key_outside_workspace(self):
    body = self.s.split('function Start-LabLinuxVMProvisioning {', 1)[1].split('\nfunction ', 1)[0]
    self.assertLess(body.index('New-LabEphemeralSshKeyPair'), body.index('Remove-LabProvisioningWorkspace'))
def test_linux_vm_name_param_shared_with_windows(self):
    # NewVMName must not be declared twice; it is the same top-level parameter either mode uses.
    self.assertEqual(self.s.count('[string]$NewVMName'), 1)
def test_linux_provision_switch_wired_in_dispatcher(self):
    self.assertIn('[switch]$ProvisionLinuxVM', self.s)
def test_creation_only_parameter_function_exists(self):
    self.assertIn('function Get-LabCreationOnlyParameter {', self.s)
def test_windows_only_parameter_list_narrowed(self):
    body = self.s.split('function Get-LabProvisioningOnlyParameter {', 1)[1].split('\nfunction ', 1)[0]
    self.assertNotIn("'NewVMName'", body)
    self.assertIn("'WindowsIsoPath'", body)
def test_l_menu_entry_wired(self):
    body = self.s.split('function Select-LabVM {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("-ieq 'L'", body)
def test_four_way_mutual_exclusivity(self):
    self.assertIn('[bool]$ProvisionLinuxVM', self.s)
```

In `Test-LabVM.ps1`: an end-to-end test faking every consumed function (Tasks 1–5 plus the shared Plan 1 functions) to prove the **sequence and failure behavior**:
  - happy path: every fake succeeds in order → returns `COMPLETED`; `Wait-LabSshSession`'s fake was called exactly twice; `Set-LabSshConnectionSettings`'s fake was called exactly once, after the second wait, with the second wait's returned address; `New-LabEphemeralSshKeyPair`'s fake was called before `Remove-LabProvisioningWorkspace`'s fake, and the key path it returned is never passed to `Remove-LabProvisioningWorkspace`;
  - version-scope refusal: `Get-LabLinuxIsoInfo`'s fake reports `IsUbuntuDesktopInScope=$false` → returns a clear refusal, `New-LabVMCore`'s fake never called;
  - a failure partway (fake the GRUB-patch step to throw) → `New-LabVMCore`'s fake WAS called, every step after the throwing one was not, the thrown message names the already-completed steps, the workspace path, and the word "password" (or equivalent sensitive-material wording), `Remove-LabProvisioningWorkspace`'s fake was never called, and `Set-LabSshConnectionSettings`'s fake was never called;
  - a failure AFTER the first `Wait-LabSshSession` succeeds but before the second one does (fake the second wait to throw) → `Set-LabSshConnectionSettings`'s fake was still never called (no stale settings for an unconfirmed clean-boot);
  - read-only mode: `$script:LabReadOnly` set → `Select-LabVM`'s `L` entry is not offered, mirroring the existing `N`/`W` read-only tests;
  - parameter-gating: `-LinuxIsoPath` supplied without `-ProvisionLinuxVM` → rejected as orphaned (mirrors the existing Windows-only orphan test, retargeted); `-WindowsIsoPath` supplied together with `-ProvisionLinuxVM` → rejected as foreign; `-NewVMName` supplied together with EITHER `-ProvisionWindowsVM` or `-ProvisionLinuxVM` → accepted in both (proves the shared-tier refactor didn't regress the existing Windows path — a regression test against Task 6's own refactor, not just a new-code test).

- [ ] **Step 2: Run tests to verify they fail**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement**

Add the new `param()` entries. Implement `Get-LabCreationOnlyParameter` and narrow `Get-LabProvisioningOnlyParameter` to the Windows-only list; add `Get-LabLinuxProvisioningOnlyParameter`. Update the dispatcher's orphan/foreign-parameter checks to the three-tier scheme described above, and extend the mutual-exclusivity array to 4 entries. Implement `Resolve-LabLinuxCredential` (same shape as `Resolve-LabWindowsCredential`, `Get-Credential -Message 'Guest Linux account credentials'`). Implement `Start-LabLinuxVMProvisioning`/`Start-LabLinuxVMProvisioningCli` per the sequence above. Wire `L` into both branches of `Select-LabVM`'s prompt text and `if` dispatch, gated the same way `W` already is. Source the exact placeholder autoinstall password hash from Canonical's own documented example (not invented) when writing Task 3's constant into this orchestrator's call — if no single canonical example hash can be found, generate one on a real Linux `mkpasswd`/`openssl passwd -6` output recorded in a code comment citing where it came from, so a future reader can verify it is a real, valid (if meaningless) hash and not a fabricated string that merely looks like one.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python test_static.py` and `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS, no regressions — including every existing Windows-provisioning test, since Step 3 changes shared dispatcher code.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py Test-LabVM.ps1
git commit -m "feat: add Linux unattended-install orchestrator, menu/CLI wiring, and shared parameter-gating refactor"
```

- [ ] **Step 6: Update `README.md` and `MANUAL-TESTS.md`**

README: document `-ProvisionLinuxVM` and every new parameter with its default, the `L` menu entry, what the flow does end-to-end, the two-boot-cycle cleanup behavior, the Ubuntu-Desktop-26.04.x-only scope restriction, the ephemeral-SSH-key/auto-saved-connection-settings behavior (and that it replaces any prior saved settings for that VM), and the Ubuntu-Desktop-needs-internet-during-install dependency (satisfied by the existing `Default Switch` default).

MANUAL-TESTS.md: the full end-to-end live run — real ISO, real provisioning, confirm the completion note actually appears on the real desktop, confirm `T`'s connection test succeeds immediately afterward with no separate `Add-LabSshKnownHost`/option-K run needed, confirm the VM boots cleanly standalone after cleanup, confirm the provisioning workspace is gone but the SSH key file is not, and (failure path) deliberately interrupt a run partway and confirm the workspace survives with a clear warning and no SSH connection settings were saved. Cross-reference Task 2's Step 6 entry rather than duplicating it. Also fold in a live confirmation of the two risks flagged as open in the design doc's "Already proven" section: whether the KVP-reported guest address appears without extra configuration, and whether `~/Desktop` exists for the note to land in.

```bash
git add README.md MANUAL-TESTS.md
git commit -m "docs: document the Linux unattended-install action"
```
