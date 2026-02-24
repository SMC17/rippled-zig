# Signed Releases with Cosign

Policy companion: `docs/RELEASE_SIGNING_POLICY.md` (authoritative release-promotion requirements).
Rotation drill companion: `docs/SIGNER_KEY_ROTATION_DRILL.md` (repeatable signer key rotation procedure + evidence checklist).

rippled-zig release artifacts can be signed with **cosign** (Sigstore) when configured.

## How It Works

On tag push (e.g. `v1.0.0`), the CI workflow:

1. Builds release binaries and WASM
2. Generates `SHA256SUMS` and `PROVENANCE.json`
3. **If configured:** Signs `SHA256SUMS` with cosign → `SHA256SUMS.sig`
4. Uploads artifacts to the workflow run

## Setup

### 1. Generate a cosign key pair

```bash
cosign generate-key-pair
```

This produces `cosign.key` (private) and `cosign.pub` (public). **Keep the private key secret.**

### 2. Add GitHub repository secrets

In **Settings → Secrets and variables → Actions**:

| Secret               | Value                          |
|----------------------|--------------------------------|
| `COSIGN_PRIVATE_KEY` | Contents of `cosign.key`       |
| `COSIGN_PASSWORD`    | Password you set during gen   |

### 3. Publish the public key

Commit `cosign.pub` to the repo or publish it so users can verify:

```bash
cosign public-key --output-key cosign.pub
# Commit cosign.pub or document where to fetch it
```

## Verifying a Release

Download `SHA256SUMS`, `SHA256SUMS.sig`, and `cosign.pub`, then:

```bash
cosign verify-blob --signature SHA256SUMS.sig \
  --key cosign.pub \
  SHA256SUMS
```

If verification succeeds, you can trust the checksums and verify binaries:

```bash
sha256sum -c SHA256SUMS
```

## When Signing Is Skipped

If `COSIGN_PRIVATE_KEY` is not set, the release job still runs but does not sign. You get:

- `SHA256SUMS` (checksums)
- `PROVENANCE.json` (build metadata)
- No `SHA256SUMS.sig` (no cosign signature)

This is acceptable for development or internal builds; for public releases, configure cosign.
