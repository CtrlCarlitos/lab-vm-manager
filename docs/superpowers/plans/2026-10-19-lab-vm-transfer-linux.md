# LAB VM File Transfer — Linux (SFTP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add bidirectional file/directory copy between the host and a **Linux** `LAB-*` guest via SFTP over SSH, plugging into the adapter-agnostic scaffolding the prior Windows plan (`2026-10-19-lab-vm-transfer-windows.md`, merged) already built — the same menu options, the same `Invoke-LabFileTransfer` orchestrator, the same pure conflict-resolution contract — so a transfer to a Linux guest and a transfer to a Windows guest are the same operator experience, differing only in which adapter runs underneath.

**Architecture:** `Invoke-LabFileTransfer` gains a second adapter branch alongside its existing PowerShell Direct one, selected by whether the operator has explicitly configured non-secret SSH connection settings for that VM (never inferred from the VM's name or Hyper-V state — per the spec's own requirement). The SFTP engine (`Copy-LabTransferItemSftp`) reuses the Windows engine's pure contract helpers (`Get-LabTransferConflictKind`/`Resolve-LabConflictAction`) and the same temp-sibling-then-finalize discipline, adapted to what OpenSSH's `sftp` batch mode actually supports natively: a single file's temp-then-`rename` is a true atomic POSIX rename; a *fresh* directory (destination doesn't already exist) is transferred via one recursive `put -r`/`get -r` into a temp sibling *directory*, then one atomic `rename` of the whole tree. **Directory transfer into an already-existing destination is explicitly out of scope for this version** (see the binding decision in Task 4) — `sftp`'s batch vocabulary has no recursive delete and no built-in per-item tree-merge primitive, and attempting to fake one with fragile `ls`-output parsing across a whole tree is a correctness risk this plan isn't taking without a live guest to validate against.

**Tech Stack:** Windows PowerShell 5.1 driving the **Windows-bundled OpenSSH client** (`ssh.exe`/`sftp.exe`, confirmed present and working on a representative host — see Task 1's empirical findings) via direct process invocation — no new third-party dependency. No SSH library, no `Posh-SSH` module, no custom chunking: `sftp -b <batchfile>` is OpenSSH's own batch-execution engine, and `sftp -r`/`get -r`/`put -r` is OpenSSH's own recursive-copy implementation.

**Spec:** GitHub issue #3 — "feat: bidirectional file and directory copy between host and Windows/Linux lab VMs" (https://github.com/CtrlCarlitos/lab-vm-manager/issues/3), Linux/SFTP half (section B's Linux row, the "Linux first connection and key roles" subsection, and the bounded section E design deliverable). The Windows/PowerShell-Direct half is already merged; this plan does not modify that adapter's behavior.

## Global Constraints

- Windows PowerShell 5.1 (Desktop edition) only; no new third-party dependencies — this plan drives the OS-bundled OpenSSH client as an external process, the same way the existing codebase already shells out to nothing else (everything else in `Lab-VM.ps1` is pure PowerShell/.NET/Hyper-V cmdlets; this is the one place that changes, and it's documented as a deliberate, bounded exception).
- **Binding empirical finding (Task 1), do not re-derive or contradict it:** OpenSSH's `ControlMaster`/`ControlPath`/`ControlPersist` connection-sharing mechanism was tested directly against both a non-routable address and `127.0.0.1` on a representative Windows host running `ssh.exe`/`sftp.exe` 9.5.6.4, and failed both times with `getsockname failed: Not a socket` before any network attempt — a broken local socket/pipe setup, not a network timeout. **This plan never uses `ControlMaster`.** A plain invocation with no connection-sharing flags, by contrast, was verified to work correctly end-to-end against a real reachable SSH host (clean key-based auth, clean "subsystem request failed" error for a host with no SFTP subsystem, no hangs). Every connection this plan makes is therefore a single, self-contained `ssh.exe`/`sftp.exe` process invocation — no persistent background connection, no multiplexing.
- `-o BatchMode=yes` on every noninteractive (key/agent-authenticated) invocation — this is the one piece of this plan's design that genuinely enforces "`-NonInteractive` never falls into an interactive prompt": `BatchMode=yes` is documented OpenSSH behavior that refuses to query a password/passphrase at all, failing cleanly instead.
- `-o StrictHostKeyChecking=yes` always, on every invocation, both interactive and noninteractive. Never `accept-new`, never `no`. An unknown host key under `BatchMode=yes` fails cleanly (no prompt is possible); under an interactive invocation, OpenSSH's own "authenticity of host... can't be established" prompt is shown directly to the operator (never auto-answered by this plan's code) via full console inheritance — this plan never captures, simulates, or auto-responds to that prompt.
- A password is never captured, relayed, stored, or simulated by this plan's own code — when password auth is needed, the relevant `sftp.exe` invocation runs with its own stdin/stdout/stderr fully inherited from the console (no redirection), so the operator types their password directly into OpenSSH's own native, non-echoing prompt. This plan's PowerShell code never sees the password.
- The host's own `~/.ssh/known_hosts` is used unmodified (no `-o UserKnownHostsFile` override) — this plan does not invent a separate trust store. A changed host key is never silently accepted or auto-removed; `Update-LabSshKnownHost` (Task 3) is the one, explicit, strongly-confirmed path for removing a stale entry, using `ssh-keygen -R`, never a raw file edit.
- Per-VM, non-secret SSH connection settings (hostname/address, port, username, identity-file path) persist by VM GUID under `%LOCALAPPDATA%\LabVmManager\SshConnections\<VMId>.json`, mirroring the existing `%LOCALAPPDATA%\LabVmManager\Logs` convention. Passwords, private-key contents, and live session state are never written there.
- Adapter selection is never inferred from the VM's name or Hyper-V state. `Get-LabTransferAdapterKind` (Task 5) returns `'SFTP'` only when the operator has explicitly configured SSH connection settings for that VM (a deliberate action, Task 6's "Configure SSH connection" menu item); every VM with no SSH settings configured keeps today's exact PowerShell Direct behavior, unchanged — this plan must not alter any existing Windows-adapter test or behavior from the merged Windows plan.
- Reuse `Get-LabTransferConflictKind`/`Resolve-LabConflictAction` (pure, already merged) directly — do not reimplement conflict-kind logic for the SFTP adapter.
- Every operation re-resolves the VM by GUID and rechecks the `LAB-` prefix before acting (`Assert-LabVMRunning`/`Get-LabVM`, already merged), exactly like the Windows adapter.
- The existing per-VM mutex (`Invoke-LabAction`'s pattern, already generalized by the Windows plan's fix round to also cover the CLI path) is held for the whole SFTP transfer too — no separate locking scheme.
- **Binding scope decision, stated here because it affects every later task:** a directory transfer (`-Recurse`) to a Linux guest is only supported when the destination directory does **not** already exist. If it does, the transfer fails immediately with a clear, honest message naming the limitation — it does not attempt a partial, fragile merge. Per-file transfer (no `-Recurse`) is fully supported with the same `Error`/`Skip`/`Overwrite` conflict semantics the Windows adapter has, since a single file's conflict check and atomic `rename`-based finalize are well within `sftp`'s native command set.

## Review Focus

- A single file transferred to/from a path whose destination doesn't exist, a path where it does (collision), and a path where the destination is the wrong type (file-vs-directory) must each resolve correctly BEFORE any `put`/`get` runs — mirroring the Windows engine's "reject before writing" guarantee. Covered in Task 4.
- A *fresh* directory transfer must land atomically (one `rename` of the whole temp tree) and never partially populate the real destination on a mid-transfer failure. Covered in Task 4.
- An attempt to transfer a directory into an *already-existing* destination must fail with the documented limitation message, not attempt a silent partial merge or a false success. Covered in Task 4.
- `-NonInteractive` on the SFTP adapter must never fall into a password prompt — it must require a configured identity file and fail clearly if one isn't set, exactly like the Windows adapter's credential requirement. Covered in Task 3 (`Resolve-LabSshAuthMode`) and a `test_static.py` source-contract check in Task 3.
- A changed host key must never be silently accepted — `Update-LabSshKnownHost` must require an explicit, strongly-typed confirmation showing what's being removed, and must use `ssh-keygen -R` (never a raw file edit that could remove the wrong entries or an unrelated host's trust). Covered in Task 3.

