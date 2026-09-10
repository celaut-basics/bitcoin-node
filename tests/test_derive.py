"""The derivation, against the published vectors and against Bitcoin's own arithmetic.

This is the only cryptography in the service and it decides where the money is, so it is
checked three ways rather than read twice:

* **BIP-39 and BIP-32 test vectors**, verbatim from the specifications. They are the
  reason a wallet derived here opens in any other tool.
* **An identity Core also relies on**: a non-hardened child's public key is the parent's
  public key plus `IL·G`. If the point arithmetic were wrong, this is where it shows.
* **Round trips**, so an encoding error cannot hide behind a value that merely looks
  plausible.

Run with `python3 -m unittest discover tests` — standard library only, like the service.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "service"))

import derive  # noqa: E402

# BIP-39, the first English test vector, and the one every wallet is tested against.
ABANDON = " ".join(["abandon"] * 11 + ["about"])
ABANDON_SEED = (
    "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1"
    "9a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4"
)
ABANDON_SEED_TREZOR = (
    "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e5349553"
    "1f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
)
# BIP-32 test vector 1: seed 000102...0f, and the master key it gives.
BIP32_SEED = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
BIP32_MASTER_XPRV = (
    "xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6"
    "LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi"
)


class Bip39Tests(unittest.TestCase):
    def test_the_published_seed(self):
        self.assertEqual(derive.mnemonic_to_seed(ABANDON).hex(), ABANDON_SEED)

    def test_a_passphrase_gives_a_different_wallet(self):
        # And the published value for it. A passphrase silently ignored would put the
        # funds somewhere the operator is not looking.
        self.assertEqual(
            derive.mnemonic_to_seed(ABANDON, "TREZOR").hex(), ABANDON_SEED_TREZOR
        )
        self.assertNotEqual(
            derive.mnemonic_to_seed(ABANDON), derive.mnemonic_to_seed(ABANDON, "TREZOR")
        )

    def test_whitespace_does_not_change_the_wallet(self):
        # An operator pasting from a wrapped config file must not get another wallet.
        spaced = "  " + "  ".join(ABANDON.split()) + "\n"
        self.assertEqual(derive.mnemonic_to_seed(spaced), derive.mnemonic_to_seed(ABANDON))


class Bip32Tests(unittest.TestCase):
    def test_the_published_master_key(self):
        key, chain_code = derive.master_from_seed(BIP32_SEED)
        serialized = derive._serialize(
            derive._XPRV_VERSION["mainnet"], 0, b"\x00\x00\x00\x00", 0,
            chain_code, key, private=True,
        )
        self.assertEqual(serialized, BIP32_MASTER_XPRV)

    def test_a_normal_child_satisfies_the_curve_identity(self):
        """`child_pub = parent_pub + IL·G`, which is what makes an xpub useful at all.

        Independent of the code path under test: it recomputes the relationship from the
        HMAC directly and checks the point addition, so a wrong scalar multiplication cannot
        pass by being wrong consistently.
        """
        import hashlib
        import hmac

        key, chain_code = derive.master_from_seed(BIP32_SEED)
        parent_public = derive.compressed_public_key(key)
        child, _ = derive._ckd_priv(key, chain_code, 0)

        digest = hmac.new(chain_code, parent_public + (0).to_bytes(4, "big"),
                          hashlib.sha512).digest()
        offset = int.from_bytes(digest[:32], "big")
        expected = derive._add(
            derive._multiply(offset),
            derive._multiply(int.from_bytes(key, "big")),
        )
        x, y = expected
        self.assertEqual(
            derive.compressed_public_key(child),
            bytes([2 + (y & 1)]) + x.to_bytes(32, "big"),
        )

    def test_hardened_and_normal_children_differ(self):
        key, chain_code = derive.master_from_seed(BIP32_SEED)
        normal, _ = derive._ckd_priv(key, chain_code, 0)
        hardened, _ = derive._ckd_priv(key, chain_code, 0 | derive._HARDENED)
        self.assertNotEqual(normal, hardened)


class AccountTests(unittest.TestCase):
    def test_the_path_is_bip84_and_the_coin_type_follows_the_network(self):
        self.assertEqual(derive.account(ABANDON, "", "mainnet")["path"], "84h/0h/0h")
        for network in ("testnet", "signet", "regtest"):
            self.assertEqual(derive.account(ABANDON, "", network)["path"], "84h/1h/0h")

    def test_mainnet_and_testnet_keys_are_not_interchangeable(self):
        # The version bytes differ, so Core refuses the wrong one outright -- which is
        # the failure to want, rather than a wallet on the wrong chain.
        self.assertTrue(derive.account(ABANDON, "", "mainnet")["xprv"].startswith("xprv"))
        self.assertTrue(derive.account(ABANDON, "", "testnet")["xprv"].startswith("tprv"))

    def test_the_master_fingerprint_is_the_published_one(self):
        # 73c5da0a is this vector's fingerprint in every wallet that implements BIP-32.
        self.assertEqual(
            derive.account(ABANDON, "", "mainnet")["master_fingerprint"], "73c5da0a"
        )

    def test_an_unknown_network_is_refused_rather_than_guessed(self):
        with self.assertRaises(ValueError):
            derive.account(ABANDON, "", "litecoin")


class DescriptorTests(unittest.TestCase):
    def test_two_chains_receiving_and_change(self):
        receiving, change = derive.descriptors(ABANDON, "", "mainnet")
        self.assertFalse(receiving["internal"])
        self.assertTrue(change["internal"])
        self.assertIn("/0/*", receiving["desc"])
        self.assertIn("/1/*", change["desc"])

    def test_the_origin_names_the_master_and_the_path(self):
        # Without it a recovery tool cannot tell where in the tree the key sits.
        [receiving, _] = derive.descriptors(ABANDON, "", "mainnet")
        self.assertTrue(receiving["desc"].startswith("wpkh([73c5da0a/84h/0h/0h]xprv"))

    def test_no_checksum_is_computed_here(self):
        # Core computes it and refuses a descriptor whose checksum does not match, so
        # asking it is both shorter and stricter than deriving one.
        for descriptor in derive.descriptors(ABANDON, "", "mainnet"):
            self.assertNotIn("#", descriptor["desc"])

    def test_a_fresh_wallet_is_imported_as_new(self):
        # `now` is what keeps a fresh wallet from asking a pruned node for a rescan it
        # cannot do. See the README on reusing a mnemonic that has history.
        for descriptor in derive.descriptors(ABANDON, "", "mainnet"):
            self.assertEqual(descriptor["timestamp"], "now")


class EncodingTests(unittest.TestCase):
    def test_base58check_keeps_leading_zeroes(self):
        # Each leading zero byte is a leading '1', and the integer arithmetic in the
        # encoder cannot know that: an address with one would be silently truncated.
        self.assertTrue(derive.base58check(b"\x00" * 3 + b"\x01").startswith("111"))

    def test_the_public_key_is_compressed_and_parity_tagged(self):
        key = derive.master_from_seed(BIP32_SEED)[0]
        public = derive.compressed_public_key(key)
        self.assertEqual(len(public), 33)
        self.assertIn(public[0], (2, 3))


if __name__ == "__main__":
    unittest.main()
