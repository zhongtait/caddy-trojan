#!/usr/bin/env bash
# Offline regression tests for the release-manifest Sigstore policy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

test_root=$(mktemp -d)
cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

manifest="${test_root}/SHA256SUMS"
bundle="${test_root}/SHA256SUMS.sigstore.json"
fake_cosign="${test_root}/cosign"
fake_log="${test_root}/cosign.args"
printf '%s\n' 'digest  artifact.tar.gz' > "$manifest"
printf '%s\n' '{}' > "$bundle"

cat > "$fake_cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$FAKE_COSIGN_LOG"
[ "${FAKE_COSIGN_RESULT:-pass}" = pass ]
EOF
chmod 755 "$fake_cosign"

# Source only the bootstrap functions; no modules, root checks, or network.
export EASYTROJAN_SOURCE_ONLY=1
. "$ROOT/easytrojan.sh"
. "$ROOT/lib/caddy.sh"
. "$ROOT/lib/manage.sh"
export EASYTROJAN_COSIGN_BIN="$fake_cosign"
export FAKE_COSIGN_LOG="$fake_log"

if _easytrojan_verify_release_manifest "$manifest" "${test_root}/missing.sigstore.json" "$test_root"; then
    fail "missing signature was accepted without the compatibility flag"
fi

EASYTROJAN_ALLOW_UNSIGNED_RELEASE=1 \
    _easytrojan_verify_release_manifest "$manifest" "${test_root}/missing.sigstore.json" "$test_root" \
    || fail "explicit legacy compatibility flag did not permit an unsigned release"

FAKE_COSIGN_RESULT=fail EASYTROJAN_ALLOW_UNSIGNED_RELEASE=1 \
    _easytrojan_verify_release_manifest "$manifest" "$bundle" "$test_root" \
    && fail "invalid signature was accepted even with the compatibility flag"

FAKE_COSIGN_RESULT=pass EASYTROJAN_ALLOW_UNSIGNED_RELEASE=0 \
    _easytrojan_verify_release_manifest "$manifest" "$bundle" "$test_root" \
    || fail "valid signature was rejected"

grep -F -- '--bundle ' "$fake_log" >/dev/null \
    || fail "cosign was not invoked with the Sigstore bundle"
grep -F -- "--certificate-identity ${EASYTROJAN_RELEASE_SIGNER_IDENTITY}" "$fake_log" >/dev/null \
    || fail "cosign signer identity policy was not passed"
grep -F -- "--certificate-oidc-issuer ${EASYTROJAN_RELEASE_OIDC_ISSUER}" "$fake_log" >/dev/null \
    || fail "cosign OIDC issuer policy was not passed"

# Exercise the complete release snapshot path with a fake HTTP client. This
# keeps the test offline while covering asset selection, digest checking, and
# the missing-signature compatibility branch.
asset_root="${test_root}/assets"
mkdir -p "${asset_root}/tree/lib" "${test_root}/fake-bin"
printf '#!/bin/bash\n' > "${asset_root}/tree/easytrojan.sh"
printf 'print(1)\n' > "${asset_root}/tree/hub_server.py"
printf ':\n' > "${asset_root}/tree/lib/common.sh"
tar -czf "${asset_root}/easytrojan_bundle.tar.gz" -C "${asset_root}/tree" easytrojan.sh hub_server.py lib
printf '%s  %s\n' "$(_easytrojan_sha256_file "${asset_root}/easytrojan_bundle.tar.gz")" easytrojan_bundle.tar.gz > "${asset_root}/SHA256SUMS"
printf '%s\n' '{}' > "${asset_root}/SHA256SUMS.sigstore.json"
cat > "${test_root}/fake-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="" output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output="${2:-}"; shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[ -n "$output" ] || exit 22
case "$url" in
    "${FAKE_RELEASE_URL}/easytrojan_bundle.tar.gz") cp "$FAKE_ASSET_ROOT/easytrojan_bundle.tar.gz" "$output" ;;
    "${FAKE_RELEASE_URL}/SHA256SUMS") cp "$FAKE_ASSET_ROOT/SHA256SUMS" "$output" ;;
    "${FAKE_RELEASE_URL}/SHA256SUMS.sigstore.json")
        [ "${FAKE_CURL_NO_SIG:-0}" = 1 ] && exit 22
        cp "$FAKE_ASSET_ROOT/SHA256SUMS.sigstore.json" "$output"
        ;;
    *) exit 22 ;;
esac
EOF
chmod 755 "${test_root}/fake-bin/curl"
release_url=https://example.invalid/release
release_stage="${test_root}/release-stage"
if ! PATH="${test_root}/fake-bin:${PATH}" \
    FAKE_RELEASE_URL="$release_url" FAKE_ASSET_ROOT="$asset_root" \
    _easytrojan_fetch_release_snapshot "$release_stage" "$release_url"; then
    fail "signed release snapshot download failed"
fi
[ -f "${release_stage}/unpack/easytrojan.sh" ] \
    || fail "signed release snapshot was not unpacked"

missing_sig_stage="${test_root}/missing-sig-stage"
if PATH="${test_root}/fake-bin:${PATH}" \
    FAKE_RELEASE_URL="$release_url" FAKE_ASSET_ROOT="$asset_root" FAKE_CURL_NO_SIG=1 \
    _easytrojan_fetch_release_snapshot "$missing_sig_stage" "$release_url"; then
    fail "release without signature was accepted by default"
