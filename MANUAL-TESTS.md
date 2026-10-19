# Hyper-V acceptance checklist

**Status: partially exercised live** — the "Before mutation" checks and disposable-baseline checkpoint creation have been run against real `LAB-*` VMs; restore, rename, deletion, export, concurrency and shutdown-failure sections below have not yet been walked end-to-end. Use one disposable `LAB-*` VM with no valuable data. Do not use production, domain-controller, shared-disk, or customer VMs. Record host/guest OS versions and the Hyper-V module version alongside the audit log.

## Before mutation

- Run `Test-LabVM.ps1` in Windows PowerShell 5.1. It must parse the full manager and pass the helper checks.
- Run the manager without elevation: it must refuse VM operations with a useful message.
- Run `-ReadOnly`. Confirm only LAB-prefixed VMs appear, including lowercase `lab-` names. Non-LAB VMs must not be offered.
- Confirm selecting invalid numbers or letters does not start any VM action.
- Select one VM, inspect details and list checkpoints. Try a changing operation in read-only mode: it must be blocked.
- Confirm R refreshes immediately, B returns to the VM list, and Q exits.
- Confirm the host audit file exists outside the guest.

## Create VM

- Run `-ReadOnly`. Confirm the VM list prompt does not offer `N`, including when the inventory is empty, and that typing `N` is not treated as a create request.
- Run normally with no `LAB-*` VMs present (or a filtered view). Confirm the empty-inventory message mentions `N` and that choosing `N` starts the create workflow.
- Start a create, enter a name that does not start with `LAB-`: it must be rejected with a re-prompt, not accepted.
- Start a create, enter a name matching an existing VM (case-insensitive): it must be rejected with a re-prompt.
- Start a create, enter names containing `\`, `/`, `:`, `*` or `?` (e.g. `LAB-a\..\b`): each must be rejected with a re-prompt.
- At the VM storage root and VHDX storage root prompts, enter a relative path (e.g. `VMs`), a UNC path (e.g. `\\server\share`) and, if available, a mapped network drive: each must be rejected with a re-prompt.
- Cancel a create at any prompt, then confirm the VM list redraws normally and selecting an existing VM and running an operation (e.g. option 1) still works in the same session.
- Enter an out-of-range or non-numeric vCPU count (0, negative, text, or above the host's logical processor count): it must be rejected with a re-prompt.
- Enter an invalid memory spec: for dynamic memory, minimum greater than startup, or startup greater than maximum, or a value not a multiple of 2MB; for static memory, a zero/negative startup value. Each must be rejected with a re-prompt.
- Reach the preview screen and cancel at the `CREATE <name>` confirmation (type anything else, or press Enter): verify no VM, folder or VHDX was created, and that the audit log has no `create-vm` `STARTED` entry for this attempt.
- Complete a create with valid inputs: verify the new VM appears in the next inventory refresh, is Generation 2, has Standard checkpoint policy with automatic checkpoints disabled, has the requested vCPU/memory, and its VHDX is attached. Verify `create-vm` `STARTED`/`COMPLETED` audit entries exist with the new VM's ID. Also inspect the on-disk folder structure under the VM storage path (`<storage root>\<name>\...`) in File Explorer or Hyper-V Manager: confirm it matches expectations and is not unexpectedly double-nested (e.g. an extra `<name>\<name>\Virtual Machines\...` layer created by Hyper-V under the already name-qualified path).
- Repeat creation using the same name and storage root as a prior successful create: it must be rejected before any Hyper-V call because the dedicated VM/VHDX destination already exists.
- Choose "Disconnected" for the switch: verify the new VM's network adapter has no switch attached.

## Edit VM settings

- Select a disposable VM while it is Running or Saved; choose option 11: it must refuse with a message requiring Off, and make no change.
- Shut down normally, then choose option 11. Verify every prompt shows the VM's current value (name, notes, vCPU count, dynamic/static memory, min/startup/max bytes, current switch or Disconnected) and that pressing Enter on every prompt keeps that field unchanged.
- Repeat with every field left blank through to the diff screen: it must report no changes and return without a confirmation prompt or any audit `COMPLETED` entry. Do this on a static-memory VM too (one whose stored minimum/maximum differ from its startup memory, e.g. Hyper-V's 512MB/1TB defaults): it must still report no changes.
- Change only the casing of the name (e.g. `LAB-Test` to `LAB-test`): it must be shown as a Name change and require the `EDIT <name>` confirmation, not be treated as no change.
- Enter a new name that does not start with `LAB-`, or that matches another existing VM's name (case-insensitive): it must be rejected with a re-prompt, not accepted.
- Change only the vCPU count to a valid new value, confirm with the exact `EDIT <name>` phrase, and verify the diff screen listed only that field. After completion, confirm the new vCPU count in Hyper-V Manager or option 1, and that notes/memory/switch are unchanged.
- Change the memory spec to an invalid combination (e.g. minimum greater than startup under dynamic memory): it must be rejected with a re-prompt, not applied.
- Change the network switch selection to a different existing switch, then to "Disconnected": verify the adapter's switch updates to match each choice.
- Cancel at the final `EDIT <name>` confirmation after making a change: verify no setting was altered and no `COMPLETED` audit entry was written for this attempt.
- If the VM has more than one network adapter, confirm the tool states which adapter it manages and leaves the others untouched.

## Disposable baseline

- Shut down the guest normally. Select option 10 and cancel the confirmation: policy must not change.
- Confirm option 10; verify Standard policy and automatic checkpoints disabled.
- Create checkpoint `acceptance-baseline`. Verify its full ID appears in inventory.
- Try the same name again: it must be rejected without replacing anything.
- Start the VM. Attempt checkpoint creation while Running: it must refuse.
- Save a harmless marker file inside the guest, and a separate marker outside the guest on the host.
- Request graceful shutdown. Verify Off; verify no hard-power-off command appears in the log.

## Restore cancellation and safety

- Choose restore, select `acceptance-baseline`, cancel at the safety prompt. No checkpoint or restore should occur.
- Repeat; accept safety, but enter the wrong typed confirmation. No checkpoint or restore should occur.
- Repeat with safety enabled and the exact confirmation. Record the newly created safety checkpoint ID.
- After restore, verify no automatic start/resume was issued. Start manually. The guest marker should be absent; the host marker must still exist.
- Shut down. Restore the safety checkpoint and start manually. The guest marker should return.
- To test a failed safety precondition safely, change checkpoint policy away from Standard while Off. Request restore with safety enabled. It must stop before restore because safety checkpoint creation is disallowed. Restore Standard policy afterward.

## Rename and single deletion

- Create two disposable checkpoints, noting parent/child relationships and all IDs.
- Rename one. Its ID should be unchanged, with only the name changed.
- Cancel deletion: inventory should be unchanged.
- Delete only the selected disposable checkpoint. The other checkpoint must remain.
- Confirm no script operation directly deletes disk files. Let Hyper-V finish storage work.
- Test a baseline-looking name such as `10-acceptance-only`; deletion must require `DELETE BASELINE ...`.

## Scope and concurrency

- Start two manager sessions. Keep a changing operation's confirmation prompt open in the first. The second must refuse an operation on the same VM because of the per-VM mutex.
- Cancel the first; the second should then work. A different LAB VM should not share that lock.
- On an otherwise idle disposable VM, select it in the manager, then rename it out of LAB scope using Hyper-V Manager. The next manager refresh/operation must reject it, not select another VM with a similar name. Rename it back afterward.
- Do not use this rename test during a live checkpoint/export action; the mutex does not control Hyper-V Manager.

## Shutdown failure

- Use a disposable guest that cannot accept graceful shutdown, such as one without enabled shutdown integration. Request normal shutdown. The script must stop with an error or timeout, never hard-power-off automatically.
- Confirm timeout output says the request may still finish and requires inspection before retrying.
- Emergency power-off is optional to test and destructive. Test only on a fully disposable guest after saving all relevant work; exact confirmation is required. Recover the guest before taking another clean baseline.

## Export

- Select an existing local export root. Cancel: no export folder should be created.
- Complete an export of the Off VM. Verify a unique export subfolder, VMCX configuration, virtual disks where applicable, and `COMPLETE` manifest.
- Repeat to the same root: the earlier export must not be overwritten.
- Preserve any failed export and confirm the manifest is INCOMPLETE or IN_PROGRESS, not trusted COMPLETE.
- Import a COPY using Hyper-V Manager's copy/new-unique-ID option into an isolated test location. Do not start both copies on a sensitive network with duplicate guest identity. Validate actual boot/recovery before trusting the export as a backup.
- Delete test VMs/exports manually only after confirming they are disposable and no longer needed, or use option 12 (see "Delete VM" below) for the VM itself; either way the script never purges virtual disk files on its own.

## Delete VM

- Select a disposable VM, note its removal preview (name, GUID, path, disk paths, checkpoint count), and cancel at the "Export this VM before deletion?" prompt by choosing `C`: verify the VM, its checkpoints and its disk files are all untouched, and that no `delete-vm` audit entry was written.
- Repeat, this time answering `N` to skip the export, then cancel at the final `DELETE VM <name> <ID prefix>` confirmation (type anything else, or press Enter): verify nothing changed and no removal manifest was written.
- Create a non-Standard (recovery/backup) checkpoint on a disposable VM — for example via a backup application, or `Checkpoint-VM -SnapshotType ... ` outside this tool — and attempt option 12: verify it refuses immediately with a message about unresolved recovery/backup checkpoints, before any export/confirmation prompt, and that the VM is unaffected. Remove that checkpoint afterward.
- On a VM with only Standard checkpoints (or none), choose option 12, answer `Y` to export, and complete the export normally: verify the export reaches `COMPLETE`, then the removal preview is re-shown, and the final `DELETE VM <name> <ID prefix>` confirmation is required before anything is removed.
- Type the exact `DELETE VM <name> <ID prefix>` confirmation: verify the VM disappears from Hyper-V Manager/inventory, a `<VM ID>-removal-manifest.json` file exists next to the host audit log with `ExportPerformed: true` and a populated `RemovedUtc`, and the console reports the retained disk paths. Confirm those `.vhdx`/`.avhdx` files are still present on disk at the reported paths.
- After that successful delete, open the host audit log: the final record for this attempt must be `delete-vm-menu` with status `COMPLETED` (carrying the deleted VM's ID/name), not `FAILED_OR_UNCONFIRMED`, and the console must not print an "Operation failed or completion is unconfirmed" warning.
- Repeat on a different disposable VM, this time answering `N` to skip the export, and complete the deletion: verify the removal manifest shows `ExportPerformed: false`, disk files are still retained on disk, and the VM is gone from inventory.
- Start a manager session, select a disposable VM while it is Running or Saved, and choose option 12: verify it refuses with a message requiring Off, and makes no change.
- Confirm no script operation directly deletes `.vhdx`/`.avhdx` files during any of the above; only `Remove-VM` (through the Hyper-V API) is used, never manual file deletion.

## PowerShell Direct connection test

- Select a disposable Windows guest while it is Running, with valid local/domain Windows credentials known. Choose option `T` and enter the correct credentials: verify it reports success and prints the guest's OS version string, and that the session is closed afterward (no leftover `Get-PSSession` entries on the host).
- Repeat with a deliberately wrong password: verify it reports a clear failure message (e.g. an authentication error), never a raw .NET stack trace, and that no session is left open.
- Shut the guest down (`Off`), then choose option `T`: it still prompts for credentials first (per the function's fixed order), but then refuses before opening any PowerShell Direct session, reporting the `Assert-LabVMRunning` message naming the VM's actual state. No session is ever attempted.
- Confirm `-ReadOnly` mode still offers option `T` and that it behaves identically to normal mode (no mutation is possible through this option).

## Transfer engine

Run these against a disposable Running Windows guest once a caller (menu option or parameter mode) is wired to `Copy-LabTransferItem`. Use absolute drive-letter paths on both sides. After every step, confirm no `*.labxfer-*.tmp` file or directory is left next to the destination on either side.

- Large file round trip: create a multi-hundred-MB file on the host (e.g. `fsutil file createnew` and then write random data into it, so it is not all zeros). Copy it to the VM with hash verification on, then copy it back from the VM to a new host path with hash verification on. Both runs must report `Completed = 1` and the correct `BytesTransferred`. `Get-FileHash -Algorithm SHA256` of the original and the round-tripped copy must match. Watch the host `powershell.exe` working set during the copy: it should stay flat, not grow by the file size.
- Single-file conflict: copy a file to a destination path that already exists as a file. With `Error`, the result must be `Failed = 1`, and the existing file must stay unchanged, with its modified time and hash the same as before. With `Skip`, the result must be `Skipped = 1`, again with the file unchanged. With `Overwrite`, the result must be `Completed = 1` and the destination must now hash the same as the source. In the `Error` and `Skip` cases, no temporary file should ever appear, because no copy is attempted.
- Type mismatch: copy a single file to a path that exists as a directory, and copy a directory with recurse to a path that exists as a file. Both must fail under every `OnConflict` value, including `Overwrite`, and nothing at the destination should change.
- Nested directory conflict: build a source tree with at least two levels of subdirectories. Pre-create the destination root containing the same subdirectory path and exactly one colliding file deep inside it, and give that file different content. Run a recursive copy once under each of `Error`, `Skip` and `Overwrite`, re-creating the destination fixture before each run.
  - `Error`: every other file is copied, and the colliding file is reported as a failed item and left unchanged.
  - `Skip`: every other file is copied, and the colliding file is reported as skipped and left unchanged.
  - `Overwrite`: every file is copied, including the colliding one, which now matches the source.
  - Do all of this in both directions (to the VM and from the VM).
- Repeat-copy nesting: run the same recursive copy to the same destination twice in a row. The second run must not create `dest\<source name>\...` nesting. Under `Skip`, every file must be reported as skipped. Under `Error`, every file must be reported as failed. Under `Overwrite`, every file must be replaced in place.
- Reparse points: inside the source directory, create a junction (`cmd /c mklink /J loop <source dir>`) and, if possible, a file symlink. Run a recursive copy. Each link must appear in the summary as a failed item with a "reparse point" message. The other files must still be copied. The destination must not contain the link, its target's contents, or a runaway nested `loop\loop\...` tree. Also pass a junction directly as the source: it must fail with nothing copied.
- Dry run: repeat the nested-conflict case with dry run enabled. The summary must show what would happen, but nothing at the destination may change, and no temporary item may be created on either side.
- Connection loss: start a large recursive copy, then turn the guest off or restart it mid-copy. The operation must stop with a connection error that states the counts reached before the failure. Afterwards, inspect the destination: only fully verified files may be at their real names. Any leftover `*.labxfer-*.tmp` item may remain on the guest, because cleanup cannot run over a lost connection, and can be deleted by hand.

## Copy file/directory to/from VM (menu)

- Select a disposable Running Windows guest. Choose option `13` and cancel by pressing Enter at the source-path prompt: verify nothing is copied, no PowerShell Direct session is opened, and no `copy-to-vm-menu` audit entry with status `COMPLETED` is written. Repeat, this time entering a source path but cancelling (blank) at the destination-path prompt: same result. Repeat again, entering both paths but typing something other than the exact `COPY TO VM <name>` phrase at the final confirmation: verify the audit log shows `CANCELLED`, not `COMPLETED`, and nothing on either side changed. Do all three cancellation points again for option `14` (`FromVM`), using `COPY FROM VM <name>`.
- Successful to-VM transfer: choose option `13`, give a small existing host file as the source and a new path on the guest as the destination, accept the `Error` conflict default and decline hash verification, review the preview (direction, VM name/ID, both resolved paths, recursion, conflict policy, verify-hash), type the exact `COPY TO VM <name>` confirmation, and confirm: the console reports `Completed: 1; Skipped: 0; Failed: 0; ...`, the file now exists on the guest with matching content, and the audit log's `copy-to-vm-menu` entry is `COMPLETED`.
- Successful from-VM transfer: choose option `14` with a small existing file on the guest as the source and a new host path as the destination, confirm with `COPY FROM VM <name>`: the console reports `Completed: 1`, the file now exists on the host with matching content, and the audit log's `copy-from-vm-menu` entry is `COMPLETED`.
- Directory source: point option `13` or `14` at a directory. Verify you are asked whether to copy recursively (and only then); answering `N` and proceeding should report the expected `Failed = 1` "use a recursive transfer" error from the engine, still surfaced as a console warning, with the operation still reported as `COMPLETED` overall (not `CANCELLED`) once you pass the final confirmation.
- Conflict policy selection: at the "Conflict policy number" prompt, confirm only the three listed numbers (`Error`/`Skip`/`Overwrite`) are accepted — typing free text (e.g. `Overwrite` spelled out, or an invalid number) must be rejected with a re-prompt, never passed through as-is.
- Read-only mode: start the manager with `-ReadOnly`, select a Running guest, and choose option `13` (or `14`): verify the menu still offers the option and lets you proceed through all prompts and the confirmation (unlike other mutating options, which are hidden/blocked by the generic read-only warning), but the actual copy is refused — the console reports `Failed: 1` with the "Read-only mode: a real file copy is blocked under -ReadOnly" message from `Invoke-LabFileTransfer` itself, not `Invoke-LabAction`'s generic read-only warning. Confirm the audit log entry for this attempt is `COMPLETED` (reflecting that the operation ran and reported a failure) and that nothing was actually copied on either side.
- Off VM: select a disposable VM that is Off (or Saved/Paused) and choose option `13` or `14`: verify it refuses immediately with the `Assert-LabVMRunning` message naming the VM's actual state, before any path prompt, and that no audit entry beyond `STARTED`/`FAILED_OR_UNCONFIRMED` is written.
