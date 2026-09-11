#!/usr/bin/env bash
# Bring up a bitcoind whose wallet is the one these twelve words describe.
#
# The whole service, in order: write a configuration from the environment, start Core,
# derive the account key from BITCOIN_MNEMONIC, import it as a descriptor wallet, prove to
# itself that the wallet Core loaded is the one it derived, and then stay out of the way
# while Core runs.
#
# Three things it is careful about, because each one is a way to lose money quietly:
#
# * It proves the wallet. After importing, it asks Core where a fresh address comes from
#   and refuses to serve if the answer is not this mnemonic's master fingerprint at the
#   documented path. A bitcoind holding a *valid* wallet that is not the operator's is
#   the failure nobody notices until they look for the funds.
# * It shuts Core down properly. A killed bitcoind can leave a corrupt chainstate, which
#   on a pruned node means downloading the chain again. SIGTERM is forwarded as `stop`
#   and waited on.
# * It never logs the secret. Not the mnemonic, not the xprv, not the RPC password. What
#   it prints is what an operator needs to see: which network, which wallet, the
#   fingerprint, and the first receiving address.
#
# On that last point, in a shell specifically: `set -x` is never turned on, the two
# commands that are handed a descriptor have their output captured rather than shown, and
# every failure message here names what went wrong without quoting what it was given.

set -euo pipefail

# shellcheck source=derive.sh
. "$(dirname "$(readlink -f "$0")")/derive.sh"

DATA_DIR="${BITCOIN_DATADIR:-/data}"
CONF_PATH="${DATA_DIR}/bitcoin.conf"

# The same port on every network, so the node that launches this has one endpoint to talk
# to and does not have to know which chain it asked for.
RPC_PORT=8332

# Core's own floor. Below it bitcoind refuses to start, and a service that never comes up
# is a worse way to learn that than a message here.
MIN_PRUNE_MIB=550

CORE_PID=''
STOPPING=''
# Core's own exit status, once something has collected it. A service that stopped cleanly
# and a service that was killed have to be distinguishable from outside the container, so
# this is what the script exits with rather than the signal that started the shutdown.
CORE_STATUS=''

log() {
    printf '[bitcoin-node] %s\n' "$1"
}

fail() {
    log "FATAL: $1"
    stop_core 'startup'
    exit 1
}

network_chain() {
    case "$1" in
        mainnet) printf 'main' ;;
        testnet) printf 'test' ;;
        signet)  printf 'signet' ;;
        regtest) printf 'regtest' ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------ environment