---

## File Structure

All changes land in the existing single-file script and its existing test/doc files, same convention as every prior plan on this project:

- Modify: `Lab-VM.ps1` — new SFTP-specific functions grouped near the Windows adapter's equivalents (Task 2's connection-settings functions near `Assert-LabVMRunning`; Task 3's SSH primitives near `New-LabPSDirectSession`; Task 4's `Copy-LabTransferItemSftp` near `Copy-LabTransferItem`); `Invoke-LabFileTransfer` gains an adapter branch; `Show-LabVMMenu` gains a "Configure SSH connection" entry and its existing `T` entry becomes adapter-aware; the top `param()` block and CLI path gain a small SSH-configuration surface.
- Modify: `Test-LabVM.ps1` — allowlist additions and `Test-Case` blocks for the pure/near-pure helpers.
- Modify: `test_static.py` — source-contract checks for the safety properties above.
- Modify: `README.md` — the Task 1 design-decision writeup, the new menu entry, the Linux-specific CLI surface, and the documented directory-merge limitation.
- Modify: `MANUAL-TESTS.md` — live acceptance sections for Linux-guest transfer, including the specific unverified-without-a-live-guest items this plan calls out.

---

### Task 1: SFTP backend investigation and design decision

**Files:**
- Modify: `Lab-VM.ps1` (add `Get-LabSshToolingInfo`)
- Modify: `Test-LabVM.ps1`, `test_static.py`
- Modify: `README.md`