fi
legacy_sig_stage="${test_root}/legacy-sig-stage"
if ! PATH="${test_root}/fake-bin:${PATH}" \
    FAKE_RELEASE_URL="$release_url" FAKE_ASSET_ROOT="$asset_root" FAKE_CURL_NO_SIG=1 \
    EASYTROJAN_ALLOW_UNSIGNED_RELEASE=1 \
    _easytrojan_fetch_release_snapshot "$legacy_sig_stage" "$release_url"; then
    fail "legacy unsigned release was not accepted with explicit compatibility flag"
fi

grep -F 'SHA256SUMS.sigstore.json' lib/caddy.sh >/dev/null \
    || fail "Caddy asset download does not request the signed manifest"
grep -F 'SHA256SUMS.sigstore.json' .github/workflows/release.yml >/dev/null \
    || fail "Release workflow does not publish the signed manifest"
awk '/^          files: \|/{in_files=1; next} in_files && /^          [^ ]/{exit} in_files {print}' \
    .github/workflows/release.yml | grep -Fx '            artifacts/SHA256SUMS.sigstore.json' >/dev/null \
    || fail "Release workflow does not upload the signed manifest asset"
grep -F 'target_commitish: ${{ needs.metadata.outputs.source_sha }}' .github/workflows/release.yml >/dev/null \
    || fail "Release tag is not pinned to the tested source commit"
grep -F 'overwrite_files: false' .github/workflows/release.yml >/dev/null \
    || fail "Release assets are still allowed to overwrite an existing tag"
grep -Eq 'uses: softprops/action-gh-release@[0-9a-f]{40}$' .github/workflows/release.yml \
    || fail "High-privilege Release action is not pinned to a commit"
grep -F 'needs: [check, gate]' .github/workflows/test.yml >/dev/null \
    || fail "Upstream SHA can be committed before candidate gates pass"
if awk '/^  publish:/{in_publish=1} in_publish {print}' .github/workflows/release.yml \
    | grep -Eq 'id-token:[[:space:]]*write|/caddy.*version'; then
    fail "Publish job has OIDC permission or executes the upstream Caddy binary"
fi
if awk '/^  sign:/{in_sign=1} /^  publish:/{in_sign=0} in_sign {print}' \
    .github/workflows/release.yml | grep -Eq 'contents:[[:space:]]*write'; then
    fail "Signing job can write repository contents"
fi

# Update staging must choose a signed Release before the legacy repository
# snapshot, and a failed default path must not mutate the staging directory.
update_stage="${test_root}/update-stage"
mkdir -p "$update_stage"
printf '%s\n' unchanged > "${update_stage}/sentinel"
update_calls="${test_root}/update-calls"
: > "$update_calls"
_easytrojan_fetch_release_snapshot() {
    printf '%s\n' release >> "$update_calls"
    return 1
}
_easytrojan_fetch_repository_snapshot() {
    printf '%s\n' repository >> "$update_calls"
    return 0
}
unset EASYTROJAN_ALLOW_UNSIGNED_RELEASE
if stage_easytrojan_update_snapshot "$update_stage" https://example.invalid/release; then
    fail "unsigned repository fallback was accepted without the compatibility flag"
fi
[ "$(tr '\n' ' ' < "$update_calls")" = "release " ] \
    || fail "default update staging did not stop after the signed Release failed"
grep -qx unchanged "${update_stage}/sentinel" \
    || fail "failed default update staging mutated existing files"

: > "$update_calls"
EASYTROJAN_ALLOW_UNSIGNED_RELEASE=1 \
    stage_easytrojan_update_snapshot "$update_stage" https://example.invalid/release \
    || fail "legacy compatibility path did not use the immutable repository snapshot"
[ "$(tr '\n' ' ' < "$update_calls")" = "release repository " ] \
    || fail "legacy update staging did not preserve Release-first ordering"

# Caddy archives must contain exactly one regular top-level caddy file.
caddy_tree="${test_root}/caddy-tree"
mkdir -p "$caddy_tree/good" "$caddy_tree/link" "$caddy_tree/extra" "$caddy_tree/empty"
printf 'binary\n' > "$caddy_tree/good/caddy"
ln -s target "$caddy_tree/link/caddy"
printf 'binary\n' > "$caddy_tree/extra/caddy"
printf 'unexpected\n' > "$caddy_tree/extra/README"
tar -czf "$caddy_tree/good.tar.gz" -C "$caddy_tree/good" caddy
tar -czf "$caddy_tree/link.tar.gz" -C "$caddy_tree/link" caddy
tar -czf "$caddy_tree/extra.tar.gz" -C "$caddy_tree/extra" caddy README
tar -czf "$caddy_tree/empty.tar.gz" -C "$caddy_tree/empty" .
validate_caddy_archive "$caddy_tree/good.tar.gz" \
    || fail "valid Caddy archive was rejected"
if validate_caddy_archive "$caddy_tree/link.tar.gz"; then
    fail "Caddy symlink archive was accepted"
fi
if validate_caddy_archive "$caddy_tree/extra.tar.gz"; then
    fail "Caddy archive with an extra path was accepted"
fi
if validate_caddy_archive "$caddy_tree/empty.tar.gz"; then
    fail "empty Caddy archive was accepted"
fi

executed_help=$(EASYTROJAN_SOURCE_ONLY=1 bash "$ROOT/easytrojan.sh" --help 2>&1) \
    || fail "executed entry failed when source-only variable was present"
printf '%s\n' "$executed_help" | grep -qi 'usage' \
    || fail "source-only test hook incorrectly bypassed an executed entry"

printf '[OK] release manifest signature policy (missing/legacy/invalid/valid)\n'
