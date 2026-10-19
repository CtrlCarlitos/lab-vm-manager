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
- Enter an out-of-range or non-numeric vCPU count (0, negative, text, or above the host's logical processor count): it must be rejected with a re-prompt.
- Enter an invalid memory spec: for dynamic memory, minimum greater than startup, or startup greater than maximum, or a value not a multiple of 2MB; for static memory, a zero/negative startup value. Each must be rejected with a re-prompt.
- Reach the preview screen and cancel at the `CREATE <name>` confirmation (type anything else, or press Enter): verify no VM, folder or VHDX was created, and that the audit log has no `create-vm` `STARTED` entry for this attempt.
- Complete a create with valid inputs: verify the new VM appears in the next inventory refresh, is Generation 2, has Standard checkpoint policy with automatic checkpoints disabled, has the requested vCPU/memory, and its VHDX is attached. Verify `create-vm` `STARTED`/`COMPLETED` audit entries exist with the new VM's ID. Also inspect the on-disk folder structure under the VM storage path (`<storage root>\<name>\...`) in File Explorer or Hyper-V Manager: confirm it matches expectations and is not unexpectedly double-nested (e.g. an extra `<name>\<name>\Virtual Machines\...` layer created by Hyper-V under the already name-qualified path).
- Repeat creation using the same name and storage root as a prior successful create: it must be rejected before any Hyper-V call because the dedicated VM/VHDX destination already exists.
- Choose "Disconnected" for the switch: verify the new VM's network adapter has no switch attached.

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
- Delete test VMs/exports manually only after confirming they are disposable and no longer needed; the script does not provide VM/disk deletion.
