# Windows Unattended Install — Design

## Intent and why

Issue #2 (ISO discovery, media prep, installer launch) was split into three sequential plans. Plan 1 (Foundation, merged) gets a VM to "Off, boot-profiled, media-attached" and stops there — no OS install happens. This is Plan 2: take a freshly created, boot-profiled VM all the way to a logged-in, ready-to-use Windows desktop, with zero manual interaction at any point, driven by a single new menu action.

The underlying goal (stated earlier, for the whole issue #2 effort): "spin, run, use, discard." Fresh installs every time, not checkpoint-revert. Once the VM is up with its account ready, the operator (or an AI driving this tool) copies in SSH keys, `chezmoi.toml`, etc. using the already-shipped file-transfer tooling — that stays a separate, manual step, out of scope here.

Plan 3 (Linux unattended install) follows this one and is not started.

## Goals

- A single new menu action creates a VM and drives it, unattended, to a logged-in Windows desktop with a known local admin account — no console interaction at any point, including the Hyper-V Gen2 "Press any key to boot from CD or DVD" prompt.
- Every setting that has a value (computer name, locale, timezone, disk size, edition, credentials) is a parameter with a sensible default — nothing hardcoded — so the same action works identically from the interactive menu and from a scripted/AI-driven caller.
- The tool knows, for certain, when the install is actually done — not a guess — and tells the operator plainly while it waits (this runs in the foreground; it's a synchronous console script, not a background service).
- Once done, a small note is left on the new account's desktop summarizing what was built (ISO, edition, VM name, boot profile, timing).
- Reuses Plan 1's building blocks (`Select-LabIsoPath`, `Set-LabVMBootProfile`, `New-LabSeedIso`, `Set-LabVMInstallMedia`, workspace helpers) rather than duplicating them.

## Non-goals

- Domain join, telemetry/privacy-setting customization beyond what's needed to skip OOBE prompts, Windows activation/product keys.
- A generic N-drive media manager — this plan only needs exactly two DVD drives (installer + seed), not an arbitrary number.
- Copying SSH keys, dotfiles, or any other post-login content — that's the existing, separate file-transfer tooling, used manually afterward.
- A background-job/async execution model. The action blocks in the foreground and shows progress; running several VMs at once means running the script in several terminals (already possible — this tool already locks per VM).

## Anti-goals

- Anything that makes "press any key" silently fail to go away and leave the operator staring at a hung VM with no explanation.
- Guessing at "is it done" via timing/heartbeat alone — the completion signal must be the real thing (a working login), not an approximation.
- Hardcoding a single Windows edition when a source ISO actually offers several.

## Already proven (this session, live, on this host)

- **The boot-loader fix needs no ADK, no ISO rebuild, no elevation.** On the real ISO at `E:\ISO\Windows11_Client_x64_en-us_26300_9457.iso`, `\efi\microsoft\boot\efisys.bin` and `efisys_noprompt.bin` are the exact same size (1,474,560 bytes). The El Torito boot catalog (Boot Record Volume Descriptor at sector 17 → catalog at sector 22 → EFI no-emulation entry → load RBA sector 536, byte offset 1,097,728) was parsed by hand and confirmed to point exactly at `efisys.bin`'s own bytes. Copying the whole ISO and overwriting only that byte range with `efisys_noprompt.bin`'s content leaves everything else — including the catalog itself — byte-identical. `cdboot.efi` does not need touching; the prompt lives inside the small FAT image `efisys.bin` carries, which is what firmware actually boots from.
  - **Not yet proven:** nobody in this development session has elevated Hyper-V access, so the patched ISO has never actually been booted. Before this ships, the operator must do one live boot test (same style as the original issue #2 live proof) — this is the first manual-test item for this plan, not an assumption to build on blind.
  - **Caveat to design around:** not every Windows ISO necessarily ships both the prompt and no-prompt variants. The tool must detect whether `efisys_noprompt.bin` exists on the chosen source ISO; if it doesn't, warn clearly and proceed without the fix (or refuse that specific capability) rather than failing opaquely.
  - A patched ISO is a new, separate file — the original source ISO is never modified, and the patched copy lives in the per-VM provisioning workspace (never under `-IsoRoot`), reusing Plan 1's `Get-LabProvisioningWorkspacePath`/`Remove-LabProvisioningWorkspace`. It is multi-gigabyte (a full copy of the source ISO), so workspace cleanup matters here more than it did for Plan 1's small seed ISOs.
- **Editions inside a multi-edition install image can be listed with in-box tooling.** Windows client ships the `Dism` PowerShell module; `Get-WindowsImage -ImagePath <mounted ISO>\sources\install.wim` (or `.esd`) lists each edition's name and index with no ADK involved.
- **PowerShell Direct** (`New-PSSession -VMId <guid> -Credential <cred>` / `Invoke-Command -VMId`) connects into a Windows guest over the Hyper-V VMBus using only the account's credentials — no network/IP address required, no WinRM configuration needed on the guest. This is the real completion signal for this plan (see below) and was confirmed to exist and work this way via Microsoft's own documentation of the feature; not yet exercised against a real guest in this session (same elevation gap as above).

## Decided, as decided

- **The new action creates the VM and provisions it in one continuous flow** — this is "create and provision," the new, separate menu action already agreed during Plan 1's design (not an extension of `N`, which stays a generic blank-VM creator; not the same as `M`, which stays the manual/interactive-install-media action). It reuses `New-LabVMCore` for VM creation and Plan 1's boot-profile/media/seed-ISO functions for preparation, then adds everything below.
- **Two DVD drives, not a generic N-drive manager.** Drive 1: the (patched) Windows installer ISO, first in boot order. Drive 2: a small seed ISO (via `New-LabSeedIso`) carrying `Autounattend.xml` at its root — Windows Setup discovers it there by scanning attached media, it does not need to be a boot device itself and is not added to the firmware boot order.
- **Completion detection is a real signal, not a guess:** the action polls for a working PowerShell Direct session into the guest using the exact credentials set in the answer file. Success means the account genuinely works — that's "done." This was chosen over watching for Hyper-V's heartbeat integration service (which goes green as soon as Windows is merely running, including mid-Setup, so it can't distinguish "installing" from "ready") and over a pure elapsed-time/quiet-period guess (which can't tell "slow" from "stuck").
- **The completion note is delivered by the host, after the first successful PowerShell Direct session** — not written by a `FirstLogonCommand` inside the guest. The host has the richer information (which ISO, how long it took, the boot profile actually applied) and PowerShell Direct makes delivering a file straightforward once connected.
- **AutoLogon is configured once (`LogonCount=1`)** purely to guarantee OOBE actually completes with zero interaction (so Setup doesn't stall waiting for someone to click through a final sign-in screen) — not left as a standing, persistent auto-logon, and not relied on to run any first-logon script, since the note is delivered from the host side instead.
- **Progress while waiting:** the action blocks in the foreground (this script has no background-job model) and shows live progress — elapsed time and periodic status — rather than returning control early. Starting several VMs at once means running the script again in another terminal; the existing per-VM locking already makes that safe.
- **Edition selection is a real picker, not a fixed default.** The chosen ISO's actual editions are enumerated (via `Get-WindowsImage`) and presented the same way `Select-LabIsoPath` presents ISOs — numbered list, pick one — defaulting to "Pro" when present. A `-OsEdition` parameter lets a scripted/AI caller skip the picker entirely.
- **Every configurable value is a parameter with a default, overridable by anyone — operator or AI — not hardcoded:**
  - `-ComputerName` (default `lab-agent-test`)
  - `-Locale` / UI language (default `en-US`)
  - `-TimeZone` (default `Central America Standard Time`)
  - `-VhdxSizeGB` (default `150`, dynamically-expanding)
  - `-OsEdition` (default `Pro`, interactive picker when omitted and the ISO has more than one edition)
  - Username and password: typed interactively by default (never displayed or persisted), overridable via parameters for a scripted/AI caller — same convention already established for the file-transfer tooling.

## Decided, as decided (round 2 — after the builder check)

A fresh builder-check reviewer read this document and flagged five open questions where a wrong guess would cost real rework. Four are settled below, with reasoning, since a competent engineer could make the call; the fifth (ISO scope) genuinely needed the project owner's answer and is recorded under its own heading.

- **The patched ISO stays DVD-first in boot order for the entire install, including every internal reboot Setup performs — this is set once, before the VM is first started, and never touched again.** The alternative (a multi-phase state machine that powers the VM off mid-install to flip the boot order) isn't just more complex, it's not clearly buildable: `Set-VMFirmware`/`Set-VMBootOrder` require the VM to be Off, and there's no reliable host-visible signal for "Setup just did one of its internal reboots" to even trigger that cycle (a guest-initiated restart generally doesn't make Hyper-V report the VM as Off; it just resets the virtual firmware in place). The reasoning for leaving it alone: on every reboot, Hyper-V's firmware tries the DVD device again, which runs the install media's own boot loader — and Windows Setup's boot loader is the thing responsible for noticing "there's a Windows installation already in progress on the attached disk" and chaining into it, rather than restarting the install wizard from scratch (this is the same mechanism that lets PXE/WDS network deployments reboot into the same network boot path repeatedly without re-running the wizard each time). This wasn't found stated outright in any single authoritative source, but it's corroborated by several independent, real community PowerShell scripts and modules (HyperVTools' `New-HyperVImage`, the OSDeploy/OSDCloud module's VM builders) that set the DVD as first boot device once for a Hyper-V Gen2 unattended install and never change it again for the rest of the process, with no reports found of a resulting install-restart loop. **Still not empirically proven in this engagement** — the single live boot test already planned to prove the no-prompt patch works (see "Already proven" above) doubles as the proof for this too, since a real end-to-end unattended install naturally exercises every internal reboot. If that live test ever does show a loop, this is the first thing to revisit.
- **VM hardware (vCPU, memory, virtual switch, VM/VHDX storage roots) is not reinvented here.** This action calls the same `New-LabVMCore` code path `N` already uses, with its existing prompts and defaults, unchanged. This plan only adds parameters for what `N` doesn't already ask about (ISO, edition, computer name, locale, timezone, credentials). Computer name stays its own independent parameter (default `lab-agent-test`), not derived from the VM's own name — confirmed earlier in this conversation.
- **Scripted/AI invocation gets its own top-level mode switch on `Lab-VM.ps1`**, following the exact pattern already established by `-CopyToVM`/`-ConfigureSsh` (a switch that gates its own parameter set, rejected unless present) — not a bare function callers have to dot-source themselves.
- **Cleanup, on success, is a second boot cycle — not something squeezed into the first one.** The moment the first PowerShell Direct login succeeds (proving the install is genuinely done), the VM is shut down once more to: eject and remove the seed DVD drive, eject the patched installer DVD, put boot order back to disk-first, and delete the host-side workspace (patched ISO, seed ISO, the answer file — every copy of the password, gone). Then the VM starts again and the action waits for a second successful login before declaring done and delivering the note — which also doubles as confirmation the VM boots cleanly standalone, with nothing attached. This costs one extra boot (a couple of minutes), in exchange for a VM that's actually clean and secret-free afterward, rather than one still dragging a multi-gigabyte patched ISO and a password-bearing seed ISO around. This matches the "never persisted" intent already stated for credentials — the answer file genuinely has to carry the password for the install to work at all, but it doesn't outlive the install.
  - **On failure or timeout:** the VM is left exactly as it is for inspection — no automatic power-off, media changes, or deletion, since forcing changes into a VM that may be mid-install risks making a real problem worse and destroys the operator's ability to see what went wrong. The host-side workspace (which does hold the password) is not silently deleted either, since the answer file itself may be needed to debug the failure — but the error output says plainly that it contains sensitive material and names its path, so it's an informed, visible decision rather than a forgotten one. It's cleaned up normally on the next retry or explicit discard.

## Windows version scope

**Windows 11 client only** — matching what's actually in `E:\ISO` today. Windows 10 and Windows Server are explicitly out of scope for this plan (Server has a materially different OOBE and generally needs a product key even on evaluation media; Windows 10 doesn't need vTPM at all — either would need its own answer-file variant and real design work, not a tweak).

**The tool detects and refuses an out-of-scope ISO clearly, rather than letting it fail wherever it happens to fail.** Consistent with this project's existing fail-loud-not-silent pattern (e.g. Plan 1's `Set-LabVMBootOrder` throwing instead of silently no-op'ing). The check happens before anything is built or attached, using the same `Get-WindowsImage` read this plan already needs for edition enumeration.

## What's left to the builder

- Exact `Autounattend.xml` structure (windowsPE/specialize/oobeSystem passes, exact component names and settings needed to skip every OOBE prompt given the decisions above) — the plan should pin the literal XML shape, informed by Microsoft's documented unattend schema.
- Exact mechanics of the in-place `efisys.bin` byte-swap as a reusable function (presence-check for the no-prompt variant, the patched-copy workspace path, error behavior when absent).
- Exact `Get-WindowsImage` invocation and how the chosen index/name feeds `Autounattend.xml`'s image-selection metadata.
- The PowerShell Direct polling loop's shape: retry interval, what counts as "still waiting" versus "something is actually wrong" (a bounded overall timeout with a clear error, consistent with this codebase's existing patterns), and exactly what the progress display looks like.
- The completion note's exact content and the mechanics of writing it onto the new account's desktop over a PowerShell Direct session.
- Whether any part of this (the PowerShell Direct completion check, the progress-display shape) is written generically enough for Plan 3 (Linux) to share, versus being Windows-specific — Plan 3 will reuse the already-shipped SSH tooling for its own completion check, so this is likely parallel-but-separate code, not shared code; the builder should not force a shared abstraction that doesn't actually fit both OSes.
