#!/usr/bin/env python3
"""Bring up a bitcoind whose wallet is the one these twelve words describe.

The whole service, in order: write a configuration from the environment, start Core,
derive the account key from ``BITCOIN_MNEMONIC``, import it as a descriptor wallet, prove
to itself that the wallet Core loaded is the one it derived, and then stay out of the
way while Core runs.

Three things it is careful about, because each one is a way to lose money quietly:

* **It proves the wallet.** After importing, it asks Core where a fresh address comes
  from and refuses to serve if the answer is not this mnemonic's master fingerprint at
  the documented path. A bitcoind holding a *valid* wallet that is not the operator's is
  the failure nobody notices until they look for the funds.
* **It shuts Core down properly.** A killed bitcoind can leave a corrupt chainstate,
  which on a pruned node means downloading the chain again. SIGTERM is forwarded as
  ``stop`` and waited on.
* **It never logs the secret.** Not the mnemonic, not the xprv, not the RPC password.
  What it prints is what an operator needs to see: which network, which wallet, the
  fingerprint, and the first receiving address.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import NoReturn

import derive

DATA_DIR = Path(os.environ.get("BITCOIN_DATADIR", "/data"))
CONF_PATH = DATA_DIR / "bitcoin.conf"
#: The same port on every network, so the node that launches this has one endpoint to
#: talk to and does not have to know which chain it asked for.
RPC_PORT = 8332

#: Core's own floor. Below it bitcoind refuses to start, and a service that never comes
#: up is a worse way to learn that than a message here.
MIN_PRUNE_MIB = 550

NETWORKS = {
    "mainnet": {"chain": "main", "section": "main"},
    "testnet": {"chain": "test", "section": "test"},
    "signet": {"chain": "signet", "section": "signet"},
    "regtest": {"chain": "regtest", "section": "regtest"},
}


def log(message: str) -> None:
    print(f"[bitcoin-node] {message}", flush=True)


def fail(message: str) -> NoReturn:
    log(f"FATAL: {message}")
    raise SystemExit(1)


def environment() -> dict:
    """What the node passed in, validated. The contract is documented in the README."""
    mnemonic = " ".join(os.environ.get("BITCOIN_MNEMONIC", "").split())
    if not mnemonic:
        fail(
            "BITCOIN_MNEMONIC is empty. This service exists to hold a wallet; without "
            "one there is nothing for Core to sign with."
        )
    user = os.environ.get("BITCOIN_RPC_USER", "").strip()
    password = os.environ.get("BITCOIN_RPC_PASSWORD", "")
    if not user or not password:
        fail(
            "BITCOIN_RPC_USER and BITCOIN_RPC_PASSWORD are what the node "
            "authenticates with; Core's cookie file is not reachable from outside this "
            "container."
        )
    network = os.environ.get("BITCOIN_NETWORK", "mainnet").strip() or "mainnet"
    if network not in NETWORKS:
        fail(f"BITCOIN_NETWORK={network!r} is not one of {', '.join(NETWORKS)}")

    raw_prune = os.environ.get("BITCOIN_PRUNE", "").strip()
    try:
        prune = int(raw_prune) if raw_prune else 0
    except ValueError:
        fail(f"BITCOIN_PRUNE={raw_prune!r} is not a whole number of MiB")
    if prune and prune < MIN_PRUNE_MIB:
        fail(
            f"BITCOIN_PRUNE={prune} is below Core's floor of {MIN_PRUNE_MIB} MiB. Use 0 "
            "to keep the whole chain, or a value from 550 up."
        )
    return {
        "mnemonic": mnemonic,
        "passphrase": os.environ.get("BITCOIN_MNEMONIC_PASSPHRASE", ""),
        "network": network,
        "prune": prune,
        "user": user,
        "password": password,
        "wallet": os.environ.get("BITCOIN_WALLET_NAME", "").strip() or "nodo",
    }


def rpcauth(user: str, password: str) -> str:
    """Core's salted ``rpcauth`` line, so the plaintext password is not in a file.

    The node has to know the password -- it authenticates with it -- but nothing is
    served by writing it to disk as well. This is the same construction
    ``share/rpcauth/rpcauth.py`` in Core's own tree produces.
    """
    salt = secrets.token_hex(16)
    digest = hmac.new(salt.encode("utf-8"), password.encode("utf-8"), hashlib.sha256)
    return f"rpcauth={user}:{salt}${digest.hexdigest()}"


def write_configuration(env: dict) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    network = NETWORKS[env["network"]]
    lines = [
        "# Written at every start from this service's environment. Editing it by hand",
        "# has no lasting effect: the next start overwrites it.",
        f"chain={network['chain']}",
        "server=1",
        "listen=1",
        # The RPC is this service's whole interface, and the only thing that can reach
        # it is what the node running this service exposes: an instance's network is
        # the node's firewall, not this file's business.
        "rpcbind=0.0.0.0",
        "rpcallowip=0.0.0.0/0",
        f"rpcport={RPC_PORT}",
        rpcauth(env["user"], env["password"]),
    ]
    if env["prune"]:
        lines.append(f"prune={env['prune']}")
    else:
        # The whole chain, and an index over it. `getrawtransaction` on an arbitrary
        # transaction needs it; a pruned node cannot have it, which is why the node
        # asking the questions reads its own wallet's transactions through the wallet.
        lines.append("txindex=1")
    CONF_PATH.write_text("\n".join(line for line in lines if line) + "\n", encoding="utf-8")
    log(f"configuration written for {env['network']}"
        + (f", pruned to {env['prune']} MiB" if env["prune"] else ", full chain with txindex"))


def cli(*args: str, check: bool = True, wallet: str = "") -> str:
    """``bitcoin-cli`` against this node. Returns stdout; raises on a checked failure."""
    command = ["bitcoin-cli", f"-conf={CONF_PATH}", f"-datadir={DATA_DIR}"]
    if wallet:
        command.append(f"-rpcwallet={wallet}")
    command.extend(args)
    result = subprocess.run(command, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(
            f"bitcoin-cli {args[0]} failed: {result.stderr.strip() or result.returncode}"
        )
    return result.stdout.strip()


def wait_for_rpc(timeout: int = 600) -> None:
    """Until Core answers. It loads the block index first, which is not instant."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            cli("-rpcclienttimeout=10", "getblockchaininfo")
            return
        except RuntimeError:
            # Not up yet, or still loading the block index. Polling rather than
            # `-rpcwait` so the deadline below is the one that decides.
            time.sleep(2)
    fail(f"Core did not answer its RPC within {timeout}s")


