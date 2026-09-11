#!/usr/bin/env bash
# The derivation, against the published vectors and against Bitcoin's own arithmetic.
#
# This is the only cryptography in the service and it decides where the money is, so it is
# checked several ways rather than read twice:
#
# * BIP-39 and BIP-32 test vectors, verbatim from the specifications. They are the reason
#   a wallet derived here opens in any other tool.
# * An identity Core also relies on: a non-hardened child's private key is the parent's
#   plus IL, so its public key is the parent's public key plus IL·G. If the modular
#   arithmetic or the curve call were wrong, this is where it shows -- it is recomputed
#   from the HMAC rather than taken from the function under test.
# * Round trips and encodings, so an error there cannot hide behind a value that merely
#   looks plausible.
# * Core's own `rpcauth`, against the output of `share/rpcauth/rpcauth.py` for a fixed
#   salt. The entrypoint writes that line and a wrong one locks the node out.
#
# Run with `bash tests/test_derive.sh`. No bitcoind is started and nothing is fetched:
# every expected value below is in this file. It needs the same `bash`, `openssl` and
# `bc` the service does, which is what makes it worth running on the host as well as in
# the image.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../service/derive.sh
. "${HERE}/../service/derive.sh"

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

is() {   # got, want, what
    if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "$2" "$1"; fi
}

isnt() {   # got, unwanted, what
    if [ "$1" != "$2" ]; then ok "$3"; else no "$3" "anything but $2" "$1"; fi
}

contains() {   # haystack, needle, what
    case "$1" in
        *"$2"*) ok "$3" ;;
        *) no "$3" "something containing $2" "$1" ;;
    esac
}

# BIP-39, the first English test vector, and the one every wallet is tested against.
ABANDON="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

echo 'BIP-39: the published English vectors (passphrase "TREZOR")'
# Every vector in the specification's own English set, not a sample. The entropy half is
# elided: what this service performs is words -> seed, and that is what is checked.
while IFS='|' read -r mnemonic seed; do
    [ -n "$mnemonic" ] || continue
    is "$(derive_mnemonic_to_seed "$mnemonic" 'TREZOR')" "$seed" \
       "$(printf '%s' "$mnemonic" | cut -c1-34)..."