**Interfaces:**
- Produces:
  - `Get-LabSshToolingInfo()` → `[pscustomobject]@{ Available = [bool]; SshPath; SftpPath; Version }`: `Get-Command ssh.exe -ErrorAction SilentlyContinue` / `sftp.exe` for paths, `(Get-Command ssh.exe).Version` for the version object; `Available` is `$true` only when both commands resolve. Not independently unit-testable (depends on the host's installed tooling) — covered by a `test_static.py` presence check, matching the precedent set by `Get-LabHostDefaults`/`Get-LabSwitchNames` in the VM-CRUD plan.

- [ ] **Step 1: Write and run the `test_static.py` presence check**

```python
def test_ssh_tooling_info_function_exists(self):
    self.assertIn('function Get-LabSshToolingInfo', self.s)
```

- [ ] **Step 2: Implement `Get-LabSshToolingInfo`**

Per the Interfaces block.

- [ ] **Step 3: Run `python test_static.py` and confirm it passes**

Run: `python test_static.py`
Expected: PASS on the new case plus every existing case.

- [ ] **Step 4: Write the design-decision section in `README.md`**

Add a new `README.md` section, "Linux file transfer: SFTP backend design decision," documenting, as a matter of record (not speculation):
- The version floor: Windows-bundled OpenSSH client (`ssh.exe`/`sftp.exe`), confirmed present and functional on a representative host at version 9.5.6.4; `Get-LabSshToolingInfo` is the runtime check this plan uses to detect it, and the manager must report a clear, actionable error (not a cryptic process-launch failure) when it's unavailable.
- The two empirical findings from this task's investigation, stated as fact: `ControlMaster`/`ControlPath`/`ControlPersist` failed with `getsockname failed: Not a socket` against both a non-routable address and `127.0.0.1` — this mechanism is not used anywhere in this plan. A plain invocation with no connection-sharing flags, by contrast, worked correctly end-to-end (clean key-based authentication, a clean "subsystem request failed" error against a host with no SFTP subsystem, no hangs) — this plan's entire design rests on plain, self-contained process invocations instead.
- The resulting two-mode authentication design this plan implements: `-o BatchMode=yes` plus a configured identity file for noninteractive/key-based transfers (never prompts, fails cleanly without a usable key); a plain invocation with full console inheritance (no `BatchMode`) for an interactive, first-time password-authenticated connection, so OpenSSH's own native password and host-key-trust prompts reach the operator directly.
- The directory-merge-into-existing-destination limitation (restated from the Global Constraints) and why: `sftp`'s batch vocabulary has no recursive delete and no built-in tree-merge primitive, and OpenSSH's own documented behavior for nested symlinks under `put -r`/`get -r` is not independently verified by this plan without a live guest — see `MANUAL-TESTS.md` for the specific live-verification step this gap requires before the limitation note can be removed or narrowed in a future version.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py README.md
git commit -m "docs: add SFTP backend investigation and design decision"
```

---

### Task 2: SSH connection settings persistence and address discovery

**Files:**
- Modify: `Lab-VM.ps1` (add functions near `Assert-LabVMRunning`)
- Modify: `Test-LabVM.ps1`, `test_static.py`

**Interfaces:**
- Consumes: `Get-LabVM` (existing).
- Produces:
  - `Get-LabSshConnectionSettingsPath(guid $VMId)` → `string`: `Join-Path $env:LOCALAPPDATA "LabVmManager\SshConnections\$VMId.json"`. Pure string-building, no I/O — fully unit-testable.
  - `Get-LabSshConnectionSettings(guid $VMId)` → `[pscustomobject]@{ HostNameOrAddress; Port; UserName; IdentityFilePath }` if the file at `Get-LabSshConnectionSettingsPath $VMId` exists and parses, otherwise `$null`. Never throws on a missing file — a missing file is a normal "not configured yet" state, not an error.
  - `Set-LabSshConnectionSettings(guid $VMId, [string]$HostNameOrAddress, [int]$Port, [string]$UserName, [AllowNull()][AllowEmptyString()][string]$IdentityFilePath)`: creates the `SshConnections` directory if missing (`[IO.Directory]::CreateDirectory`, matching the existing `Initialize-LabLog` idiom), writes the four fields as JSON via `ConvertTo-Json`/`Set-Content`. Never writes a password or key *contents* — only an identity-file *path* (a reference, not the secret itself) — this is the one field this function accepts that could be mistaken for a secret, so its own doc comment says so explicitly.
  - `Get-LabGuestAddressCandidates(guid $VMId)` → `string[]`: `Get-VMNetworkAdapter -VM (Get-LabVM $VMId) -ErrorAction Stop | Select-Object -ExpandProperty IPAddresses`, filtered to exclude obviously-unusable entries (link-local `169.254.*`/`fe80::*`) — a *suggestion list* for the configuration prompt in Task 6, never auto-selected or auto-trusted (per the Global Constraint that an IP address doesn't establish guest identity).

- [ ] **Step 1: Write failing `Test-LabVM.ps1` cases for `Get-LabSshConnectionSettingsPath`**

```powershell
Test-Case 'SSH connection settings path is scoped by VM GUID' {
    $id = [guid]'11111111-1111-1111-1111-111111111111'
    $path = Get-LabSshConnectionSettingsPath $id
    Assert-Equal ($path -like "*SshConnections*$id.json") $true
}
```

Add `'Get-LabSshConnectionSettingsPath'` to the `$allowlist` array.

- [ ] **Step 2: Run `Test-LabVM.ps1` and confirm it fails**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL — function doesn't exist yet.

- [ ] **Step 3: Implement all four functions**

Per the Interfaces block. `Get-LabSshConnectionSettings`/`Set-LabSshConnectionSettings`/`Get-LabGuestAddressCandidates` depend on real I/O or Hyper-V and aren't independently unit-testable via `Test-LabVM.ps1`'s fakes — covered by `test_static.py` presence/shape checks in the next step, matching established precedent.

- [ ] **Step 4: Run `Test-LabVM.ps1` and confirm it passes**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS on the new case plus everything existing.

- [ ] **Step 5: Write and run `test_static.py` cases for the other three functions**

```python
def test_ssh_connection_settings_functions_exist(self):
    for name in ['Get-LabSshConnectionSettings', 'Set-LabSshConnectionSettings', 'Get-LabGuestAddressCandidates']:
        self.assertIn('function ' + name, self.s)
def test_ssh_connection_settings_never_writes_password_field(self):
    body = self.s.split('function Set-LabSshConnectionSettings {', 1)[1].split('\nfunction ', 1)[0]
    self.assertNotIn('Password', body)
    self.assertNotIn('$Credential', body)
```

Run: `python test_static.py`
Expected: PASS on both new cases.

- [ ] **Step 6: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1 test_static.py
git commit -m "feat: add SSH connection settings persistence and address discovery"
```

---

### Task 3: SSH authentication primitives, connection test, and changed-host-key workflow

**Files:**
- Modify: `Lab-VM.ps1` (add functions near `New-LabPSDirectSession`)
- Modify: `test_static.py`
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: `Get-LabSshToolingInfo` (Task 1), `Get-LabSshConnectionSettings` (Task 2), `Assert-LabVMRunning` (existing).
- Produces:
  - `Resolve-LabSshAuthMode([AllowNull()][AllowEmptyString()][string]$IdentityFilePath, [bool]$NonInteractive)` → `string`, `'KeyAgent'` or `'InteractivePassword'`: `'KeyAgent'` when `$IdentityFilePath` is non-empty; otherwise, when `-not $NonInteractive`, `'InteractivePassword'`; when `$NonInteractive` and `$IdentityFilePath` is empty, throws naming `-Credential`-equivalent-for-SSH (an identity file) as required — mirrors `Resolve-LabWindowsCredential`'s exact never-prompt-under-NonInteractive guarantee. Pure, fully unit-testable.
  - `Invoke-LabSftpCommand([string]$HostNameOrAddress, [int]$Port, [string]$UserName, [AllowNull()][AllowEmptyString()][string]$IdentityFilePath, [string]$BatchFilePath, [string]$AuthMode)` → `[pscustomobject]@{ ExitCode = [int]; Output = [string[]] }`. **First statement, before anything else:** calls `Get-LabSshToolingInfo` (Task 1) and throws a clear message naming `ssh.exe`/`sftp.exe` as missing if `Available` is `$false` — this is the one, single integration point for that check; both `Test-LabSshConnection` and `Copy-LabTransferItemSftp` (Task 4) call into this function for every real SFTP operation, so neither needs its own separate tooling check. Then builds the `sftp.exe` argument list per the Global Constraints: `-o BatchMode=yes -o StrictHostKeyChecking=yes -P $Port -i $IdentityFilePath -b $BatchFilePath $UserName@$HostNameOrAddress` for `'KeyAgent'` (omit `-i` when `$IdentityFilePath` is empty, relying on agent/default identities); `-o StrictHostKeyChecking=yes -P $Port -b $BatchFilePath $UserName@$HostNameOrAddress` for `'InteractivePassword'` — **no `-o BatchMode=yes`, and the call must not redirect stdin/stdout/stderr**, so the operator's console is the real terminal OpenSSH prompts against. Runs via the `&` call operator (not `Start-Process`) so the console is inherited by default. Captures `$LASTEXITCODE` and whatever output streams were captured (interactive mode's prompts are NOT part of `Output` — they go straight to the real console, not through this function's return value). (Task 4's separate `ssh.exe ... sha256sum` hash-verification call does *not* go through this function and so isn't covered by this check — accepted as a minor residual gap, since `ssh.exe`/`sftp.exe` ship together in the same OpenSSH package and are overwhelmingly likely to be present or absent together.)
  - `Test-LabSshConnection(guid $VMId)` → no return value (console-reporting only, like `Test-LabTransferConnection`); requires `Get-LabSshConnectionSettings $VMId` to be non-null (else reports "not configured, use Configure SSH connection first"); calls `Assert-LabVMRunning`; builds a one-line batch file (`pwd`) in a temp location; calls `Invoke-LabSftpCommand` with `Resolve-LabSshAuthMode`'s result; reports success/failure; always deletes the temp batch file in `finally`. Not wrapped in `Invoke-LabAction` (no mutation) — same precedent as `Test-LabTransferConnection`.
  - `Update-LabSshKnownHost([string]$HostNameOrAddress, [int]$Port)`: previews what's about to be removed (names the host:port being cleared), requires `Confirm-LabText "UPDATE KNOWN HOST $HostNameOrAddress"`, then runs `ssh-keygen.exe -R "[$HostNameOrAddress]:$Port"` (or `-R $HostNameOrAddress` when `$Port` is the default `22`, matching `ssh-keygen`'s own bracket-notation convention for non-default ports) — never edits `known_hosts` directly.

