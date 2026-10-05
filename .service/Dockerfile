# Every dependency is pinned, and the two that matter are pinned by digest and by
# checksum. This service is content-addressed -- two packs of the same source tree must
# produce the same image -- and the image holds a wallet, so "whatever was on that tag
# today" is not a thing to build a key holder out of.
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

# Bitcoin Core, from the release the project publishes, for aarch64. The checksum is the
# one in that release's own SHA256SUMS: a tarball that does not match it is not the
# release, and the build stops rather than shipping whatever was served.
#
# Verifying the signature on SHA256SUMS as well would be better still, and it needs the
# guix builders' keys in the image; the checksum here is pinned in a file under review,
# which is the property that matters most -- it cannot change without a diff.
ARG BITCOIN_VERSION=31.1
ARG BITCOIN_SHA256=dcf1873f2208ba4f962f3398d47e154c39c0084be8f4553e05c940d0ace3d004
ADD https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz /tmp/bitcoin.tar.gz
RUN echo "${BITCOIN_SHA256}  /tmp/bitcoin.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/bitcoin.tar.gz -C /tmp \
    && install -m 0755 /tmp/bitcoin-${BITCOIN_VERSION}/bin/bitcoind /usr/local/bin/bitcoind \
    && install -m 0755 /tmp/bitcoin-${BITCOIN_VERSION}/bin/bitcoin-cli /usr/local/bin/bitcoin-cli \
    && rm -rf /tmp/bitcoin.tar.gz /tmp/bitcoin-${BITCOIN_VERSION}

# Four packages, pinned to the version and not to the suite, because an image that holds
# a wallet should be the same image tomorrow. `bash` and the coreutils the scripts use
# are already in the base.
#
#  openssl  every primitive the derivation needs: PBKDF2-HMAC-SHA512, HMAC-SHA512,
#           SHA-256, RIPEMD-160, and secp256k1 for the one public key that has to be
#           computed. It is what replaces Python's `hashlib` and `hmac`.
#  bc       256-bit arithmetic: the modular addition BIP-32 defines a child key as, and
#           the divmod loop base58 is.
#  jq       Core's JSON-RPC answers, read without a JSON parser written in shell.
#
# Pinning to the patch version means a Debian security update does not silently change
# this image -- and equally that the build stops until this file is edited when the old
# version leaves the mirror. That is the trade this service already makes for Core and
# for the base image, made once more.
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        openssl=3.0.20-1~deb12u2 \
        libssl3=3.0.20-1~deb12u2 \
        bc=1.07.1-3 \
        jq=1.6-2.1+deb12u2 \
        libjq1=1.6-2.1+deb12u2 \
        libonig5=6.9.8-1 \
    && rm -rf /var/lib/apt/lists/*

# No language runtime and no third-party cryptography library: the key derivation is
# `service/derive.sh`, which arranges OpenSSL's primitives into BIP-39 and BIP-32 and is
# checked against the published test vectors. A wallet holder is a smaller thing to audit
# when what is in it is a shell script and a library Debian already ships to everything.
#
# The packer build context is `.service/`. Project files land under `.service/service/`
# (`pack_config.json` `include: ["service"]` -> `.service/service/service/...`).
# A COPY source must start with `.` so the packer rewrites `./service` to `service/service`
# (`prepare_directory.py`). `COPY service /service` is left as-is and the pack fails.
COPY ./service /service
RUN chmod +x /service/entrypoint.sh /service/derive.sh && mkdir -p /data