# What the node passed in, validated. The contract is documented in the README.
read_environment() {
    MNEMONIC=$(printf '%s' "${BITCOIN_MNEMONIC:-}" | tr -s ' \t\n\r' ' ')
    MNEMONIC="${MNEMONIC# }"
    MNEMONIC="${MNEMONIC% }"
    if [ -z "$MNEMONIC" ]; then
        fail "BITCOIN_MNEMONIC is empty. This service exists to hold a wallet; without one there is nothing for Core to sign with."
    fi

    PASSPHRASE="${BITCOIN_MNEMONIC_PASSPHRASE:-}"

    RPC_USER="${BITCOIN_RPC_USER:-}"
    RPC_USER="${RPC_USER#"${RPC_USER%%[![:space:]]*}"}"
    RPC_USER="${RPC_USER%"${RPC_USER##*[![:space:]]}"}"
    RPC_PASSWORD="${BITCOIN_RPC_PASSWORD:-}"
    if [ -z "$RPC_USER" ] || [ -z "$RPC_PASSWORD" ]; then
        fail "BITCOIN_RPC_USER and BITCOIN_RPC_PASSWORD are what the node authenticates with; Core's cookie file is not reachable from outside this container."
    fi

    NETWORK="${BITCOIN_NETWORK:-}"
    NETWORK="${NETWORK#"${NETWORK%%[![:space:]]*}"}"
    NETWORK="${NETWORK%"${NETWORK##*[![:space:]]}"}"
    NETWORK="${NETWORK:-mainnet}"
    if ! CHAIN=$(network_chain "$NETWORK"); then
        fail "BITCOIN_NETWORK='${NETWORK}' is not one of mainnet, testnet, signet, regtest"
    fi

    local raw_prune="${BITCOIN_PRUNE:-}"
    raw_prune="${raw_prune#"${raw_prune%%[![:space:]]*}"}"
    raw_prune="${raw_prune%"${raw_prune##*[![:space:]]}"}"
    if [ -z "$raw_prune" ]; then
        PRUNE=0
    else
        case "$raw_prune" in
            ''|*[!0-9]*) fail "BITCOIN_PRUNE='${raw_prune}' is not a whole number of MiB" ;;
        esac
        PRUNE=$(( 10#$raw_prune ))
    fi
    if [ "$PRUNE" -ne 0 ] && [ "$PRUNE" -lt "$MIN_PRUNE_MIB" ]; then
        fail "BITCOIN_PRUNE=${PRUNE} is below Core's floor of ${MIN_PRUNE_MIB} MiB. Use 0 to keep the whole chain, or a value from 550 up."
    fi

    WALLET="${BITCOIN_WALLET_NAME:-}"
    WALLET="${WALLET#"${WALLET%%[![:space:]]*}"}"
    WALLET="${WALLET%"${WALLET##*[![:space:]]}"}"
    WALLET="${WALLET:-nodo}"
}

# --------------------------------------------------------------- configuration
# Core's salted `rpcauth` line, so the plaintext password is not in a file.
#
# The node has to know the password -- it authenticates with it -- but nothing is served
# by writing it to disk as well. This is the same construction `share/rpcauth/rpcauth.py`
# in Core's own tree produces: a 16-byte random salt in hex, and HMAC-SHA256 of the
# password keyed by the *hex digits of the salt* as ASCII, which is what Core's own
# `HMAC-SHA256` check recomputes.
rpcauth_line() {   # user, password
    local salt digest
    salt=$(openssl rand -hex 16)
    digest=$(derive_hmac_sha256 "$(derive_hex_of "$salt")" "$(derive_hex_of "$2")")
    printf 'rpcauth=%s:%s$%s' "$1" "$salt" "$digest"
}

write_configuration() {
    mkdir -p "$DATA_DIR"
    # The file holds an rpcauth line; it is no one else's business on a shared filesystem.
    local previous_umask
    previous_umask=$(umask)
    umask 077
    {
        printf '%s\n' '# Written at every start from this service'"'"'s environment. Editing it by hand'
        printf '%s\n' '# has no lasting effect: the next start overwrites it.'
        printf 'chain=%s\n' "$CHAIN"
        printf '%s\n' 'server=1'
        printf '%s\n' "$(rpcauth_line "$RPC_USER" "$RPC_PASSWORD")"
        if [ "$PRUNE" -ne 0 ]; then
            printf 'prune=%s\n' "$PRUNE"
        else
            # The whole chain, and an index over it. `getrawtransaction` on an arbitrary
            # transaction needs it; a pruned node cannot have it, which is why the node
            # asking the questions reads its own wallet's transactions through the wallet.
            printf '%s\n' 'txindex=1'
        fi
        # Core refuses to start if a network-specific setting appears at the top level of
        # the file on any chain but main: `rpcbind` and `rpcport` mean something different
        # on each network, and it will not guess which one was meant. They go in the
        # section for the chain that was asked for -- which is the same port on every one
        # of them, because the node talking to this has one endpoint and does not have to
        # know which chain it got.
        printf '\n[%s]\n' "$CHAIN"
        printf '%s\n' 'listen=1'
        # The RPC is this service's whole interface, and the only thing that can reach it
        # is what the node running this service exposes: an instance's network is the
        # node's firewall, not this file's business.
        printf '%s\n' 'rpcbind=0.0.0.0'
        printf '%s\n' 'rpcallowip=0.0.0.0/0'
        printf 'rpcport=%s\n' "$RPC_PORT"
    } > "$CONF_PATH"
    umask "$previous_umask"

    if [ "$PRUNE" -ne 0 ]; then
        log "configuration written for ${NETWORK}, pruned to ${PRUNE} MiB"
    else
        log "configuration written for ${NETWORK}, full chain with txindex"
    fi
}

# ------------------------------------------------------------------ bitcoin-cli
# `bitcoin-cli` against this node. Prints stdout; returns non-zero on a failure, and the
# caller decides whether that is fatal. stderr is passed through only for the calls that
# carry nothing secret.
cli() {
    bitcoin-cli "-conf=${CONF_PATH}" "-datadir=${DATA_DIR}" "$@"
}

cli_wallet() {
    bitcoin-cli "-conf=${CONF_PATH}" "-datadir=${DATA_DIR}" "-rpcwallet=${WALLET}" "$@"
}

# The two calls that are handed a descriptor. Their stderr is dropped, because a Core
# error for a malformed descriptor quotes the descriptor -- and that string contains the
# xprv.
cli_wallet_quiet() {
    bitcoin-cli "-conf=${CONF_PATH}" "-datadir=${DATA_DIR}" "-rpcwallet=${WALLET}" "$@" 2>/dev/null
}

# Until Core answers. It loads the block index first, which is not instant.
wait_for_rpc() {
    local timeout="${1:-600}" deadline=$(( SECONDS + ${1:-600} ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if cli -rpcclienttimeout=10 getblockchaininfo >/dev/null 2>&1; then
            return 0
        fi
        # Not up yet, or still loading the block index. Polling rather than `-rpcwait` so
        # the deadline above is the one that decides. A Core that has already died is not
        # worth waiting six hundred seconds for.
        if [ -n "$CORE_PID" ] && ! kill -0 "$CORE_PID" 2>/dev/null; then
            fail "Core exited while starting up"
        fi
        sleep 2
    done
    fail "Core did not answer its RPC within ${timeout}s"
}

# ---------------------------------------------------------------------- wallet
# Create the wallet and import the mnemonic's descriptors, once.
#
# Idempotent, because this runs on every start and the wallet outlives none, some or all
# of them depending on what the node did with this instance's filesystem. A wallet that is
# already there is loaded and left alone: re-importing would be harmless but a rescan on a
# pruned node is not.
ensure_wallet() {
    local known loaded

    known=$(cli listwalletdir 2>/dev/null | jq -r '.wallets[]?.name' || true)
    if printf '%s\n' "$known" | grep -Fxq "$WALLET"; then
        loaded=$(cli listwallets 2>/dev/null | jq -r '.[]?' || true)
        if ! printf '%s\n' "$loaded" | grep -Fxq "$WALLET"; then
            cli loadwallet "$WALLET" >/dev/null || fail "Core would not load the wallet '${WALLET}'"
        fi
        log "wallet '${WALLET}' was already here; left as it is"
        return 0
    fi

    # Blank, so nothing is generated by Core and everything comes from the mnemonic;
    # private keys enabled, which is what makes it able to sign. `descriptors` is
    # deliberately not named: it has defaulted to true since Core 24 and legacy wallets are
    # gone in the versions this image pins, so passing it would buy nothing and create a
    # dependency on an argument that is on its way out.
    cli -named createwallet "wallet_name=${WALLET}" blank=true disable_private_keys=false \
        >/dev/null || fail "Core would not create the wallet '${WALLET}'"
    log "wallet '${WALLET}' created, blank"

    derive_descriptors "$MNEMONIC" "$PASSPHRASE" "$NETWORK" \
        || fail "the mnemonic could not be turned into a key; see the message above"

    # Core computes the checksum, and refuses a descriptor whose checksum does not match --
    # so asking it is both shorter than deriving one here and stricter.
    #
    # What is taken from the answer is `.checksum` and not `.descriptor`: the latter is the
    # canonical form, in which the xprv has been replaced by its xpub, and importing that
    # into a wallet with private keys enabled is refused by Core -- correctly, since a
    # watch-only descriptor cannot sign. The checksum covers the string as it was sent, so
    # appending it to the descriptor this service derived is what produces something Core
    # both accepts and can spend from.
    #
    # The descriptors go in as arguments and come back inside a JSON document; neither is
    # ever echoed, and stderr is dropped because Core quotes the descriptor -- and so the
    # xprv -- in its parse errors.
    local receive_checksum change_checksum receive_checked change_checked
    local requests results failure
    receive_checksum=$(cli_wallet_quiet getdescriptorinfo "$DERIVE_DESC_RECEIVE" \
        | jq -r '.checksum // ""') || receive_checksum=''
    change_checksum=$(cli_wallet_quiet getdescriptorinfo "$DERIVE_DESC_CHANGE" \
        | jq -r '.checksum // ""') || change_checksum=''
    if [ -z "$receive_checksum" ] || [ -z "$change_checksum" ]; then
        fail "Core would not parse the descriptors this mnemonic produces"
    fi
    receive_checked="${DERIVE_DESC_RECEIVE}#${receive_checksum}"
    change_checked="${DERIVE_DESC_CHANGE}#${change_checksum}"

    # `timestamp: "now"`: nothing before now can have paid this wallet unless the operator
    # reused a mnemonic; see the pruning note in the README. It is what keeps a fresh
    # wallet from asking a pruned node for a rescan it cannot do.
    requests=$(jq -nc --arg receive "$receive_checked" --arg change "$change_checked" \
        '[{desc:$receive, active:true, internal:false, timestamp:"now"},
          {desc:$change,  active:true, internal:true,  timestamp:"now"}]')

    results=$(cli_wallet_quiet importdescriptors "$requests") \
        || fail "Core refused the import of the descriptors"
    failure=$(printf '%s' "$results" | jq -r '[.[] | select(.success != true)] | length')
    if [ "$failure" != "0" ]; then
        # The error text, not the descriptor it was about.
        log "Core refused a descriptor: $(printf '%s' "$results" \
            | jq -r '[.[] | select(.success != true) | .error.message // "no reason given"] | join("; ")')"
        fail "the wallet was not imported"
    fi
    log "2 descriptor(s) imported: receiving and change"
}

# Refuse to serve a wallet that is not the one these words describe.
#
# Core is a second, independent implementation of BIP-32, so this is a real check and not a
# restatement: it asks Core for an address, then asks Core where that address came from.
# The master fingerprint and the path have to be the ones this service derived. A bitcoind
# holding a valid wallet that is not the operator's is the failure that stays quiet until
# somebody goes looking for the funds.
prove_the_wallet() {
    derive_account "$MNEMONIC" "$PASSPHRASE" "$NETWORK" \
        || fail "the mnemonic could not be turned into a key; see the message above"
    local expected_fingerprint="$DERIVE_ACCOUNT_FINGERPRINT"
    local wanted_path="m/${DERIVE_ACCOUNT_PATH}/0/"

    local address info fingerprint key_path
    address=$(cli_wallet getnewaddress nodo bech32) \
        || fail "Core would not hand out an address from the wallet it just loaded"
    info=$(cli_wallet getaddressinfo "$address") \
        || fail "Core would not say where ${address} came from"

    fingerprint=$(printf '%s' "$info" | jq -r '.hdmasterfingerprint // ""' | tr 'A-F' 'a-f')
    # Core writes a hardened step as `h` in some versions and as `'` in others, and both
    # mean the same index. Comparing the two spellings as strings would make this check
    # fail on a wallet that is entirely correct, which is the worst way for a safety check
    # to behave -- so both sides are put in the same notation first.
    key_path=$(printf '%s' "$info" | jq -r '.hdkeypath // ""' | tr "'" 'h')

    if [ "$fingerprint" != "$expected_fingerprint" ]; then
        fail "the wallet Core loaded is not the one this mnemonic derives: it reports master fingerprint ${fingerprint:-<none>}, and these words give ${expected_fingerprint}. Nothing has been served."
    fi
    case "$key_path" in
        "$wanted_path"*) : ;;
        *) fail "Core derived ${address} at ${key_path:-<unknown>}, which is not ${wanted_path}*. Nothing has been served." ;;
    esac

    log "wallet proven: master fingerprint ${fingerprint}, path ${wanted_path}*"
    log "receiving address: ${address}"
}

# ------------------------------------------------------------------- lifecycle
# Forward a stop, and let Core close its databases.
#
# A killed bitcoind can leave a corrupt chainstate, and on a pruned node that means
# downloading the chain again -- hours on the kind of board this runs on.
stop_core() {
    local reason="${1:-signal}"
    [ -n "$CORE_PID" ] || return 0
    [ -z "$STOPPING" ] || return 0
    STOPPING=1
    kill -0 "$CORE_PID" 2>/dev/null || return 0

    log "${reason}: asking Core to stop"
    cli stop >/dev/null 2>&1 || true

    local deadline=$(( SECONDS + 300 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! kill -0 "$CORE_PID" 2>/dev/null; then
            # It is gone. `wait` on a child this shell started still reports the status it
            # exited with, which is the one worth carrying out of here -- the signal that
            # asked for the shutdown says nothing about whether Core closed its databases.
            #
            # The `||` is not decoration: under `set -e` a non-zero `wait` would end this
            # handler on the spot, and the status it was called to collect would be lost.
            wait "$CORE_PID" 2>/dev/null && CORE_STATUS=0 || CORE_STATUS=$?
            return 0
        fi
        sleep 1
    done
    log "Core did not stop in 300s; terminating it"
    kill -TERM "$CORE_PID" 2>/dev/null || true
    wait "$CORE_PID" 2>/dev/null && CORE_STATUS=0 || CORE_STATUS=$?
    return 0
}

on_signal() {
    stop_core "signal $1"
}

main() {
    read_environment
    write_configuration

    bitcoind "-conf=${CONF_PATH}" "-datadir=${DATA_DIR}" -printtoconsole &
    CORE_PID=$!

    trap 'on_signal TERM' TERM
    trap 'on_signal INT' INT

    wait_for_rpc
    ensure_wallet
    prove_the_wallet

    log "ready: RPC on :${RPC_PORT}, wallet '${WALLET}'"

    # `wait` returns when a signal is handled as well as when Core exits, so it is asked
    # again until the process is really gone. Whichever of the two collected Core's status
    # -- this loop, or the signal handler -- that status is what leaves this script, so
    # that a bitcoind which shut down cleanly reports as one from outside the container.
    local status=0
    while kill -0 "$CORE_PID" 2>/dev/null; do
        wait "$CORE_PID" && status=0 || status=$?
    done
    if [ -n "$CORE_STATUS" ]; then
        return "$CORE_STATUS"
    fi
    return "$status"
}

main "$@"
