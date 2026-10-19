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
        for name in ['Get-LabVM','Select-LabVM','Start-LabVM','Stop-LabVMGracefully','New-LabCheckpoint','Restore-LabCheckpoint','Rename-LabCheckpoint','Remove-LabCheckpoint','Export-LabVM','Set-LabCheckpointPolicy','Stop-LabVMPower','Invoke-LabAction','Start-LabVMManager','New-LabVM','Edit-LabVMSettings','Remove-LabVM']:
            self.assertIn('function '+name+' {',self.s)
    def test_host_discovery_functions_exist(self):
        self.assertIn('function Get-LabHostDefaults', self.s)
        self.assertIn('function Get-LabSwitchNames', self.s)
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
        body = self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('LabReadOnly', body)
    def test_file_transfer_orchestrator_closes_session_in_finally(self):
        body = self.s.split('function Invoke-LabFileTransfer {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('finally', body)
        self.assertIn('Remove-PSSession', body)
    def test_copy_menu_options_pass_allow_readonly(self):
        body = self.s.split('function Show-LabVMMenu {', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn("'copy-to-vm-menu' -AllowReadOnly", body)
        self.assertIn("'copy-from-vm-menu' -AllowReadOnly", body)

if __name__ == '__main__':
    unittest.main(verbosity=2)
