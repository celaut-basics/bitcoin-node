#!/usr/bin/env bash
# Packer-layout checks against the nodo contract (dev @ 698e6583).
#
# These do not pack or run a node. They catch the class of error that PR #1 missed:
# a Docker build from the repo root succeeds, and `nodo pack` then copies the scripts
# to the wrong path because the Dockerfile COPY source does not start with `.`.
#
# Run with `bash tests/test_pack.sh`. Needs `bash`, `python3` and `jq`.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "${HERE}/.." && pwd)
SERVICE_JSON="${ROOT}/.service/service.json"
PACK_CONFIG="${ROOT}/.service/pack_config.json"
DOCKERFILE="${ROOT}/.service/Dockerfile"
README="${ROOT}/README.md"

PASSED=0
FAILED=0

ok() {
    PASSED=$(( PASSED + 1 ))
    printf '  ok    %s\n' "$1"
}

no() {
    FAILED=$(( FAILED + 1 ))
    printf '  FAIL  %s\n' "$1"
    printf '        expected: %s\n' "$2"
    printf '        got:      %s\n' "$3"
}

is() {
    if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "$2" "$1"; fi
}

contains() {
    case "$1" in
        *"$2"*) ok "$3" ;;
        *) no "$3" "something containing $2" "$1" ;;
    esac
}

absent() {
    case "$1" in
        *"$2"*) no "$3" "no $2" "$1" ;;
        *) ok "$3" ;;
    esac
}

rewrite_copy_sources() {
    # Mirror src/commands/packer/zip_with_dockerfile/prepare_directory.py:23-41.
    python3 -c '
import sys
line = sys.argv[1]
parts = line.split()
if not parts or parts[0] != "COPY":
    print(line)
    raise SystemExit(0)
flags = [p for p in parts[1:] if p.startswith("--")]
if any(f.startswith("--from") for f in flags):
    print(line)
    raise SystemExit(0)
start = 1
while start < len(parts) and parts[start].startswith("--"):
    start += 1
for j in range(start, len(parts) - 1):
    if parts[j].startswith("."):
        parts[j] = "service" + parts[j][1:]
print(" ".join(parts))
' "$1"
}

echo 'JSON'
python3 -m json.tool "${SERVICE_JSON}" >/dev/null && ok 'service.json parses' || no 'service.json parses' 'valid JSON' 'parse error'
python3 -m json.tool "${PACK_CONFIG}" >/dev/null && ok 'pack_config.json parses' || no 'pack_config.json parses' 'valid JSON' 'parse error'

echo
echo 'service.json shape'
is "$(jq -r '.architecture' "${SERVICE_JSON}")" 'linux/arm64' 'architecture is linux/arm64'
is "$(jq -r '.tag' "${SERVICE_JSON}")" 'bitcoin-node' 'tag is bitcoin-node'
is "$(jq -c '.init.entry_path' "${SERVICE_JSON}")" '["service","entrypoint.sh"]' 'entry_path is /service/entrypoint.sh'
is "$(jq -r '.api[0].port' "${SERVICE_JSON}")" '8332' 'RPC slot is 8332'
is "$(jq -r '.api[0].protocol[0]' "${SERVICE_JSON}")" 'http' 'RPC protocol is http'
is "$(jq -r '.network[0].tags[0]' "${SERVICE_JSON}")" '*' 'egress is open (*)'
prose=$(jq -r '.network[0].prose' "${SERVICE_JSON}")
isnt_empty=$( [ -n "$prose" ] && printf 'yes' || printf 'no' )
is "$isnt_empty" 'yes' 'network prose is present'
is "$(jq -r 'has("shared_filesystems")' "${SERVICE_JSON}")" 'false' \
   'no shared_filesystems (a guest share cannot run as a core service)'

for name in BITCOIN_MNEMONIC BITCOIN_MNEMONIC_PASSPHRASE BITCOIN_NETWORK \
            BITCOIN_PRUNE BITCOIN_RPC_USER BITCOIN_RPC_PASSWORD BITCOIN_WALLET_NAME; do
    jq -e --arg n "$name" '.envs | index($n) != null' "${SERVICE_JSON}" >/dev/null \
        && ok "envs names ${name}" \
        || no "envs names ${name}" "$name" 'missing'
done

echo
echo 'pack_config.json'
is "$(jq -r '.include[0]' "${PACK_CONFIG}")" 'service' 'include packs the service/ tree'
is "$(jq -r '.zip' "${PACK_CONFIG}")" 'false' 'dependencies are not zipped'

echo
echo 'Dockerfile COPY rewrite'
copy_line=$(grep -E '^COPY ' "${DOCKERFILE}" | grep -v -- '--from' | head -n1)
contains "$copy_line" 'COPY ./service /service' 'COPY source is ./service'
rewritten=$(rewrite_copy_sources "$copy_line")
is "$rewritten" 'COPY service/service /service' \
   'packer rewrites ./service to service/service'

bad_line='COPY service /service'
bad_rewritten=$(rewrite_copy_sources "$bad_line")
is "$bad_rewritten" 'COPY service /service' \
   'COPY service (no leading .) is left as-is and would miss the scripts'

grep -q 'mkdir -p /data' "${DOCKERFILE}" && ok 'image creates /data' || no 'image creates /data' 'mkdir -p /data' 'missing'
grep -q 'chmod +x /service/entrypoint.sh' "${DOCKERFILE}" \
    && ok 'entrypoint is marked executable in the image' \
    || no 'entrypoint is marked executable in the image' 'chmod +x /service/entrypoint.sh' 'missing'

echo
echo 'Scripts on disk'
[ -x "${ROOT}/service/entrypoint.sh" ] && ok 'service/entrypoint.sh is executable' \
    || no 'service/entrypoint.sh is executable' 'executable' 'not executable'
[ -x "${ROOT}/service/derive.sh" ] && ok 'service/derive.sh is executable' \
    || no 'service/derive.sh is executable' 'executable' 'not executable'
head -n1 "${ROOT}/service/entrypoint.sh" | grep -q bash \
    && ok 'entrypoint has a bash shebang' \
    || no 'entrypoint has a bash shebang' '#!/usr/bin/env bash' "$(head -n1 "${ROOT}/service/entrypoint.sh")"

echo
echo 'README CLI and contract'
readme=$(cat "${README}")
contains "$readme" 'nodo pack .' 'README uses nodo pack'
contains "$readme" 'nodo execute' 'README uses nodo execute'
contains "$readme" 'nodo kill' 'README uses nodo kill'
contains "$readme" 'BACKEND: explorer' 'README names BACKEND explorer'
absent "$readme" 'esplora' 'README does not name esplora'
absent "$readme" '`nodo run`' 'README does not use nodo run'
absent "$readme" '`nodo stop`' 'README does not use nodo stop'
absent "$readme" '`nodo build`' 'README does not use nodo build'
contains "$readme" 'shared_filesystems' 'README states why there is no share'
contains "$readme" 'no DNS' 'README states the guest has no DNS'
contains "$readme" 'regtest' 'README manual execute is on regtest'

echo
echo "--------------------------------------------------"
printf 'passed %s, failed %s\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
