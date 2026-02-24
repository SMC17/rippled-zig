# Signer Key Rotation Drill

Status: Operational runbook for rotating release-signing keys while preserving verifier continuity.

Scope:
- cosign key rotation for release signing (`SHA256SUMS.sig`)
- documentation/evidence updates required by release policy
- rollback path for failed rotations

This runbook complements:
- `docs/RELEASE_SIGNING.md`
- `docs/RELEASE_SIGNING_POLICY.md`

## Objectives
- rotate signing keys without breaking current release verification discipline
- preserve historical verification guidance for previously signed releases
- produce auditable evidence of the rotation change

## Preconditions
- Maintainer access to GitHub Actions secrets
- Existing public key location documented (e.g., `cosign.pub`)
- Ability to run a dry-run verification locally with cosign

Recommended timing:
- between releases (not mid-incident unless emergency rotation is required)

## Prepare
1. Record current signer state:
   - current public key fingerprint
   - current publication path (repo file or documented URL)
   - most recent signed release tag verified with current key
2. Export a local copy of the current public key (`cosign.pub`) for rollback/reference.
3. Confirm current verification path still works:
   - `cosign verify-blob --signature SHA256SUMS.sig --key cosign.pub SHA256SUMS`
4. Open a change record (issue/PR) noting planned rotation window and operator.

## Rotate (Staged)
1. Generate new key pair:
   - `cosign generate-key-pair`
2. Store new private key material in GitHub Actions:
   - update `COSIGN_PRIVATE_KEY`
   - update `COSIGN_PASSWORD` (if used)
3. Publish the new public key (or versioned public key path).
4. Update verifier docs/reference paths if publication location changed.
5. Preserve previous public key for historical release verification (archive path or versioned file).

## Verify (Post-Rotation)
1. Trigger a release-provenance capable workflow on a test tag or controlled release candidate.
2. Confirm artifacts include:
   - `SHA256SUMS`
   - `PROVENANCE.json`
   - `SHA256SUMS.sig`
3. Verify with the new public key:
   - `cosign verify-blob --signature SHA256SUMS.sig --key <new-pubkey> SHA256SUMS`
4. Verify checksum chain:
   - `sha256sum -c SHA256SUMS`
5. Confirm release docs still describe how to verify older releases (previous key location retained/documented).

## Rollback (If Verification Fails)
1. Restore previous `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` in GitHub Actions secrets.
2. Restore previous public-key reference in docs/publication path.
3. Re-run release-provenance workflow and confirm signature verification succeeds with previous key.
4. Document failure cause and do not delete failed rotation artifacts; mark them non-promoted.

## Evidence Checklist (Attach to PR / Release Decision)
- Rotation date/time and operator
- Old key fingerprint (or identifier)
- New key fingerprint (or identifier)
- Updated public key publication path
- Proof of GitHub Actions secret update (change confirmation, not secret contents)
- Verification command output (new key) for rotated test artifact
- Confirmation that historical key remains available for prior release verification
- Link to updated docs:
  - `docs/RELEASE_SIGNING.md`
  - `docs/RELEASE_SIGNING_POLICY.md`
  - `docs/SIGNER_KEY_ROTATION_DRILL.md`

## Historical Verification Compatibility Rule
Never replace historical verification instructions with only the newest key reference.

Minimum acceptable posture:
- current key documented for new releases
- prior key retained/documented for older releases signed before rotation

## Emergency Rotation Notes
If rotation is triggered by suspected key compromise:
1. Stop claiming production-oriented release promotion until new key is verified.
2. Treat all signatures produced after suspected compromise time as untrusted until reviewed.
3. Publish a short incident note with affected tag range and verifier guidance.
