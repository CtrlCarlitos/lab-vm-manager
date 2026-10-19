# LAB VM Manager — v1.0.0

A standalone menu-driven PowerShell script for managing **local Hyper-V VMs whose names start with `LAB-`**: creating them, operating and checkpointing them, editing their basic settings, and deleting them while retaining their virtual disks. The prefix check is case-insensitive. It is intended for your Linux/Windows development-and-test lab, not production VMs.

**Run the manager on the physical Hyper-V host, not inside either guest.** Use elevated **Windows PowerShell 5.1 (`powershell.exe`)**. The manager deliberately refuses PowerShell Core/7 rather than silently importing Hyper-V through a compatibility session. You can invoke `powershell.exe` from an elevated Windows Terminal tab running PowerShell 7.

## Package contents

- `Lab-VM.ps1`: standalone manager; no third-party runtime dependencies beyond the Windows Hyper-V management tools and CIM cmdlets.
- `Test-LabVM.ps1`: PowerShell parser and helper tests; does not import Hyper-V or invoke VM operations.
- `MANUAL-TESTS.md`: acceptance checklist for a disposable VM.
- `test_static.py`: source-level regression checks; optional, requires Python.

The script has been source-reviewed: all 47 `test_static.py` source-contract checks pass, and all 68 `Test-LabVM.ps1` helper tests pass in Windows PowerShell 5.1. An earlier version (before the Create, Edit and Delete VM workflows were added) was exercised live against real Hyper-V VMs (inventory, `-ReadOnly` mode, and checkpoint creation all confirmed working). The full `MANUAL-TESTS.md` checklist — restore, rename, checkpoint deletion, export, concurrency and shutdown-failure scenarios, and the new Create VM, Edit VM settings and Delete VM workflows — has not yet been walked end-to-end. Validate those remaining paths on one disposable `LAB-*` VM before relying on them for anything you care about.

## Start

Extract this package into a host folder you control, for example `C:\Tools\LabVmManager`. Review the scripts before running them. Unblock only the reviewed scripts if Windows marked the downloads as internet-origin:

```powershell
Unblock-File -LiteralPath .\Lab-VM.ps1
Unblock-File -LiteralPath .\Test-LabVM.ps1
```

Run the parser/helper tests first; these do not need administrator privileges:

```powershell
powershell.exe -NoProfile -File .\Test-LabVM.ps1
```

Then open an elevated terminal and inspect the inventory without VM changes:

```powershell
powershell.exe -NoProfile -File .\Lab-VM.ps1 -ReadOnly
```

For normal operation:

```powershell
powershell.exe -NoProfile -File .\Lab-VM.ps1
```

Optional host paths and state-polling timeout:

```powershell
powershell.exe -NoProfile -File .\Lab-VM.ps1 `
    -ExportRoot 'E:\HyperV-Exports' `
    -LogRoot 'C:\LabHostLogs' `
    -TimeoutSeconds 300
```

Create the export root yourself first, or choose an existing local folder when prompted. Each export creates a new timestamp-and-ID subfolder. Network-share export and import/cloning are outside this version.

The manager never changes execution policy. `Unblock-File` only addresses internet-origin marking; it does not override Restricted or AllSigned policy. Inspect `Get-ExecutionPolicy -List` when blocked. On your own unmanaged host, a one-process RemoteSigned invocation is an option after reviewing/unblocking the script:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Lab-VM.ps1 -ReadOnly
```

This does not persist a machine/user policy change and cannot override an organization's Group Policy. Do not change organizational policy to run this tool.

## Menus

The first menu lists matching VMs, current state, CPU count, assigned memory and full VM ID. Assigned memory can be zero while a VM is Off. Pick a number, `N` to create a new VM (hidden in `-ReadOnly` mode), `R` to refresh or `Q` to quit. An empty list still offers `N` (unless read-only); it never creates or renames one automatically on its own.

### Create VM (`N`)

