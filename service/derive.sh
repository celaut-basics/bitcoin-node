#!/usr/bin/env bash
# BIP-39 words -> the BIP-84 account key bitcoind imports, in bash and OpenSSL.
#
# Bitcoin Core has no BIP-39. It takes a *descriptor*, and a spendable one needs an
# extended private key -- so something has to turn twelve words into an `xprv`, and this
# is that something. It is deliberately the only cryptography in this image: the
# primitives are OpenSSL's, from Debian, pinned by package version in the Dockerfile, and
# the code that arranges them into a key is short enough to read in one sitting.
#
# What is derived, and why exactly this:
#
# * BIP-84: `m/84'/0'/0'` on mainnet, `m/84'/1'/0'` on the test networks, P2WPKH. The
#   ordinary path for native segwit, so the wallet opens in any standard tool from the
#   words alone -- which is the property that makes the mnemonic a real backup.
# * Both chains: `0/*` for receiving and `1/*` for change. A descriptor wallet with no
#   internal chain sends its change to the receive chain, which works and makes every
#   payment look like a payment to yourself in your own history.
# * The account key, not the master. What is imported is the key at the account level
#   with an origin annotation (`[fingerprint/84h/0h/0h]`), so Core knows where in the
#   tree it sits and a hardware signer or a recovery tool can match it up. The master key
#   never leaves this process.
#
# Verification is not left to inspection. `tests/test_derive.sh` checks every step
# against the published BIP-32 and BIP-39 test vectors, and the entrypoint asks Core --
# a second, independent implementation of BIP-32 -- where the address it just derived
# came from. A wrong key is loud here rather than silent for as long as it takes somebody
# to notice the money is not where they thought.
#
# Nothing in this file writes a secret to a descriptor, to stdout or to stderr except the
# one value the caller asked for. OpenSSL's own errors are sent to /dev/null on every
# call that is handed key material, because an error message that quotes its input is a
# leak and not a diagnostic.

# secp256k1's group order. A derived key is only valid modulo it, which is what makes the
# vanishingly-improbable retry in `ckd_priv` a rule of the specification and not an error
# case somebody invented. `bc` wants its hex in upper case.
DERIVE_N='FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141'

DERIVE_HARDENED=2147483648   # 0x80000000

# Version bytes for an extended key, per network. Getting these wrong does not produce a
# wrong wallet: Core refuses to parse the descriptor, which is the failure mode to want.
DERIVE_XPRV_MAINNET='0488ade4'
DERIVE_XPUB_MAINNET='0488b21e'
DERIVE_XPRV_TESTNET='04358394'
DERIVE_XPUB_TESTNET='043587cf'

DERIVE_B58='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'

# ------------------------------------------------------------------ bytes and hex
# Hex goes in and out of every function here; binary exists only inside a pipe, because a
# shell variable cannot hold a NUL byte and a key with one in it would be silently
# truncated rather than wrong in a way anybody could see.