def ensure_wallet(env: dict) -> None:
    """Create the wallet and import the mnemonic's descriptors, once.

    Idempotent, because this runs on every start and the wallet outlives none, some or
    all of them depending on what the node did with this instance's filesystem. A
    wallet that is already there is loaded and left alone: re-importing would be
    harmless but a rescan on a pruned node is not.
    """
    wallet = env["wallet"]
    existing = json.loads(cli("listwalletdir") or '{"wallets":[]}').get("wallets", [])
    known = {entry.get("name") for entry in existing}

    if wallet in known:
        loaded = json.loads(cli("listwallets") or "[]")
        if wallet not in loaded:
            cli("loadwallet", wallet)
        log(f"wallet {wallet!r} was already here; left as it is")
        return

    # Blank, so nothing is generated by Core and everything comes from the mnemonic;
    # private keys enabled, which is what makes it able to sign. `descriptors` is
    # deliberately not named: it has defaulted to true since Core 24 and legacy wallets
    # are gone in the versions this image pins, so passing it would buy nothing and
    # create a dependency on an argument that is on its way out.
    cli("-named", "createwallet", f"wallet_name={wallet}",
        "blank=true", "disable_private_keys=false")
    log(f"wallet {wallet!r} created, blank")

    requests = []
    for descriptor in derive.descriptors(env["mnemonic"], env["passphrase"], env["network"]):
        # Core computes the checksum, and refuses a descriptor whose checksum does not
        # match -- so asking it is both shorter than deriving one here and stricter.
        info = json.loads(cli("getdescriptorinfo", descriptor["desc"], wallet=wallet))
        requests.append({**descriptor, "desc": info["descriptor"]})

    results = json.loads(cli("importdescriptors", json.dumps(requests), wallet=wallet))
    for result in results:
        if not result.get("success"):
            fail(f"Core refused a descriptor: {result.get('error', result)}")
    log(f"{len(requests)} descriptor(s) imported: receiving and change")


def prove_the_wallet(env: dict) -> None:
    """Refuse to serve a wallet that is not the one these words describe.

    Core is a second, independent implementation of BIP-32, so this is a real check and
    not a restatement: it asks Core for an address, then asks Core where that address
    came from. The master fingerprint and the path have to be the ones this service
    derived. A bitcoind holding a valid wallet that is not the operator's is the failure
    that stays quiet until somebody goes looking for the funds.
    """
    expected = derive.account(env["mnemonic"], env["passphrase"], env["network"])
    address = cli("getnewaddress", "nodo", "bech32", wallet=env["wallet"])
    info = json.loads(cli("getaddressinfo", address, wallet=env["wallet"]))

    fingerprint = str(info.get("hdmasterfingerprint", "")).lower()
    key_path = str(info.get("hdkeypath", ""))
    wanted_path = "m/" + expected["path"].replace("h", "'") + "/0/"
    if fingerprint != expected["master_fingerprint"]:
        fail(
            "the wallet Core loaded is not the one this mnemonic derives: it reports "
            f"master fingerprint {fingerprint or '<none>'}, and these words give "
            f"{expected['master_fingerprint']}. Nothing has been served."
        )
    if not key_path.startswith(wanted_path):
        fail(
            f"Core derived {address} at {key_path or '<unknown>'}, which is not "
            f"{wanted_path}*. Nothing has been served."
        )
    log(f"wallet proven: master fingerprint {fingerprint}, path {wanted_path}*")
    log(f"receiving address: {address}")


def main() -> int:
    env = environment()
    write_configuration(env)

    core = subprocess.Popen(
        ["bitcoind", f"-conf={CONF_PATH}", f"-datadir={DATA_DIR}", "-printtoconsole"],
    )

    def stop(signum, _frame):
        """Forward a stop, and let Core close its databases.

        A killed bitcoind can leave a corrupt chainstate, and on a pruned node that
        means downloading the chain again -- hours on the kind of board this runs on.
        """
        log(f"signal {signum}: asking Core to stop")
        try:
            cli("stop", check=False)
        finally:
            try:
                core.wait(timeout=300)
            except subprocess.TimeoutExpired:
                log("Core did not stop in 300s; terminating it")
                core.terminate()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    try:
        wait_for_rpc()
        ensure_wallet(env)
        prove_the_wallet(env)
    except SystemExit:
        stop("startup", None)
        raise
    except Exception as exc:  # a broken start must not leave Core orphaned
        log(f"FATAL: {type(exc).__name__}: {exc}")
        stop("startup", None)
        return 1

    log(f"ready: RPC on :{RPC_PORT}, wallet {env['wallet']!r}")
    return core.wait()


if __name__ == "__main__":
    sys.exit(main())
