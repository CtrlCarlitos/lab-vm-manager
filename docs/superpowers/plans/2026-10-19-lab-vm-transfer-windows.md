# LAB VM File Transfer — Windows (PowerShell Direct) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add bidirectional file/directory copy between the host and a **Windows** `LAB-*` guest via PowerShell Direct — menu UI, a parameter-mode CLI surface, and the shared copy contract (exact-destination semantics, conflict policy, bounded-memory transfer, optional hash verification, optional private-file permissions) that a follow-up plan will extend with a Linux/SFTP adapter.

**Architecture:** A pure contract layer (conflict-kind detection + conflict-policy resolution, fully unit-testable) sits underneath one transfer engine (`Copy-LabTransferItem`) that both the interactive menu and the parameter-mode CLI call through a shared orchestrator (`Invoke-LabFileTransfer`). The engine copies to a temporary sibling (file or directory) via `Copy-Item -LiteralPath ... -ToSession/-FromSession` (PowerShell's own chunked remoting transport — no custom chunking needed), verifies, then finalizes into the real destination honoring the per-item conflict policy, so a crash mid-transfer never leaves a half-written file at the real destination path. No guest-OS detection is attempted: this plan only knows how to drive PowerShell Direct, and reports a clear "not yet supported" error for any guest it can't reach that way (see Out of Scope) rather than guessing an OS from the VM name.

**Tech Stack:** Windows PowerShell 5.1, Hyper-V PowerShell Direct (`New-PSSession -VMId`, `Copy-Item -ToSession`/`-FromSession`, `Invoke-Command -Session`), `Get-FileHash -Algorithm SHA256`, Windows ACL cmdlets (`Get-Acl`/`Set-Acl`, or `icacls.exe`) for the private-file permission profile, existing `Test-LabVM.ps1`/`test_static.py` harnesses.

**Spec:** GitHub issue #3 — "feat: bidirectional file and directory copy between host and Windows/Linux lab VMs" (https://github.com/CtrlCarlitos/lab-vm-manager/issues/3). This plan implements the Windows/PowerShell-Direct half plus all adapter-agnostic scaffolding (sections A, C, D of the issue, scoped to Windows); the Linux/SFTP adapter (section B's Linux row, and section E) is explicitly **out of scope** here and is a separate follow-up plan.

## Global Constraints

- Windows PowerShell 5.1 (Desktop edition) only; no new third-party dependencies. `Copy-Item -ToSession`/`-FromSession` and `New-PSSession -VMId` are built into the Hyper-V/remoting modules already in use.
- Every filesystem cmdlet touching a transfer path — on the host or inside a guest-side `Invoke-Command`/`Copy-Item` call — uses `-LiteralPath`, never `-Path`, and never `Invoke-Expression` or a string handed to `cmd.exe`/`sh`. Paths are literal data; this plan does not add any new wildcard-matching surface.
- `DestinationPath` always names the resulting file or directory root, regardless of whether it already exists — never append the source's basename onto an existing destination directory.
- A type mismatch (file source vs. existing directory destination, or the reverse) always fails, regardless of `-OnConflict`. `-OnConflict`'s `Error`/`Skip`/`Overwrite` only governs a same-type collision (both files, or the directory-merge case).
- The VM must be `Running` for any transfer (new `Assert-LabVMRunning`, mirroring the existing `Assert-LabVMOff`); every operation re-resolves the VM by GUID and rechecks the `LAB-` prefix immediately before acting, exactly like every existing mutation.
- `-ReadOnly` allows `Test-LabTransferConnection` and a `-DryRun` plan, but blocks every real copy in either direction. Ordinary audit logging (`session` and the dry-run's own record) remains allowed even under `-ReadOnly`.
- `-NonInteractive` never falls into an interactive credential prompt. If no usable credential is available, fail immediately with an actionable message — never silently proceed with default/cached credentials either.
- A `PSCredential` is never written to process arguments, environment variables, temporary files, connection settings, or audit logs. Audit records capture direction, paths, counts, conflict policy, permission profile, and verification level — never credential material or file contents.
- Both the menu and parameter-mode call the same engine (`Invoke-LabFileTransfer`); no duplicated transfer logic between the two entry points.
- The existing per-VM mutex (via `Invoke-LabAction`) is held for the entire transfer, same as every other mutating menu option. The `-AllowReadOnly` switch this plan adds to `Invoke-LabAction` (Task 4) must not change behavior for any of the 12 existing call sites that don't pass it.
- Bounded memory: all payload bytes move through `Copy-Item -ToSession`/`-FromSession`'s own chunked transport. Nothing in this plan reads a whole file into a PowerShell variable to relay it manually (e.g. no `Get-Content -Raw` on a multi-gigabyte file).

## Review Focus

- A large file transferred with `-VerifyHash` must actually exercise the chunked transport and produce a correct SHA-256 match on both ends, not just pass because a small fixture happened to work. Covered in Task 3's live-adjacent test plus a `MANUAL-TESTS.md` large-file round-trip step.
- Copying the same directory to the same target twice must not create nested duplication (`dest\dest\...`) on the second run, and must apply `-OnConflict` per colliding file inside it, not fail/succeed as a single all-or-nothing unit. Covered in Task 3.
- `-NonInteractive` with no `-Credential` supplied must fail with a clear message and never prompt. Covered in Task 2 (`Resolve-LabWindowsCredential`) and a `test_static.py` source-contract check in Task 6.
- A destination that's a directory where the source is a single file (or vice versa) must fail before any bytes move, in both the menu path and parameter mode, since both call the same engine. Covered in Task 1 (`Get-LabTransferConflictKind`/`Resolve-LabConflictAction`) and exercised again in Task 3's directory-merge tests.
- A connection or disk failure partway through a directory copy must report honest completed/skipped/failed counts (never a false "all succeeded"), and must close the PSSession and release the mutex regardless of outcome. Covered in Task 3 (engine-level `finally`) and Task 4 (orchestrator-level `finally`).

---

## File Structure

All changes land in the existing single-file script and its existing test/doc files, matching the project's established convention (no module split):

- Modify: `Lab-VM.ps1` — new functions grouped near related existing ones (contract helpers near the top with the other pure validators; `Assert-LabVMRunning` near `Assert-LabVMOff`; the transfer engine and orchestrator as a new cohesive block before `Invoke-LabAction`; menu wiring in `Select-LabVM`'s companion `Show-LabVMMenu`; parameter-mode wiring in the top `param()` block and the bottom invocation gate).
- Modify: `Test-LabVM.ps1` — allowlist additions and `Test-Case` blocks for the pure contract helpers.
- Modify: `test_static.py` — source-contract checks for the safety properties above.
- Modify: `README.md` — document the two new menu entries and the parameter-mode CLI surface.
- Modify: `MANUAL-TESTS.md` — live acceptance sections for Windows-guest transfer.

---

### Task 1: Pure transfer-contract helpers

**Files:**
- Modify: `Lab-VM.ps1` (add functions near the existing pure validators, after `Test-LabMemorySpec`)
- Modify: `Test-LabVM.ps1`

**Interfaces:**
- Produces:
  - `Get-LabTransferConflictKind(bool $SourceIsDirectory, bool $DestinationExists, bool $DestinationIsDirectory)` → `string`: `'None'` when `$DestinationExists` is `$false`; `'TypeMismatch'` when `$DestinationExists` is `$true` and `$SourceIsDirectory -ne $DestinationIsDirectory`; `'Exists'` when `$DestinationExists` is `$true` and the types match (same-type collision).
  - `Resolve-LabConflictAction(string $ConflictKind, string $OnConflict)` → `string`, one of `'Proceed'`/`'Skip'`/`'Overwrite'`/`'Error'`: `'TypeMismatch'` always maps to `'Error'` regardless of `$OnConflict`; `'None'` always maps to `'Proceed'`; `'Exists'` maps directly from `$OnConflict` (`'Error'`→`'Error'`, `'Skip'`→`'Skip'`, `'Overwrite'`→`'Overwrite'`).

- [ ] **Step 1: Write failing `Test-LabVM.ps1` cases**

```powershell
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
```

Add `'Get-LabTransferConflictKind', 'Resolve-LabConflictAction'` to the `$allowlist` array.

- [ ] **Step 2: Run `Test-LabVM.ps1` and confirm the new cases fail**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: FAIL — "Expected one definition of Get-LabTransferConflictKind."

- [ ] **Step 3: Implement both functions**

Pure `if`/`switch` logic per the Interfaces block above — the signatures and test cases fully determine the bodies.

- [ ] **Step 4: Run `Test-LabVM.ps1` and confirm all cases pass**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1`
Expected: PASS — all cases including the 12 new ones.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 Test-LabVM.ps1
git commit -m "feat: add pure transfer-conflict contract helpers"
```

---

### Task 2: Running-state guard, Windows credential/session primitives, and connection test

**Files:**
- Modify: `Lab-VM.ps1` (add functions near `Assert-LabVMOff`; add a new `Show-LabVMMenu` entry)
- Modify: `test_static.py`
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: `Get-LabVM` (existing).
- Produces:
  - `Assert-LabVMRunning(guid $VMId)` → the VM object if `[string]$vm.State -eq 'Running'`; otherwise throws `"'$($vm.Name)' is $($vm.State). This operation requires Running. Start it first."` — exact mirror of `Assert-LabVMOff`'s shape and message style.
  - `Resolve-LabWindowsCredential([AllowNull()][PSCredential]$Credential, [bool]$NonInteractive)` → `PSCredential`: returns `$Credential` unchanged if supplied; otherwise, when `-not $NonInteractive`, prompts via `Get-Credential -Message 'Guest Windows credentials for PowerShell Direct'` and throws if the operator cancels (`Get-Credential` returns `$null`); when `$NonInteractive`, throws immediately with a message naming `-Credential` as required — never prompts.
  - `New-LabPSDirectSession(guid $VMId, [PSCredential]$Credential)` → `[System.Management.Automation.Runspaces.PSSession]`: calls `Assert-LabVMRunning $VMId` first, then `New-PSSession -VMId $VMId -Credential $Credential -ErrorAction Stop`. Caller is responsible for closing it (`Remove-PSSession`) in a `finally` block — this function does not close it.
  - `Test-LabTransferConnection(guid $VMId)` → no return value (console-reporting only, like `Show-LabVMDetails`); prompts for credentials via `Resolve-LabWindowsCredential $null $false`, opens a session via `New-LabPSDirectSession`, runs `Invoke-Command -Session $session { [Environment]::OSVersion.VersionString }` to prove round-trip execution, reports success with the returned guest OS version string, closes the session in `finally` regardless of outcome, and reports a clear failure message (not a raw stack trace) on any exception.

- [ ] **Step 1: Write the failing `test_static.py` cases**

```python
def test_assert_vm_running_exists(self):
    self.assertIn('function Assert-LabVMRunning', self.s)
    body = self.s.split('function Assert-LabVMRunning {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("-ne 'Running'", body)
def test_resolve_windows_credential_noninteractive_never_prompts(self):
    body = self.s.split('function Resolve-LabWindowsCredential {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('$NonInteractive', body)
    self.assertNotRegex(body, r'if\s*\(\s*\$NonInteractive\s*\)\s*\{\s*Get-Credential')
def test_psdirect_session_uses_vmid(self):
    body = self.s.split('function New-LabPSDirectSession {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('New-PSSession -VMId', body)
def test_connection_test_closes_session_in_finally(self):
    body = self.s.split('function Test-LabTransferConnection {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('finally', body)
    self.assertIn('Remove-PSSession', body)
```

- [ ] **Step 2: Run `test_static.py` and confirm it fails**

Run: `python test_static.py`
Expected: FAIL on all four new cases.

- [ ] **Step 3: Implement the four functions**

Per the Interfaces block. For `Test-LabTransferConnection`, structure the body as `try { ... } catch { Write-Warning "Connection test failed: $($_.Exception.Message)" } finally { if ($session) { Remove-PSSession $session } }`, matching the file's existing try/catch/finally idiom (see `Invoke-LabAction`).

- [ ] **Step 4: Run `test_static.py` and confirm it passes**

Run: `python test_static.py`
Expected: PASS on all cases.

- [ ] **Step 5: Wire `Test-LabTransferConnection` into `Show-LabVMMenu`**

Add a menu entry (not gated by `-ReadOnly`, not wrapped in `Invoke-LabAction` — it performs no mutation, same precedent as the existing `Inspect VM` option) calling `Test-LabTransferConnection $VMId` directly. Place it in both the read-only and normal menu text blocks, since it's safe either way.

- [ ] **Step 6: Update `README.md` and `MANUAL-TESTS.md`**

Document the new menu entry. Add a `MANUAL-TESTS.md` section: connection test against a Running Windows guest with correct credentials (succeeds, reports guest OS version), against a wrong password (fails with a clear message, no stack trace), and against an Off VM (fails with the `Assert-LabVMRunning` message, no session attempt).

- [ ] **Step 7: Commit**

```bash
git add Lab-VM.ps1 test_static.py README.md MANUAL-TESTS.md
git commit -m "feat: add PowerShell Direct connection primitives and connection test"
```

---

### Task 3: Core transfer engine

**Files:**
- Modify: `Lab-VM.ps1` (add `Copy-LabTransferItem` as a new block before `Invoke-LabAction`)
- Modify: `test_static.py`
- Modify: `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: `Get-LabTransferConflictKind`, `Resolve-LabConflictAction` (Task 1).
- Produces:
  - `Copy-LabTransferItem([System.Management.Automation.Runspaces.PSSession]$Session, [ValidateSet('ToVM','FromVM')][string]$Direction, [string]$SourcePath, [string]$DestinationPath, [bool]$Recurse, [ValidateSet('Error','Skip','Overwrite')][string]$OnConflict, [bool]$VerifyHash, [bool]$DryRun)` → `[pscustomobject]@{ Completed = [int]; Skipped = [int]; Failed = [int]; BytesTransferred = [long]; Errors = [string[]] }`. Never throws for a per-item conflict/verification problem (those become `Failed`/`Skipped` entries in the summary); still throws for a connection-level failure (session unusable) since that aborts the whole operation.

**Design decision this task implements (binding — not left open to the implementer):**

1. **Single file:** FIRST, cheaply check the real destination — determine `$DestinationExists`/`$DestinationIsDirectory` (guest-side via `Invoke-Command -Session $Session { Test-Path -LiteralPath $using:DestinationPath }`/`(Get-Item ...).PSIsContainer`, host-side locally), call `Get-LabTransferConflictKind`/`Resolve-LabConflictAction`. When the resolved action is `'Error'` or `'Skip'`, stop here — no `Copy-Item` call, zero bytes moved — and record a `Failed`/`Skipped` entry naming the path (this is what "rejects known regular-file collisions before writes" means: a doomed-or-declined item never touches the transport). Only when the action is `'Proceed'` or `'Overwrite'` does any payload move: copy to a temporary sibling name at the destination (`"$DestinationPath.labxfer-$([guid]::NewGuid().ToString('N').Substring(0,8)).tmp"`) via `Copy-Item -LiteralPath $SourcePath -ToSession/-FromSession $Session -Destination $tempPath -Force` (omit entirely when `$DryRun` — a dry run never calls `Copy-Item`, it only reports what action each item would resolve to). Verify the temp file's size (and SHA-256 via `Get-FileHash` when `$VerifyHash`) on the destination side. On success, finalize: for `'Overwrite'`, remove the existing real destination first (guest-side via `Invoke-Command`, host-side via `Remove-Item -LiteralPath`); then `Move-Item -LiteralPath $tempPath -Destination $DestinationPath -Force` (guest-side via `Invoke-Command` for `ToVM`), count as `Completed`. On any failure between the temp copy and the finalize move, remove the temp artifact and count as `Failed` — never leave a `.labxfer-*.tmp` file mistaken for a real one, and never leave the real destination partially written (the real destination is only ever touched by the single, already-verified `Move-Item`/`Remove-Item`+`Move-Item` pair).
2. **Directory (`$Recurse`):** enumerate the source tree first (guest-side via `Invoke-Command { Get-ChildItem -LiteralPath $using:SourcePath -Recurse }` for `FromVM`, host-side `Get-ChildItem -Recurse` for `ToVM`'s source) and, for every item, compute its path relative to the source root and resolve the conflict against that same relative path under the real `$DestinationPath` using the same upfront check as the single-file case — before copying anything. Items resolving to `'Error'`/`'Skip'` are recorded and excluded from the payload copy entirely. For the remaining items (`'Proceed'`/`'Overwrite'`), copy the whole tree into a temporary sibling *directory* (`Copy-Item -LiteralPath $SourcePath -ToSession/-FromSession $Session -Destination $tempDir -Recurse -Force` — copying the full tree in one call is still simpler and faster than per-item remoting calls, even though some of its contents will be discarded), then finalize only the items that passed the upfront check: move each from its path under `$tempDir` to its real destination path (creating intermediate directories as needed), removing an existing real destination first when the action is `'Overwrite'`. Remove the entire temp directory tree at the end regardless of outcome, including the discarded excluded items it still contains.
3. Reject (as a `Failed` entry, never silently, and excluded from the payload copy just like an `'Error'`-resolved conflict) any enumerated source item that `Invoke-Command`/`Get-Item` reports as a symlink, junction, or reparse point (`$item.LinkType` non-null, or `Attributes -band [IO.FileAttributes]::ReparsePoint`) — per the issue spec, v1 guarantees regular files and plain directory trees only.

- [ ] **Step 1: Write failing `test_static.py` cases pinning the design decision above**

```python
def test_transfer_engine_uses_temp_sibling(self):
    body = self.s.split('function Copy-LabTransferItem {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('.labxfer-', body)
def test_transfer_engine_literal_path_only(self):
    body = self.s.split('function Copy-LabTransferItem {', 1)[1].split('\nfunction ', 1)[0]
    self.assertNotRegex(body, r'-ToSession[^\r\n]*-Path ')
    self.assertNotRegex(body, r'-FromSession[^\r\n]*-Path ')
def test_transfer_engine_rejects_reparse_points(self):
    body = self.s.split('function Copy-LabTransferItem {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('ReparsePoint', body)
def test_transfer_engine_dry_run_skips_copy_item(self):
    body = self.s.split('function Copy-LabTransferItem {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('$DryRun', body)
def test_transfer_engine_returns_summary_shape(self):
    body = self.s.split('function Copy-LabTransferItem {', 1)[1].split('\nfunction ', 1)[0]
    for field in ['Completed', 'Skipped', 'Failed', 'BytesTransferred', 'Errors']:
        self.assertIn(field, body)
```

- [ ] **Step 2: Run `test_static.py` and confirm it fails**

Run: `python test_static.py`
Expected: FAIL — `Copy-LabTransferItem` doesn't exist yet.

- [ ] **Step 3: Implement `Copy-LabTransferItem`**

Per the design decision above. This is the single largest function in this plan; keep the single-file and directory branches as clearly separated code blocks (an `if ($Recurse) { ... } else { ... }` at the top, not interleaved), and factor the per-item finalize logic (steps: resolve conflict kind → resolve action → act) into a small private helper used by both branches so the directory branch doesn't duplicate the single-file branch's finalize logic.

- [ ] **Step 4: Run `test_static.py` and confirm it passes**

Run: `python test_static.py`
Expected: PASS on all cases.

- [ ] **Step 5: Update `MANUAL-TESTS.md`**

Add a "Transfer engine" section: single file to-VM and from-VM round trip with `-VerifyHash` on a multi-hundred-MB file (exercises bounded-memory transport, per Review Focus); a directory with a nested conflict (one colliding file, rest new) under each of `Error`/`Skip`/`Overwrite`; running the same directory copy twice back-to-back and confirming no `dest\dest` nesting; a reparse point/symlink inside a source directory being reported as a failed item rather than silently skipped or followed.

- [ ] **Step 6: Commit**

```bash
git add Lab-VM.ps1 test_static.py MANUAL-TESTS.md
git commit -m "feat: add core file-transfer engine with temp-sibling finalize"
```

---

### Task 4: Orchestrator and `Invoke-LabAction`'s read-only-aware dry-run path

**Files:**
- Modify: `Lab-VM.ps1` (add `Invoke-LabFileTransfer`; modify `Invoke-LabAction`'s signature and read-only check, around its existing definition)
- Modify: `test_static.py`

**Interfaces:**
- Consumes: `Assert-LabVMRunning`, `Resolve-LabWindowsCredential`, `New-LabPSDirectSession`, `Copy-LabTransferItem` (Tasks 2-3); `Get-LabVM`, `Write-LabAudit` (existing).
- Produces:
  - `Invoke-LabFileTransfer(guid $VMId, [ValidateSet('ToVM','FromVM')][string]$Direction, [string]$SourcePath, [string]$DestinationPath, [bool]$Recurse, [string]$OnConflict, [bool]$VerifyHash, [bool]$DryRun, [AllowNull()][PSCredential]$Credential, [bool]$NonInteractive)` → the same summary shape `Copy-LabTransferItem` returns, plus the resolved `$VMId`. This is the one function both the menu wrapper (Task 5) and parameter mode (Task 6) call.
  - `Invoke-LabAction` gains one new parameter: `[switch]$AllowReadOnly`. Its existing top-of-function check changes from `if ($script:LabReadOnly) { Write-Warning ...; return }` to `if ($script:LabReadOnly -and -not $AllowReadOnly) { Write-Warning ...; return }`. Every one of its 12 existing call sites is unmodified (they don't pass the new switch, so `$AllowReadOnly` defaults to `$false` and behavior is identical to today).

- [ ] **Step 1: Write failing `test_static.py` cases**

```python
def test_invoke_lab_action_has_allow_readonly_switch(self):
    body = self.s.split('function Invoke-LabAction {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('[switch]$AllowReadOnly', body)
    self.assertIn('-not $AllowReadOnly', body)
def test_file_transfer_orchestrator_blocks_real_copy_in_readonly(self):
    body = self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('LabReadOnly', body)
def test_file_transfer_orchestrator_closes_session_in_finally(self):
    body = self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn('finally', body)
    self.assertIn('Remove-PSSession', body)
```

- [ ] **Step 2: Run `test_static.py` and confirm it fails**

Run: `python test_static.py`
Expected: FAIL on all three new cases.

- [ ] **Step 3: Modify `Invoke-LabAction`**

Add the `[switch]$AllowReadOnly` parameter and the one-line condition change described above. Nothing else in the function changes.

- [ ] **Step 4: Implement `Invoke-LabFileTransfer`**

Sequence: `Assert-LabVMRunning $VMId` (re-resolve/recheck, same as every mutation); resolve credentials via `Resolve-LabWindowsCredential`; when `-not $DryRun -and $script:LabReadOnly`, return a summary with `Failed = 1` and an `Errors` entry explaining real copies are blocked under `-ReadOnly` (do this check here, inside the orchestrator, *in addition to* the `Invoke-LabAction` caller passing `-AllowReadOnly` — the switch lets the mutex/audit wrapper run so a dry-run's audit record gets written, but this function is still the one source of truth for "did a real copy actually happen"); open the session via `New-LabPSDirectSession`; call `Copy-LabTransferItem` with `$DryRun` passed through; close the session in `finally`; return the summary with `$VMId` attached.

- [ ] **Step 5: Run `test_static.py` and confirm it passes**

Run: `python test_static.py`
Expected: PASS on all cases.

- [ ] **Step 6: Commit**

```bash
git add Lab-VM.ps1 test_static.py
git commit -m "feat: add file-transfer orchestrator and read-only-aware dry-run path"
```

---

### Task 5: Menu wiring

**Files:**
- Modify: `Lab-VM.ps1` (add `Copy-LabVMItemInteractive`; modify `Show-LabVMMenu`)
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: `Invoke-LabFileTransfer` (Task 4); `Read-LabText`, `Read-LabYesNoCancel`, `Confirm-LabText`, `Invoke-LabAction` (existing).
- Produces:
  - `Copy-LabVMItemInteractive(guid $VMId, [ValidateSet('ToVM','FromVM')][string]$Direction)` → matches the `Invoke-LabAction` status contract (`'COMPLETED'`/`'CANCELLED'`/`'NO_CHANGE'`). Collects source path, destination path, recursion (ask only when the source resolves to a directory — resolve source type by `Test-Path`/guest-side `Invoke-Command` before asking, not by a blind prompt), conflict policy (default `Error`), verify-hash yes/no, blank-cancels on the two path prompts. Shows a preview (direction, VM name/GUID, both resolved paths, recursion, conflict policy, verify-hash) and requires `Confirm-LabText` with a direction-specific phrase (`"COPY TO VM $($vm.Name)"` / `"COPY FROM VM $($vm.Name)"`). Reports the returned `Completed`/`Skipped`/`Failed` counts and any `Errors` entries to the console. Returns `'COMPLETED'` when `Failed -eq 0`, else still `'COMPLETED'` with a prominent warning listing failures (partial completion is not the same as cancellation — `Invoke-LabAction`'s audit should reflect what actually happened, not be forced into a binary pass/fail that doesn't exist in the brief's own "completed/skipped/failed counts" model).

- [ ] **Step 1: Implement `Copy-LabVMItemInteractive`**

No new pure logic here beyond prompting/display — this function is not independently unit-testable (it's interactive), so there is no RED/GREEN cycle for this step; the existing Task 1-4 tests already cover the logic it calls into. Follow the existing prompt/preview/confirm style used by `New-LabVM`/`Edit-LabVMSettings`.

- [ ] **Step 2: Wire into `Show-LabVMMenu`**

Add two options to the non-read-only menu text and switch: `13  Copy file/directory to VM          [requires Running]` → `Invoke-LabAction $VMId 'copy-to-vm-menu' -AllowReadOnly { param($id) Copy-LabVMItemInteractive $id 'ToVM' }`; `14  Copy file/directory from VM        [requires Running]` → the `'FromVM'` equivalent. Passing `-AllowReadOnly` here is required so a `-DryRun`-equivalent... **note:** the menu path has no separate dry-run toggle in this plan (dry-run is parameter-mode only, per the issue's own framing — "a minimal parameter mode... -DryRun for a plan without copying"); still pass `-AllowReadOnly` so `Test-LabTransferConnection`-adjacent inspection remains possible, and so `Invoke-LabFileTransfer`'s own internal `-ReadOnly` check (Task 4 Step 4) is the actual enforcement point for menu-triggered copies, not `Invoke-LabAction`'s blanket gate. Confirm via a `test_static.py` case that both new switch entries pass `-AllowReadOnly` and that `Invoke-LabFileTransfer`'s own `-ReadOnly` check (already covered in Task 4) is what blocks a real copy from the menu under `-ReadOnly`.

- [ ] **Step 3: Write and run the `test_static.py` case for Step 2**

```python
def test_copy_menu_options_pass_allow_readonly(self):
    body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("'copy-to-vm-menu' -AllowReadOnly", body)
    self.assertIn("'copy-from-vm-menu' -AllowReadOnly", body)
```

Run: `python test_static.py` — expect FAIL before Step 2, PASS after.

- [ ] **Step 4: Update `README.md` and `MANUAL-TESTS.md`**

Add menu rows 13/14 to the table. Add a "Copy file/directory to/from VM (menu)" section to `MANUAL-TESTS.md`: cancel at each prompt leaves nothing copied; a successful to-VM and from-VM transfer of a small file; attempting either option under `-ReadOnly` reports the real-copy block from `Invoke-LabFileTransfer` rather than `Invoke-LabAction`'s generic read-only warning (both messages are acceptable to the operator, but the live tester should confirm the audit log for a blocked attempt doesn't claim `COMPLETED`); attempting either option against an Off VM is rejected by `Assert-LabVMRunning`.

- [ ] **Step 5: Commit**

```bash
git add Lab-VM.ps1 test_static.py README.md MANUAL-TESTS.md
git commit -m "feat: add Copy file/directory to/from VM menu options"
```

---

### Task 6: Parameter-mode CLI surface

**Files:**
- Modify: `Lab-VM.ps1` (top `param()` block; bottom invocation gate; add `Resolve-LabVMByNameOrId`)
- Modify: `test_static.py`
- Modify: `README.md`

**Interfaces:**
- Consumes: `Invoke-LabFileTransfer` (Task 4); `Get-LabVM`, `Assert-LabHost`, `Initialize-LabLog`, `Write-LabAudit` (existing).
- Produces:
  - `Resolve-LabVMByNameOrId([AllowEmptyString()][string]$VMName, [Nullable[guid]]$VMId)` → `guid`: exactly one of the two must be supplied (both-or-neither throws); for `$VMName`, matches case-insensitively against `(Get-VM -ErrorAction Stop).Name` with no wildcard expansion, throws naming the ambiguity if more than one match, throws "no matching VM" if zero.
  - New top-level script parameters (all optional, default unset): `[switch]$CopyToVM`, `[switch]$CopyFromVM` (mutually exclusive — validate in the invocation gate, not via `[CmdletBinding(DefaultParameterSetName=...)]`, to keep the existing `param()` block's style consistent with its current flat structure), `[string]$VMName`, `[Nullable[guid]]$VMId`, `[string]$SourcePath`, `[string]$DestinationPath`, `[switch]$Recurse`, `[ValidateSet('Error','Skip','Overwrite')][string]$OnConflict = 'Error'`, `[switch]$DryRun`, `[switch]$NonInteractive`, `[switch]$VerifyHash`, `[ValidateSet('Default','PrivateFiles')][string]$PermissionProfile = 'Default'`, `[PSCredential]$Credential`.

- [ ] **Step 1: Write failing `test_static.py` cases**

```python
def test_transfer_params_exist(self):
    for p in ['$CopyToVM', '$CopyFromVM', '$SourcePath', '$DestinationPath', '$OnConflict', '$DryRun', '$NonInteractive', '$VerifyHash', '$Credential']:
        self.assertIn(p, self.s.split('param(', 1)[1].split(')\n\n', 1)[0])
def test_copyto_and_copyfrom_mutually_exclusive(self):
    self.assertRegex(self.s, r'CopyToVM.{0,200}CopyFromVM|CopyFromVM.{0,200}CopyToVM')
def test_parameter_mode_does_not_launch_menu(self):
    body = self.s.rsplit("if ($MyInvocation.InvocationName -ne '.')", 1)[1]
    self.assertIn('CopyToVM', body)
def test_credential_never_passed_as_plaintext_arg(self):
    self.assertNotIn('-Password ', self.s)
    self.assertNotRegex(self.s, r'\$Credential\.GetNetworkCredential\(\)\.Password')
```

- [ ] **Step 2: Run `test_static.py` and confirm it fails**

Run: `python test_static.py`
Expected: FAIL on all four new cases.

- [ ] **Step 3: Implement `Resolve-LabVMByNameOrId`**

Per the Interfaces block.

- [ ] **Step 4: Add the new parameters to the top `param()` block**

Append to the existing flat parameter list; no behavior change to the existing four parameters (`ReadOnly`, `LogRoot`, `ExportRoot`, `TimeoutSeconds`).

- [ ] **Step 5: Extend the bottom invocation gate**

Currently:
```powershell
if ($MyInvocation.InvocationName -ne '.') {
    try { Start-LabVMManager -RequestedLogRoot $LogRoot }
    catch { Write-Error -Message $_.Exception.Message -ErrorAction Continue; exit 1 }
}
```
Change to branch on `$CopyToVM -or $CopyFromVM`: when either is set, validate exactly one of `$CopyToVM`/`$CopyFromVM` and exactly one of `$VMName`/`$VMId` are supplied (throw otherwise); run the same host/log setup `Start-LabVMManager` does (`Assert-LabHost`, `Initialize-LabLog $LogRoot`, a `'session' 'STARTED'` audit record) but skip the interactive menu loop; resolve the VM via `Resolve-LabVMByNameOrId`; call `Invoke-LabFileTransfer` with the resolved direction/paths/options; write a `'session' 'ENDED'` audit record in a `finally`; set `$LASTEXITCODE`/call `exit` with `0` only when the summary's `Failed -eq 0` (and, per the plan's "no plaintext password" constraint, the summary itself never contains credential data to log). When neither switch is set, fall through to today's `Start-LabVMManager` call unchanged.

- [ ] **Step 6: Run `test_static.py` and confirm it passes**

Run: `python test_static.py`
Expected: PASS on all cases.

- [ ] **Step 7: Update `README.md`**

Add a "Parameter mode: file transfer" section documenting the new switches/parameters, the mutual-exclusivity rule, the exit-code contract, and that `-Credential` only works when Lab-VM.ps1 is dot-sourced or invoked from a calling Windows PowerShell session holding a `PSCredential` object (never pass a plaintext password on the command line).

- [ ] **Step 8: Commit**

```bash
git add Lab-VM.ps1 test_static.py README.md
git commit -m "feat: add parameter-mode CLI surface for file transfer"
```

---

### Task 7: Private-file permission profile (Windows)

**Files:**
- Modify: `Lab-VM.ps1` (extend `Copy-LabTransferItem`'s finalize step; add a small ACL helper)
- Modify: `test_static.py`
- Modify: `README.md`, `MANUAL-TESTS.md`

**Interfaces:**
- Consumes: the finalize step inside `Copy-LabTransferItem` (Task 3) — this task adds a parameter and a hook, it does not restructure the engine.
- Produces:
  - `Copy-LabTransferItem` gains `[ValidateSet('Default','PrivateFiles')][string]$PermissionProfile = 'Default'`.
  - `Set-LabTransferPrivateAcl([System.Management.Automation.Runspaces.PSSession]$Session, [AllowNull()]$Session, [string]$Path, [bool]$IsDirectory)`: when `$Session` is `$null` (host-side, `FromVM` finalize), uses `Get-Acl`/`Set-Acl` (or `icacls.exe "$Path" /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(F)"`, your choice, document which) to restrict the file/directory to the current host user only; when `$Session` is supplied (guest-side, `ToVM` finalize), runs the equivalent inside `Invoke-Command -Session $Session { ... }` against the *executing guest account* (the account the PS Direct session authenticated as), never an owner inferred from the path. Applied **after** the temp-to-real finalize move, to exactly the finalized file/directory and, when the destination directory root was newly created by this transfer, that root directory too — never recursively re-touches pre-existing sibling files.

- [ ] **Step 1: Write failing `test_static.py` cases**

```python
def test_private_permission_profile_param_exists(self):
    body = self.s.split('function Copy-LabTransferItem {', 1)[1].split('\nfunction ', 1)[0]
    self.assertIn("'PrivateFiles'", body)
def test_private_acl_applied_after_finalize_not_before(self):
    body = self.s.split('function Copy-LabTransferItem {', 1)[1].split('\nfunction ', 1)[0]
    idx_move = body.index('Move-Item')
    idx_acl = body.index('Set-LabTransferPrivateAcl')
    self.assertLess(idx_move, idx_acl)
def test_private_acl_helper_exists(self):
    self.assertIn('function Set-LabTransferPrivateAcl', self.s)
```

- [ ] **Step 2: Run `test_static.py` and confirm it fails**

Run: `python test_static.py`
Expected: FAIL on all three new cases.

- [ ] **Step 3: Implement `Set-LabTransferPrivateAcl` and wire it into `Copy-LabTransferItem`'s finalize**

Per the Interfaces block. Call it immediately after each successful `'Proceed'`/`'Overwrite'` finalize move, only when `$PermissionProfile -eq 'PrivateFiles'`; a failure to establish the ACL turns that item's result into `Failed` (with a message), even though the byte copy itself succeeded — per the issue's "a successful byte copy with failed final permission setup is a failed/partial result" requirement.

- [ ] **Step 4: Run `test_static.py` and confirm it passes**

Run: `python test_static.py`
Expected: PASS on all cases.

- [ ] **Step 5: Update `README.md` and `MANUAL-TESTS.md`**

Document the `-PermissionProfile PrivateFiles` option and its Windows-ACL behavior (chmod-style Linux behavior is explicitly future work — see Out of Scope). Add a `MANUAL-TESTS.md` step: copy a synthetic private file both directions with `PrivateFiles`, and verify (via `icacls`/`Get-Acl` on whichever side is the destination) that only the receiving account has access, and that an unrelated pre-existing sibling file in the destination directory is untouched.

- [ ] **Step 6: Commit**

```bash
git add Lab-VM.ps1 test_static.py README.md MANUAL-TESTS.md
git commit -m "feat: add Windows private-file permission profile"
```

---

### Task 8: Final regression pass and script help update

**Files:**
- Modify: `Lab-VM.ps1` (comment-based help)
- Modify: `test_static.py` (`test_all_named_operations_exist`)

**Interfaces:**
- Consumes: everything from Tasks 1-7.
- Produces: no new functions.

- [ ] **Step 1: Add the new interactive-entry-point names to `test_all_named_operations_exist`**

Add `'Copy-LabVMItemInteractive', 'Invoke-LabFileTransfer'` (the `*Core`/pure-helper functions stay excluded from this particular check, matching the existing convention).

- [ ] **Step 2: Update comment-based help**

Add a `.PARAMETER` block (or extend `.DESCRIPTION`) documenting `-CopyToVM`/`-CopyFromVM` and friends at a summary level, pointing to `README.md` for the full parameter list — matching how existing parameters are documented in the file's header comment.

- [ ] **Step 3: Run the complete test suite**

Run: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` then `python test_static.py`
Expected: PASS — every case from Tasks 1-7 plus everything that existed before this plan.

- [ ] **Step 4: Commit**

```bash
git add Lab-VM.ps1 test_static.py
git commit -m "docs: update help and static checks for Windows file transfer"
```

---

## Out of Scope (deferred to the follow-up Linux/SFTP plan, or genuinely out of scope per the issue)

Linux/SFTP adapter entirely (SSH host-key verification, password/key/agent authentication, `ssh`/`sftp` process invocation strategy, the `.ssh`-directory/`authorized_keys` collision handling specific to that scenario); the optional non-secret per-VM-GUID connection-settings store (its only driver in the issue is SSH's hostname/port/identity-file — PowerShell Direct needs none of that); `chmod 0600`/`0700` Linux semantics for `-PermissionProfile PrivateFiles`; the one-way no-SSH `Copy-VMFile` bootstrap design (issue section E). Clipboard sync, drag-and-drop, SMB shares, continuous sync, offline VHD mounting, VM-to-VM transfer, remote Hyper-V hosts, resumable transfers, a custom guest agent, automatic guest provisioning — all explicitly out of scope per the issue itself, unchanged by this plan.