done <<'VECTORS'
abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about|c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04
legal winner thank year wave sausage worth useful legal winner thank yellow|2e8905819b8723fe2c1d161860e5ee1830318dbf49a83bd451cfb8440c28bd6fa457fe1296106559a3c80937a1c1069be3a3a5bd381ee6260e8d9739fce1f607
letter advice cage absurd amount doctor acoustic avoid letter advice cage above|d71de856f81a8acc65e6fc851a38d4d7ec216fd0796d0a6827a3ad6ed5511a30fa280f12eb2e47ed2ac03b5c462a0358d18d69fe4f985ec81778c1b370b652a8
zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong|ac27495480225222079d7be181583751e86f571027b0497b5b5d11218e0a8a13332572917f0f8e5a589620c6f15b11c61dee327651a14c34e18231052e48c069
abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon agent|035895f2f481b1b0f01fcf8c289c794660b289981a78f8106447707fdd9666ca06da5a9a565181599b79f53b844d8a71dd9f439c52a3d7b3e8a79c906ac845fa
legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal will|f2b94508732bcbacbcc020faefecfc89feafa6649a5491b8c952cede496c214a0c7b3c392d168748f2d4a612bada0753b52a1c7ac53c1e93abd5c6320b9e95dd
letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter always|107d7c02a5aa6f38c58083ff74f04c607c2d2c0ecc55501dadd72d025b751bc27fe913ffb796f841c49b1d33b610cf0e91d3aa239027f5e99fe4ce9e5088cd65
zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo when|0cd6e5d827bb62eb8fc1e262254223817fd068a74b5b449cc2f667c3f1f985a76379b43348d952e2265b4cd129090758b3e3c2c49103b5051aac2eaeb890a528
abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art|bda85446c68413707090a52022edd26a1c9462295029f2e60cd7c4f2bbd3097170af7a4d73245cafa9c3cca8d561a7c3de6f5d4a10be8ed2a5e608d68f92fcc8
legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title|bc09fca1804f7e69da93c2f2028eb238c227f2e9dda30cd63699232578480a4021b146ad717fbb7e451ce9eb835f43620bf5c514db0f8add49f5d121449d3e87
letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless|c0c519bd0e91a2ed54357d9d1ebef6f5af218a153624cf4f2da911a0ed8f7a09e2ef61af0aca007096df430022f7a2b6fb91661a9589097069720d015e4e982f
zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote|dd48c104698c30cfe2b6142103248622fb7bb0ff692eebb00089b32d22484e1613912f0a5b694407be899ffd31ed3992c456cdf60f5d4564b8ba3f05a69890ad
ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic|274ddc525802f7c828d8ef7ddbcdc5304e87ac3535913611fbbfa986d0c9e5476c91689f9c8a54fd55bd38606aa6a8595ad213d4c9c9f9aca3fb217069a41028
gravity machine north sort system female filter attitude volume fold club stay feature office ecology stable narrow fog|628c3827a8823298ee685db84f55caa34b5cc195a778e52d45f59bcf75aba68e4d7590e101dc414bc1bbd5737666fbbef35d1f1903953b66624f910feef245ac
hamster diagram private dutch cause delay private meat slide toddler razor book happy fancy gospel tennis maple dilemma loan word shrug inflict delay length|64c87cde7e12ecf6704ab95bb1408bef047c22db4cc7491c4271d170a1b213d20b385bc1588d9c7b38f1b39d415665b8a9030c9ec653d75e65f847d8fc1fc440
scheme spot photo card baby mountain device kick cradle pact join borrow|ea725895aaae8d4c1cf682c1bfd2d358d52ed9f0f0591131b559e2724bb234fca05aa9c02c57407e04ee9dc3b454aa63fbff483a8b11de949624b9f1831a9612
horn tenant knee talent sponsor spell gate clip pulse soap slush warm silver nephew swap uncle crack brave|fd579828af3da1d32544ce4db5c73d53fc8acc4ddb1e3b251a31179cdb71e853c56d2fcb11aed39898ce6c34b10b5382772db8796e52837b54468aeb312cfc3d
panda eyebrow bullet gorilla call smoke muffin taste mesh discover soft ostrich alcohol speed nation flash devote level hobby quick inner drive ghost inside|72be8e052fc4919d2adf28d5306b5474b0069df35b02303de8c1729c9538dbb6fc2d731d5f832193cd9fb6aeecbc469594a70e3dd50811b5067f3b88b28c3e8d
cat swing flag economy stadium alone churn speed unique patch report train|deb5f45449e615feff5640f2e49f933ff51895de3b4381832b3139941c57b59205a42480c52175b6efcffaa58a2503887c1e8b363a707256bdd2b587b46541f5
light rule cinnamon wrap drastic word pride squirrel upgrade then income fatal apart sustain crack supply proud access|4cbdff1ca2db800fd61cae72a57475fdc6bab03e441fd63f96dabd1f183ef5b782925f00105f318309a7e9c3ea6967c7801e46c8a58082674c860a37b93eda02
all hour make first leader extend hole alien behind guard gospel lava path output census museum junior mass reopen famous sing advance salt reform|26e975ec644423f4a4c4f4215ef09b4bd7ef924e85d1d17c4cf3f136c2863cf6df0a475045652c57eb5fb41513ca2a2d67722b77e954b4b3fc11f7590449191d
vessel ladder alter error federal sibling chat ability sun glass valve picture|2aaa9242daafcee6aa9d7269f17d4efe271e1b9a529178d7dc139cd18747090bf9d60295d0ce74309a78852a9caadf0af48aae1c6253839624076224374bc63f
scissors invite lock maple supreme raw rapid void congress muscle digital elegant little brisk hair mango congress clump|7b4a10be9d98e6cba265566db7f136718e1398c71cb581e1b2f464cac1ceedf4f3e274dc270003c670ad8d02c4558b2f8e39edea2775c9e232c7cb798b069e88
void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold|01f5bced59dec48e362f2c45b5de68b9fd6c92c6634f44d6d40aab69056506f0e35524a518034ddc1192e1dacd32c1ed3eaa3c3b131c88ed8e7e54c49a5d0998
VECTORS

echo
echo 'BIP-39: seeds'
is "$(derive_mnemonic_to_seed "$ABANDON" '')" \
   "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4" \
   'the published seed'

# And the published value for a passphrase. A passphrase silently ignored would put the
# funds somewhere the operator is not looking.
is "$(derive_mnemonic_to_seed "$ABANDON" 'TREZOR')" \
   "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04" \
   'a passphrase gives the published, different seed'

isnt "$(derive_mnemonic_to_seed "$ABANDON" '')" "$(derive_mnemonic_to_seed "$ABANDON" 'TREZOR')" \
   'a passphrase gives a different wallet'