- [ ] **Step 1: Write failing `Test-LabVM.ps1` cases for `Resolve-LabSshAuthMode`**

```powershell
Test-Case 'Identity file present selects KeyAgent mode' { Assert-Equal (Resolve-LabSshAuthMode 'C:\keys\id_ed25519' $false) 'KeyAgent' }
Test-Case 'No identity file, interactive allowed, selects InteractivePassword' { Assert-Equal (Resolve-LabSshAuthMode '' $false) 'InteractivePassword' }
Test-Case 'No identity file under NonInteractive throws' {
    Assert-Throws { Resolve-LabSshAuthMode '' $true } 'identity file'
}
Test-Case 'Identity file present under NonInteractive still selects KeyAgent' { Assert-Equal (Resolve-LabSshAuthMode 'C:\keys\id_ed25519' $true) 'KeyAgent' }
```

Add `'Resolve-LabSshAuthMode'` to the `$allowlist` array.

- [ ] **Step 2: Run `Test-LabVM.ps1` and confirm it fails**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL — function doesn't exist yet.

- [ ] **Step 3: Implement `Resolve-LabSshAuthMode`**

Per the Interfaces block.

- [ ] **Step 4: Run `Test-LabVM.ps1` and confirm it passes**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS on all four new cases plus everything existing.

- [ ] **Step 5: Write failing `test_static.py` cases for the other three functions**

```python
def test_sftp_command_checks_tooling_before_invoking(self):
    body = self.s.split('function Invoke-LabSftpCommand {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Get-LabSshToolingInfo', body)
    idx_check = body.index('Get-LabSshToolingInfo')
    idx_sftp = body.index('sftp.exe')
    self.assertLess(idx_check, idx_sftp)
def test_sftp_command_uses_batch_mode_for_key_auth(self):
    body = self.s.split('function Invoke-LabSftpCommand {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('BatchMode=yes', body)
    self.assertIn('StrictHostKeyChecking=yes', body)
def test_sftp_command_recognizes_interactive_password_mode(self):
    # Presence check only — this does not prove BatchMode=yes is absent from this
    # specific branch's code path at runtime, only that the branch exists at all.
    body = self.s.split('function Invoke-LabSftpCommand {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("'InteractivePassword'", body)
def test_connection_test_requires_configured_settings(self):
    body = self.s.split('function Test-LabSshConnection {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Get-LabSshConnectionSettings', body)
def test_update_known_host_requires_confirmation(self):
    body = self.s.split('function Update-LabSshKnownHost {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Confirm-LabText', body)
    self.assertIn('ssh-keygen', body)
    self.assertNotRegex(body, r'Set-Content[^\r\n]*known_hosts')
def test_sftp_command_never_uses_controlmaster(self):
    # Standing invariant, not a red/green case: this is already true on unmodified
    # code (the substring doesn't exist anywhere yet) and must *stay* true — it can
    # only ever go red if a future change reintroduces ControlMaster/ControlPath.
    self.assertNotIn('ControlMaster', self.s)
    self.assertNotIn('ControlPath', self.s)
```

- [ ] **Step 6: Run `test_static.py` and confirm it fails**

Run: `python test_static.py`
Expected: FAIL on the first five cases (`test_sftp_command_checks_tooling_before_invoking`, `test_sftp_command_uses_batch_mode_for_key_auth`, `test_sftp_command_recognizes_interactive_password_mode`, `test_connection_test_requires_configured_settings`, `test_update_known_host_requires_confirmation`) — none of those functions/branches exist yet. `test_sftp_command_never_uses_controlmaster` is a standing invariant and already passes on unmodified code; it isn't expected to go red.

- [ ] **Step 7: Implement `Invoke-LabSftpCommand`, `Test-LabSshConnection`, `Update-LabSshKnownHost`**

Per the Interfaces block.

- [ ] **Step 8: Run `test_static.py` and confirm it passes**

Run: `python test_static.py`
Expected: PASS on all cases.

- [ ] **Step 9: Update `README.md` and `MANUAL-TESTS.md`**

Document `Update-LabSshKnownHost`'s role and the connection-test behavior. State explicitly (per the issue's "Linux first connection" guidance) that the guest needs a reachable SSH **server** during a transfer — an installed SSH client alone is insufficient — and that a socket-activated SSH server (started on first incoming connection rather than running continuously) also qualifies; the connection test is exactly the minimal guest-console-setup verification the issue asks for. Also document the case where password login is disabled on the guest: explain that the operator establishes trust by adding their public key to the guest's `~/.ssh/authorized_keys` through the existing guest console (or whatever provisioning already put files there) *before* attempting a `KeyAgent`-mode connection — this manager never edits `authorized_keys` itself, on the guest or otherwise, as a side effect of any configuration or transfer action. Add a `MANUAL-TESTS.md` section: connection test against a reachable Linux guest with key auth (succeeds noninteractively), with password auth on first connection (shows the real OpenSSH host-key-trust prompt, then the real password prompt, both on the live console — confirm neither is captured/echoed by the manager's own output), against an unconfigured VM (clear "not configured" message, no connection attempt), against a guest with password login disabled and no authorized key yet (clear, actionable failure — not a hang), and a deliberately-changed host key scenario exercising `Update-LabSshKnownHost`.

- [ ] **Step 10: Commit**

```bash
git add Lab-VM.ps1 test_static.py README.md MANUAL-TESTS.md
git commit -m "feat: add SSH authentication primitives, connection test, and known-host update"
```

---

### Task 4: SFTP transfer engine

