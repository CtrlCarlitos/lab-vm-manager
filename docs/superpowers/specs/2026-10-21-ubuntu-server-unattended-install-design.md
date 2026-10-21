# Ubuntu Server Unattended Install — Design

## Intent and why

Issue #14 (filed from this same session): the Server peer of the just-merged Ubuntu Desktop unattended-install feature (Plan 3 / issue #2's part D). Carlos's dotfiles-testing workflow needs four always-available baseline guests — Ubuntu Desktop, Ubuntu Server, Windows Home, Windows Pro. Desktop/Home/Pro are built and live-proven; Server is the missing one.

Unlike Plan 3, this plan starts with the live-testing lessons already in hand, not as open risks: Plan 3's live debugging session found and fixed five real bugs in shared, OS-agnostic code (seed-ISO filesystem type, boot order after a self-ejecting installer, KVP/ARP address discovery, SFTP identity restriction, and finding the installer drive by elimination after self-eject). None of that is Desktop-specific — it already applies to this plan for free, because it lives in functions this plan reuses unchanged. This plan's own new risk surface is much smaller: mainly, whether Ubuntu Server's autoinstall/boot specifics (verified read-only against the real ISO below) hold up once actually booted, which no one has done yet.

## Goals

- A single new menu action + CLI switch creates a VM and drives it, unattended, to a running Ubuntu Server with a known local account and a working SSH server — no console interaction at any point, including GRUB's menu.
- Reuse every piece of Plan 3's machinery that isn't genuinely Desktop-specific, rather than forking a parallel copy. Most of Plan 3's functions have no Desktop-specific logic in their bodies at all (see "Already proven" below) — they just have Desktop-flavored names and are called from Desktop-only orchestration code today.
- Same "every setting is a defaulted parameter" convention as Plans 2 and 3.

## Non-goals

- Any Linux distribution or Ubuntu release other than this one ISO's Server image (`ubuntu-26.04.1-live-server-amd64.iso`) — same scope discipline as Plan 3.
- A desktop environment, GUI packages, or anything beyond a bare, SSH-reachable base system (explicitly decided with the project owner: this VM starts bare; dotfiles installs whatever it needs afterward).
- Installing `linux-cloud-tools-virtual` or any other Hyper-V-integration package to try to fix Hyper-V Manager's own IP display. Confirmed on the Desktop VM this session: that package was already present and `hv-kvp-daemon` still never started, because the KVP VMBus channel itself was never offered to the guest (every OTHER util channel — Heartbeat, Shutdown, VSS, TimeSync — came up fine; only KVP's own kernel-side IC-version announcement never appeared). That points at the host side, which nothing installable in the guest can reach. This plan's own address discovery already works around it (see "Already proven").
- Copying SSH keys, dotfiles, or chezmoi files, or running the dotfiles installer — same as Plan 3, a separate piece of work.

## Anti-goals

- Forking near-duplicate copies of functions that have no actual OS-specific logic in them, just to keep a "Linux" vs "Server" naming distinction. Where Plan 3's functions are genuinely generic, this plan calls them directly.
- Anything that leaves GRUB's menu waiting silently for a keypress that will never come (same as Plan 3).
- Guessing "is it done" from anything other than a real, working SSH login (same as Plan 3).

## Already proven (this session, live or read-only against the real ISO, on this host)