echo
echo 'BIP-32: the published master keys'
bip32_master() {   # seed hex, xprv, xpub, label
    if ! derive_master_from_seed "$1"; then
        no "$4" "$2" "derive_master_from_seed refused the seed"
        return
    fi
    is "$(derive_serialize "$DERIVE_XPRV_MAINNET" 0 0 "$DERIVE_CHAINCODE" "$DERIVE_KEY" 1 00000000)" \
       "$2" "$4 (xprv)"
    is "$(derive_serialize "$DERIVE_XPUB_MAINNET" 0 0 "$DERIVE_CHAINCODE" "$(derive_pubkey "$DERIVE_KEY")" 0 00000000)" \
       "$3" "$4 (xpub)"
}
bip32_master '000102030405060708090a0b0c0d0e0f' \
  'xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi' \
  'xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8' \
  'test vector 1'
bip32_master 'fffcf9f6f3f0edeae7e4e1dedbd8d5d2cfccc9c6c3c0bdbab7b4b1aeaba8a5a29f9c999693908d8a8784817e7b7875726f6c696663605d5a5754514e4b484542' \
  'xprv9s21ZrQH143K31xYSDQpPDxsXRTUcvj2iNHm5NUtrGiGG5e2DtALGdso3pGz6ssrdK4PFmM8NSpSBHNqPqm55Qn3LqFtT2emdEXVYsCzC2U' \
  'xpub661MyMwAqRbcFW31YEwpkMuc5THy2PSt5bDMsktWQcFF8syAmRUapSCGu8ED9W6oDMSgv6Zz8idoc4a6mr8BDzTJY47LJhkJ8UB7WEGuduB' \
  'test vector 2'
bip32_master '4b381541583be4423346c643850da4b320e46a87ae3d2a4e6da11eba819cd4acba45d239319ac14f863b8d5ab5a0d0c64d2e8a1e7d1457df2e5a3c51c73235be' \
  'xprv9s21ZrQH143K25QhxbucbDDuQ4naNntJRi4KUfWT7xo4EKsHt2QJDu7KXp1A3u7Bi1j8ph3EGsZ9Xvz9dGuVrtHHs7pXeTzjuxBrCmmhgC6' \
  'xpub661MyMwAqRbcEZVB4dScxMAdx6d4nFc9nvyvH3v4gJL378CSRZiYmhRoP7mBy6gSPSCYk6SzXPTf3ND1cZAceL7SfJ1Z3GC8vBgp2epUt13' \
  'test vector 3 (a leading zero in the key)'
bip32_master '3ddd5602285899a946114506157c7997e5444528f3003f6134712147db19b678' \
  'xprv9s21ZrQH143K48vGoLGRPxgo2JNkJ3J3fqkirQC2zVdk5Dgd5w14S7fRDyHH4dWNHUgkvsvNDCkvAwcSHNAQwhwgNMgZhLtQC63zxwhQmRv' \
  'xpub661MyMwAqRbcGczjuMoRm6dXaLDEhW1u34gKenbeYqAix21mdUKJyuyu5F1rzYGVxyL6tmgBUAEPrEz92mBXjByMRiJdba9wpnN37RLLAXa' \
  'test vector 4 (a leading zero in the chain code path)'

echo
echo 'BIP-32: the published children'
# Vector 1 walked to m/0'/1/2'/2/1000000000, which is every kind of step: hardened,
# non-hardened, and the one with the well-known 1000000000 index at the end. The
# non-hardened steps exercise `derive_pubkey`, since the data hashed is a public key.
derive_master_from_seed '000102030405060708090a0b0c0d0e0f'
KEY="$DERIVE_KEY"; CC="$DERIVE_CHAINCODE"
walk() {   # index, xprv, label
    local parent
    parent=$(derive_fingerprint "$KEY")
    derive_ckd_priv "$KEY" "$CC" "$1"
    KEY="$DERIVE_KEY"; CC="$DERIVE_CHAINCODE"
    DEPTH=$(( ${DEPTH:-0} + 1 ))
    is "$(derive_serialize "$DERIVE_XPRV_MAINNET" "$DEPTH" "$1" "$CC" "$KEY" 1 "$parent")" "$2" "$3"
}
DEPTH=0
walk 2147483648 'xprv9uHRZZhk6KAJC1avXpDAp4MDc3sQKNxDiPvvkX8Br5ngLNv1TxvUxt4cV1rGL5hj6KCesnDYUhd7oWgT11eZG7XnxHrnYeSvkzY7d2bhkJ7' "m/0'"
walk 1          'xprv9wTYmMFdV23N2TdNG573QoEsfRrWKQgWeibmLntzniatZvR9BmLnvSxqu53Kw1UmYPxLgboyZQaXwTCg8MSY3H2EU4pWcQDnRnrVA1xe8fs' "m/0'/1"
walk 2147483650 'xprv9z4pot5VBttmtdRTWfWQmoH1taj2axGVzFqSb8C9xaxKymcFzXBDptWmT7FwuEzG3ryjH4ktypQSAewRiNMjANTtpgP4mLTj34bhnZX7UiM' "m/0'/1/2'"
walk 2          'xprvA2JDeKCSNNZky6uBCviVfJSKyQ1mDYahRjijr5idH2WwLsEd4Hsb2Tyh8RfQMuPh7f7RtyzTtdrbdqqsunu5Mm3wDvUAKRHSC34sJ7in334' "m/0'/1/2'/2"
walk 1000000000 'xprvA41z7zogVVwxVSgdKUHDy1SKmdb533PjDz7J6N6mV6uS3ze1ai8FHa8kmHScGpWmj4WggLyQjgPie1rFSruoUihUZREPSL39UNdE3BBDu76' "m/0'/1/2'/2/1000000000"