# Write the bytes a hex string names to stdout. No subprocess: `printf %b` is a builtin,
# so the bytes never become an argument to anything that shows up in `ps`.
derive_unhex() {
    local hex="$1" escaped='' i
    for (( i = 0; i < ${#hex}; i += 2 )); do
        escaped="${escaped}\\x${hex:i:2}"
    done
    printf '%b' "$escaped"
}

# The hex of whatever arrives on stdin.
derive_hex_stdin() {
    od -An -v -tx1 | tr -d ' \n'
}

# The hex of a string's UTF-8 bytes, passed on stdin rather than as an argument.
derive_hex_of() {
    printf '%s' "$1" | derive_hex_stdin
}

# OpenSSL prints its digests in upper case and sometimes colon-separated. Everything
# downstream of it wants plain lower-case hex.
derive_tidy_hex() {
    tr -d ':\r\n ' | tr 'A-F' 'a-f'
}

derive_pad64() {
    printf '%064s' "$1" | tr ' ' '0'
}

# ------------------------------------------------------------------- primitives
derive_sha256() {
    derive_unhex "$1" | openssl dgst -sha256 -r 2>/dev/null | cut -d' ' -f1 | derive_tidy_hex
}

derive_sha256d() {
    derive_sha256 "$(derive_sha256 "$1")"
}

# RIPEMD-160 lives in OpenSSL 3's default provider again as of 3.0.7, which is older than
# anything Debian bookworm ships; the fallback is here so that a build against an OpenSSL
# where it is still in `legacy` fails loudly at the right line instead of producing a
# wrong address.
derive_ripemd160() {
    local out
    if out=$(derive_unhex "$1" | openssl dgst -ripemd160 -r 2>/dev/null | cut -d' ' -f1) \
        && [ -n "$out" ]; then
        printf '%s' "$out" | derive_tidy_hex
        return 0
    fi
    out=$(derive_unhex "$1" \
        | openssl dgst -provider legacy -provider default -ripemd160 -r 2>/dev/null \
        | cut -d' ' -f1) || out=''
    if [ -z "$out" ]; then
        echo "derive: this OpenSSL has no RIPEMD-160; an address cannot be derived without it" >&2
        return 1
    fi
    printf '%s' "$out" | derive_tidy_hex
}

derive_hash160() {
    derive_ripemd160 "$(derive_sha256 "$1")"
}

derive_hmac_sha512() {   # hexkey, hexdata
    derive_unhex "$2" | openssl mac -digest SHA512 -macopt "hexkey:$1" HMAC 2>/dev/null \
        | derive_tidy_hex
}

derive_hmac_sha256() {   # hexkey, hexdata
    derive_unhex "$2" | openssl mac -digest SHA256 -macopt "hexkey:$1" HMAC 2>/dev/null \
        | derive_tidy_hex
}

# ------------------------------------------------------------------ big integers
# Three operations on 256-bit numbers, all of them `bc`'s. `BC_LINE_LENGTH=0` stops it
# folding a long answer across lines with a backslash; the `tr` after it is the belt to
# that braces, because a wrapped key would be a wrong key.
derive_bc() {
    BC_LINE_LENGTH=0 bc 2>/dev/null | tr -d '\\\n'
}

derive_upper() {
    printf '%s' "$1" | tr 'a-f' 'A-F'
}

# (a + b) mod n, in hex, padded to 32 bytes.
derive_mod_add_n() {
    local sum
    sum=$(printf 'obase=16;ibase=16;(%s + %s) %% %s\n' \
        "$(derive_upper "$1")" "$(derive_upper "$2")" "$DERIVE_N" | derive_bc)
    derive_pad64 "$(printf '%s' "$sum" | tr 'A-F' 'a-f')"
}

# Whether a 32-byte hex value is at or above the group order: BIP-32 says such a child is
# unusable and the next index has to be taken.
derive_ge_n() {
    [ "$(printf 'ibase=16;if (%s >= %s) 1 else 0\n' \
        "$(derive_upper "$1")" "$DERIVE_N" | derive_bc)" = "1" ]
}

derive_is_zero() {
    case "$1" in
        *[!0]*) return 1 ;;
        *) return 0 ;;
    esac
}

# --------------------------------------------------------------------- encodings
derive_base58() {   # hex payload (already including its checksum)
    local hex="$1" digits out='' leading='' rest d

    # Every leading zero byte is a leading '1'; the arithmetic below cannot know that, and
    # an extended key or an address missing one is a different string entirely.
    rest="$hex"
    while [ "${rest:0:2}" = "00" ]; do
        leading="${leading}1"
        rest="${rest:2}"
    done

    digits=$(printf 'ibase=16\nn=%s\nibase=A\nwhile (n > 0) { n %% 58; n = n / 58 }\n' \
        "$(derive_upper "$hex")" | derive_bc_lines)
    for d in $digits; do
        out="${DERIVE_B58:d:1}${out}"
    done
    printf '%s%s' "$leading" "$out"
}

# The base58 loop is the one place a line per answer is wanted rather than one long line,
# so it gets its own `bc` wrapper.
derive_bc_lines() {
    BC_LINE_LENGTH=0 bc 2>/dev/null
}

derive_base58check() {   # hex payload without checksum
    local checksum
    checksum=$(derive_sha256d "$1")
    derive_base58 "${1}${checksum:0:8}"
}

# version, depth, parent fingerprint, index, chain code, key -- the 78 bytes BIP-32
# serialises, base58check-encoded. A private key is prefixed with the zero byte that
# makes it 33 long, like a public one.
derive_serialize() {   # version_hex depth index chaincode_hex key_hex private(0|1) parentfp_hex
    local version="$1" depth="$2" index="$3" chaincode="$4" key="$5" private="$6" parent="$7"
    local payload
    payload=$(printf '%s%02x%s%08x%s' "$version" "$depth" "$parent" "$index" "$chaincode")
    if [ "$private" = "1" ]; then
        payload="${payload}00${key}"
    else
        payload="${payload}${key}"
    fi
    derive_base58check "$payload"
}

# ------------------------------------------------------------------------ curve
# The compressed public key of a private scalar, from OpenSSL's secp256k1. The scalar is
# wrapped in the RFC 5915 ECPrivateKey DER that `openssl ec` reads -- 46 content bytes:
# version, the 32-byte key, and the curve's OID (1.3.132.0.10) -- and the answer is the
# last 33 bytes of the SubjectPublicKeyInfo it writes back.
#
# The DER is built and consumed inside a pipe. It is never a file and never an argument.
derive_pubkey() {   # private key hex -> 33-byte compressed public key hex
    local public
    public=$(derive_unhex "302e0201010420${1}a00706052b8104000a" \
        | openssl ec -inform DER -pubout -conv_form compressed -outform DER 2>/dev/null \
        | derive_hex_stdin)
    if [ ${#public} -lt 66 ]; then
        echo "derive: OpenSSL would not take this private key" >&2
        return 1
    fi
    printf '%s' "${public: -66}"
}

derive_fingerprint() {   # private key hex -> 4-byte hex
    local h
    h=$(derive_hash160 "$(derive_pubkey "$1")") || return 1
    printf '%s' "${h:0:8}"
}

# ----------------------------------------------------------------------- BIP-39
# The 64-byte BIP-39 seed. 2048 rounds of PBKDF2-HMAC-SHA512, salt "mnemonic" + the
# passphrase.
#
# The words are *not* checked against a wordlist, deliberately and as in the Python this
# replaces. This runs at startup with whatever the operator configured, and refusing to
# start on a valid-but-unlisted phrase -- a different language file, a passphrase-style
# phrase somebody chose on purpose -- would lock a node out of a wallet that works
# everywhere else.
#
# BIP-39 normalises both strings to NFKD before hashing. A shell cannot do that, so
# `derive_require_ascii` refuses anything outside ASCII rather than hashing an unnormalised
# string: for ASCII, NFKD is the identity, and a mnemonic in a script that has composed
# forms would otherwise derive a wallet nobody else can open. The README says so.
derive_mnemonic_to_seed() {   # mnemonic passphrase -> 64-byte hex
    # `openssl kdf` takes its password on the command line and there is no option that
    # reads it from a file or a pipe. Inside this container that means the mnemonic is
    # briefly visible in /proc to a process running as this same user -- which is the
    # same exposure the Python had when it handed descriptors to bitcoin-cli, and is the
    # reason the instance runs nothing else.
    openssl kdf -keylen 64 -kdfopt digest:SHA512 \
        -kdfopt "hexpass:$(derive_hex_of "$1")" \
        -kdfopt "hexsalt:$(derive_hex_of "mnemonic$2")" \
        -kdfopt iter:2048 PBKDF2 2>/dev/null | derive_tidy_hex
}

# `[:print:]` and `[:space:]` in the C locale are exactly ASCII, so anything with a byte
# at 0x80 or above -- or a stray control character -- is what this catches. The value is
# piped rather than passed as an argument, and grep is asked only for its exit status, so
# the string itself is never printed anywhere.
derive_require_ascii() {   # value, name
    if printf '%s' "$1" | LC_ALL=C grep -q '[^[:print:][:space:]]'; then
        echo "derive: $2 has a byte outside ASCII. BIP-39 hashes the NFKD form of" >&2
        echo "        this string and a shell cannot normalise one, so deriving from it" >&2
        echo "        could produce a wallet no other tool opens. Refusing rather than" >&2
        echo "        guessing." >&2
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------- BIP-32
# The results of the two functions below are returned in globals rather than on stdout:
# a command substitution is a subshell and a fork, and the fewer places 32 secret bytes
# are copied to the better.
derive_master_from_seed() {   # seed hex -> DERIVE_KEY, DERIVE_CHAINCODE
    local digest
    digest=$(derive_hmac_sha512 "$(derive_hex_of 'Bitcoin seed')" "$1")
    DERIVE_KEY="${digest:0:64}"
    DERIVE_CHAINCODE="${digest:64:128}"
    if derive_is_zero "$DERIVE_KEY" || derive_ge_n "$DERIVE_KEY"; then
        echo "derive: this seed does not produce a valid master key" >&2
        return 1
    fi
    return 0
}

# One step down the tree. Hardened when the index has the high bit set, which is the only
# kind this service takes: a hardened child needs the parent's private key and nothing
# else, so no public point has to be computed to walk to the account.
derive_ckd_priv() {   # key hex, chaincode hex, index (decimal) -> DERIVE_KEY, DERIVE_CHAINCODE
    local key="$1" chaincode="$2" index="$3" data digest offset child

    if [ "$(( index & DERIVE_HARDENED ))" -ne 0 ]; then
        data=$(printf '00%s%08x' "$key" "$index")
    else
        data=$(printf '%s%08x' "$(derive_pubkey "$key")" "$index")
    fi
    digest=$(derive_hmac_sha512 "$chaincode" "$data")
    offset="${digest:0:64}"
    child=$(derive_mod_add_n "$offset" "$key")

    if derive_ge_n "$offset" || derive_is_zero "$child"; then
        # The specification's own answer: this index is unusable, take the next one. It
        # has never been observed; leaving it out would be a wrong key rather than an
        # error if it ever were.
        derive_ckd_priv "$key" "$chaincode" "$(( index + 1 ))"
        return $?
    fi

    DERIVE_KEY="$child"
    DERIVE_CHAINCODE="${digest:64:128}"
    return 0
}

# ---------------------------------------------------------------------- account
derive_coin_type() {
    case "$1" in
        mainnet) printf '0' ;;
        testnet|signet|regtest) printf '1' ;;
        *) echo "derive: unknown network '$1'" >&2; return 1 ;;
    esac
}

# Everything the entrypoint needs: the master fingerprint, the path in descriptor
# notation, the account xprv and its xpub. Set as globals, again so the key is copied
# as few times as possible. The account key is the deepest thing this produces -- the
# master key stays inside the call.
#
# DERIVE_ACCOUNT_FINGERPRINT, DERIVE_ACCOUNT_PATH, DERIVE_ACCOUNT_XPRV, DERIVE_ACCOUNT_XPUB
derive_account() {   # mnemonic, passphrase, network
    local mnemonic passphrase="$2" network="$3"
    local coin seed depth=0 parent='00000000' index=0 xprv_version xpub_version

    # An operator pasting from a wrapped config file must not get another wallet.
    mnemonic=$(printf '%s' "$1" | tr -s ' \t\n\r' ' ')
    mnemonic="${mnemonic# }"
    mnemonic="${mnemonic% }"

    derive_require_ascii "$mnemonic" 'BITCOIN_MNEMONIC' || return 1
    derive_require_ascii "$passphrase" 'BITCOIN_MNEMONIC_PASSPHRASE' || return 1

    coin=$(derive_coin_type "$network") || return 1
    if [ "$network" = "mainnet" ]; then
        xprv_version="$DERIVE_XPRV_MAINNET"; xpub_version="$DERIVE_XPUB_MAINNET"
    else
        xprv_version="$DERIVE_XPRV_TESTNET"; xpub_version="$DERIVE_XPUB_TESTNET"
    fi

    seed=$(derive_mnemonic_to_seed "$mnemonic" "$passphrase")
    if [ ${#seed} -ne 128 ]; then
        echo "derive: PBKDF2 did not return 64 bytes" >&2
        return 1
    fi
    derive_master_from_seed "$seed" || return 1

    DERIVE_ACCOUNT_FINGERPRINT=$(derive_fingerprint "$DERIVE_KEY") || return 1

    for index in $(( 84 | DERIVE_HARDENED )) $(( coin | DERIVE_HARDENED )) $(( 0 | DERIVE_HARDENED )); do
        parent=$(derive_fingerprint "$DERIVE_KEY") || return 1
        derive_ckd_priv "$DERIVE_KEY" "$DERIVE_CHAINCODE" "$index" || return 1
        depth=$(( depth + 1 ))
    done

    DERIVE_ACCOUNT_PATH="84h/${coin}h/0h"
    DERIVE_ACCOUNT_XPRV=$(derive_serialize "$xprv_version" "$depth" "$index" \
        "$DERIVE_CHAINCODE" "$DERIVE_KEY" 1 "$parent")
    DERIVE_ACCOUNT_XPUB=$(derive_serialize "$xpub_version" "$depth" "$index" \
        "$DERIVE_CHAINCODE" "$(derive_pubkey "$DERIVE_KEY")" 0 "$parent")

    # The master key and the account private scalar have both been through this shell's
    # variables; drop the ones that are no longer needed.
    DERIVE_KEY=''
    DERIVE_CHAINCODE=''
    return 0
}

# The two descriptors to import: receiving (`0/*`) and change (`1/*`), without the
# checksum. Core computes that itself (`getdescriptorinfo`) and refuses a descriptor whose
# checksum does not match, so asking it is both shorter than deriving one here and
# stricter.
#
# DERIVE_DESC_RECEIVE, DERIVE_DESC_CHANGE
derive_descriptors() {   # mnemonic, passphrase, network
    derive_account "$1" "$2" "$3" || return 1
    local origin="[${DERIVE_ACCOUNT_FINGERPRINT}/${DERIVE_ACCOUNT_PATH}]"
    DERIVE_DESC_RECEIVE="wpkh(${origin}${DERIVE_ACCOUNT_XPRV}/0/*)"
    DERIVE_DESC_CHANGE="wpkh(${origin}${DERIVE_ACCOUNT_XPRV}/1/*)"
    return 0
}