- **The ISO9660/Joliet/El Torito layout matches Plan 3's assumptions exactly**, confirmed by directly reading the real `ubuntu-26.04.1-live-server-amd64.iso` with the same byte-level scan `New-LabPatchedBootableLinuxIso` already uses: Primary Volume Descriptor at sector 16, El Torito Boot Record Volume Descriptor at sector 17, Joliet Supplementary Volume Descriptor at sector 18, terminator at sector 19. `New-LabPatchedBootableLinuxIso` needs **no changes** to patch this ISO.
- **`grub.cfg`'s shape is simpler than Desktop's, and still fits the already-shipped patch logic without changes.** Read directly from the real ISO:
  ```
  menuentry "Try or Install Ubuntu Server" {
      set gfxpayload=keep
      linux  /casper/vmlinuz  ---
      initrd /casper/initrd
  }
  ```
  One `linux /casper/vmlinuz` line (Desktop has two: the default entry and a `nomodeset` fallback), with `---` as the very last token on the line and nothing after it. The already-shipped insertion logic (insert ` autoinstall` before the first whitespace-preceded `---`, whether mid-line or at the end — the exact fix Plan 3's final review added) handles this case already; this was true before this plan started, not something this plan has to re-fix.
- **The release string is `Ubuntu-Server 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)`**, read directly from the real ISO's `.disk/info` (same `Mount-DiskImage`/read/dismount mechanism `Get-LabLinuxIsoInfo` already uses). Hyphenated `Ubuntu-Server`, not `Ubuntu Server` — a clean, unambiguous prefix for a new scope check, and one `Get-LabLinuxIsoInfo`'s existing Desktop check already excludes via its own `-notmatch 'Server'` guard (confirmed: Plan 3's existing scope check already correctly refuses this exact ISO for `-ProvisionLinuxVM`, per `MANUAL-TESTS.md`'s already-documented refusal case).
- **Every one of Plan 3's live-debugging fixes lives in code this plan reuses unchanged, with no Desktop-specific logic in it:**
  - `New-LabSeedIso`'s ISO9660 filesystem fix — OS-agnostic, already shipped.
  - `Set-LabVMBootOrder`'s ordered-class-list fix (`@('Dvd', 'Disk')`) — OS-agnostic, already shipped; this plan's own call site just needs to pass the same ordered list, for the same reason (Server's installer also uses casper's own self-eject-before-reboot behavior — not yet confirmed live for Server specifically, but the mechanism that caused Plan 3's bug is casper's, not Desktop's own).
  - `Get-LabGuestAddressCandidates`'s ARP-table fallback — OS-agnostic, already shipped, reused automatically by `Wait-LabSshSession`.
  - `Invoke-LabSftpCommand`'s `IdentitiesOnly=yes` fix for a named identity — OS-agnostic, already shipped, reused automatically by note delivery.
  - `Complete-LabLinuxProvisioning`'s find-the-installer-drive-by-elimination fix — OS-agnostic (nothing in its body reads anything Desktop-specific); this plan can call it directly rather than writing a Server-flavored copy.
  - `New-LabEphemeralSshKeyPair`, `Wait-LabSshSession` (both trust-on-first-connect phases, including the pinned-second-wait closure) — fully OS-agnostic, reused directly.
- **Not yet proven — the actual gaps this plan's own live test has to close:**
  - Whether this ISO's autoinstall actually reaches a finished, SSH-reachable system end to end (the GRUB-patch and release-string checks above are read-only/offline; nobody has booted this ISO yet).
  - Whether Server's installer also self-ejects its own media before its internal reboot the way Desktop's does (the reason Plan 3 needed the `Set-LabVMBootOrder` ordered-list fix at the attach-media call site in the first place). If it doesn't, the existing `@('Dvd', 'Disk')` call is still correct and simply unnecessary insurance, not a defect.
  - Whether `ssh.install-server: true` is still required (i.e., Server doesn't ship `openssh-server` pre-installed either) — assumed true, matching Desktop, until live-tested otherwise.

## Decided, as decided

- **Bare system, no `packages:` list.** Confirmed directly with the project owner, including the specific question of whether a Hyper-V-integration package belongs there (see "Non-goals" above for why the answer is no).
- **Completion note goes in the home directory, not `~/Desktop`.** Server has no desktop environment. Confirmed directly with the project owner. Left to the builder: whether `Write-LabLinuxProvisioningNote` grows a parameter for the destination's remote relative path (Desktop passes `Desktop/lab-vm-manager-provisioning-note.txt`, Server passes `lab-vm-manager-provisioning-note.txt`, with `-mkdir` only ever applied to a path that actually has a directory component) or Server gets its own thin wrapper — an implementation detail, not a design decision, since the function's own SFTP-batch-building logic doesn't otherwise differ.
- **A new, separate switch, `-ProvisionLinuxServerVM`**, not an extension of `-ProvisionLinuxVM` that auto-detects Desktop vs. Server from the ISO. Same precedent Plan 3 itself followed for Windows vs. Linux: separate actions for separate OS flavors, even where the underlying mechanics overlap heavily, so each has its own clear scope-refusal message and its own parameter-gating tier (mirroring `Get-LabLinuxProvisioningOnlyParameter`'s existing pattern).
- **`-ProvisionLinuxServerVM` gets its own, separate ISO/timezone parameters — `-LinuxServerIsoPath` / `-LinuxServerTimeZone` — rather than sharing `-LinuxIsoPath`/`-LinuxTimeZone` with `-ProvisionLinuxVM`.** Confirmed directly with the project owner. This mirrors the existing pattern exactly (every provisioning switch owns its parameter names outright, same as Windows vs. Desktop-Linux today) and requires no change to the existing "this name belongs to exactly one switch" parameter-gating logic that Windows and Desktop-Linux already rely on — a new `Get-LabLinuxServerProvisioningOnlyParameter`-equivalent tier, not a restructuring of an existing one.
- **`Get-LabLinuxIsoInfo` grows a second field, `IsUbuntuServerInScope`, rather than a parallel `Get-LabLinuxServerIsoInfo` function.** It already mounts the ISO and reads `.disk/info` once; computing a second boolean from the same already-read string is strictly cheaper and less error-prone than mounting the same ISO twice through two near-identical functions.
- **`Set-LabVMBootProfile` grows a new accepted value, `'UbuntuServer'`, with the identical Secure Boot template behavior as `'UbuntuDesktop'`** (same signing chain, same `MicrosoftUEFICertificateAuthority` template) — so a Server VM's recorded/displayed boot profile says what it actually is, rather than reusing the Desktop label on a VM that isn't one. **This new value is used only by this plan's own new orchestrator.** The manual install-media flow (menu `M` / `Set-LabVMInstallationMediaInteractive`, `Get-LabVMInstallationMediaPreview`) is not extended to offer it — this plan is specifically about unattended provisioning (per "Goals" above), not a general improvement to hand-driven installs, matching the same scope discipline as every other "Non-goal" in this document. Offering `'UbuntuServer'` from the manual menu too is a trivial, separate follow-up if ever wanted, not part of this plan.
- **Reuse, don't fork, every function listed as OS-agnostic in "Already proven" above.** Only `New-LabLinuxAutoinstallUserData` (or a generalized version of it) and the new orchestrator/CLI surface are genuinely new code.

## Ubuntu Server ISO scope

**Ubuntu Server 26.04.x only** — same discipline, and the same regex shape, as Plan 3's Desktop scope check (`IsUbuntuDesktopInScope`'s actual shipped regex accepts any `26.04.x`, even though its own design doc's prose names the one point release it was tested against). `IsUbuntuServerInScope` follows the identical convention: `-cmatch '^Ubuntu-Server 26\.04(\.\d+)? LTS'`, tested and proven against `ubuntu-26.04.1-live-server-amd64.iso` specifically — the GRUB-patch and release-string checks above are proven against this one ISO, not the whole point-release family, but the scope check's own pattern follows Desktop's established precedent rather than hard-coding `26.04.1`. Refused clearly, before anything is built or attached, the same fail-loud pattern Plans 2 and 3 already established.

## What's left to the builder

- Whether `New-LabLinuxAutoinstallUserData` grows a parameter (e.g. for the completion-note path, and possibly a flag for whether `storage`/`identity`/`ssh` differ at all between Desktop and Server — read-only inspection so far suggests they don't) or Server gets its own near-identical copy. Generalizing the existing function is preferred per the reuse decision above, but the actual autoinstall YAML needed may reveal a real difference once this plan's own live test runs.
- The exact new orchestrator function name and shape (a `Start-LabLinuxServerVMProvisioning` mirroring `Start-LabLinuxVMProvisioning`'s structure, calling the same shared helpers) and its menu letter.
- Whether Server's `ssh.install-server: true` assumption holds, confirmed on this plan's own first live boot test — this plan's version of Plan 3's "not yet proven" items, now narrowed to just this one question instead of five.
- The exact `-ComputerName` default (distinguishing it from Desktop's `lab-agent-test` and Plans 2/3's other defaults) and `-ProvisioningTimeoutSeconds` default (likely shorter than Desktop's, given no desktop-environment packages to install — left to the builder to judge once live-tested, not guessed here).
