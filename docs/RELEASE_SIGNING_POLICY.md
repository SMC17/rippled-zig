# Release Signing Policy

Status: Active policy for signed release artifacts and verification.

## Purpose
Define a deterministic, reviewable release artifact chain so production-oriented claims are tied to verifiable provenance.

## Scope
- Tag-triggered release artifacts from CI
- Checksum/signature/provenance outputs
- Verifier workflow for downstream users/operators

## Required Release Artifacts
For each release tag:
- `rippled-zig` binary
- built WASM artifacts (when produced by workflow)
- `SHA256SUMS`
- `PROVENANCE.json`
- `SHA256SUMS.sig` (required for signed release posture)

## Signing Format
- Sign `SHA256SUMS` using `cosign sign-blob`.
- Verification target is checksum manifest integrity; binary verification is chained through checksum validation.

Reference workflow:
- `.github/workflows/ci.yml` (`release-provenance` job)

## Key Management Assumptions
- Private signing key (`COSIGN_PRIVATE_KEY`) is stored only as GitHub Actions secret.
- Optional key password (`COSIGN_PASSWORD`) is stored as secret.
- Public key is published for verifiers (`cosign.pub` or documented retrieval path).
- Key rotation requires updating verifier docs and preserving historical verification guidance.

## Release Promotion Requirements
Before promoting a tag as production-oriented:
1. Gate A/B/C/E green on candidate commit.
2. Gate D green or explicitly skipped per policy with artifact reason.
3. Release artifact set present.
4. `SHA256SUMS.sig` present and verifiable with published public key.
5. `PROJECT_STATUS.md` updated with evidence references.

Security artifact integrity note:
- Gate E decision inputs (`security-metrics.json`, `security-trend-summary-7d.json` when generated) are now schema-checked in `scripts/gates/gate_e.sh` to prevent silent artifact format drift before release decisions.

If signing is unavailable, release may be published for development/internal use only and must not be represented as production-oriented.

## Verifier Runbook
Given release artifacts and public key:

```bash
cosign verify-blob \
  --signature SHA256SUMS.sig \
  --key cosign.pub \
  SHA256SUMS

sha256sum -c SHA256SUMS
```

Verification succeeds only when:
- cosign signature check passes
- checksum verification for downloaded artifacts passes

## Failure Handling
- Missing signature: mark release as unsigned/non-production.
- Signature mismatch: treat artifacts as untrusted, halt promotion.
- Checksum mismatch: treat specific artifact as tampered/corrupt, halt promotion.

## Operational Ownership
- Security owner: signing policy and key lifecycle
- Release owner: artifact publication and evidence linkage
- Engineering owner: workflow integrity and reproducibility