**Files:**
- Modify: `Lab-VM.ps1` (add `Copy-LabTransferItemSftp` near `Copy-LabTransferItem`)
- Modify: `test_static.py`
- Modify: `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: `Get-LabTransferConflictKind`, `Resolve-LabConflictAction` (existing, reused directly), `Invoke-LabSftpCommand` (Task 3).
- Produces:
  - `Copy-LabTransferItemSftp([string]$HostNameOrAddress, [int]$Port, [string]$UserName, [AllowNull()][AllowEmptyString()][string]$IdentityFilePath, [string]$AuthMode, [ValidateSet('ToVM','FromVM')][string]$Direction, [string]$SourcePath, [string]$DestinationPath, [bool]$Recurse, [ValidateSet('Error','Skip','Overwrite')][string]$OnConflict, [bool]$VerifyHash, [bool]$DryRun)` → the same summary shape as `Copy-LabTransferItem`: `[pscustomobject]@{ Completed; Skipped; Failed; BytesTransferred; Errors }`. Never throws for a per-item conflict/verification problem; still throws for a connection-level failure (an `Invoke-LabSftpCommand` call whose `ExitCode` indicates the connection itself failed, e.g. `255`, distinct from a per-item SFTP command error inside a successfully-connected batch).

**Design decision this task implements (binding — not left open to the implementer):**

0. **Dry run (`$DryRun`, applies to every case below):** perform the same upfront existence/type check (`ls -la`) and the same `Get-LabTransferConflictKind`/`Resolve-LabConflictAction` resolution as the real run, so a dry run reports exactly what a real run would decide per item — but never issue `put`, `get`, `rename`, `rm`, or `chmod`. An item whose resolved action is `'Proceed'`/`'Overwrite'` is counted in `Completed` (matching the Windows engine's dry-run convention — the fixed summary shape has no separate "planned" bucket) with `BytesTransferred` left at `0` (nothing moved); `'Skip'`/`'Error'` items are counted exactly as in a real run. This means every branch below still runs its upfront check unconditionally; only the payload-moving batch (the second `sftp` invocation, or the `put -r`/`get -r` line) is skipped when `$DryRun` is set.
1. **Single file:** build one batch file per attempt. First batch: `ls -la "$DestinationPath"` (or the equivalent quoting `sftp` expects for a path with spaces) to determine existence/type (parse the leading mode character: `d` = directory, `l` = symlink/reparse — reject as `Failed` per the Global Constraint, never follow; `-` = regular file; a `No such file` response in `Output` means `$DestinationExists = $false`). Call `Get-LabTransferConflictKind`/`Resolve-LabConflictAction` with the parsed result. When the resolved action is `'Error'`/`'Skip'`, return here — no `put`/`get` ever runs, matching the Windows engine's "reject before writing" guarantee. When `'Proceed'`/`'Overwrite'`: a second batch file containing `put "$SourcePath" "$DestinationPath.labxfer-<id>.tmp"` (or `get` for `FromVM`, with the temp suffix on the *local* side instead) followed by, for `'Overwrite'`, an `rm "$DestinationPath"` line, then `rename "$DestinationPath.labxfer-<id>.tmp" "$DestinationPath"` as the last line of the SAME batch invocation — `sftp`'s batch commands execute in one session, so the temp-copy and the finalize `rename` happen within the same connection, and `rename` on the same filesystem is an atomic POSIX rename. For `FromVM`, the `put`/`rename` pair is naturally `get`-then-local-`[IO.File]::Move`, mirroring `Copy-LabTransferItem`'s existing host-side finalize pattern (not a new mechanism). Verify (size always; SHA-256 when `$VerifyHash`) before trusting the transfer: size via a trailing `ls -la` in the same batch (parse the size field); hash via a **separate** `ssh.exe "$UserName@$HostNameOrAddress" "sha256sum '<path>'"` call (quoting single-quoted on the remote shell) compared against a local `Get-FileHash -Algorithm SHA256`, since `sftp`'s own batch vocabulary has no hash command — document this `sha256sum` guest dependency in `README.md`. On any verification failure, the temp artifact is removed with a dedicated cleanup batch (`rm "$DestinationPath.labxfer-<id>.tmp"`) and the item is `Failed`.
2. **Directory, destination doesn't exist (`$Recurse`, fresh case):** one batch: `put -r "$SourcePath" "$DestinationPath.labxfer-<id>.tmp"` (or `get -r` for `FromVM`, same temp-suffix placement as the single-file case) followed by `rename "$DestinationPath.labxfer-<id>.tmp" "$DestinationPath"` in the same session — one atomic rename of the whole tree once the recursive copy completes, giving the same all-or-nothing guarantee as a single file. `BytesTransferred` for directories is a best-effort sum from `sftp`'s own progress/summary output when `-o Compression` or similar makes it available; if it can't be reliably parsed, report `0` and say so in a code comment rather than fabricate a number.
3. **Directory, destination already exists:** per the Global Constraint, this is an immediate, honest failure — a single `ls -la "$DestinationPath"` upfront check (same existence probe as the single-file case) determines this before any `put -r`/`get -r` is attempted; the function returns with one `Failed` entry whose message names the limitation (e.g. `"Directory '$DestinationPath' already exists; merging into an existing directory on the Linux/SFTP adapter is not supported in this version."`) and does not touch anything.
4. Reject (as a `Failed` entry) a single-file source/destination path that resolves to a symlink per the `ls -la` leading-character check — per the issue's reparse-point exclusion requirement. **Explicitly document, not silently assume:** this task cannot verify, without a live guest, what OpenSSH's own `put -r`/`get -r` recursive copy does when it encounters a symlink *nested inside* a directory tree (follow it, skip it, or error) — add a code comment saying so at the point `put -r`/`get -r` is invoked, and add the corresponding `MANUAL-TESTS.md` live-verification step (Step 5 below) rather than guessing at the behavior.

- [ ] **Step 1: Write failing `test_static.py` cases pinning the design decision above**

```python
def test_sftp_engine_checks_conflict_before_put(self):
    body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Get-LabTransferConflictKind', body)
    idx_conflict = body.index('Get-LabTransferConflictKind')
    idx_put = body.index("'put ")
    self.assertLess(idx_conflict, idx_put)
def test_sftp_engine_uses_rename_for_finalize(self):
    body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("'rename ", body)
def test_sftp_engine_rejects_existing_directory_destination(self):
    body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('not supported in this version', body)
def test_sftp_engine_hash_verification_uses_ssh_not_sftp_batch(self):
    body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('sha256sum', body)
def test_sftp_engine_rejects_symlinks(self):
    body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("-eq 'l'", body)
def test_sftp_engine_dry_run_skips_payload_commands(self):
    body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('$DryRun', body)
