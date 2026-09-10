#!/usr/bin/env python3
"""BIP-39 words -> the BIP-84 account key bitcoind imports, in pure Python.

Bitcoin Core has no BIP-39. It takes a *descriptor*, and a spendable one needs an
extended private key -- so something has to turn twelve words into an ``xprv``, and this
is that something. It is deliberately the only cryptography in this image: no third-party
library derives the key that holds the funds, so the code that does is small enough to
read in one sitting and pinned to nothing that can move underneath it.

What is derived, and why exactly this:

* **BIP-84**: ``m/84'/0'/0'`` on mainnet, ``m/84'/1'/0'`` on the test networks, P2WPKH.
  The ordinary path for native segwit, so the wallet opens in any standard tool from the
  words alone -- which is the property that makes the mnemonic a real backup.
* **Both chains**: ``0/*`` for receiving and ``1/*`` for change. A descriptor wallet with
  no internal chain sends its change to the receive chain, which works and makes every
  payment look like a payment to yourself in your own history.
* **The account key, not the master.** What is imported is the key at the account level
  with an origin annotation (``[fingerprint/84h/0h/0h]``), so Core knows where in the
  tree it sits and a hardware signer or a recovery tool can match it up. The master key
  never leaves this process.

Verification is not left to inspection. ``test_derive.py`` in this repository checks
every step against the published BIP-32 and BIP-39 test vectors, and against two
independent implementations; and the entrypoint asks Core to derive addresses from the
descriptor it just imported and compares them with what this module derived. A wrong key
is loud here rather than silent for as long as it takes somebody to notice the money is
not where they thought.
"""
from __future__ import annotations

import hashlib
import hmac
import unicodedata
from typing import Dict, List, Tuple

# secp256k1, from the curve parameters rather than from a library. `n` is the order of
# the generator: a derived key is only valid modulo it, which is what makes the
# vanishingly-improbable retry in `_ckd_priv` a rule of the specification and not an
# error case somebody invented.
_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
_GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
_GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

_HARDENED = 0x80000000

#: Version bytes for an extended key, per network. Getting these wrong does not produce
#: a wrong wallet: Core refuses to parse the descriptor, which is the failure mode to
#: want.
_XPRV_VERSION = {"mainnet": 0x0488ADE4, "testnet": 0x04358394}
_XPUB_VERSION = {"mainnet": 0x0488B21E, "testnet": 0x043587CF}

#: BIP-44 coin type. Test networks share one, which is why they share a version too.
_COIN_TYPE = {"mainnet": 0, "testnet": 1, "signet": 1, "regtest": 1}

_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def _keys_network(network: str) -> str:
    """Which key version applies. Everything that is not mainnet shares testnet's."""
    return "mainnet" if network == "mainnet" else "testnet"


# --------------------------------------------------------------------------- curve
def _inverse(value: int, modulus: int) -> int:
    return pow(value, modulus - 2, modulus)


def _add(p: Tuple[int, int] | None, q: Tuple[int, int] | None):
    """Affine point addition. Slow and obvious, which is the right trade for 3 keys."""
    if p is None:
        return q
    if q is None:
        return p
    (x1, y1), (x2, y2) = p, q
    if x1 == x2 and (y1 + y2) % _P == 0:
        return None
    if p == q:
        slope = 3 * x1 * x1 % _P * _inverse(2 * y1 % _P, _P) % _P
    else:
        slope = (y2 - y1) % _P * _inverse((x2 - x1) % _P, _P) % _P
    x3 = (slope * slope - x1 - x2) % _P
    return x3, (slope * (x1 - x3) - y1) % _P


def _multiply(scalar: int, point=(_GX, _GY)):
    result = None
    addend = point
    while scalar:
        if scalar & 1:
            result = _add(result, addend)
        addend = _add(addend, addend)
        scalar >>= 1
    return result


def compressed_public_key(private_key: bytes) -> bytes:
    """The 33-byte compressed SEC1 encoding of ``private_key``'s public point."""
    point = _multiply(int.from_bytes(private_key, "big"))
    if point is None:
        raise ValueError("private key is not on the curve")
    x, y = point
    return bytes([2 + (y & 1)]) + x.to_bytes(32, "big")


# ----------------------------------------------------------------------- encodings
def _hash160(data: bytes) -> bytes:
    return hashlib.new("ripemd160", hashlib.sha256(data).digest()).digest()


def base58check(payload: bytes) -> str:
    checksum = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    number = int.from_bytes(payload + checksum, "big")
    encoded = ""
    while number:
        number, remainder = divmod(number, 58)
        encoded = _B58[remainder] + encoded
    # Every leading zero byte is a leading '1'; the loop above cannot know that.
    return "1" * (len(payload + checksum) - len((payload + checksum).lstrip(b"\x00"))) + encoded


