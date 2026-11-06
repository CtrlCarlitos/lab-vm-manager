# Update Automation Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Windows CI, weekly grouped GitHub Actions updates, vulnerability reporting guidance, and default-branch protections to `CtrlCarlitos/lab-vm-manager`.

**Architecture:** One read-only Windows workflow executes both existing test suites in their supported runtimes. Standard-library source-contract tests lock the workflow and Dependabot policy, while repository security settings and the `main` ruleset are applied only after the new CI has merged and succeeded.

**Tech Stack:** GitHub Actions, Windows PowerShell 5.1, Python 3, `unittest`, Dependabot v2, GitHub REST API/rulesets.

**Spec:** `docs/superpowers/specs/2026-11-06-update-automation-baseline.md`

## Global Constraints

- Use `windows-latest`; do not use a self-hosted Hyper-V runner for public pull requests.
- Run `Test-LabVM.ps1` with Windows PowerShell 5.1 and `test_static.py` with Python.
- Pin every Action to a full 40-character commit SHA and retain a readable major-version comment.
- Keep workflow permissions read-only (`contents: read`).
- Configure Dependabot only for `github-actions`; do not invent a package manifest or add package-manager automation.
- Never auto-merge dependency pull requests.
- Apply the `main` ruleset only after the required `test` check exists and has succeeded on the default branch.

## Review Focus

- The PowerShell step must use Desktop PowerShell 5.1, not `pwsh`; covered by Task 1's workflow contract test and runtime assertion.
- Mutable Action tags must be rejected even when followed by a version comment; covered by Task 1's full-SHA regex test.
- CI must not gain write permissions or secrets on public pull requests; covered by Task 1's permission and trigger tests.
- Dependabot must not infer Python/pip automation from `test_static.py`; covered by Task 2's single-ecosystem contract test.
- Branch protection must not be enabled before the required check is known to GitHub; Task 4 explicitly verifies a successful default-branch run before ruleset creation.

---

## File Structure

- Create `.github/workflows/ci.yml` for Windows PowerShell and Python tests.
- Create `.github/dependabot.yml` for weekly grouped GitHub Actions updates.
- Create `SECURITY.md` for private vulnerability disclosure guidance.
- Modify `test_static.py` with standard-library policy contract tests for all three files.
- Modify `README.md` to keep its exact static-test count current.

### Task 1: Windows CI

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `test_static.py`

**Interfaces:**
- Produces: Workflow `CI`, job/check context `test`, triggered by pull requests and pushes to `main`.
- Consumes: `Test-LabVM.ps1` under `shell: powershell` and `test_static.py` under setup Python.

- [ ] **Step 1: Write failing workflow contract tests**

Add an `AutomationContract` class that reads `.github/workflows/ci.yml`. Add tests named `test_ci_is_windows_read_only_and_uses_expected_triggers`, `test_ci_actions_use_full_sha_pins`, and `test_ci_runs_both_existing_suites`. Assert job id `test`, `windows-latest`, `permissions` with only `contents: read`, `pull_request`, push branch `main`, `shell: powershell`, a `$PSVersionTable.PSEdition -eq 'Desktop'` and major-version `5` guard before `& .\Test-LabVM.ps1`, and `python -m unittest -v test_static.py`. Reject `@vN` Action references and require exactly two `uses:` lines matching 40 lowercase hexadecimal characters.

- [ ] **Step 2: Run the new tests and verify they fail**

Run: `python -m unittest -v test_static.AutomationContract`

Expected: FAIL because `.github/workflows/ci.yml` does not exist.

- [ ] **Step 3: Create the workflow**

Pin `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7` and `actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7`; configure Python `3.x`. The PowerShell step must throw before running tests unless `$PSVersionTable.PSEdition -eq 'Desktop'` and `$PSVersionTable.PSVersion.Major -eq 5`.

- [ ] **Step 4: Run local contract and static tests**

