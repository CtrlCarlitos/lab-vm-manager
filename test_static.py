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
        for name in ['Get-LabVM','Select-LabVM','Start-LabVM','Stop-LabVMGracefully','New-LabCheckpoint','Restore-LabCheckpoint','Rename-LabCheckpoint','Remove-LabCheckpoint','Export-LabVM','Set-LabCheckpointPolicy','Stop-LabVMPower','Invoke-LabAction','Start-LabVMManager','New-LabVM','Edit-LabVMSettings','Remove-LabVM','Copy-LabVMItemInteractive','Invoke-LabFileTransfer']:
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

if __name__ == '__main__':
    unittest.main(verbosity=2)
