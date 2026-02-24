# Historical Docs Index

Status: index of removed/stale documentation that is no longer part of the active GitHub-facing doc set.

## Purpose
- reduce noise in the active repository root/docs surface
- preserve discoverability of historical material
- clarify that canonical project truth lives in current docs and gate evidence

## Retrieval Policy
Historical docs remain recoverable via:
1. Git history (`git log -- <path>`, `git show <sha>:<path>`)
2. Local ignored archive folder (maintainer convenience):
   - `.docs_archive_local/`

The local archive folder is intentionally gitignored and is not authoritative.

## Moved/Retired Historical Docs (2026-02-24 cleanup)
- `HONEST_PARITY_ASSESSMENT.md`
- `PARITY_PROGRESS.md`
- `READY_FOR_LAUNCH.md`
- `READY_TO_LAUNCH.md`
- `LAUNCH_ANNOUNCEMENT.md`
- `LAUNCH_CHECKLIST.md`
- `TASK_BOARD_14_DAYS.md`
- `TEST_COVERAGE_PLAN.md`
- `WEEK2_SECP256K1_INTEGRATION.md`
- `docs/status/PROJECT_SUMMARY.md`
- `docs/status/FEATURE_VERIFICATION.md`
- `docs/status/ED25519_API_FIX.md`
- `docs/status/LEDGER_HASH_FIX.md`

## Canonical Replacements
- Operational status / release decision: `PROJECT_STATUS.md`
- Execution milestones / next steps: `docs/ROADMAP.md`
- Parity program / evidence levels: `docs/ROADMAP_TO_PARITY.md`
- Module maturity / ownership / risk: `docs/status/ARCHITECTURE_SOT.md`
- Backlog and priorities: `docs/status/AGENT_NATIVE_BACKLOG.md`
- Runtime policy boundaries: `docs/CONTROL_PLANE_POLICY.md`
- Automation/release safety policy: `docs/AGENT_AUTOMATION_POLICY.md`, `docs/RELEASE_SIGNING_POLICY.md`