Run: `python -m unittest -v test_static.AutomationContract && python -m unittest -v test_static.py`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml test_static.py
git commit -m "ci: run Windows PowerShell and Python tests"
```

### Task 2: Weekly GitHub Actions Updates

**Files:**
- Create: `.github/dependabot.yml`
- Modify: `test_static.py`

**Interfaces:**
- Consumes: GitHub's Dependabot v2 schema.
- Produces: One grouped weekly `github-actions` update queue rooted at `/`.

- [ ] **Step 1: Write a failing Dependabot contract test**

Add `test_dependabot_only_updates_actions_weekly_as_one_group`. Assert exactly one `package-ecosystem`, value `github-actions`, directory `/`, schedule interval `weekly`, day `monday`, time `09:00`, timezone `Etc/UTC`, one group matching `*`, `open-pull-requests-limit: 1`, and no `pip` ecosystem.

- [ ] **Step 2: Run the test and verify it fails**

Run: `python -m unittest test_static.AutomationContract.test_dependabot_only_updates_actions_weekly_as_one_group -v`

Expected: FAIL because `.github/dependabot.yml` does not exist.

- [ ] **Step 3: Create the Dependabot configuration**

Set `version: 2`, commit-message prefix `ci`, and the exact schedule/group/limit values asserted in Step 1.

- [ ] **Step 4: Run the contract tests**

Run: `python -m unittest -v test_static.AutomationContract`

Expected: all automation contract tests pass.

- [ ] **Step 5: Commit**

```bash
git add .github/dependabot.yml test_static.py
git commit -m "ci: add weekly Actions updates"
```

### Task 3: Private Vulnerability Reporting Policy

**Files:**
- Create: `SECURITY.md`
- Modify: `test_static.py`
- Modify: `README.md:14`

**Interfaces:**
- Produces: A policy supporting the latest `main` revision and directing undisclosed reports to `https://github.com/CtrlCarlitos/lab-vm-manager/security/advisories/new`.

- [ ] **Step 1: Write a failing security-policy contract test**

Add `test_security_policy_uses_private_reporting`. Assert `SECURITY.md` names the private advisory URL, asks reporters not to open a public issue for an undisclosed vulnerability, states that only the latest `main` revision is supported, and does not publish an email address.

- [ ] **Step 2: Run the test and verify it fails**

Run: `python -m unittest test_static.AutomationContract.test_security_policy_uses_private_reporting -v`

Expected: FAIL because `SECURITY.md` does not exist.

- [ ] **Step 3: Create the security policy**

Include supported-version scope, the private reporting link, requested reproduction/impact/environment details, a request to avoid public disclosure until a fix is available, and a response-expectation statement that does not promise a fixed deadline.

- [ ] **Step 4: Run all local Python tests**

Run: `python -m unittest -v test_static.py`

Expected: all 254 tests pass. Update `README.md` from `249` to `254` source-contract checks after this count is confirmed.

- [ ] **Step 5: Commit**

```bash
git add SECURITY.md test_static.py README.md
git commit -m "docs: add vulnerability reporting policy"
```

### Task 4: Merge Validation and Repository Protections

**Files:**
- No additional repository files.

**Interfaces:**
- Consumes: successful default-branch check context `test` from Task 1.
- Produces: vulnerability alerts and private vulnerability reporting enabled; automated security fixes disabled; active `main` branch ruleset.

- [ ] **Step 1: Run the complete local test suite before opening the pull request**

Run on Windows: `powershell.exe -NoProfile -File .\Test-LabVM.ps1` and `python -m unittest -v test_static.py`.

Expected: both suites pass with zero failures.

- [ ] **Step 2: Merge through a pull request and verify default-branch CI**

Wait for the pull request's `test` job, merge only when green, then confirm a `push` run on `main` also completes successfully. Do not create the ruleset until both facts are visible through `gh run view`.

- [ ] **Step 3: Enable passive security settings**

Run `gh api --method PUT repos/CtrlCarlitos/lab-vm-manager/vulnerability-alerts` and `gh api --method PUT repos/CtrlCarlitos/lab-vm-manager/private-vulnerability-reporting`.

Expected: both requests return HTTP 204. Verify `gh api -i repos/CtrlCarlitos/lab-vm-manager/automated-security-fixes` returns HTTP 404, which is GitHub's disabled-state response for that endpoint.

- [ ] **Step 4: Create the active default-branch ruleset**

Create one branch ruleset named `main protection`, target `branch`, enforcement `active`, condition include `~DEFAULT_BRANCH`, and no bypass actors. Add `deletion` and `non_fast_forward` rules. Add a `pull_request` rule with `required_approving_review_count: 0`, `dismiss_stale_reviews_on_push: false`, `require_code_owner_review: false`, `require_last_push_approval: false`, and `required_review_thread_resolution: true`. Add `required_status_checks` with context `test`, `strict_required_status_checks_policy: true`, and `do_not_enforce_on_create: true`.

- [ ] **Step 5: Verify repository policy**

Run `gh api repos/CtrlCarlitos/lab-vm-manager/rulesets` and inspect the created ruleset by id. Confirm its target, enforcement, default-branch condition, four rules, and required `test` context. Confirm private vulnerability reporting reports `enabled: true`, vulnerability alerts return HTTP 204, and automated security fixes remain disabled.
