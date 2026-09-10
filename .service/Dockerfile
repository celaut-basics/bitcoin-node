# Every dependency is pinned, and the two that matter are pinned by digest and by
# checksum. This service is content-addressed -- two packs of the same source tree must
# produce the same image -- and the image holds a wallet, so "whatever was on that tag
# today" is not a thing to build a key holder out of.
FROM python:3.11-slim-bookworm@sha256:528257d48c1da0dcecc2e725d1ae34498d60c965f1241e39cd6a85a8859bdf84

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

# Nothing is installed for the key derivation: it is standard library only, in
# service/derive.py, checked against the published BIP test vectors. A wallet holder
# with no third-party cryptography in it is a smaller thing to audit, and nothing in it
# can move underneath the pin above.
COPY service /service
RUN chmod +x /service/entrypoint.py && mkdir -p /data