```

- [ ] **Step 2: Run `test_static.py` and confirm it fails**

Run: `python test_static.py`
Expected: FAIL — `Copy-LabTransferItemSftp` doesn't exist yet.

- [ ] **Step 3: Implement `Copy-LabTransferItemSftp`**

Per the design decision above. Factor the `ls -la` output parsing (mode character, size, "No such file" detection) into one small private helper, since both the single-file and directory branches need it for their upfront existence/type check.

- [ ] **Step 4: Run `test_static.py` and confirm it passes**

Run: `python test_static.py`
Expected: PASS on all cases.

- [ ] **Step 5: Update `MANUAL-TESTS.md`**

Add a "Linux transfer engine" section: single file to-VM and from-VM round trip with `-VerifyHash`; a single-file `Overwrite`/`Skip`/`Error` collision; a fresh-directory recursive copy including an empty subdirectory and a dotfile; attempting a directory copy into an already-existing destination (must fail with the documented message, nothing written); **the specific unverified item from the design decision** — create a symlink nested inside a source directory tree before a recursive copy and observe/document what `put -r`/`get -r` actually does with it (follow, skip, or error), then update this plan's binding decision comment and `README.md`'s limitation note to match the observed behavior rather than leaving it as "unverified" once this live step has actually been walked.

- [ ] **Step 6: Commit**

```bash
git add Lab-VM.ps1 test_static.py MANUAL-TESTS.md
git commit -m "feat: add SFTP transfer engine for Linux guests"
```

---

### Task 5: Adapter selection and orchestrator generalization

**Files:**
- Modify: `Lab-VM.ps1` (add `Get-LabTransferAdapterKind`; modify `Invoke-LabFileTransfer`)
- Modify: `test_static.py`

**Interfaces:**
- Consumes: `Get-LabSshConnectionSettings` (Task 2), `Resolve-LabSshAuthMode` (Task 3), `Copy-LabTransferItemSftp` (Task 4); `Invoke-LabFileTransfer`, `Assert-LabVMRunning`, `New-LabPSDirectSession`, `Copy-LabTransferItem`, `Resolve-LabWindowsCredential` (existing, from the merged Windows plan — **do not change their behavior or signatures**).
- Produces:
  - `Get-LabTransferAdapterKind(guid $VMId)` → `string`, `'SFTP'` or `'PSDirect'`: `'SFTP'` when `Get-LabSshConnectionSettings $VMId` returns non-null; `'PSDirect'` otherwise. Pure given its one dependency's result — fully testable by faking that one call.
  - `Invoke-LabFileTransfer`'s body gains one branch point, immediately after its existing read-only check and before any adapter-specific connection work: `if ((Get-LabTransferAdapterKind $VMId) -eq 'SFTP') { <SFTP path> } else { <existing PSDirect path, byte-for-byte unchanged> }`. The SFTP path resolves `$sshSettings = Get-LabSshConnectionSettings $VMId`, `$authMode = Resolve-LabSshAuthMode $sshSettings.IdentityFilePath $NonInteractive`, and calls `Copy-LabTransferItemSftp` with the resolved connection details plus every parameter `Invoke-LabFileTransfer` already receives (`$Direction`/`$SourcePath`/`$DestinationPath`/`$Recurse`/`$OnConflict`/`$VerifyHash`/`$DryRun`). The function's own `-Credential $Credential` parameter is accepted but genuinely unused on this branch — SFTP authentication never uses a `PSCredential` object. The existing `finally` block's session-close (`Remove-PSSession`) only applies to the PSDirect branch (no session object exists on the SFTP branch to close) and the audit-writing `finally` logic is adapter-agnostic already (it only reads the returned summary's counts, not anything adapter-specific) — confirm this by reading the current `Invoke-LabFileTransfer` body before editing it, rather than assuming.

- [ ] **Step 1: Write failing `Test-LabVM.ps1` case for `Get-LabTransferAdapterKind`**

```powershell
Test-Case 'Configured SSH settings select the SFTP adapter' {
    # faked via a scriptblock override of Get-LabSshConnectionSettings in this test file, following the existing fake-cmdlet pattern
}
```

(Write the actual fake using whichever override mechanism `Test-LabVM.ps1`'s existing Task 3/4-era fakes already use for a single-dependency pure wrapper — follow that established pattern rather than inventing a new one.)

Add `'Get-LabTransferAdapterKind'` to the `$allowlist` array.

- [ ] **Step 2: Run `Test-LabVM.ps1` and confirm it fails**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL — function doesn't exist yet.

- [ ] **Step 3: Implement `Get-LabTransferAdapterKind`**

Per the Interfaces block.

- [ ] **Step 4: Run `Test-LabVM.ps1` and confirm it passes**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS.

- [ ] **Step 5: Write failing `test_static.py` cases for the `Invoke-LabFileTransfer` branch**

```python
def test_orchestrator_branches_on_adapter_kind(self):
    body = self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Get-LabTransferAdapterKind', body)
    self.assertIn("'SFTP'", body)
    self.assertIn('Copy-LabTransferItemSftp', body)
def test_orchestrator_still_calls_psdirect_path(self):
    body = self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('New-LabPSDirectSession', body)
    # Trailing space distinguishes the real call from the substring "Copy-LabTransferItemSftp",
    # which also contains the literal text "Copy-LabTransferItem" and would otherwise false-pass this check.
    self.assertIn('Copy-LabTransferItem ', body)
```

- [ ] **Step 6: Run `test_static.py` and confirm it fails**

Run: `python test_static.py`
Expected: FAIL on both new cases.

- [ ] **Step 7: Modify `Invoke-LabFileTransfer`**

Read its current full body first. Insert the branch per the Interfaces block; move the existing PSDirect-specific lines into the `else` arm unchanged (do not reformat or "clean up" anything in that arm beyond the indentation the branch requires).

- [ ] **Step 8: Run both `Test-LabVM.ps1` and `test_static.py` and confirm everything passes**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` then `python test_static.py`
Expected: PASS on every case, including every pre-existing Windows-adapter case — this step is also your regression check that the Windows adapter's behavior is unchanged.