echo
echo 'BIP-32: the curve identity a non-hardened child has to satisfy'
# child_pub = parent_pub + IL·G, which is what makes an xpub useful at all. Recomputed
# from the HMAC here, with the point addition done by OpenSSL through a private key whose
# scalar is the sum: if the modular addition in `bc` were wrong, this is where it shows.
derive_master_from_seed '000102030405060708090a0b0c0d0e0f'
parent_key="$DERIVE_KEY"; parent_cc="$DERIVE_CHAINCODE"
parent_pub=$(derive_pubkey "$parent_key")
derive_ckd_priv "$parent_key" "$parent_cc" 0
child_pub=$(derive_pubkey "$DERIVE_KEY")
digest=$(derive_hmac_sha512 "$parent_cc" "${parent_pub}00000000")
sum=$(derive_mod_add_n "${digest:0:64}" "$parent_key")
is "$child_pub" "$(derive_pubkey "$sum")" 'a normal child is the parent scalar plus IL'
isnt "$(derive_pubkey "$sum")" "$parent_pub" 'and is not the parent itself'

derive_master_from_seed '000102030405060708090a0b0c0d0e0f'
derive_ckd_priv "$DERIVE_KEY" "$DERIVE_CHAINCODE" 0
normal="$DERIVE_KEY"
derive_master_from_seed '000102030405060708090a0b0c0d0e0f'
derive_ckd_priv "$DERIVE_KEY" "$DERIVE_CHAINCODE" "$DERIVE_HARDENED"
isnt "$normal" "$DERIVE_KEY" 'hardened and normal children of the same index differ'

echo
echo 'The account'
derive_account "$ABANDON" '' mainnet
is "$DERIVE_ACCOUNT_PATH" '84h/0h/0h' 'the path is BIP-84 on mainnet'
# 73c5da0a is this vector's fingerprint in every wallet that implements BIP-32.
is "$DERIVE_ACCOUNT_FINGERPRINT" '73c5da0a' 'the master fingerprint is the published one'
is "$DERIVE_ACCOUNT_XPRV" \
   'xprv9ybY78BftS5UGANki6oSifuQEjkpyAC8ZmBvBNTshQnCBcxnefjHS7buPMkkqhcRzmoGZ5bokx7GuyDAiktd5HemohAU4wV1ZPMDRmLpBMm' \
   'the account xprv is the one every BIP-84 wallet derives'
is "$DERIVE_ACCOUNT_XPUB" \
   'xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V' \
   'and so is its xpub'

for network in testnet signet regtest; do
    derive_account "$ABANDON" '' "$network"
    is "$DERIVE_ACCOUNT_PATH" '84h/1h/0h' "the coin type follows the network (${network})"
    # The version bytes differ, so Core refuses the wrong one outright -- which is the
    # failure to want, rather than a wallet on the wrong chain.
    case "$DERIVE_ACCOUNT_XPRV" in
        tprv*) ok "${network} keys are test keys" ;;
        *) no "${network} keys are test keys" 'tprv...' "$DERIVE_ACCOUNT_XPRV" ;;
    esac
done
derive_account "$ABANDON" '' mainnet
case "$DERIVE_ACCOUNT_XPRV" in
    xprv*) ok 'mainnet keys are mainnet keys' ;;
    *) no 'mainnet keys are mainnet keys' 'xprv...' "$DERIVE_ACCOUNT_XPRV" ;;
esac

