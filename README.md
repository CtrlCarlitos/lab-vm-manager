# LAB VM Manager — v1.0.0

A standalone menu-driven PowerShell script for managing **local Hyper-V VMs whose names start with `LAB-`**: creating them, operating and checkpointing them, editing their basic settings, and deleting them while retaining their virtual disks. The prefix check is case-insensitive. It is intended for your Linux/Windows development-and-test lab, not production VMs.

**Run the manager on the physical Hyper-V host, not inside either guest.** Use elevated **Windows PowerShell 5.1 (`powershell.exe`)**. The manager deliberately refuses PowerShell Core/7 rather than silently importing Hyper-V through a compatibility session. You can invoke `powershell.exe` from an elevated Windows Terminal tab running PowerShell 7.

## Package contents

- `Lab-VM.ps1`: standalone manager; no third-party runtime dependencies beyond the Windows Hyper-V management tools and CIM cmdlets.
- `Test-LabVM.ps1`: PowerShell parser and helper tests; does not import Hyper-V or invoke VM operations.
- `MANUAL-TESTS.md`: acceptance checklist for a disposable VM.
- `test_static.py`: source-level regression checks; optional, requires Python.

The script has been source-reviewed: all 70 `test_static.py` source-contract checks pass, and all 101 `Test-LabVM.ps1` helper tests pass in Windows PowerShell 5.1. An earlier version (before the Create, Edit and Delete VM workflows were added) was exercised live against real Hyper-V VMs (inventory, `-ReadOnly` mode, and checkpoint creation all confirmed working). The full `MANUAL-TESTS.md` checklist — restore, rename, checkpoint deletion, export, concurrency and shutdown-failure scenarios, and the new Create VM, Edit VM settings and Delete VM workflows — has not yet been walked end-to-end. Validate those remaining paths on one disposable `LAB-*` VM before relying on them for anything you care about.

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

