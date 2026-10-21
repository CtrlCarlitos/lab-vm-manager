# Addendum: optional -ProductKey

## What was built

The final whole-branch review of the Windows unattended-install plan flagged a possible Setup
product-key prompt on some multi-edition ISOs, and MANUAL-TESTS.md got a contingency note
documenting the known remedy (a dummy all-zero key, `WillShowUI=OnError`) without implementing it,
since "no activation key" had already been settled. The user has now asked for that remedy to be
implemented as an optional parameter, defaulting to off.

1. `New-LabWindowsAnswerFileXml` (Lab-VM.ps1) gained `[string]$ProductKey = ''`, appended as the
   LAST parameter (after `$Password`) to preserve every existing positional caller unchanged. When
   empty (default), the windowsPE `UserData` block is byte-for-byte identical to before (no
   `<ProductKey>` element). When non-empty, it inserts, between `<AcceptEula>` and `</UserData>`:
   ```xml
   <ProductKey>
       <Key>$escapedProductKey</Key>
       <WillShowUI>OnError</WillShowUI>
   </ProductKey>
   ```
   escaped via the same `[Security.SecurityElement]::Escape(...)` pattern already used for every
   other value in this function.

2. `Start-LabWindowsVMProvisioning` resolves `-ProductKey` via the same `& $getOption` pattern as
   `-ComputerName`/`-Locale`/`-TimeZone`, validates it (only when non-empty) against
   `^[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}$`, throws a clear
   message naming the expected format on mismatch, and adds `ProductKey = $productKey` to the
   `$answerFileArguments` splat. Also added a `ProductKey` row to the pre-creation preview
   (`'none (no activation)'` vs `'supplied (not shown here)'` -- the raw key is never printed, same
   spirit as the password never being shown) since this preview is the one confirmation gate before
   anything is created; this one addition was not explicitly requested but is a natural, low-risk fit
   with the existing preview's purpose.

3. Top-level `param()` block gained `[string]$ProductKey = ''` with matching `.PARAMETER` help text.

4. `Get-LabProvisioningOnlyParameter`'s orphan-parameter guard list gained `'ProductKey'`.

5. Docs: README.md's parameter list, its step-5 prose, and its "Intentionally not included" OS
   activation line were all updated to say activation/the product key is now optional via
   `-ProductKey` (default still off). MANUAL-TESTS.md's product-key contingency note was updated
   from "not yet implemented, pending evidence" to naming the exact command-line fix
   (`-ProductKey 00000-00000-00000-00000-00000`) now available if the live end-to-end test ever hits
   that page.

## What was tested (RED/GREEN)

- `test_static.py`: replaced `test_answer_file_no_product_key` (asserted the literal string
  `ProductKey` never appeared in the function body -- no longer true once the feature exists) with
  `test_answer_file_product_key_defaults_to_none`, which statically asserts the function's
  `param()` block declares `[string]$ProductKey = ''`. Confirmed RED before the implementation
  (param didn't exist), GREEN after.
- `Test-LabVM.ps1` (real runtime behavior):
  - New: "`New-LabWindowsAnswerFileXml` without `-ProductKey` has no `ProductKey` element anywhere"
    -- XPath-based (namespace-agnostic, matching this suite's existing `Select-LabXmlNode` style),
    checked both the omitted case and the explicit-empty-string case.
  - New: "`New-LabWindowsAnswerFileXml` with `-ProductKey` adds the key and `WillShowUI=OnError`,
    keeping `AcceptEula`" -- confirms `Key`, `WillShowUI`, and that `AcceptEula` is still present
    alongside (not replaced).
  - Strengthened the existing happy-path provisioning test with an explicit assertion that
    `New-LabWindowsAnswerFileXml`'s `ProductKey` arg is `''` when `-ProductKey` isn't supplied.
  - New: "Provision: a malformed `-ProductKey` is rejected before any VM is created" -- asserts the
    error names `ProductKey`, no VM is created, and no audit record is written.
  - New: "Provision: a well-formed `-ProductKey` passes through unchanged to the answer-file call".
  - Updated the orchestrator-test harness's fake `New-LabWindowsAnswerFileXml` to accept
    `[string]$ProductKey = ''` (needed since the real orchestrator now splats that key into it).

Initial implementation attempt hit a real PowerShell gotcha: a here-string's closing `"@` must be
the first thing on its own line (column 0); placing it on the same line as content (as the plan
prose literally showed) is a parse error (`MissingEndCurlyBrace`/`MissingCatchOrFinally`). Fixed by
putting the closing delimiter on its own line and then `TrimEnd("`r`n")`-ing the trailing newline
off the built fragment so the final XML matches the spec's exact formatting with no stray blank
line.

## Test results

- `python test_static.py`: 185/185 (baseline 185 + 0 net new -- one test renamed/retargeted, not
  added, per the task's instruction).
- `powershell.exe -NoProfile -File .\Test-LabVM.ps1` (Windows PowerShell 5.1): 305/305 (baseline
  301 + 4 new test cases), exit code 0.

## Files changed

- `Lab-VM.ps1`
- `Test-LabVM.ps1`
- `test_static.py`
- `README.md`
- `MANUAL-TESTS.md`

## Concerns

None outstanding. Default behavior for every existing caller is byte-for-byte unchanged (verified
both by the default-case XPath test and by the fact that none of the 301 pre-existing Test-LabVM.ps1
cases needed changes beyond the one fake-function signature update required by the new splat key).
The validation regex is intentionally the standard 5x5 Windows product-key shape only; it does not
attempt to validate the key against the ISO's edition or verify it would actually activate anything,
which matches this project's existing "fail loud on shape, not on semantics" validation style
elsewhere (e.g. `-TimeZone`, `-Locale`).