# An operator pasting from a wrapped config file must not get another wallet.
spaced="   $(printf '%s' "$ABANDON" | tr ' ' '\n' | tr '\n' ' ')
"
derive_account "$spaced" '' mainnet
is "$DERIVE_ACCOUNT_XPRV" \
   'xprv9ybY78BftS5UGANki6oSifuQEjkpyAC8ZmBvBNTshQnCBcxnefjHS7buPMkkqhcRzmoGZ5bokx7GuyDAiktd5HemohAU4wV1ZPMDRmLpBMm' \
   'whitespace does not change the wallet'

if derive_account "$ABANDON" '' litecoin 2>/dev/null; then
    no 'an unknown network is refused rather than guessed' 'a refusal' 'a key'
else
    ok 'an unknown network is refused rather than guessed'
fi

# BIP-39 hashes the NFKD form and a shell cannot normalise one, so a passphrase that is
# not ASCII is refused rather than hashed as whatever bytes arrived. The README says so.
if derive_account "$ABANDON" "$(printf 'caf\303\251')" mainnet 2>/dev/null; then
    no 'a non-ASCII passphrase is refused, not silently mis-normalised' 'a refusal' 'a key'
else
    ok 'a non-ASCII passphrase is refused, not silently mis-normalised'
fi

echo
echo 'The descriptors, as Core receives them'
derive_descriptors "$ABANDON" '' mainnet
contains "$DERIVE_DESC_RECEIVE" '/0/*' 'the receiving descriptor is the external chain'
contains "$DERIVE_DESC_CHANGE" '/1/*' 'the change descriptor is the internal chain'
# Without the origin a recovery tool cannot tell where in the tree the key sits.
case "$DERIVE_DESC_RECEIVE" in
    'wpkh([73c5da0a/84h/0h/0h]xprv'*) ok 'the origin names the master and the path' ;;
    *) no 'the origin names the master and the path' 'wpkh([73c5da0a/84h/0h/0h]xprv...' "${DERIVE_DESC_RECEIVE:0:40}..." ;;
esac
# Core computes the checksum and refuses a descriptor whose checksum does not match, so
# asking it is both shorter and stricter than deriving one.
case "$DERIVE_DESC_RECEIVE$DERIVE_DESC_CHANGE" in
    *'#'*) no 'no checksum is computed here' 'no #' 'a #' ;;
    *) ok 'no checksum is computed here' ;;
esac

echo
echo 'Encodings'
# Each leading zero byte is a leading '1', and the integer arithmetic in the encoder
# cannot know that: an address with one would be silently truncated.
case "$(derive_base58check '00000001')" in
    '111'*) ok 'base58check keeps leading zeroes' ;;
    *) no 'base58check keeps leading zeroes' '111...' "$(derive_base58check '00000001')" ;;
esac
# The classic vector: a P2PKH address for the all-zero hash160 -- 21 bytes, all of them
# a leading zero, which is the encoder's worst case.
is "$(derive_base58check '000000000000000000000000000000000000000000')" \
   '1111111111111111111114oLvT2' 'base58check of the zero hash160'
is "$(derive_hash160 "$(derive_hex_of 'abc')")" 'bb1be98c142444d7a56aa3981c3942a978e4dc33' \
   'hash160 is RIPEMD-160 of SHA-256'
is "$(derive_sha256 "$(derive_hex_of 'abc')")" \
   'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' 'sha256'
is "$(derive_sha256d "$(derive_hex_of 'hello')")" \
   '9595c9df90075148eb06860365df33584b75bff782a510c6cd4883a419833d50' 'sha256d'
public=$(derive_pubkey 'e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35')
is "${#public}" '66' 'a public key is 33 bytes'
case "${public:0:2}" in
    02|03) ok 'and is compressed and parity-tagged' ;;
    *) no 'and is compressed and parity-tagged' '02 or 03' "${public:0:2}" ;;
esac
is "$public" '0339a36013301597daef41fbe593a02cc513d0b55527ec2df1050e2e8ff49c85c2' \
   "and is the public key BIP-32's vector 1 publishes"

echo
echo "Core's rpcauth"
# The same construction `share/rpcauth/rpcauth.py` in Core's own tree produces, for a
# fixed salt. A wrong line here locks the node out of the service it just started.
is "$(derive_hmac_sha256 "$(derive_hex_of 'd3a2b1c4e5f60718293a4b5c6d7e8f90')" "$(derive_hex_of 'hunter2')")" \
   '4f0172f8af28bc93af1aa84bb292bad5c9e0f95947fdce1af2aa74689d65bd84' \
   'HMAC-SHA256 of the password, keyed by the salt as ASCII hex'
salt=$(openssl rand -hex 16)
is "${#salt}" '32' 'the salt is 16 random bytes'

echo
echo "--------------------------------------------------"
printf 'passed %s, failed %s\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