def _serialize(version: int, depth: int, parent_fingerprint: bytes, index: int,
               chain_code: bytes, key: bytes, private: bool) -> str:
    return base58check(
        version.to_bytes(4, "big")
        + bytes([depth])
        + parent_fingerprint
        + index.to_bytes(4, "big")
        + chain_code
        + ((b"\x00" + key) if private else key)
    )


# ------------------------------------------------------------------------- BIP-39
def mnemonic_to_seed(mnemonic: str, passphrase: str = "") -> bytes:
    """The 64-byte BIP-39 seed. NFKD, 2048 rounds, salt ``"mnemonic" + passphrase``.

    The words are *not* checked against a wordlist here. This runs at startup with
    whatever the operator configured, and refusing to start on a valid-but-unlisted
    phrase -- a different language file, a passphrase-style phrase somebody chose
    deliberately -- would lock a node out of a wallet that works everywhere else.
    """
    normalized = unicodedata.normalize("NFKD", " ".join(mnemonic.split()))
    salt = unicodedata.normalize("NFKD", "mnemonic" + passphrase)
    return hashlib.pbkdf2_hmac(
        "sha512", normalized.encode("utf-8"), salt.encode("utf-8"), 2048, dklen=64
    )


# ------------------------------------------------------------------------- BIP-32
def master_from_seed(seed: bytes) -> Tuple[bytes, bytes]:
    digest = hmac.new(b"Bitcoin seed", seed, hashlib.sha512).digest()
    key, chain_code = digest[:32], digest[32:]
    if not 0 < int.from_bytes(key, "big") < _N:
        raise ValueError("this seed does not produce a valid master key")
    return key, chain_code


def _ckd_priv(key: bytes, chain_code: bytes, index: int) -> Tuple[bytes, bytes]:
    """One step down the tree. Hardened when ``index`` has the high bit set."""
    if index & _HARDENED:
        data = b"\x00" + key + index.to_bytes(4, "big")
    else:
        data = compressed_public_key(key) + index.to_bytes(4, "big")
    digest = hmac.new(chain_code, data, hashlib.sha512).digest()
    offset = int.from_bytes(digest[:32], "big")
    child = (offset + int.from_bytes(key, "big")) % _N
    if offset >= _N or child == 0:
        # The specification's own answer: this index is unusable, take the next one.
        # It has never been observed; leaving it out would be a wrong key rather than
        # an error if it ever were.
        return _ckd_priv(key, chain_code, index + 1)
    return child.to_bytes(32, "big"), digest[32:]


def fingerprint(key: bytes) -> bytes:
    return _hash160(compressed_public_key(key))[:4]


def account(mnemonic: str, passphrase: str = "", network: str = "mainnet") -> Dict[str, object]:
    """Everything the entrypoint needs: the account key, and how to describe it.

    Returns the master fingerprint, the derivation path in descriptor notation, the
    account ``xprv`` and its ``xpub``. The account key is the deepest thing this
    function hands back -- the master key stays in this call.
    """
    keys_network = _keys_network(network)
    coin = _COIN_TYPE.get(network)
    if coin is None:
        raise ValueError(f"unknown network {network!r}")

    key, chain_code = master_from_seed(mnemonic_to_seed(mnemonic, passphrase))
    master_fingerprint = fingerprint(key)

    depth = 0
    parent = b"\x00\x00\x00\x00"
    index = 0
    for index in (84 | _HARDENED, coin | _HARDENED, 0 | _HARDENED):
        parent = fingerprint(key)
        key, chain_code = _ckd_priv(key, chain_code, index)
        depth += 1

    return {
        "master_fingerprint": master_fingerprint.hex(),
        "path": f"84h/{coin}h/0h",
        "xprv": _serialize(_XPRV_VERSION[keys_network], depth, parent, index,
                           chain_code, key, private=True),
        "xpub": _serialize(_XPUB_VERSION[keys_network], depth, parent, index,
                           chain_code, compressed_public_key(key), private=False),
    }


def descriptors(mnemonic: str, passphrase: str = "",
                network: str = "mainnet") -> List[Dict[str, object]]:
    """The two descriptors to import: receiving (``0/*``) and change (``1/*``).

    Without the checksum, which Core computes itself (``getdescriptorinfo``). Deriving
    it here would be a fourth thing to get right for no gain: Core refuses a descriptor
    whose checksum does not match, so asking it is both shorter and stricter.
    """
    keys = account(mnemonic, passphrase, network)
    origin = f"[{keys['master_fingerprint']}/{keys['path']}]"
    return [
        {
            "desc": f"wpkh({origin}{keys['xprv']}/{chain}/*)",
            "active": True,
            "internal": chain == 1,
            # Nothing before now can have paid this wallet unless the operator reused a
            # mnemonic; see the pruning note in the README. `now` is what keeps a fresh
            # wallet from asking a pruned node for a rescan it cannot do.
            "timestamp": "now",
        }
        for chain in (0, 1)
    ]
