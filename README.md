# bitcoin-node

A Bitcoin Core that derives its wallet from twelve words, packaged as a Celaut service so
a [nodo](https://github.com/celaut-project/nodo) can run one itself.

## Why this exists

Bitcoin Core is what signs a Bitcoin transaction. nodo builds no raw ones — no segwit
construction, no BIP-143 sighashes, no UTXO selection — so being able to **pay** in BTC
has always meant "install a bitcoind and trust it with your wallet". That is a reasonable
ask of a data centre and an unreasonable one of a node on a board in somebody's flat,
which is where most of them run.

So: the node runs the Core. It hands it a mnemonic, the Core derives the wallet, and
nodo talks to it over JSON-RPC exactly as it would to a bitcoind the operator installed.
The operator backs up one phrase, the way they already do for Ergo. Core still signs.

Pair it with `ledgers.bitcoin.BACKEND: service` on the node — see
[`docs/BITCOIN.md`](https://github.com/celaut-project/nodo/blob/dev/docs/BITCOIN.md).

## The environment it reads

This table is the contract with the node, which builds it from the same names
(`contracts/bitcoin/node_service.py:ENVIRONMENT`).

| variable | | what it is |
|---|---|---|
| `BITCOIN_MNEMONIC` | **required** | 12 or 24 BIP-39 words. The wallet. |
| `BITCOIN_RPC_USER` | **required** | What the node authenticates with. |
| `BITCOIN_RPC_PASSWORD` | **required** | Stored in `bitcoin.conf` as a salted `rpcauth`, never in plaintext. |
| `BITCOIN_NETWORK` | `mainnet` | `mainnet`, `testnet`, `signet` or `regtest`. Also picks the coin type. |
| `BITCOIN_WALLET_NAME` | `nodo` | The wallet Core loads. |
| `BITCOIN_PRUNE` | `0` | MiB of block history to keep. `0` keeps everything and builds a `txindex`. |
| `BITCOIN_MNEMONIC_PASSPHRASE` | — | Optional BIP-39 passphrase. Unset and empty are **different wallets**. |
| `BITCOIN_DATADIR` | `/data` | Where Core keeps the chain. |

The RPC is on **8332 on every network**, so whatever launches this has one endpoint to
talk to and does not have to know which chain it asked for.

## The wallet

Derived at **`m/84'/0'/0'`** on mainnet, `m/84'/1'/0'` on the test networks — BIP-84,
P2WPKH, the ordinary path for native segwit. Both chains are imported: `0/*` for
receiving and `1/*` for change.

That path is the point: **any standard wallet opens the same funds from the same words**,
with no knowledge of this service. It is what makes the mnemonic a real backup rather
than a string this particular container happens to understand.

`service/derive.py` does it in the standard library and nothing else. No third-party
cryptography derives the key that holds the funds, so the code that does is short enough
to read in one sitting and there is nothing in it that can move underneath the pinned
image. `tests/test_derive.py` checks it against the published BIP-39 and BIP-32 test
vectors.

And the service does not take its own word for it. After importing, it asks Core — a
second, independent implementation of BIP-32 — where a fresh address came from, and
**refuses to serve** unless the master fingerprint and the path are the ones it derived.
A bitcoind holding a valid wallet that is not the operator's is the failure that stays
quiet until somebody goes looking for the money.

## What it costs to run

Two things are worth knowing before setting `BITCOIN_PRUNE`, and neither is a bug:

**A pruned node cannot rescan.** The wallet is imported with `timestamp: "now"`, so it
sees only payments made from then on. Reuse a mnemonic that already has history and those
funds will not appear: that needs `BITCOIN_PRUNE=0` (the whole chain, ~700 GB) or a
rescan done elsewhere. **Generate a fresh mnemonic** and there is nothing to rescan —
which is what the node does by default.

**A Celaut instance has no persistent volume for its own data.** Stop the instance and
the chain data goes with it, so the next start is an initial block download again — hours
on the kind of board this is for. Nothing irrecoverable is lost, because the wallet is
*derived*: what costs is the sync, not the funds. Leave the instance running; the node
only ever starts it when it is not already up.

Declared: 16 GB of disk and up to 2.5 GB of memory, which fits `BITCOIN_PRUNE=10000` with
room for the chainstate and the UTXO cache. A full node needs the disk raised to match.

## Where the secret is

The mnemonic arrives in the environment. That means:

- it is in the node's `config.yaml`, which with this backend is **the only backup of the
  wallet** — the service stores no keys, it derives them;
- the node records how each instance was launched and **redacts** this value, keeping the
  variable's name and not its contents, so the phrase does not end up in the node's
  database as well;
- nothing here logs it. Not the mnemonic, not the derived `xprv`, not the RPC password.
  The log says which network, which wallet, the master fingerprint and the first
  receiving address — what an operator needs to confirm it came up right.

A node that would rather hold no Bitcoin key should not use this. `BACKEND: esplora`
needs no key anywhere and can still be *paid* in BTC, which is the half that earns.

## Building it

```sh
nodo pack .        # produces the service and prints its id (content hash)
```

Then point the node at that id:

```yaml
core_services:
  bitcoin-node: "<the id nodo pack printed>"
```

The image is `linux/arm64`. A node on another architecture needs a build for it — change
`architecture` in `.service/service.json` and the tarball in `.service/Dockerfile` to
match, since the Core release is per platform.

Bitcoin Core is pinned by version **and** by the SHA256 from that release's own
`SHA256SUMS`; the base image is pinned by digest. Verifying the *signature* on
`SHA256SUMS` would be better still and would need the guix builders' keys in the image —
what is here is a checksum in a reviewed file, which cannot change without a diff.

## Tests

```sh
python3 -m unittest discover tests
```

Standard library only, like the service. They cover the derivation: the published
vectors, the curve identity a non-hardened child has to satisfy, the encodings, and the
descriptors as they are handed to Core.

What they do **not** cover is anything past that boundary — no bitcoind is started, no
chain is synced, no transaction is signed. The service's own startup check is what
verifies the wallet against Core, and it runs on the real thing.

## What is not here

- **Lightning.** A separate payment contract with its own rate, on the node's side.
- **A second wallet, or per-deposit addresses.** One account, one wallet, `getnewaddress`
  when the node asks.
- **Signature verification of the Core release** (above).
- **Tor.** Core's defaults, on the egress the node gives the instance.
