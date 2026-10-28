# shellcheck shell=bash
# Shared by sign.sh and package.sh (sourced, not run): the Developer ID
# identity and notarytool's credentials.
#
#   SIGN_ID          codesign identity (default: the keychain's first
#                    "Developer ID Application")
#   NOTARY_PROFILE   notarytool keychain profile (default: nip), made once with
#                    xcrun notarytool store-credentials nip --apple-id … --team-id A2WT9CD8P3
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                    App Store Connect API key (.p8 path, key id, issuer id);
#                    used instead of the profile when set (CI)
#   NOTARIZE=0       sign only, skip notarisation

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"

if [ -n "${NOTARY_KEY:-}" ]; then
    NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID unset}" --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER unset}")
else
    NOTARY_AUTH=(--keychain-profile "${NOTARY_PROFILE:-nip}")
fi

# notarize <file>: submit, wait, print Apple's log on rejection.
notarize() {
    local out sub
    out="$(xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait 2>&1)" || true
    echo "$out" | tail -4
    if [[ "$out" != *"status: Accepted"* ]]; then
        sub="$(echo "$out" | sed -n 's/^ *id: //p' | head -1)"
        if [ -n "$sub" ]; then
            xcrun notarytool log "$sub" "${NOTARY_AUTH[@]}" >&2 || true
        fi
        echo "notarisation failed: $1" >&2
        return 1
    fi
}

# has_developer_id <path>: signed with a Developer ID (not ad hoc)?
has_developer_id() {
    # Captured first: `codesign | grep -q` fails under pipefail (SIGPIPE).
    local info
    info="$(codesign -dvv "$1" 2>&1)" || return 1
    [[ "$info" == *$'\nAuthority=Developer ID Application:'* ]]
}