- [ ] **Step 9: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1 test_static.py
git commit -m "feat: add SFTP adapter selection to the transfer orchestrator"
```

---

### Task 6: Menu and CLI wiring for SSH configuration

**Files:**
- Modify: `Lab-VM.ps1` (add `Configure-LabSshConnectionInteractive`; modify `Show-LabVMMenu`'s `T` entry; modify the top `param()` block and invocation gate)
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: `Set-LabSshConnectionSettings`, `Get-LabSshConnectionSettings`, `Get-LabGuestAddressCandidates` (Task 2); `Test-LabSshConnection` (Task 3); `Resolve-LabVMByNameOrId` (existing).
- Produces:
  - `Configure-LabSshConnectionInteractive(guid $VMId)` → no return value; shows `Get-LabGuestAddressCandidates $VMId` as suggestions (never auto-selected — the operator must type or explicitly pick one), prompts for hostname/address (blank re-prompts, doesn't default to a suggestion silently), port (default `22`), username, and an optional identity-file path (blank means password auth); shows a preview and requires a lightweight confirmation (`Read-LabYesNoCancel`, not a full `Confirm-LabText` phrase — this only writes a local, non-secret settings file, not a destination mutation); calls `Set-LabSshConnectionSettings`.
  - `Show-LabVMMenu`'s existing `T` entry (`Test-LabTransferConnection`) becomes adapter-aware: when `Get-LabTransferAdapterKind $VMId` is `'SFTP'`, call `Test-LabSshConnection $VMId` instead; when `'PSDirect'`, call the existing `Test-LabTransferConnection $VMId` unchanged. A new menu entry `C  Configure SSH connection for this VM` (not gated by `-ReadOnly` — it only writes local, non-secret settings, no VM mutation, same precedent class as `T`) calls `Configure-LabSshConnectionInteractive $VMId`.
  - The top `param()` block gains `[switch]$ConfigureSsh`, `[string]$SshHost`, `[int]$SshPort = 22`, `[string]$SshUser`, `[string]$SshIdentityFile` for a scriptable one-time setup path; the invocation gate gains a branch (parallel to the existing `$CopyToVM`/`$CopyFromVM` branch, checked before it) that, when `$ConfigureSsh` is set, validates exactly one of `-VMName`/`-VMId` plus `-SshHost`/`-SshUser` are supplied, resolves the VM, calls `Set-LabSshConnectionSettings` directly (no interactive prompts — this is the scriptable path, `Configure-LabSshConnectionInteractive` is the menu's own interactive path, not reused here), and exits `0` on success.

- [ ] **Step 1: Implement `Configure-LabSshConnectionInteractive`**

Not independently unit-testable (interactive) — no RED/GREEN cycle for this step; Task 2's tests already cover the logic it calls into. Follow the existing prompt/preview/confirm style used by `New-LabVM`/`Edit-LabVMSettings`/`Copy-LabVMItemInteractive`.

- [ ] **Step 2: Wire `C` and adapter-aware `T` into `Show-LabVMMenu`**

Per the Interfaces block. Add `C` to both the read-only and normal menu text blocks (same reasoning as `T`'s existing both-blocks placement: no mutation, safe under `-ReadOnly`).

- [ ] **Step 3: Write and run the `test_static.py` case for Step 2**

```python
def test_menu_t_entry_is_adapter_aware(self):
    body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Get-LabTransferAdapterKind', body)
    self.assertIn('Test-LabSshConnection', body)
def test_configure_ssh_menu_entry_exists(self):
    body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("'C'", body)
    self.assertIn('Configure-LabSshConnectionInteractive', body)
```

Run: `python test_static.py` — expect FAIL before Step 2, PASS after.

- [ ] **Step 4: Add the `-ConfigureSsh` parameters and invocation-gate branch**

Per the Interfaces block. Place the new branch's check before the existing `-CopyToVM`/`-CopyFromVM` mutual-exclusivity check in the gate, and make sure `-ConfigureSsh` together with `-CopyToVM`/`-CopyFromVM` is rejected as an invalid combination (one action per invocation).

- [ ] **Step 5: Write and run the `test_static.py` cases for Step 4**

```python
def test_configure_ssh_cli_params_exist(self):
    body = self.s.split('param(', 1)[1].split(')\n\n', 1)[0]
    for p in ['$ConfigureSsh', '$SshHost', '$SshPort', '$SshUser', '$SshIdentityFile']:
        self.assertIn(p, body)
def test_configure_ssh_does_not_prompt(self):
    body = self.s.rsplit("if ($MyInvocation.InvocationName -ne '.')", 1)[1]
    self.assertIn('ConfigureSsh', body)
```

- [ ] **Step 6: Update `README.md` and `MANUAL-TESTS.md`**

Document the `C` menu entry, the adapter-aware `T` behavior, and the `-ConfigureSsh`/`-SshHost`/`-SshPort`/`-SshUser`/`-SshIdentityFile` CLI parameters. Add a `MANUAL-TESTS.md` section: configuring a Linux VM's connection via the menu with an address suggested from `Get-LabGuestAddressCandidates`, then successfully transferring a file; configuring via the CLI `-ConfigureSsh` path and confirming a subsequent `-CopyToVM` picks up the SFTP adapter automatically; confirming a Windows VM with no SSH settings configured still uses PowerShell Direct exactly as before (the explicit regression check for the Global Constraint that this plan must not change existing behavior).

- [ ] **Step 7: Commit**

```bash
git add Lab-VM.ps1 test_static.py README.md MANUAL-TESTS.md
git commit -m "feat: add SSH connection configuration menu and CLI surface"
```

---

### Task 7: Private-file permission profile for Linux (chmod)

**Files:**
- Modify: `Lab-VM.ps1` (extend `Copy-LabTransferItemSftp`'s finalize step and signature)
- Modify: `test_static.py`
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: the finalize step inside `Copy-LabTransferItemSftp` (Task 4); `Invoke-LabFileTransfer`'s existing `$PermissionProfile` parameter (already threaded through from the merged Windows plan's Task 7 — **this task only extends what that parameter does on the SFTP branch, it does not re-add the parameter anywhere**).
- Produces:
  - `Copy-LabTransferItemSftp` gains `[ValidateSet('Default','PrivateFiles')][string]$PermissionProfile = 'Default'`.
  - When `$PermissionProfile -eq 'PrivateFiles'`, the finalize batch gains one trailing `chmod 600 "$DestinationPath"` line (single-file path) appended **after** the `rename` line in the same batch invocation — `sftp`'s native `chmod` command, no external tool needed. A `chmod` failure (nonzero exit, or an error line in `Invoke-LabSftpCommand`'s `Output`) demotes that item's result to `Failed` even though the byte copy itself succeeded, matching the issue's "a successful byte copy with failed final permission setup is a failed/partial result" requirement and the Windows adapter's identical rule from its own Task 7.
  - **Binding scope decision for directories, stated here because Task 4 deliberately does not build a per-file enumeration for the fresh-directory case (the same reasoning that ruled out fragile tree-parsing for directory-merge in Task 4 applies here too):** for a fresh-directory copy (`$Recurse`) with `PrivateFiles`, only the newly-created destination directory *root* gets `chmod 700` (one line, appended after the directory's `rename`) — individual files inside a recursive `put -r`/`get -r` copy are **not** chmod'd individually in this version; they retain whatever mode the guest's SFTP server assigns on creation (typically governed by the guest account's umask). This is a documented, disclosed limitation (see Step 5), not a silent gap — `PrivateFiles` on a non-recursive, single-file transfer still gets the full per-file `0600` guarantee the issue asks for; `PrivateFiles` combined with `-Recurse` only restricts the directory root itself. A future version could add a verified, tested enumeration pass to chmod every file individually, but this plan does not attempt one without a live guest to validate the enumeration approach against.
  - `Invoke-LabFileTransfer`'s SFTP branch (Task 5) forwards its existing `$PermissionProfile` parameter to `Copy-LabTransferItemSftp` (one line — the parameter already exists on `Invoke-LabFileTransfer` from the merged Windows plan, this task just stops dropping it on the floor for the SFTP branch).

- [ ] **Step 1: Write failing `test_static.py` cases**

```python
def test_sftp_engine_private_profile_param_exists(self):
    body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("'PrivateFiles'", body)
