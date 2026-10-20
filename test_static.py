"""Source-level checks only; these do not run PowerShell or Hyper-V."""
from pathlib import Path
import re
import unittest

SCRIPT = Path(__file__).with_name('Lab-VM.ps1')

class SourceContract(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.exists(), 'Lab-VM.ps1 has not been implemented')
        self.s = SCRIPT.read_text(encoding='utf-8-sig')

    def test_minimum_powershell(self):
        self.assertIn('#requires -Version 5.1', self.s)
    def test_exact_prefix_guard(self):
        self.assertIn("StartsWith('LAB-', [StringComparison]::OrdinalIgnoreCase)", self.s)
    def test_id_resolution(self):
        self.assertRegex(self.s, r'Get-VM -Id \$VMId')
    def test_off_guard(self):
        self.assertIn('function Assert-LabVMOff', self.s)
    def test_shutdown_is_never_forced(self):
        self.assertIn('Force = $false', self.s)
        self.assertNotRegex(self.s, r'Stop-VM[^\r\n]*-Force')
    def test_no_manual_disk_file_deletion(self):
        for cmd in ['Remove-VMSavedState ', 'Remove-Item ', 'Invoke-Expression ']:
            self.assertNotIn(cmd, self.s)
    def test_no_subtree_delete(self):
        self.assertNotRegex(self.s, r'Remove-VMSnapshot[^\r\n]*-IncludeAllChildSnapshots')
    def test_mutations_use_objects(self):
        for cmd in ['Start-VM', 'Resume-VM', 'Stop-VM', 'Set-VM', 'Checkpoint-VM', 'Export-VM', 'Remove-VM']:
            for line in self.s.splitlines():
                if re.match(r'\s*'+re.escape(cmd)+r'\s', line):
                    self.assertIn('-VM ', line, line)
        for cmd in ['Restore-VMSnapshot', 'Remove-VMSnapshot', 'Rename-VMSnapshot']:
            for line in self.s.splitlines():
                if re.match(r'\s*'+re.escape(cmd)+r'\s', line):
                    self.assertIn('-VMSnapshot ', line, line)
    def test_no_implicit_auto_start_after_restore(self):
        body=self.s.split('function Restore-LabCheckpoint {',1)[1].split('\nfunction ',1)[0]
        self.assertNotIn('Start-VM ',body)
        self.assertNotIn('Resume-VM ',body)
    def test_safety_checkpoint_before_restore(self):
        body=self.s.split('function Restore-LabCheckpoint {',1)[1].split('\nfunction ',1)[0]
        self.assertLess(body.index('New-LabCheckpointCore'),body.index('Restore-VMSnapshot -VMSnapshot'))
    def test_readonly_gate(self):
        self.assertIn('if ($script:LabReadOnly)',self.s)
    def test_mutex(self):
        self.assertIn('Global\\LabVmManager-',self.s)
        self.assertIn('ReleaseMutex()',self.s)
    def test_unique_export(self):
        self.assertIn("'export-manifest.json'",self.s)
        self.assertIn("Status = 'IN_PROGRESS'",self.s)
        self.assertIn("$manifest.Status = 'COMPLETE'",self.s)
        self.assertIn("$manifest.Status = 'INCOMPLETE'",self.s)
    def test_dry_run_does_not_change_execution_policy(self):
        self.assertNotIn('Set-ExecutionPolicy ',self.s)
    def test_type_confirmations(self):
        for token in ['RESTORE ', 'DELETE ', 'POWER OFF ', 'CONFIGURE ']:
            self.assertIn(token,self.s)
    def test_all_named_operations_exist(self):
        for name in ['Get-LabVM','Select-LabVM','Start-LabVM','Stop-LabVMGracefully','New-LabCheckpoint','Restore-LabCheckpoint','Rename-LabCheckpoint','Remove-LabCheckpoint','Export-LabVM','Set-LabCheckpointPolicy','Stop-LabVMPower','Invoke-LabAction','Start-LabVMManager','New-LabVM','Edit-LabVMSettings','Remove-LabVM','Copy-LabVMItemInteractive','Invoke-LabFileTransfer','Configure-LabSshConnectionInteractive','Add-LabSshKnownHost','Update-LabSshKnownHost']:
            self.assertIn('function '+name+' {',self.s)
    def test_host_discovery_functions_exist(self):
        self.assertIn('function Get-LabHostDefaults', self.s)
        self.assertIn('function Get-LabSwitchNames', self.s)
    def test_ssh_tooling_info_function_exists(self):
        self.assertIn('function Get-LabSshToolingInfo', self.s)
    def test_create_vm_blocked_in_readonly(self):
        body = self.s.split('function Select-LabVM {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('-not $script:LabReadOnly', body)
    def test_create_vm_uses_dedicated_directory(self):
        self.assertIn('function New-LabVMCore', self.s)
        self.assertRegex(self.s, r'New-VM[^\r\n]*-Path ')
    def test_create_vm_rejects_existing_destination(self):
        body = self.s.split('function New-LabVMCore {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Test-Path', body)
    def test_create_vm_generation_2_default(self):
        self.assertRegex(self.s, r'New-VM[^\r\n]*-Generation 2')
    def test_create_vm_name_collision_lock(self):
        self.assertIn('LabVmManager-Create-', self.s)
    def test_edit_requires_off(self):
        body = self.s.split('function Edit-LabVMSettings {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Assert-LabVMOff', body)
    def test_edit_rename_preserves_lab_prefix(self):
        body = self.s.split('function Set-LabVMSettingsCore {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Test-LabNewVMName', body)
    def test_edit_no_generation_change(self):
        body = self.s.split('function Set-LabVMSettingsCore {', 1)[1].split('\nfunction ', 1)[0]
        self.assertNotIn('-Generation', body)
    def test_edit_diff_is_pure(self):
        body = self.s.split('function Get-LabSettingsDiff {', 1)[1].split('\nfunction ', 1)[0]
        for cmd in ['Get-VM', 'Set-VM', 'Rename-VM', 'Connect-VMNetworkAdapter', 'Disconnect-VMNetworkAdapter']:
            self.assertNotIn(cmd, body)
    def test_edit_menu_option_eleven(self):
        self.assertIn("'11' { Invoke-LabAction $VMId 'edit-settings-menu' { param($id) Edit-LabVMSettings $id } }", self.s)
    def test_edit_diff_not_double_wrapped(self):
        body = self.s.split('function Edit-LabVMSettings {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('$diff = Get-LabSettingsDiff', body)
        self.assertNotIn('$diff = @(Get-LabSettingsDiff', body)
    def test_delete_requires_off(self):
        body = self.s.split('function Remove-LabVM {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Assert-LabVMOff', body)
    def test_delete_stops_on_nonstandard_checkpoints(self):
        body = self.s.split('function Remove-LabVM {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('HasNonStandardCheckpoints', body)
    def test_delete_offers_export_first(self):
        body = self.s.split('function Remove-LabVM {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Export-LabVM', body)
    def test_delete_uses_remove_vm_object(self):
        self.assertRegex(self.s, r'Remove-VM -VM ')
    def test_delete_strong_confirmation(self):
        self.assertIn('DELETE VM ', self.s)
    def test_delete_manifest_before_removal(self):
        body = self.s.split('function Remove-LabVM {', 1)[1].split('\nfunction ', 1)[0]
        idx_manifest = body.index("'removal-manifest.json'")
        idx_remove = body.index('Remove-VM -VM ')
        self.assertLess(idx_manifest, idx_remove)
    def test_select_vm_discards_new_vm_return(self):
        body = self.s.split('function Select-LabVM {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('$null = New-LabVM', body)
    def test_action_audit_survives_completed_vm_removal(self):
        body = self.s.split('function Invoke-LabAction {', 1)[1].split('\nfunction ', 1)[0]
        self.assertNotIn('Write-LabAudit $Name $status (Get-LabVM $VMId)', body)
        self.assertIn('$finalVm = $vm', body)
        self.assertIn("if ($status -ne 'COMPLETED' -or @(Get-VM -Id $VMId -ErrorAction SilentlyContinue).Count -ne 0)", body)
        self.assertIn('Write-LabAudit $Name $status $finalVm', body)
    def test_edit_static_memory_carries_min_max_forward(self):
        body = self.s.split('function Edit-LabVMSettings {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('$newMinimumBytes = $current.MinimumBytes\n', body.replace('\r\n', '\n'))
        self.assertIn('$newMaximumBytes = $current.MaximumBytes\n', body.replace('\r\n', '\n'))
        self.assertNotIn('$newMinimumBytes = $newStartupBytes', body)
        self.assertNotIn('$newMaximumBytes = $newStartupBytes', body)
    def test_edit_rename_detection_is_case_sensitive(self):
        body = self.s.split('function Edit-LabVMSettings {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('$newName -ceq $current.Name', body)
    def test_settings_diff_name_notes_case_sensitive(self):
        body = self.s.split('function Get-LabSettingsDiff {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('[string]$oldValue -cne [string]$newValue', body)
    def test_create_vm_creates_vhdx_directory_before_new_vhd(self):
        body = self.s.split('function New-LabVMCore {', 1)[1].split('\nfunction ', 1)[0]
        idx_check = body.index('VHDX directory already exists')
        idx_create = body.index('[IO.Directory]::CreateDirectory((Split-Path -Parent $VhdxPath))')
        idx_new_vhd = body.index('New-VHD -Path $VhdxPath')
        self.assertLess(idx_check, idx_create)
        self.assertLess(idx_create, idx_new_vhd)
    def test_new_vm_name_rejects_path_characters(self):
        body = self.s.split('function Test-LabNewVMName {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('\'[\\\\/:*?"<>|\\x00-\\x1F]\'', body)
    def test_create_vm_roots_are_local_absolute_paths(self):
        body = self.s.split('function New-LabVM {', 1)[1].split('\nfunction ', 1)[0]
        for root in ['$storageRoot', '$vhdxRoot']:
            self.assertIn(root + " -notmatch '^[A-Za-z]:\\\\'", body)
            self.assertIn('[IO.DriveInfo]::new([IO.Path]::GetPathRoot(' + root + ')).DriveType -eq [IO.DriveType]::Network', body)
        export = self.s.split('function Export-LabVM {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn("-notmatch '^[A-Za-z]:\\\\'", export)
        self.assertIn('[IO.DriveType]::Network', export)
    def test_set_vm_settings_core_requires_off(self):
        body = self.s.split('function Set-LabVMSettingsCore {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Assert-LabVMOff', body)
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
    def test_transfer_engine_abandons_tree_when_no_file_verified(self):
        # When every planned file fails, the directory skeleton must not be created at the destination.
        body = self.s.split('function Copy-LabTransferItem {', 1)[1].split('\nfunction ', 1)[0]
        guard = re.search(r'if \(\$files\.Count -gt 0 -and @\(\$files \| Where-Object \{ -not \$_\.Done \}\)\.Count -eq 0\) \{', body)
        self.assertIsNotNone(guard)
        rest = body[guard.end():]
        self.assertIn('return & $summary', rest.split('\n            }', 1)[0])
        self.assertLess(guard.start(), body.index('$finalEntries ='))
    def test_invoke_lab_action_has_allow_readonly_switch(self):
        body = self.s.split('function Invoke-LabAction {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('[switch]$AllowReadOnly', body)
        self.assertIn('-not $AllowReadOnly', body)
    def test_file_transfer_orchestrator_blocks_real_copy_in_readonly(self):
        # The read-only refusal must come before credentials are resolved (no needless prompt)
        # and before any PowerShell Direct session is opened.
        body = self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0]
        idx_guard = body.index('if (-not $DryRun -and $script:LabReadOnly) {')
        idx_return = body.index('return $result', idx_guard)
        self.assertLess(idx_guard, body.index('Resolve-LabWindowsCredential'))
        self.assertLess(idx_return, body.index('Resolve-LabWindowsCredential'))
        self.assertLess(idx_guard, body.index('New-LabPSDirectSession'))
        self.assertLess(idx_guard, body.index('Copy-LabTransferItem'))
    def test_file_transfer_writes_one_audit_record_in_finally(self):
        body = self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0]
        idx_finally = body.index('} finally {')
        self.assertEqual(body.count("Write-LabAudit 'file-transfer'"), 1)
        self.assertLess(idx_finally, body.index("Write-LabAudit 'file-transfer'"))
        for status in ["'BLOCKED_READONLY'", "'DRY_RUN'", "'COMPLETED'", "'PARTIAL'", "'FAILED'"]:
            self.assertIn(status, body[idx_finally:])
        for field in ['Direction=', 'Source=', 'Destination=', 'OnConflict=', 'PermissionProfile=', 'VerifyHash=',
                      'Completed=', 'Skipped=', 'Failed=']:
            self.assertIn(field, body[idx_finally:])
    def test_file_transfer_audit_never_logs_credential(self):
        body = self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0]
        audit_part = body[body.index('} finally {'):]
        self.assertNotIn('Credential', audit_part)
    def test_cli_holds_per_vm_mutex_for_whole_transfer(self):
        # Last function in the file: stop at its closing brace, not at the invocation gate below it.
        body = self.s.split('function Start-LabFileTransferCli {', 1)[1].split('\n}\n', 1)[0]
        code = '\n'.join(l for l in body.splitlines() if not l.lstrip().startswith('#'))
        self.assertNotIn('Invoke-LabAction', code)
        idx_new = body.index('[Threading.Mutex]::new($false, "Global\\LabVmManager-$resolvedVMId")')
        idx_wait = body.index('$held = $mutex.WaitOne(0)')
        idx_abandoned = body.index('catch [Threading.AbandonedMutexException] { $held = $true }')
        idx_refuse = body.index('Another copy of this script is operating on this VM.')
        idx_transfer = body.index('Invoke-LabFileTransfer ')
        idx_finally = body.index('} finally {', idx_transfer)
        idx_release = body.index('if ($held) { $mutex.ReleaseMutex() }')
        idx_dispose = body.index('$mutex.Dispose()')
        self.assertLess(body.index('Resolve-LabVMByNameOrId'), idx_new)
        self.assertLess(idx_new, idx_wait)
        self.assertLess(idx_wait, idx_abandoned)
        self.assertLess(idx_abandoned, idx_refuse)
        self.assertLess(idx_refuse, idx_transfer)
        self.assertLess(idx_transfer, idx_finally)
        self.assertLess(idx_finally, idx_release)
        self.assertLess(idx_release, idx_dispose)
    def test_single_file_creates_missing_parent_before_copy(self):
        body = self.s.split('function Copy-LabTransferItem {', 1)[1].split('\nfunction ', 1)[0]
        # The single-file branch is the else of the top-level 'if ($Recurse)' (4-space indent).
        single = re.split(r'\n    \} else \{\n', body, maxsplit=1)[1]
        idx_dry = single.index('if ($DryRun) {')
        idx_parent = single.index('$finalizeSb @(, @(@{ IsDirectory = $true; Destination = $missingParents[0] }))')
        idx_copy = single.index('& $copyPayload $SourcePath $tempPath $false')
        self.assertLess(idx_dry, idx_parent)
        self.assertLess(idx_parent, idx_copy)
        self.assertIn('$removeEmptyCreatedSb', single[single.index('} finally {', idx_copy):])
    def test_orphan_transfer_parameters_do_not_open_menu(self):
        body = self.s.rsplit("if ($MyInvocation.InvocationName -ne '.')", 1)[1]
        idx_check = body.index('Get-LabTransferOnlyParameter @($PSBoundParameters.Keys)')
        idx_exit = body.index('exit 1', idx_check)
        self.assertLess(body.index('if ($CopyToVM -or $CopyFromVM)'), idx_check)
        self.assertLess(idx_exit, body.index('Start-LabVMManager'))
    def test_credential_docs_do_not_recommend_dot_sourcing(self):
        readme = SCRIPT.with_name('README.md').read_text(encoding='utf-8-sig')
        self.assertNotIn('This only works when `Lab-VM.ps1` is dot-sourced', readme)
        self.assertIn('& .\\Lab-VM.ps1 -CopyToVM', readme)
        help_text = self.s.split('#>', 1)[0]
        self.assertNotIn('(dot-source this script', help_text)
        self.assertIn('& .\\Lab-VM.ps1 -CopyToVM', help_text)
    def test_file_transfer_orchestrator_closes_session_in_finally(self):
        body = self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('finally', body)
        self.assertIn('Remove-PSSession', body)
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
    def test_copy_menu_options_pass_allow_readonly(self):
        body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn("'copy-to-vm-menu' -AllowReadOnly", body)
        self.assertIn("'copy-from-vm-menu' -AllowReadOnly", body)
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
    def test_private_permission_profile_threaded_through_every_layer(self):
        self.assertIn("'PrivateFiles'", self.s.split('function Copy-LabTransferItem {', 1)[1].split('\nfunction ', 1)[0])
        self.assertIn('$PermissionProfile', self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0])
        self.assertIn('PermissionProfile', self.s.split('param(', 1)[1].split(')\n\n', 1)[0])
    def test_private_acl_applied_after_finalize_not_before(self):
        # Every ACL call site must sit after the real finalize call (the one that runs Move-Item over
        # the planned moves) and after that call's .Ok result has been checked -- i.e. inside the
        # success branch -- not merely after the Move-Item keyword in source order.
        body = self.s.split('function Copy-LabTransferItem {', 1)[1].split('\nfunction ', 1)[0]
        finalize_def = body.split('$finalizeSb = {', 1)[1].split('\n    $removeSb = {', 1)[0]
        self.assertIn('Move-Item', finalize_def)
        self.assertEqual(body.count('Set-LabTransferPrivateAcl'), 1)
        self.assertLess(body.index('Set-LabTransferPrivateAcl'), body.index('$applyPrivateAcl = {') + 200)
        finalize_call = re.compile(r'\$results? = @\(Invoke-LabTransferSide \$Session \$destinationRemote \$finalizeSb @\(, (?:@\(\$move\)|\$moves)\)\)')
        acl_calls = [m.start() for m in re.finditer(r'& \$applyPrivateAcl ', body)]
        self.assertEqual(len(acl_calls), 2)
        for idx_acl in acl_calls:
            before = body[:idx_acl]
            calls = list(finalize_call.finditer(before))
            self.assertTrue(calls, 'ACL call has no preceding finalize call')
            between = before[calls[-1].end():]
            self.assertRegex(between, r'if \((?:\$result\.Ok|-not \$results\[\$i\]\.Ok)\) \{')
            # Not inside a dry-run branch, and no new payload copy happens between finalize and ACL.
            self.assertNotIn('$copyPayload', between)
            self.assertNotIn('$DryRun', between)
    def test_private_acl_helper_exists(self):
        self.assertIn('function Set-LabTransferPrivateAcl', self.s)
    def test_ssh_connection_settings_functions_exist(self):
        for name in ['Get-LabSshConnectionSettings', 'Set-LabSshConnectionSettings', 'Get-LabGuestAddressCandidates']:
            self.assertIn('function ' + name, self.s)
    def test_ssh_connection_settings_never_writes_password_field(self):
        body = self.s.split('function Set-LabSshConnectionSettings {', 1)[1].split('\nfunction ', 1)[0]
        self.assertNotIn('Password', body)
        self.assertNotIn('$Credential', body)
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
        # Presence check only -- this does not prove BatchMode=yes is absent from this
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
        # code (the substring doesn't exist anywhere yet) and must *stay* true -- it can
        # only ever go red if a future change reintroduces ControlMaster/ControlPath.
        self.assertNotIn('ControlMaster', self.s)
        self.assertNotIn('ControlPath', self.s)
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
    def test_ssh_command_uses_same_auth_mode_flags_as_sftp(self):
        # Controller ruling A: the follow-up ssh.exe calls (hash/size checks, password-mode probe)
        # use the same AuthMode-driven flags as sftp: StrictHostKeyChecking=yes always, BatchMode=yes
        # only in the KeyAgent branch, and the tooling check before any ssh.exe invocation.
        body = self.s.split('function Invoke-LabSshCommand {', 1)[1].split('\nfunction ', 1)[0]
        body = '\n'.join(l for l in body.splitlines() if not l.lstrip().startswith('#'))
        idx_check = body.index('Get-LabSshToolingInfo')
        self.assertLess(idx_check, body.index('ssh.exe @arguments'))
        key_branch = body.split("'KeyAgent' {", 1)[1].split("'InteractivePassword' {", 1)[0]
        password_branch = body.split("'InteractivePassword' {", 1)[1].split('default {', 1)[0]
        self.assertIn('BatchMode=yes', key_branch)
        self.assertIn('StrictHostKeyChecking=yes', key_branch)
        self.assertNotIn('BatchMode', password_branch)
        self.assertIn('StrictHostKeyChecking=yes', password_branch)
        self.assertNotIn('2>&1', password_branch)
    def test_ssh_keyagent_call_passes_n_to_avoid_stdin_interference(self):
        # Final-review fix: -n (stdin from /dev/null) stops a BatchMode=yes ssh.exe call from reading,
        # or hanging on, this process's own stdin. Only the ssh.exe KeyAgent branch needs it: the
        # InteractivePassword branch needs real stdin for OpenSSH's own password prompt, sftp.exe has
        # its own stdin handling via -b, and Add-LabSshKnownHost needs stdin for the interactive
        # fingerprint prompt (StrictHostKeyChecking=ask), so none of those three gets -n.
        ssh_body = self.s.split('function Invoke-LabSshCommand {', 1)[1].split('\nfunction ', 1)[0]
        key_branch = ssh_body.split("'KeyAgent' {", 1)[1].split("'InteractivePassword' {", 1)[0]
        password_branch = ssh_body.split("'InteractivePassword' {", 1)[1].split('default {', 1)[0]
        self.assertIn("'-n'", key_branch)
        self.assertNotIn("'-n'", password_branch)
        sftp_body = self.s.split('function Invoke-LabSftpCommand {', 1)[1].split('\nfunction ', 1)[0]
        self.assertNotIn("'-n'", sftp_body)
        known_host_body = self.s.split('function Add-LabSshKnownHost {', 1)[1].split('\nfunction ', 1)[0]
        self.assertNotIn("'-n'", known_host_body)
    def test_sftp_size_check_distinguishes_mismatch_from_check_failure(self):
        # Final-review fix: a stat failure on the guest (missing/unreadable file, etc.) must not be
        # reported with the same "size mismatch" wording as a genuine, confirmed size disagreement.
        body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('exit 23', body)
        self.assertIn('could not be completed', body)
        self.assertIn('not a confirmed size mismatch', body)
    def test_sftp_engine_routes_every_process_through_helpers(self):
        # The engine never launches ssh.exe/sftp.exe itself: every connection goes through the two
        # helpers that own the flag rules and the tooling check. Comment lines are ignored.
        body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
        body = '\n'.join(l for l in body.splitlines() if not l.lstrip().startswith('#'))
        self.assertNotIn('ssh.exe', body)
        self.assertNotIn('sftp.exe', body)
        self.assertIn('Invoke-LabSftpCommand ', body)
        self.assertIn('Invoke-LabSshCommand ', body)
    def test_sftp_listing_parent_mode_fails_closed(self):
        # Review M2: in parent-listing mode an unrecognized listing is an error, never "absent" --
        # the parent's own '.' entry must parse -- and the engine's probe uses that mode.
        listing = self.s.split('function ConvertFrom-LabSftpListing {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('[switch]$ParentListing', listing)
        self.assertIn("$name -ceq '.'", listing)
        engine = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('-ParentListing', engine)
    def test_sftp_engine_creates_missing_parents_before_payload(self):
        # Review M1: like the Windows engine, missing destination parents are created (guest: mkdir
        # lines in the payload batch; host: CreateDirectory) and only those are removed on failure.
        body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
        body = '\n'.join(l for l in body.splitlines() if not l.lstrip().startswith('#'))
        self.assertIn("'mkdir '", body)
        self.assertIn("'-rmdir '", body)
        self.assertIn('[IO.Directory]::CreateDirectory(', body)
        self.assertLess(body.index("'mkdir '"), body.index("'put "))
    def test_menu_t_entry_is_adapter_aware(self):
        body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Get-LabTransferAdapterKind', body)
        self.assertIn('Test-LabSshConnection', body)
    def test_configure_ssh_menu_entry_exists(self):
        body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn("'C'", body)
        self.assertIn('Configure-LabSshConnectionInteractive', body)
    def test_configure_ssh_cli_params_exist(self):
        body = self.s.split('param(', 1)[1].split(')\n\n', 1)[0]
        for p in ['$ConfigureSsh', '$SshHost', '$SshPort', '$SshUser', '$SshIdentityFile']:
            self.assertIn(p, body)
    def test_configure_ssh_does_not_prompt(self):
        body = self.s.rsplit("if ($MyInvocation.InvocationName -ne '.')", 1)[1]
        self.assertIn('ConfigureSsh', body)
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
    def test_sftp_chmod_lines_follow_rename_in_the_same_batch(self):
        # Every chmod line is appended to a batch after that batch's rename line (never in batch A).
        body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn("'chmod 600 '", body)
        self.assertIn("'chmod 700 '", body)
        batch_b = body.split('$batchB += \'rename ', 1)[1]
        self.assertLess(batch_b.index("'chmod 600 '"), batch_b.index('$finalize = & $runBatch $batchB'))
        batch_a = body.split('$batchA = ', 1)[1].split('$upload = & $runBatch $batchA', 1)[0]
        self.assertNotIn('chmod', batch_a)
    def test_sftp_download_private_profile_uses_host_side_acl(self):
        # A download's destination is on this Windows host: the same host-side ACL the Windows
        # adapter applies to its own downloads (no session), never an sftp chmod.
        body = self.s.split('function Copy-LabTransferItemSftp {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Set-LabTransferPrivateAcl -Session $null', body)

    # --- Final-review fix wave ---
    def _body(self, name):
        return self.s.split('function ' + name + ' {', 1)[1].split('\nfunction ', 1)[0]
    def _code(self, text):
        return '\n'.join(l for l in text.splitlines() if not l.lstrip().startswith('#'))
    def _sftp_password_branch(self):
        body = self._code(self._body('Invoke-LabSftpCommand'))
        return body.split("'InteractivePassword' {", 1)[1].split('default {', 1)[0]
    def test_sftp_password_branch_batchmode_no_precedes_b(self):
        # sftp -b forces '-oBatchMode yes' on its ssh child; ssh keeps the FIRST value it sees, so
        # BatchMode=no must be earlier in the same argument list than -b, not merely present.
        branch = self._sftp_password_branch()
        args_line = [l for l in branch.splitlines() if '$arguments = @(' in l]
        self.assertEqual(len(args_line), 1)
        args_line = args_line[0]
        self.assertIn("'-o', 'BatchMode=no'", args_line)
        self.assertLess(args_line.index("'BatchMode=no'"), args_line.index("'-b'"))
        self.assertNotIn('BatchMode=yes', branch)
        self.assertIn("'StrictHostKeyChecking=yes'", args_line)
    def test_sftp_password_branch_keeps_stdout_off_return_value(self):
        branch = self._sftp_password_branch()
        self.assertIn('& sftp.exe @arguments | Out-Host', branch)
        self.assertNotIn('2>&1', branch)
        self.assertNotRegex(branch, r'sftp\.exe[^\r\n]*[<>]')
    def test_sftp_engine_takes_single_result_from_helper(self):
        body = self._code(self._body('Copy-LabTransferItemSftp'))
        run_batch = body.split('$runBatch = {', 1)[1].split('$runSsh = {', 1)[0]
        self.assertIn('$result = Invoke-LabSftpCommand ', run_batch)
        self.assertIn("throw 'sftp returned no result.'", run_batch)
    def test_trust_host_key_confirms_before_ask_mode_connection(self):
        body = self._code(self._body('Add-LabSshKnownHost'))
        idx_confirm = body.index('Confirm-LabText "TRUST HOST KEY ')
        idx_ssh = body.index('& ssh.exe @arguments')
        self.assertLess(idx_confirm, idx_ssh)
        self.assertIn("'StrictHostKeyChecking=ask'", body)
        self.assertIn("'BatchMode=no'", body)
        self.assertLess(body.index('Get-LabSshToolingInfo'), idx_ssh)
        self.assertLess(body.index('Assert-LabVMRunning'), idx_ssh)
    def test_trust_host_key_never_touches_prompt_or_known_hosts_itself(self):
        # OpenSSH's own fingerprint prompt goes straight to the console: no stdin/stderr redirection,
        # no captured output, no scripted answer, and no direct write to known_hosts by this script.
        body = self._code(self._body('Add-LabSshKnownHost'))
        self.assertIn('& ssh.exe @arguments | Out-Host', body)
        ssh_line = [l for l in body.splitlines() if '& ssh.exe' in l]
        self.assertEqual(len(ssh_line), 1)
        self.assertNotRegex(ssh_line[0], r'2>|<|\$\w+\s*=\s*&')
        for forbidden in ['Read-Host', 'Start-Process', 'Set-Content', 'Add-Content', 'Out-File', 'WriteAllText',
                          'AppendAllText', 'UserKnownHostsFile', '& ssh-keygen', 'ssh-keyscan', 'StrictHostKeyChecking=no',
                          'StrictHostKeyChecking=accept-new']:
            self.assertNotIn(forbidden, body)
    def test_ask_mode_exists_only_in_the_trust_action(self):
        code = self._code(self.s)
        self.assertEqual(code.count('StrictHostKeyChecking=ask'), 1)
        self.assertNotIn('StrictHostKeyChecking=no', code)
        self.assertNotIn('accept-new', code)
        for name in ['Invoke-LabSftpCommand', 'Invoke-LabSshCommand']:
            body = self._code(self._body(name))
            for branch in ["'KeyAgent' {", "'InteractivePassword' {"]:
                part = body.split(branch, 1)[1].split('}', 1)[0]
                self.assertIn("'StrictHostKeyChecking=yes'", part, name + ' ' + branch)
    def test_menu_wires_known_host_actions(self):
        body = self._body('Show-LabVMMenu')
        self.assertIn("'K'  { Add-LabSshKnownHost $VMId }", body)
        self.assertIn('Update-LabSshKnownHost $sshSettings.HostNameOrAddress $sshSettings.Port', body)
        read_only_text, normal_text = re.findall(r"Write-Host @'\r?\n(.*?)\r?\n'@", body, re.S)[:2]
        for text in (read_only_text, normal_text):
            self.assertRegex(text, r'(?m)^  K  Trust ')
            self.assertRegex(text, r'(?m)^  U  Clear ')
        # Host-local known_hosts actions, like C: not routed through Invoke-LabAction's read-only gate.
        self.assertNotRegex(body, r"Invoke-LabAction[^\r\n]*(Add-LabSshKnownHost|Update-LabSshKnownHost)")
    def test_copy_from_vm_menu_is_adapter_aware(self):
        body = self._code(self._body('Copy-LabVMItemInteractive'))
        idx_kind = body.index('$adapterKind = Get-LabTransferAdapterKind $VMId')
        self.assertLess(idx_kind, body.index('Resolve-LabWindowsCredential'))
        self.assertLess(idx_kind, body.index('New-LabPSDirectSession'))
        sftp_branch = body.split("if ($sourceRemote -and $adapterKind -eq 'SFTP') {", 1)[1].split('\n    } else {', 1)[0]
        self.assertNotIn('Resolve-LabWindowsCredential', sftp_branch)
        self.assertNotIn('New-LabPSDirectSession', sftp_branch)
        self.assertIn('Read-LabText', sftp_branch)
    def test_connection_test_surfaces_failure_reason(self):
        body = self._code(self._body('Test-LabSshConnection'))
        self.assertIn('$result.Output', body)
        self.assertIn("-notmatch '^sftp>'", body)
    def test_ssh_settings_read_fails_closed(self):
        body = self._code(self._body('Get-LabSshConnectionSettings'))
        self.assertEqual(body.count('return $null'), 1)
        self.assertIn('if (-not (Test-Path -LiteralPath $path)) { return $null }', body)
        catch_part = body.split('} catch {', 1)[1].split('}', 1)[0]
        self.assertNotIn('return', catch_part)
        self.assertIn('throw "The saved SSH connection settings', body)
        self.assertIn('Test-LabSshHostName', body)
        self.assertIn('Test-LabSshUserName', body)
    def test_ssh_values_validated_wherever_accepted(self):
        for name in ['Set-LabSshConnectionSettings', 'Start-LabSshConfigurationCli', 'Configure-LabSshConnectionInteractive']:
            body = self.s.split('function ' + name + ' {', 1)[1].split('\n}\n', 1)[0]
            self.assertIn('Test-LabSshHostName', body, name)
            self.assertIn('Test-LabSshUserName', body, name)
        host_check = self._body('Test-LabSshHostName')
        self.assertIn("StartsWith('-')", host_check)
        self.assertIn("StartsWith('-')", self._body('Test-LabSshUserName'))
        params = self.s.split('param(', 1)[1].split(')\n\n', 1)[0]
        self.assertRegex(params, r'\[ValidateRange\(1, 65535\)\]\s*\[int\]\$SshPort')
    def test_docs_describe_real_first_trust_flow(self):
        readme = SCRIPT.with_name('README.md').read_text(encoding='utf-8-sig')
        manual = SCRIPT.with_name('MANUAL-TESTS.md').read_text(encoding='utf-8-sig')
        for stale in ['host-key-trust prompt reaches', 'password and host-key-trust prompts',
                      'password/host-key prompts', 'real host-key-trust prompt reappears']:
            self.assertNotIn(stale, readme)
            self.assertNotIn(stale, manual)
        for doc in (readme, manual):
            self.assertIn('TRUST HOST KEY', doc)
            self.assertIn('StrictHostKeyChecking=ask', doc)
        self.assertIn('SshConnections\\<VMId>.json', readme)
    def test_iso_root_parameter_exists(self):
        body = self.s.split('param(', 1)[1].split(')\n\n', 1)[0]
        self.assertIn('$IsoRoot', body)
    def test_iso_discovery_function_exists(self):
        self.assertIn('function Get-LabIsoCandidates', self.s)
    def test_iso_discovery_never_follows_reparse_points(self):
        body = self.s.split('function Get-LabIsoCandidates {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('ReparsePoint', body)
    def test_iso_discovery_reports_incomplete_not_silent_partial(self):
        body = self.s.split('function Get-LabIsoCandidates {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Incomplete', body)
    def test_iso_selection_function_exists(self):
        self.assertIn('function Select-LabIsoPath', self.s)
    def test_iso_selection_revalidates_before_returning(self):
        body = self.s.split('function Select-LabIsoPath {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('OpenRead', body)
    def test_key_protector_check_is_read_only(self):
        self.assertIn('function Test-LabVMHasKeyProtector', self.s)
        body = self.s.split('function Test-LabVMHasKeyProtector {', 1)[1].split('\nfunction ', 1)[0]
        self.assertNotIn('Set-VMKeyProtector', body)
        self.assertNotIn('Enable-VMTPM', body)
    def test_boot_profile_function_exists(self):
        self.assertIn('function Set-LabVMBootProfile', self.s)
    def test_boot_profile_rejects_generation_1(self):
        body = self.s.split('function Set-LabVMBootProfile {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Generation', body)
    def test_boot_profile_never_rotates_existing_key_protector(self):
        body = self.s.split('function Set-LabVMBootProfile {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('KeyProtectorAdded', body)
    def test_boot_profile_linux_never_touches_tpm(self):
        body = self.s.split('function Set-LabVMBootProfile {', 1)[1].split('\nfunction ', 1)[0]
        # rindex, not index: the [ValidateSet('Windows11','UbuntuDesktop')] parameter
        # declaration contains both literal strings before either branch body does, so the
        # FIRST occurrence of each is always inside that declaration, not inside the actual
        # branch logic -- using the LAST occurrence of each is what actually lands inside
        # each branch's own code, regardless of switch/if-elseif/hashtable-dispatch style.
        idx_ubuntu = body.rindex("'UbuntuDesktop'")
        idx_windows = body.rindex("'Windows11'")
        ubuntu_branch = body[idx_ubuntu:idx_windows] if idx_ubuntu < idx_windows else body[idx_ubuntu:]
        self.assertNotIn('Enable-VMTPM', ubuntu_branch)
        self.assertNotIn('Set-VMKeyProtector', ubuntu_branch)
    def test_install_media_function_exists(self):
        self.assertIn('function Set-LabVMInstallMedia', self.s)
    def test_install_media_records_previous_attachment(self):
        body = self.s.split('function Set-LabVMInstallMedia {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('PreviousAttachment', body)
    def test_install_media_revalidates_iso_before_attach(self):
        body = self.s.split('function Set-LabVMInstallMedia {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Length', body)
    def test_boot_order_preserves_other_entries(self):
        self.assertIn('function Set-LabVMBootOrder', self.s)
        body = self.s.split('function Set-LabVMBootOrder {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('BootOrder', body)
    def test_eject_install_media_function_exists(self):
        self.assertIn('function Remove-LabVMInstallMedia', self.s)
    def test_install_media_rejects_multiple_dvd_drives(self):
        body = self.s.split('function Set-LabVMInstallMedia {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn("doesn't choose among them", body)
    def test_install_media_path_helper_scoped_by_vm_guid(self):
        body = self.s.split('function Get-LabVMInstallMediaPath {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('InstallMedia', body)
        self.assertIn('$VMId', body)
    def test_seed_iso_builder_function_exists(self):
        self.assertIn('function New-LabSeedIso', self.s)
        self.assertIn('IMAPI2FS', self.s)
    def test_provisioning_workspace_never_under_iso_root(self):
        self.assertIn('function Get-LabProvisioningWorkspacePath', self.s)
        body = self.s.split('function Get-LabProvisioningWorkspacePath {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('LOCALAPPDATA', body)
        self.assertNotIn('$IsoRoot', body)
    def test_provisioning_workspace_cleanup_function_exists(self):
        self.assertIn('function Remove-LabProvisioningWorkspace', self.s)
    def test_installation_media_function_exists(self):
        self.assertIn('function Set-LabVMInstallationMediaInteractive', self.s)
    def test_installation_media_requires_confirmation(self):
        body = self.s.split('function Set-LabVMInstallationMediaInteractive {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Read-LabYesNoCancel', body)
    def test_installation_media_menu_entry_exists(self):
        body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Set-LabVMInstallationMediaInteractive', body)
    def test_installation_media_routed_through_invoke_lab_action(self):
        body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
        idx = body.index('Set-LabVMInstallationMediaInteractive')
        nearby = body[max(0, idx - 200):idx]
        self.assertIn('Invoke-LabAction', nearby)
    def test_installation_media_warns_on_existing_key_protector(self):
        body = self.s.split('function Set-LabVMInstallationMediaInteractive {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('recovery', body.lower())
    def test_installation_media_warns_before_overwriting_existing_data(self):
        body = self.s.split('function Set-LabVMInstallationMediaInteractive {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Checkpoint', body)
    def test_installation_media_gates_mutation_internally_under_readonly(self):
        body = self.s.split('function Set-LabVMInstallationMediaInteractive {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('$script:LabReadOnly', body)
    def test_installation_media_preview_is_read_only(self):
        # The preview runs before any confirmation, so it must decide the encryption warning via the
        # read-only Test-LabVMHasKeyProtector and never call anything that changes the VM.
        body = self.s.split('function Get-LabVMInstallationMediaPreview {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('Test-LabVMHasKeyProtector', body)
        for mutating in ('Set-LabVMBootProfile', 'Set-LabVMInstallMedia', 'Set-LabVMBootOrder',
                         'Set-VM', 'Add-VM', 'Enable-VM', 'Remove-'):
            self.assertNotIn(mutating, body)
    def test_installation_media_menu_letter_in_both_menu_blocks(self):
        body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
        self.assertEqual(body.count('  M  Installation media'), 2)

    # --- Final-review fix wave ---
    def _body(self, name):
        return self.s.split('function %s {' % name, 1)[1].split('\nfunction ', 1)[0]
    def test_key_protector_reads_the_real_byte_array_shape(self):
        # Reflection-confirmed: Get-VMKeyProtector emits a bare byte[]; no wrapper property exists.
        body = self._body('Test-LabVMHasKeyProtector')
        self.assertNotIn('.RawKeyProtector', body)
        self.assertNotIn('.RawData', body)
        self.assertIn('-is [byte[]]', body)
        self.assertIn('-gt 4', body)
    def test_seed_iso_never_infers_content_from_an_existing_path(self):
        body = self._body('New-LabSeedIso')
        self.assertIn('SourcePath', body)
        self.assertNotIn('$value -is [string] -and (Test-Path', body)
        self.assertIn('IsPathRooted', body)
        self.assertIn("'..'", body)
        # Every key/value is validated before the COM image is created.
        self.assertLess(body.index('IsPathRooted'), body.index('IMAPI2FS.MsftFileSystemImage'))
        self.assertLess(body.index('does not exist'), body.index('IMAPI2FS.MsftFileSystemImage'))
    def test_install_media_revalidates_iso_before_adding_a_drive_or_writing_the_record(self):
        body = self._body('Set-LabVMInstallMedia')
        idx_validate = body.index('no longer exists')
        self.assertLess(idx_validate, body.index('Add-VMDvdDrive'))
        self.assertLess(body.index('is empty (0 bytes)'), body.index('Add-VMDvdDrive'))
        self.assertLess(idx_validate, body.index('Set-Content'))
    def test_boot_profile_turns_secure_boot_on_when_off(self):
        body = self._body('Set-LabVMBootProfile')
        self.assertIn('$firmware.SecureBoot', body)
        self.assertIn('-EnableSecureBoot On', body)
        self.assertIn('SecureBootEnabled', body)
    def test_preview_checks_secure_boot_state_and_dvd_boot_entry(self):
        body = self._body('Get-LabVMInstallationMediaPreview')
        self.assertIn("'SecureBoot'", body)
        self.assertIn('-> On.', body)
        self.assertIn('Get-LabBootEntryKind', body)
        self.assertIn('DvdBootEntryRecognized', body)
        interactive = self._body('Set-LabVMInstallationMediaInteractive')
        self.assertLess(interactive.index('DvdBootEntryRecognized'), interactive.index("Read-LabYesNoCancel 'Apply these changes'"))
    def test_installation_media_audits_key_protector_attach_and_eject(self):
        body = self._body('Set-LabVMInstallationMediaInteractive')
        self.assertIn("Write-LabAudit 'add-key-protector' 'COMPLETED'", body)
        self.assertIn("Write-LabAudit 'attach-install-media' 'COMPLETED'", body)
        self.assertIn("Write-LabAudit 'eject-install-media' 'COMPLETED'", body)
        # The key-protector record is written right after the boot-profile step, before media/boot order.
        self.assertLess(body.index("'add-key-protector'"), body.index('Set-LabVMInstallMedia $VMId'))
    def test_inspect_guards_the_key_protector_read(self):
        body = self._body('Show-LabVMInstallMediaConfiguration')
        self.assertIn('try { $keyProtector = Test-LabVMHasKeyProtector $VMId } catch', body)
    def test_docs_state_reflection_findings_acl_and_press_any_key(self):
        readme = SCRIPT.with_name('README.md').read_text(encoding='utf-8-sig')
        manual = SCRIPT.with_name('MANUAL-TESTS.md').read_text(encoding='utf-8-sig')
        self.assertNotIn('It is never written to:', readme)
        self.assertIn('access-control entry', readme)
        self.assertIn('Press any key to boot from CD or DVD', readme)
        self.assertIn('Get-Acl', manual)
        self.assertIn('VMBootSource', readme)
        self.assertIn('VMBootSource', manual)
        self.assertIn('byte[]', readme)
        self.assertIn('byte[]', manual)
        self.assertNotIn("has not yet been verified against a live host's `Get-VMFirmware` output", readme)

    # --- Windows unattended install, Task 1: edition enumeration and version-scope check ---
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

if __name__ == '__main__':
    unittest.main(verbosity=2)
