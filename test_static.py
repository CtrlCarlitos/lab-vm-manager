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
    def test_no_vm_deletion_or_disk_unlink(self):
        for cmd in ['Remove-VM ', 'Remove-VMSavedState ', 'Remove-Item ', 'Invoke-Expression ']:
            self.assertNotIn(cmd, self.s)
    def test_no_subtree_delete(self):
        self.assertNotRegex(self.s, r'Remove-VMSnapshot[^\r\n]*-IncludeAllChildSnapshots')
    def test_mutations_use_objects(self):
        for cmd in ['Start-VM', 'Resume-VM', 'Stop-VM', 'Set-VM', 'Checkpoint-VM', 'Export-VM']:
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
        for name in ['Get-LabVM','Select-LabVM','Start-LabVM','Stop-LabVMGracefully','New-LabCheckpoint','Restore-LabCheckpoint','Rename-LabCheckpoint','Remove-LabCheckpoint','Export-LabVM','Set-LabCheckpointPolicy','Stop-LabVMPower','Invoke-LabAction','Start-LabVMManager']:
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

if __name__ == '__main__':
    unittest.main(verbosity=2)