Collects, in order: a unique `LAB-` name (at most 100 characters, with no path, wildcard or control characters, since it becomes a folder and file name); a VM storage root (defaults to the host's configured VM path; an ISO/installer media folder such as `E:\ISO` is explicitly called out as invalid storage); vCPU count (bounded by host logical processors); startup RAM and a static/dynamic memory choice with minimum/maximum when dynamic; a VHDX storage root and maximum capacity; and a virtual switch, or an explicit "Disconnected" choice. Both storage roots must be existing absolute local drive paths (e.g. `D:\Hyper-V`); relative paths, UNC paths and mapped network drives are rejected, as for exports. Each new VM gets its own dedicated storage subfolder and VHDX subfolder, so creation refuses to proceed if that destination already exists. The VM is always created as **Generation 2**, with the same Standard/no-automatic-checkpoints policy used elsewhere in this tool. A full preview is shown before the `CREATE <name>` confirmation; creation itself is also protected by a dedicated per-name creation lock, and is blocked entirely in `-ReadOnly` mode.

The selected-VM menu provides:

| Choice | Operation |
|---|---|
| 1 | Inspect VM configuration, virtual disks, network and integration services |
| 2 | Start an Off VM; resume a Saved/Paused VM |
| 3 | Request guest OS shutdown without forcing applications closed |
| 4 | List checkpoints with dates, type, parent and IDs |
| 5 | Create a named checkpoint; VM must be Off |
| 6 | Restore a chosen checkpoint; VM must be Off; offers a safety checkpoint |
| 7 | Rename a checkpoint; VM must be Off |
| 8 | Delete one checkpoint; VM must be Off; never requests subtree deletion |
| 9 | Export the full VM into a fresh folder; VM must be Off |
| 10 | Explicitly select Standard checkpoints and disable automatic checkpoints |
| 11 | Edit VM settings: name, notes, vCPU count, memory, network switch; VM must be Off |
| 12 | Delete the VM (retain virtual disks); VM must be Off; blocked by non-Standard checkpoints |
| 13 | Copy a file or directory from this host to the VM; VM must be Running |
| 14 | Copy a file or directory from the VM to this host; VM must be Running |
| T | Test Windows guest connectivity over PowerShell Direct; VM must be Running |
| X | Emergency power-off, with strong confirmation and data-loss warning |
| R / B / Q | Refresh / choose another VM / quit |

`-ReadOnly` allows only inspection, listing, the connectivity test (option `T`) and the file-copy options (`13`/`14`); it performs no mutation. The copy options still remain listed because a real copy is blocked deeper inside the transfer itself (reported as a failed item, not a generic read-only warning), not by the menu dispatch gate. It still writes a host audit log.

### Test connection (`T`)

Prompts for the guest's Windows credentials (never stored), opens a PowerShell Direct session to the Running VM, and runs a trivial remote command to confirm round-trip execution. On success it reports the guest's OS version string; on failure (wrong credentials, VM not Running, etc.) it reports a clear message, never a raw stack trace. The session is always closed afterward. This does not transfer any files by itself; it only proves the connection used by later file-transfer operations is reachable.

### Copy file/directory to/from VM (`13` / `14`)

Collects a source path, a destination path (blank cancels either), recursion (asked only when the source resolves to a directory, checked by inspection rather than a blind prompt), a conflict policy chosen from a numbered list (`Error`, `Skip` or `Overwrite`; default `Error`), and whether to verify a SHA-256 hash after copying. A preview of the direction, VM name/ID, both resolved paths, recursion, conflict policy and verify-hash choice is shown, and you then type the exact `COPY TO VM <name>` or `COPY FROM VM <name>` confirmation. The transfer itself uses PowerShell Direct and the same temp-sibling-then-finalize engine described below; the console reports the returned completed/skipped/failed counts and any per-item errors. A partial failure is still reported as a completed operation (with a prominent warning listing what failed), since "some items failed" is not the same as "the whole operation was cancelled." The VM must be `Running`.

## Parameter mode: file transfer

Pass `-CopyToVM` or `-CopyFromVM` on the command line to run a single file-transfer operation non-interactively and exit, instead of launching the menu. The two switches are mutually exclusive; supplying both (or neither, while still using either switch) throws before anything else runs.

```
powershell.exe -NoProfile -File .\Lab-VM.ps1 -CopyToVM -VMName LAB-dev -SourcePath C:\code\app -DestinationPath C:\app -Recurse -OnConflict Skip -VerifyHash
```

Parameters:

- `-CopyToVM` / `-CopyFromVM` — direction switch; pick exactly one.
- `-VMName` / `-VMId` — identify the target VM; pick exactly one. `-VMName` matches case-insensitively against the current VM inventory with no wildcard expansion; zero or more than one match throws.
- `-SourcePath` / `-DestinationPath` — required paths, on the side implied by the direction switch (e.g. `-CopyToVM` reads `-SourcePath` from this host and writes `-DestinationPath` on the VM).
- `-Recurse` — copy a directory source's contents recursively.
- `-OnConflict` — `Error` (default), `Skip`, or `Overwrite`.
- `-DryRun` — report what would be copied without changing any files.
- `-NonInteractive` — never prompt; `-Credential` must already supply what's needed.
- `-VerifyHash` — verify a SHA-256 hash of each copied file after the copy.
- `-Credential` — a `PSCredential` for the guest Windows account. This only works when `Lab-VM.ps1` is dot-sourced (`. .\Lab-VM.ps1`) or invoked from a calling Windows PowerShell session that already holds a `PSCredential` object in a variable; **never pass a plaintext password on the command line** (there is no `-Password` parameter, and none will be added).

Exit-code contract: the process exits `0` only when the transfer summary reports `Failed -eq 0` (including when `-DryRun` is set and nothing failed); any failed item, or a thrown validation/setup error, exits non-zero. The same host assertion, log initialization, and `session` `STARTED`/`ENDED` audit records that interactive mode writes are also written in parameter mode; only the menu loop itself is skipped.

## First baseline

1. Install/update the guest, finish required reboots, and shut it down **normally**.
2. Select it in the manager. Confirm its state is `Off`.
3. Choose `10`, then type the displayed `CONFIGURE LAB-...` confirmation. This changes only checkpoint policy; it does not delete existing checkpoints.
4. Choose `5`, name the checkpoint `00-os-clean`, and type the displayed confirmation.
5. Choose `2` to boot, provision with your intended dotfiles profile, and verify the tools.
6. Shut down normally. Choose `5` again and create `10-toolchain-v1`.

An optional `20-live-ready-private-v1` can retain native logins and operational setup. Treat that state and any export containing it as private. Authentication expiration is external to VM rollback; a restored session may still need login.

`Off` is a state, not proof of a clean shutdown. A VM just hard-powered-off is also Off. Do not label that state a clean baseline without recovering and shutting it down properly first.

## Restore workflow

Collect code changes and guest test results **outside the VM first**. This manager logs host operations, not guest files, agent conversations, or test output.

Shut down normally, choose `6`, then select the target checkpoint by number. The target's full ID and creation time are displayed. The manager asks whether to create a safety checkpoint first. The default is **Yes**; `C` cancels. You then type the displayed `RESTORE <VM name> <checkpoint ID prefix>` phrase.

With safety enabled, creation and verification must succeed before restore is called. A failed safety checkpoint aborts the restore. Safety checkpoint names are unique and begin `safety-before-restore-`. The manager never automatically deletes them; review and prune them later using option `8` when they are no longer needed.

The manager does **not** start/resume the VM after restore and prints the observed Hyper-V state. Existing checkpoints taken while running may contain saved execution state; the checkpoints newly created by this manager require Off. Check restored VM configuration before booting. The restored configuration may include different settings, so re-check checkpoint policy when needed rather than assuming it is unchanged.

## Shutdown behavior

Normal shutdown uses the Hyper-V `Msvm_ShutdownComponent.InitiateShutdown` integration-service method with `Force = false`. It checks return codes and then polls for `Off`. A locked/unresponsive guest, unsaved work, disabled integration service, or unavailable component can stop the operation. Use the guest console to shut down in those cases.

There is no automatic escalation to `Stop-VM -Force` or `-TurnOff`. `X` is the separate emergency action and uses `Stop-VM -TurnOff` only after the displayed exact confirmation. It can lose data or corrupt the guest filesystem.

The state timeout applies to polling for Running/Off, not to checkpoint, export, merge, or every individual provider call. A timeout does not cancel an already-accepted Hyper-V operation. Inspect current state before retrying. `Running` does not establish that the guest OS, SSH or any CLI is ready.

## Selection, locking and audit

Every operation re-resolves the selected VM by **GUID** and checks its current name still begins `LAB-`. Checkpoints are re-resolved by GUID within that selected VM. Duplicate display names cannot turn the command into a wildcard/bulk operation.

A per-VM, host-global named mutex prevents overlapping operations from cooperating copies of this script. It does **not** lock Hyper-V Manager, backup software, other tools, or privileged users. Do not modify the VM concurrently using those tools. If a process is terminated during a provider operation, verify Hyper-V state before rerunning; the provider can outlive the script.

Audit files default to:

```text
%LOCALAPPDATA%\LabVmManager\Logs\<timestamp>-<process>-<random>.jsonl
```

Records contain UTC timestamps, host/operator, VM ID/name, actions, status and relevant checkpoint/export/error details. They do not capture guest logs. Log creation failure prevents startup. Failure after a VM command may mean the VM changed but completion could not be recorded; the script reports `FAILED_OR_UNCONFIRMED`, not "nothing changed."

No passwords are requested by the manager for VM lifecycle/checkpoint operations. The connectivity test (`T`) is the one exception: it prompts for guest Windows credentials via `Get-Credential` to open a PowerShell Direct session, and credentials are never logged or written to disk. VM names, export paths and error messages can still be sensitive. Protect the host scripts, logs and exports with appropriate filesystem permissions. This tool is not a security boundary against an administrator or a sandbox for untrusted guest code.

## Export and checkpoint deletion

Exports use `Export-VM` and include the selected full VM and its checkpoint data. Each gets `export-manifest.json` with `IN_PROGRESS`, `COMPLETE` or `INCOMPLETE` status. Abrupt process/host termination can leave `IN_PROGRESS`. An incomplete export is retained for diagnosis, never deleted automatically. A successful provider return and a discovered VMCX configuration are checked; disk content hashes and a recovery boot are not validated.

Use independent storage and import-test a copy before depending on an export for recovery. Windows TPM/BitLocker-protected VMs may require additional host key-protector or recovery material when moved; this tool does not validate portability or manage those secrets. Never assume a VM export alone replaces your encryption recovery-key procedure.

Deleting a checkpoint removes the return point; it does not restore it. Hyper-V owns the disk merging. Never remove `.avhdx` or `.vhdx` files manually. Baseline-like names beginning `00-`, `10-` or `20-` require the longer `DELETE BASELINE ...` confirmation; other names still require exact confirmation. Recovery/backup checkpoint objects are excluded from modification.

## Delete VM

Option `12` calls Hyper-V's `Remove-VM`, which unregisters the VM and its configuration but **never deletes virtual disk files**. A removal preview (name, GUID, VM path, disk paths, checkpoint count) is shown first. Removal is blocked while the VM has any recovery/backup (non-Standard) checkpoint, since this tool does not manage merging those. You are then offered an export of the full VM before deletion; declining the export is allowed, but if you accept and the export does not reach `COMPLETE`, deletion does not proceed. A host-side `<VM ID>-removal-manifest.json` (listing the VM name/ID/path, retained disk paths, checkpoint count and whether an export was performed) is written next to the audit log **before** `Remove-VM` is called, and its `RemovedUtc` field is filled in only after Hyper-V confirms the VM is gone. The strong `DELETE VM <name> <ID prefix>` confirmation is required. After removal, the manager reports the retained disk paths from the preview; use Hyper-V Manager or File Explorer to purge them yourself once you are sure they are not needed.

## Intentionally not included

No guest OS installation, VM clone/import, virtual disk resizing or guest partition changes, virtual switch creation, OS activation/licensing, remote hosts, automatic login, guest provisioning or dotfiles execution, guest result collection, or automatic checkpoint pruning. VM deletion (option `12`) is implemented through the Hyper-V API and retains virtual disk files; purging those retained disk files is still out of scope for this tool.

## Primary references

- Microsoft: Using checkpoints — https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/checkpoints
- Microsoft: Set-VM — https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vm
- Microsoft: InitiateShutdown — https://learn.microsoft.com/en-us/windows/win32/hyperv_v2/msvm-shutdowncomponent-initiateshutdown
- Microsoft: Stop-VM — https://learn.microsoft.com/en-us/powershell/module/hyper-v/stop-vm
- Microsoft: Export-VM — https://learn.microsoft.com/en-us/powershell/module/hyper-v/export-vm
- Microsoft: Remove-VM — https://learn.microsoft.com/en-us/powershell/module/hyper-v/remove-vm
- Microsoft: Execution policies — https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies
