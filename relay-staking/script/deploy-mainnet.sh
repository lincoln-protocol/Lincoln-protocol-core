#!/usr/bin/env bash
# RelayStakeRegistry on Robinhood mainnet. Only your own terminal enters the keystore password.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$here/.."
forge build >/dev/null
node script/deploy-mainnet.mjs --plan
[[ -t 0 && -t 2 ]] || { echo 'Run in your own interactive terminal to enter the keystore password.' >&2; exit 1; }
echo 'Deploys RelayStakeRegistry (LINCOLN stake, 5,000,000 minimum, 14-day unbonding, guardian = Safe) from lincoln-deployer.' >&2
read -r -p 'Type DEPLOY to continue: ' answer
[[ "$answer" == 'DEPLOY' ]] || { echo 'Cancelled.' >&2; exit 1; }
umask 077
password_file="$(mktemp "${TMPDIR:-/tmp}/lincoln-relay-registry-password.XXXXXX")"
cleanup() { unset wallet_password; rm -f -- "$password_file"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
IFS= read -r -s -p 'Keystore password for lincoln-deployer (local only): ' wallet_password
printf '\n' >&2
printf '%s' "$wallet_password" > "$password_file"
unset wallet_password
node script/deploy-mainnet.mjs --deploy --password-file "$password_file"