Collects a source path, a destination path (blank cancels either), recursion (asked only when the source resolves to a directory, checked by inspection rather than a blind prompt), a conflict policy chosen from a numbered list (`Error`, `Skip` or `Overwrite`; default `Error`), whether to verify a SHA-256 hash after copying, and whether the content is private ("Private files (SSH keys / private configuration)? [y/N]"; default `N`/`Default`). A preview of the direction, VM name/ID, both resolved paths, recursion, conflict policy, verify-hash choice and permission profile is shown, and you then type the exact `COPY TO VM <name>` or `COPY FROM VM <name>` confirmation. The transfer itself uses PowerShell Direct and the same temp-sibling-then-finalize engine described below; the console reports the returned completed/skipped/failed counts and any per-item errors. A partial failure is still reported as a completed operation (with a prominent warning listing what failed), since "some items failed" is not the same as "the whole operation was cancelled." The VM must be `Running`. Missing destination parent directories are created (for example a fresh guest's `C:\Users\<name>\.ssh` when copying a single key file there); if a single-file copy then fails, the directories it created are removed again as long as they are still empty, and a pre-existing directory is never removed.

Answering `Y` to the private-files prompt restricts each item actually delivered by this transfer (and, for a recursive copy, the destination root directory, but only if this transfer newly created it) to the receiving Windows account only, using `icacls` on whichever side is the destination -- the current signed-in user for a `FromVM` copy landing on this host, or the account the PowerShell Direct session authenticated as for a `ToVM` copy landing in the guest (never an owner inferred from the path). It never walks into a pre-existing destination directory to touch files this transfer did not itself write. If the permission step fails for an item that otherwise copied successfully, that item is reported as `Failed`, not `Completed` -- a byte-identical copy with a permission you couldn't lock down is not a successful private-file transfer. This is a Windows-ACL-only feature; there is no equivalent chmod-style behavior for a Linux guest (see "Intentionally not included" below).

**Timing limitation (this version):** the restrictive permission is applied immediately *after* each file (or newly created directory) has been written and moved into place, not before. There is therefore a brief window in which the data exists at the destination (and, during the copy, in its `*.labxfer-*.tmp` temporary sibling) with the default/inherited permissions of its parent directory before being restricted. That is acceptable for disposable lab VMs, but if the destination directory's inherited permissions would expose the content to other accounts even briefly, restrict that directory yourself first. Restricting permissions *before* any private bytes are written (including the temporary item), and reading the final permissions back to verify them, is planned follow-up work.

## Parameter mode: file transfer

Pass `-CopyToVM` or `-CopyFromVM` on the command line to run a single file-transfer operation non-interactively and exit, instead of launching the menu. The two switches are mutually exclusive; supplying both throws before anything else runs, and supplying transfer parameters without either switch is also an error (see below).

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
- `-PermissionProfile` — `Default` (no permission change, the default) or `PrivateFiles`, which restricts each finalized item to the receiving Windows account only (see the private-files description above).
- `-Credential` — a `PSCredential` for the guest Windows account. Build it in an elevated Windows PowerShell 5.1 session and invoke the script normally with the call operator, for example:

  ```powershell
  $cred = Get-Credential
  & .\Lab-VM.ps1 -CopyToVM -VMName LAB-dev -SourcePath C:\keys\id_ed25519 -DestinationPath C:\Users\dev\.ssh\id_ed25519 -PermissionProfile PrivateFiles -NonInteractive -Credential $cred
  ```

  Do **not** dot-source the script for this (`. .\Lab-VM.ps1 ...`): dot-sourcing only loads its functions and silently runs no transfer. `powershell.exe -File` cannot receive a `PSCredential` object either; when it is used without `-Credential` (and without `-NonInteractive`), the script prompts for the guest credentials instead. **Never pass a plaintext password on the command line** (there is no `-Password` parameter, and none will be added).

The transfer-only parameters (`-VMName`, `-VMId`, `-SourcePath`, `-DestinationPath`, `-Recurse`, `-OnConflict`, `-DryRun`, `-NonInteractive`, `-VerifyHash`, `-PermissionProfile`, `-Credential`) require `-CopyToVM` or `-CopyFromVM`. Supplying any of them without a direction switch is an error (exit `1`) rather than silently opening the interactive menu, so an unattended `-NonInteractive` job can never hang at a menu prompt.

Exit-code contract: the process exits `0` only when the transfer summary reports `Failed -eq 0` (including when `-DryRun` is set and nothing failed); any failed item, or a thrown validation/setup error, exits non-zero. The same host assertion, log initialization, and `session` `STARTED`/`ENDED` audit records that interactive mode writes are also written in parameter mode; only the menu loop itself is skipped. Parameter mode holds the same per-VM lock as the menu operations for the whole transfer, so it fails immediately ("Another copy of this script is operating on this VM...") rather than run alongside another operation on that VM.

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

Every file transfer (menu options `13`/`14` and parameter mode alike) also writes one `file-transfer` record whose detail lists the direction, source and destination paths, recursion, conflict policy, permission profile, whether hash verification was requested, dry-run, and the completed/skipped/failed counts and bytes transferred. Its status is `COMPLETED` (nothing failed), `PARTIAL` (some items failed, some completed), `FAILED` (items failed and none completed, or the transfer could not start), `DRY_RUN`, `BLOCKED_READONLY` (a real copy refused under `-ReadOnly`), or `FAILED_OR_UNCONFIRMED` (the connection or engine failed mid-transfer, so what reached the destination is unknown). The menu's own `copy-to-vm-menu`/`copy-from-vm-menu` record still reads `COMPLETED` whenever the operation ran to the end, whatever the per-item outcome; the `file-transfer` record is the one that tells them apart. Credentials and file contents are never written to the log.

No passwords are requested by the manager for VM lifecycle/checkpoint operations. Only the guest-facing operations prompt for guest Windows credentials via `Get-Credential` to open a PowerShell Direct session: the connectivity test (`T`), the copy options (`13`/`14`), and parameter-mode transfers run without `-Credential` (unless `-NonInteractive` is set, which fails instead of prompting). Credentials are never logged or written to disk. VM names, export paths and error messages can still be sensitive. Protect the host scripts, logs and exports with appropriate filesystem permissions. This tool is not a security boundary against an administrator or a sandbox for untrusted guest code.

## Export and checkpoint deletion

Exports use `Export-VM` and include the selected full VM and its checkpoint data. Each gets `export-manifest.json` with `IN_PROGRESS`, `COMPLETE` or `INCOMPLETE` status. Abrupt process/host termination can leave `IN_PROGRESS`. An incomplete export is retained for diagnosis, never deleted automatically. A successful provider return and a discovered VMCX configuration are checked; disk content hashes and a recovery boot are not validated.

Use independent storage and import-test a copy before depending on an export for recovery. Windows TPM/BitLocker-protected VMs may require additional host key-protector or recovery material when moved; this tool does not validate portability or manage those secrets. Never assume a VM export alone replaces your encryption recovery-key procedure.

Deleting a checkpoint removes the return point; it does not restore it. Hyper-V owns the disk merging. Never remove `.avhdx` or `.vhdx` files manually. Baseline-like names beginning `00-`, `10-` or `20-` require the longer `DELETE BASELINE ...` confirmation; other names still require exact confirmation. Recovery/backup checkpoint objects are excluded from modification.

## Delete VM

Option `12` calls Hyper-V's `Remove-VM`, which unregisters the VM and its configuration but **never deletes virtual disk files**. A removal preview (name, GUID, VM path, disk paths, checkpoint count) is shown first. Removal is blocked while the VM has any recovery/backup (non-Standard) checkpoint, since this tool does not manage merging those. You are then offered an export of the full VM before deletion; declining the export is allowed, but if you accept and the export does not reach `COMPLETE`, deletion does not proceed. A host-side `<VM ID>-removal-manifest.json` (listing the VM name/ID/path, retained disk paths, checkpoint count and whether an export was performed) is written next to the audit log **before** `Remove-VM` is called, and its `RemovedUtc` field is filled in only after Hyper-V confirms the VM is gone. The strong `DELETE VM <name> <ID prefix>` confirmation is required. After removal, the manager reports the retained disk paths from the preview; use Hyper-V Manager or File Explorer to purge them yourself once you are sure they are not needed.

## Intentionally not included

No guest OS installation, VM clone/import, virtual disk resizing or guest partition changes, virtual switch creation, OS activation/licensing, remote hosts, automatic login, guest provisioning or dotfiles execution, guest result collection, or automatic checkpoint pruning. VM deletion (option `12`) is implemented through the Hyper-V API and retains virtual disk files; purging those retained disk files is still out of scope for this tool. `-PermissionProfile PrivateFiles` is Windows-ACL-only (`icacls`); an equivalent chmod-style permission profile for a Linux guest destination/source is future work, not implemented here.

## Linux file transfer: SFTP backend design decision

Linux-guest file transfer is implemented with the Windows-bundled OpenSSH client (`ssh.exe`/`sftp.exe`), confirmed present and functional on a representative host at version `9.5.6.4`. `Get-LabSshToolingInfo` is the runtime check this plan uses to detect that tooling; the manager reports a clear, actionable error (not a cryptic process-launch failure) when `ssh.exe`/`sftp.exe` cannot be resolved.

This task's investigation produced two empirical findings, recorded here as fact rather than speculation. `ControlMaster`/`ControlPath`/`ControlPersist` failed with `getsockname failed: Not a socket` against both a non-routable address and `127.0.0.1` — this connection-sharing mechanism is not used anywhere in this plan. A plain invocation with no connection-sharing flags, by contrast, worked correctly end-to-end (clean key-based authentication, a clean "subsystem request failed" error against a host with no SFTP subsystem, no hangs) — this plan's entire design rests on plain, self-contained process invocations instead of `ControlMaster`.

Those findings produce a two-mode authentication design: `-o BatchMode=yes` plus a configured identity file for noninteractive/key-based transfers (never prompts; fails cleanly without a usable key), and a plain invocation with full console inheritance (no `BatchMode`) for an interactive, first-time password-authenticated connection, so OpenSSH's own native password and host-key-trust prompts reach the operator directly.

**Directory-merge-into-existing-destination limitation** (restated from the Global Constraints): `sftp`'s batch vocabulary has no recursive delete and no built-in tree-merge primitive, and OpenSSH's own documented behavior for nested symlinks under `put -r`/`get -r` is not independently verified by this plan without a live guest. See `MANUAL-TESTS.md` for the specific live-verification step this gap requires before the limitation note can be removed or narrowed in a future version.

## SSH connection test and known-host trust

`Test-LabSshConnection` is the minimal guest-console-setup verification the issue asks for before any Linux file transfer is attempted: it requires an SSH connection already saved for the VM (`Get-LabSshConnectionSettings`; otherwise it reports "not configured, use Configure SSH connection first" and attempts nothing), requires the VM to be `Running`, then runs a trivial one-line `pwd` batch through `Invoke-LabSftpCommand` and reports success or failure. A reachable guest **SSH server** is required, not merely an installed SSH client — the two are different packages on most Linux distributions, and only the server accepts incoming connections. A socket-activated SSH server (one started on-demand by the guest's init system on the first incoming connection, rather than kept running continuously) satisfies this requirement equally well; the connection test's own first attempt is exactly what triggers that on-demand start.

`Resolve-LabSshAuthMode` picks between the two authentication modes from the saved connection settings: `KeyAgent` (batch, non-interactive) when an identity file is configured, `InteractivePassword` (full console, real OpenSSH prompts) otherwise. `Invoke-LabSftpCommand` is the single integration point all real SFTP operations route through, including the connection test and every later transfer; it checks `Get-LabSshToolingInfo` first and throws a clear error naming `ssh.exe`/`sftp.exe` if the OpenSSH client tooling is missing.

**Password login disabled on the guest:** if the guest only accepts key-based SSH authentication (or you intend to use `KeyAgent` mode from the start), the operator establishes trust before ever attempting a `KeyAgent`-mode connection, by adding their public key to the guest's `~/.ssh/authorized_keys` through the existing guest console (or whatever provisioning already placed files there). This manager never edits `authorized_keys` itself, on the guest or otherwise, as a side effect of any configuration or transfer action — that file is entirely the operator's and the guest's own responsibility.

**Changed host key:** if the guest's host key changes (reinstall, restored snapshot, etc.), `StrictHostKeyChecking=yes` means every connection attempt fails until the stale entry is cleared. `Update-LabSshKnownHost` handles that: it previews the exact host:port entry about to be cleared, requires the strong `UPDATE KNOWN HOST <host>` confirmation, and only then runs `ssh-keygen.exe -R` (bracket notation, `[host]:port`, for a non-default port; plain `host` for the default port 22) to remove the stale entry from the operator's own `~/.ssh/known_hosts` — it never edits that file directly. The very next connection attempt (interactive, so the real OpenSSH host-key-trust prompt reaches the operator) re-establishes trust in the new key.

## Linux transfer engine (SFTP)

`Copy-LabTransferItemSftp` is the Linux counterpart of the PowerShell Direct engine and returns the same summary (`Completed`, `Skipped`, `Failed`, `BytesTransferred`, `Errors`). It uses the same `Error`/`Skip`/`Overwrite` conflict rules, and it decides every conflict before any data moves. Every connection goes through `Invoke-LabSftpCommand` or `Invoke-LabSshCommand`. Both apply the same flags for the selected auth mode: `StrictHostKeyChecking=yes` always, and `BatchMode=yes` only in `KeyAgent` mode. Both also check that the OpenSSH client is installed first. A connection-level failure (OpenSSH exit code `255`: unreachable, refused, authentication or host-key failure, or a dropped connection) stops the transfer with an error that states the counts reached so far. A command that fails inside a working session only fails that item.

- **Upfront check.** The source and destination are inspected before anything is copied. In `KeyAgent` mode, this is an `ls -la` of the guest-side path's parent directory. The parent is listed rather than the path itself because `sftp`'s `ls` of a symlink to a directory silently lists the target's contents. That listing counts as "destination absent" only when it is positively recognized. The parent's own `.` entry must parse, and no unrecognized line may end in the destination's name. Otherwise, for example with an unexpected date format or a device node, the item fails instead of risking an overwrite. In `InteractivePassword` mode, no output can be read, because the console belongs to the operator. Instead, one `ssh` call runs a shell `if [ -L … ]; elif [ -d … ] …` test, and the guest reports the result through its exit code. A symbolic link, either as the source or as the destination, is refused and never followed. So is any other non-regular file.
- **Single-file upload.** The upload uses two separate `sftp` batches. The first batch uploads to a `<destination>.labxfer-<id>.tmp` sibling. In `KeyAgent` mode, the same session also lists that temporary copy. The size is then checked, plus SHA-256 with `-VerifyHash`. Only after those checks pass does the second batch (`rm` the old file for `Overwrite`, then `rename`) put the copy at the real destination. A single batch could not do this, because every command in it runs before any of its output can be checked. If a check fails, the temporary copy is removed and the destination is left untouched. `Overwrite` uses an explicit `rm` before the `rename`. That is the portable choice: servers with the `posix-rename@openssh.com` extension could replace the file in a single step, but that cannot be relied on without testing the guest.
- **Single-file download.** The file lands as a temporary sibling on this host and is checked there. It is then moved into place with the same delete-then-move finalize that the Windows engine uses on the host.
- **Directories.** A directory is copied only when the destination does not exist yet. An existing destination directory fails with the documented "not supported in this version" message, whatever `-OnConflict` says. A fresh directory is copied with one `put -r`/`get -r` into a temporary sibling directory, followed by one `rename` (or host-side move) of the whole tree, so the tree lands all at once or not at all. It counts as one item in `Completed`. `BytesTransferred` is measured from the host-side tree, not parsed from `sftp`'s progress output. `-VerifyHash` is not applied to the files inside a recursive Linux transfer in this version, and the engine prints a warning saying so. Before an upload, the host-side source tree is scanned, and any junction or symlink inside it refuses the whole upload. A downloaded tree is scanned in the same way before it is moved into place.
- **Paths.** Guest-side paths must be absolute POSIX paths without empty, `.` or `..` segments. Host-side paths must be absolute drive-letter paths. They are passed to `sftp.exe` with forward slashes. Characters that `sftp` treats specially even inside quotes are rejected rather than escaped: `"`, a backslash on the guest side, `*`, `?`, `[`, `]`, `{`, `}`, and control characters.
- **Missing parent directories.** As in the Windows engine, missing parent directories above the destination are created on either side. Only the contiguous run of missing directories directly above the destination is created, never one that already exists. On the guest, they are found during the upfront check: in `InteractivePassword` mode inside the same `ssh` call, and in `KeyAgent` mode with one extra listing per missing level. They are then created by `mkdir` lines at the start of the payload batch itself. On the host, they are created with `CreateDirectory` just before the download. If the transfer fails, only the directories that this transfer created are removed, deepest first, and only while they are empty: `rmdir` on the guest, and a non-recursive delete on the host. This cleanup is best-effort. If the nearest existing ancestor is not a directory, the item fails before anything is written. A dry run reports how many parent directories it would create.

**Password prompts.** Every connection is a separate process, because connection sharing is not available (see the design decision above). In `KeyAgent` mode this costs only time. In `InteractivePassword` mode, each connection asks for the password again:

| Transfer | Password prompts |
|---|---|
| Single-file upload | Up to 4: upfront check, upload, size/SHA-256 check, finalize |
| Single-file download | 3: upfront check, download, size/SHA-256 check |
| Directory | 2: upfront check, copy |
| Cleanup after a failed single-file upload | 1 more, plus 1 if the upload created guest-side parent directories |
| Cleanup after a failed directory upload that created guest-side parent directories | 1 more |

This is the cost of checking every copy before it replaces anything, and it is accepted on purpose.

**Guest requirements:**

- An SSH server with the SFTP subsystem enabled.
- For `-VerifyHash`, and for any transfer in `InteractivePassword` mode: shell access for the account. An `sftp`-only account (for example `ForceCommand internal-sftp`) is not enough. The account also needs a POSIX-compatible login shell (`sh`, `bash`, `dash`, `zsh`; not `fish` or `csh`).
- **`sha256sum`** (GNU coreutils or BusyBox) on the guest for `-VerifyHash`. The guest computes the hash and compares it with the host's own `Get-FileHash`. If `sha256sum` is missing, the item fails with a message saying so.
- `stat -c %s` on the guest for the size check in `InteractivePassword` mode.

**Known limitations:**

- A failed recursive upload can leave a partial `*.labxfer-*.tmp` directory tree on the guest. `sftp` has no recursive delete, so the engine cannot remove the tree. The failure message names it so you can delete it by hand. This is the same kind of accepted gap as the Windows engine's leftover temporary item after a lost connection.
- After a lost connection, a temporary item may remain on either side.
- `Overwrite` is `rm` then `rename`, so there is a short window in which the destination does not exist. If the `rename` then fails, the verified temporary copy is kept and named in the error, because it may be the only copy left.
- The conflict check happens before the copy, so a file that someone else creates at the destination in between is not seen by it. On servers whose `rename` replaces an existing file, the final `rename` would then replace that file.
- In `KeyAgent` mode, a guest parent directory that cannot be listed fails the upfront check. So does a listing whose line format is not recognized. Nothing is copied in either case.
- Parent-directory cleanup removes only directories that the upfront check found missing. If someone else creates one of them, empty, between that check and this transfer's `mkdir`, the cleanup after a failure may remove it. A lost connection skips the guest-side cleanup entirely.
- What OpenSSH's `get -r` does with a symlink nested inside a guest-side tree (follow it, skip it, or fail) has not been verified without a live guest. See `MANUAL-TESTS.md`, "Linux transfer engine".

## Primary references

- Microsoft: Using checkpoints — https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/checkpoints
- Microsoft: Set-VM — https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vm
- Microsoft: InitiateShutdown — https://learn.microsoft.com/en-us/windows/win32/hyperv_v2/msvm-shutdowncomponent-initiateshutdown
- Microsoft: Stop-VM — https://learn.microsoft.com/en-us/powershell/module/hyper-v/stop-vm
- Microsoft: Export-VM — https://learn.microsoft.com/en-us/powershell/module/hyper-v/export-vm
- Microsoft: Remove-VM — https://learn.microsoft.com/en-us/powershell/module/hyper-v/remove-vm
- Microsoft: Execution policies — https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies
