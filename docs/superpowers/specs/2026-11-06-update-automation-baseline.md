# Update Automation Baseline Design

## Goal

Add a Windows-first CI and conservative repository update/security baseline without introducing runtime dependencies or a self-hosted runner.

## Continuous Integration

- Run on pull requests and pushes to `main`.
- Use `windows-latest` and Windows PowerShell 5.1 for `Test-LabVM.ps1`.
- Use Python for `test_static.py` after `actions/setup-python`.
- Pin `actions/checkout` and `actions/setup-python` to full commit SHAs with readable major-version comments.
- Grant only read access to repository contents.
- Do not add CodeQL or expose a self-hosted Hyper-V runner to public pull requests.

## Dependency Updates

- Configure only the `github-actions` ecosystem.
- Run weekly on Monday at 09:00 UTC.
- Group all Action updates into one pull request and allow at most one open update pull request.
- Never auto-merge dependency pull requests.
- Do not add package-manager automation while the repository has no package manifest.

## Security and Branch Policy

- Add a `SECURITY.md` directing vulnerability reports to GitHub private vulnerability reporting rather than public issues.
- Enable dependency vulnerability alerts and private vulnerability reporting; leave automated security fixes disabled.
- After CI has succeeded on the default branch, protect `main` with an active branch ruleset that blocks deletion and force pushes, requires pull requests with resolved review conversations, and requires the `test` status check against an up-to-date branch.

## Verification

- Source-contract tests pin the workflow, Dependabot, and security-policy requirements without adding a YAML dependency.
- Existing PowerShell and Python suites pass on `windows-latest` before branch protection is activated.
