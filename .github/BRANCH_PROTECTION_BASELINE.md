# Branch Protection Baseline (`main`)

Apply these repository settings in GitHub:

1. Enable branch protection for `main`.
2. Require pull request before merging.
3. Require status checks to pass before merging.
4. Mark these checks as required:
   - `Gate A - Build/Test/Format (ubuntu-latest)`
   - `Gate A - Build/Test/Format (macos-latest)`
   - `Gate B - Deterministic Serialization/Hash`
   - `Gate C - Cross-Implementation Parity`
   - `Gate E - Security/Fuzz/Static`
   - `Release Readiness Summary`
5. Keep Gate D policy:
   - `Gate D - Live Testnet Conformance` is not required globally.
   - It must still emit explicit `skipped` artifact when secrets are absent.

Notes:
- This file documents policy; GitHub branch protection itself is configured in repo settings.
- If check names change in workflow YAML, update this file in the same PR.
