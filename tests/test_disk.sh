#!/usr/bin/env bash
# The disk check of service/disk.sh: the need for each network and prune value, and the
# answer for a disk that is too small, large enough, or not readable.
#
# Run with `bash tests/test_disk.sh`. Needs `bash` and coreutils. No bitcoind is
# started; the free space is replaced by fixed values, except in the last check.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../service/disk.sh
. "${HERE}/../service/disk.sh"

PASSED=0
FAILED=0

check() {   # name, expected, actual
    if [ "$2" = "$3" ]; then
        PASSED=$(( PASSED + 1 ))
        printf '  ok    %s\n' "$1"
    else
        FAILED=$(( FAILED + 1 ))
        printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
    fi
}

GB=1000000000
MIB=1048576

echo 'need'
# Pruned: the prune target, the chainstate, and 2 GB of headroom.
check 'mainnet, default prune 10000 MiB' \
    $(( 10000 * MIB + 16 * GB )) "$(disk_need_bytes main 10000)"
check 'mainnet, prune 550 MiB' \
    $(( 550 * MIB + 16 * GB )) "$(disk_need_bytes main 550)"
check 'testnet3, default prune' \
    $(( 10000 * MIB + 21 * GB )) "$(disk_need_bytes test 10000)"
check 'signet, default prune' \
    $(( 10000 * MIB + 6 * GB )) "$(disk_need_bytes signet 10000)"
# A prune larger than the whole chain needs no more than the whole chain.
check 'signet, prune larger than the chain' \
    $(( 24 * GB + 6 * GB )) "$(disk_need_bytes signet 100000)"
check 'regtest, default prune' $(( 2 * GB )) "$(disk_need_bytes regtest 10000)"
# Whole chain: the block data, 10 % for the txindex, the chainstate, the headroom.
check 'mainnet, whole chain' \
    $(( 856 * GB + 856 * GB / 10 + 16 * GB )) "$(disk_need_bytes main 0)"
check 'signet, whole chain' \
    $(( 24 * GB + 24 * GB / 10 + 6 * GB )) "$(disk_need_bytes signet 0)"
check 'regtest, whole chain' $(( 2 * GB )) "$(disk_need_bytes regtest 0)"
disk_need_bytes nochain 0 >/dev/null; check 'unknown chain is an error' 1 "$?"

echo 'declared disk'
# service.json declares 32 GB. The default prune must fit it on mainnet.
DECLARED=$(jq -r '.resources.at_init.disk_space' "${HERE}/../amd64/.service/service.json" 2>/dev/null)
if [ -n "$DECLARED" ] && [ "$DECLARED" != null ]; then
    fits=no; [ "$(disk_need_bytes main 10000)" -le "$DECLARED" ] && fits=yes
    check 'mainnet with the default prune fits the declared disk' yes "$fits"
    fits=no; [ "$(disk_need_bytes main 0)" -le "$DECLARED" ] && fits=yes
    check 'the whole mainnet chain does not fit the declared disk' no "$fits"
else
    echo '  skip  jq is not installed'
fi

echo 'check'
disk_have_bytes() { printf '%s' "$FAKE_HAVE"; }

FAKE_HAVE=$(( 31 * GB ))
status=0; disk_check /data main mainnet 10000 || status=$?
check 'mainnet, default prune, 31 GB: passes' 0 "$status"
check 'mainnet, default prune, 31 GB: need is set' "$(disk_need_bytes main 10000)" "$DISK_NEED"

FAKE_HAVE=$(( 16 * GB ))
status=0; disk_check /data main mainnet 10000 || status=$?
check 'mainnet, default prune, 16 GB: fails' 1 "$status"
case "$DISK_MESSAGE" in
    'not enough disk for mainnet with BITCOIN_PRUNE=10000 MiB. It needs about 26.4 GB in /data, and /data has 16.0 GB.'*)
        check 'the message names the network, prune, need and free space' yes yes ;;
    *) check 'the message names the network, prune, need and free space' 'not enough disk for mainnet ...' "$DISK_MESSAGE" ;;
esac

FAKE_HAVE=$(( 31 * GB ))
status=0; disk_check /data signet signet 0 || status=$?
check 'signet, whole chain, 31 GB: fails' 1 "$status"
case "$DISK_MESSAGE" in
    *'BITCOIN_PRUNE=0 (the whole chain and a txindex)'*) check 'the message says whole chain' yes yes ;;
    *) check 'the message says whole chain' 'BITCOIN_PRUNE=0 (...)' "$DISK_MESSAGE" ;;
esac

disk_have_bytes() { return 1; }
status=0; disk_check /data main mainnet 10000 || status=$?
check 'unreadable disk: status 2' 2 "$status"

echo 'free space'
unset -f disk_have_bytes
. "${HERE}/../service/disk.sh"
DIR=$(mktemp -d)
have=$(disk_have_bytes "$DIR"); status=$?
check 'a real directory gives a number' 0 "$status"
case "$have" in ''|*[!0-9]*) check 'the number is bytes' digits "$have" ;; *) check 'the number is bytes' yes yes ;; esac
rmdir "$DIR"

echo "${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