def test_sftp_chmod_after_rename_not_before(self):
    body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
    idx_rename = body.index("'rename ")
    idx_chmod = body.index("chmod")
    self.assertLess(idx_rename, idx_chmod)
def test_sftp_branch_forwards_permission_profile(self):
    body = self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('Copy-LabTransferItemSftp', body)
    # the forwarding call site must reference $PermissionProfile
    sftp_call_start = body.index('Copy-LabTransferItemSftp')
    sftp_call_region = body[sftp_call_start:sftp_call_start + 400]
    self.assertIn('$PermissionProfile', sftp_call_region)
```

- [ ] **Step 2: Run `test_static.py` and confirm it fails**

Run: `python test_static.py`
Expected: FAIL on all three new cases.

- [ ] **Step 3: Implement the `chmod` hook and the forwarding edit**

Per the Interfaces block.

- [ ] **Step 4: Run `test_static.py` and confirm it passes**

Run: `python test_static.py`
Expected: PASS on all cases.

- [ ] **Step 5: Update `README.md` and `MANUAL-TESTS.md`**

Document the Linux `chmod 0600`/`0700` behavior for `-PermissionProfile PrivateFiles`, alongside the already-documented Windows ACL behavior (note that, unlike the Windows adapter, this task applies `chmod` within the same batch as the finalize `rename`, so there's a smaller — though still nonzero, same caveat as the Windows adapter's own documented limitation — window between data landing and permissions tightening). **Document the directory-contents limitation explicitly and prominently:** `PrivateFiles` combined with `-Recurse` only chmods the newly-created destination directory *root* to `700` — individual files inside that recursive copy are not chmod'd and retain the guest's default/umask permissions; operators who need a guaranteed `0600` on a specific private file (the issue's own key-file scenario) should transfer that file individually rather than as part of a directory copy. Add a `MANUAL-TESTS.md` step: copy a synthetic private key individually (not as part of a directory) to a Linux guest with `PrivateFiles`, then verify via a direct guest-console check (`ls -la`) that its mode is `600`; separately, copy a small directory with `PrivateFiles` and `-Recurse` and confirm the root is `700` while a file inside it is NOT guaranteed any particular mode (documenting whatever the guest's actual umask produced, so the limitation note above is verified against real behavior rather than assumed); confirm an unrelated pre-existing sibling file's permissions are untouched in both cases.

- [ ] **Step 6: Commit**

```bash
git add Lab-VM.ps1 test_static.py README.md MANUAL-TESTS.md
git commit -m "feat: add Linux private-file permission profile (chmod)"
```

---

### Task 8: `.ssh`/key-role documentation, bounded Copy-VMFile design note, and final regression

**Files:**
- Modify: `Lab-VM.ps1` (comment-based help)
- Modify: `test_static.py` (`test_all_named_operations_exist`)
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1-7.
- Produces: no new functions.

- [ ] **Step 1: Add the new interactive-entry-point names to `test_all_named_operations_exist`**

Add `'Configure-LabSshConnectionInteractive'` (the pure/engine helpers — `Copy-LabTransferItemSftp`, `Invoke-LabSftpCommand`, etc. — stay excluded from this particular check, matching the established convention for `*Core`/engine functions).

- [ ] **Step 2: Write the `.ssh`/key-role documentation in `README.md`**

Per the issue's "Linux first connection and key roles" subsection: distinguish, in plain language, **host-authenticating-to-guest** (the host holds a private key; the guest's `authorized_keys` must already authorize the matching public key — this manager never edits `authorized_keys` as a side effect of a configuration or transfer action) from **guest-authenticating-outward** (a private/public key pair copied *into* the guest via an ordinary file transfer, for the guest's own later use connecting out to somewhere else, e.g. GitHub — copying such a key file is just a regular transfer, governed by the same conflict policy as any other file, and does not grant any new inbound login). State explicitly that copying a complete `.ssh` directory is "just" a directory transfer under the same rules as any other directory — existing `authorized_keys`/`config`/`known_hosts` inside it collide under the operator's chosen `-OnConflict` policy like any other file, with no special-cased merging or enrollment logic anywhere in this plan.

- [ ] **Step 3: Write the bounded `Copy-VMFile` design note in `README.md`**

Per the issue's section E: a short, clearly-labeled "future work" note (not implemented functionality) describing the one-way, host-to-guest-only bootstrap option built on Hyper-V's Guest Service Interface and `Copy-VMFile`, that it cannot replace SFTP for this plan's bidirectional requirement, that actual guest support (not just the OS name) would need to be probed at runtime rather than assumed, and that it remains unimplemented in this version.

- [ ] **Step 4: Run the complete test suite**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` then `python test_static.py`
Expected: PASS — every case from Tasks 1-7 plus everything that existed before this plan (including every Windows-adapter case from the merged Windows plan — the final regression check that nothing in that adapter was disturbed).

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py README.md
git commit -m "docs: add SSH key-role documentation, Copy-VMFile design note, and final regression"
```

---

## Out of Scope (genuinely out of scope per the issue, or explicitly deferred by this plan's own binding decisions)

Directory-merge-into-an-already-existing-destination on the Linux/SFTP adapter (Task 4's binding decision — a future version could add this with a verified, tested tree-diff approach, but not blindly here). The `Copy-VMFile` one-way bootstrap implementation itself (Task 8 documents the design only, per the issue's own "not required for the first implementation"). Full Windows Subiquity/cloud-init-style unattended provisioning (issue #2's territory, unrelated to this plan). Downloading/installing any SSH tooling — this plan only drives what's already bundled with Windows and fails clearly if it's unavailable, never silently fetches a replacement. Changing guest-side SSH server configuration (enabling password auth, installing `sshd`, opening firewall ports) — explicitly the operator's own responsibility, per the issue's own "do not enable password authentication on the guest automatically."
