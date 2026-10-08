#!/usr/bin/env bash
# The disk this node needs, and the check of it at start.
#
# A node that starts on a disk too small for its chain syncs for hours, then stops with
# "Disk space is too low" and leaves a partial chain. This check stops it at start, with
# the numbers, before Core downloads anything.
#
# The sizes are Bitcoin Core's own estimates, from the chain parameters of the pinned
# release (src/kernel/chainparams.cpp of v31.1: m_assumed_blockchain_size and
# m_assumed_chain_state_size). Core's GUI uses the same numbers to warn about disk.
# Units are GB (10^9 bytes). The chains grow: update the numbers with BITCOIN_VERSION.
#
# Sourced by entrypoint.sh and by tests/test_disk.sh. It defines functions only.

DISK_GB=1000000000

# Room for the block index, the wallet, debug.log, and the prune margin: Core deletes
# whole block files (up to 128 MiB each) and keeps the last 288 blocks.
DISK_HEADROOM_GB=2

# "<block data GB> <chainstate GB>" for a Core chain name.
disk_estimate() {
    case "$1" in
        main)    printf '856 14' ;;
        test)    printf '245 19' ;;
        signet)  printf '24 4' ;;
        regtest) printf '0 0' ;;
        *) return 1 ;;
    esac
}

# Bytes that <chain> needs with a prune of <MiB>. 0 is the whole chain and a txindex.
disk_need_bytes() {
    local chain=$1 prune_mib=$2 estimate blocks_gb state_gb blocks prune
    estimate=$(disk_estimate "$chain") || return 1
    read -r blocks_gb state_gb <<< "$estimate"
    blocks=$(( blocks_gb * DISK_GB ))
    if [ "$prune_mib" -ne 0 ]; then
        prune=$(( prune_mib * 1024 * 1024 ))
        [ "$prune" -lt "$blocks" ] && blocks=$prune
    else
        # The txindex is not in Core's estimate. 10 % of the block data is more than it
        # takes on mainnet.
        blocks=$(( blocks + blocks / 10 ))
    fi
    printf '%s' $(( blocks + (state_gb + DISK_HEADROOM_GB) * DISK_GB ))
}

# Bytes that the chain can use in <dir>: the free space, plus what the data directory
# already holds (a restart does not need that space a second time).
disk_have_bytes() {
    local dir=$1 free used
    # POSIX output (-P) in KiB (-k): one line per file system, the free space in field 4.
    free=$(df -P -k "$dir" 2>/dev/null | awk 'NR == 2 { print $4 }') || return 1
    case "$free" in ''|*[!0-9]*) return 1 ;; esac
    used=$(du -s -k "$dir" 2>/dev/null | cut -f1) || used=0
    case "$used" in ''|*[!0-9]*) used=0 ;; esac
    printf '%s' $(( (free + used) * 1024 ))
}

# Bytes as GB with one decimal.
disk_gb() {
    printf '%d.%d' $(( $1 / DISK_GB )) $(( ($1 % DISK_GB) * 10 / DISK_GB ))
}

# Compare the disk with the need. On success, set DISK_NEED and DISK_HAVE (bytes) and
# return 0. If the chain does not fit, set DISK_MESSAGE and return 1. If the disk cannot
# be read, set DISK_MESSAGE and return 2.
# Arguments: data directory, Core chain name, network name, prune MiB.
disk_check() {
    local dir=$1 chain=$2 network=$3 prune_mib=$4 kept
    DISK_MESSAGE=''
    DISK_NEED=$(disk_need_bytes "$chain" "$prune_mib") || {
        DISK_MESSAGE="no disk estimate for the chain '${chain}'"
        return 2
    }
    DISK_HAVE=$(disk_have_bytes "$dir") || {
        DISK_MESSAGE="cannot read the free disk space of ${dir}"
        return 2
    }
    [ "$DISK_HAVE" -ge "$DISK_NEED" ] && return 0

    if [ "$prune_mib" -ne 0 ]; then
        kept="BITCOIN_PRUNE=${prune_mib} MiB"
    else
        kept="BITCOIN_PRUNE=0 (the whole chain and a txindex)"
    fi
    DISK_MESSAGE="not enough disk for ${network} with ${kept}. It needs about $(disk_gb "$DISK_NEED") GB in ${dir}, and ${dir} has $(disk_gb "$DISK_HAVE") GB. Give the instance more disk (resources.disk_space in service.json), or set a smaller BITCOIN_PRUNE (550 MiB or more)."
    return 1
}
