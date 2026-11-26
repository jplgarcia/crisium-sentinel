# crisium as a PRT sentinel: the machine-emulator release package (the cartesi Lua modules and the
# cartesi-machine binaries), crisium from the emulator's doc/recipes, the anomaly handler in handler/,
# and Dave's contract artifacts. The application's template is not in the image: the entrypoint
# downloads it from TEMPLATE_URL and checks it against the application's getTemplateHash().
ARG DEBIAN=debian:trixie-slim
FROM ${DEBIAN}

ARG TARGETARCH
# The emulator package must be the release the recipes in ./machine-emulator come from.
ARG EMULATOR_VERSION=v0.23.0
ARG EMULATOR_SHA256_amd64=6d63f3094228694e2cf01d60e0a96e2f9d1fb8b4f152548f89a8a5646d4b75ca
ARG EMULATOR_SHA256_arm64=134fe1b96896e27ed93b74251e6bb0942e19e2b54b9681da13ad696fc5f004b6
# Dave's contract artifacts give crisium the ABIs. Set DAVE_ARTIFACTS_SHA256 to "" to skip the check
# when building another DAVE_VERSION.
ARG DAVE_VERSION=v3.0.0-alpha.8-test1
ARG DAVE_ARTIFACTS_SHA256=f83e5f09a69feff8c767ecd5be2e19db34fe998228aac989cba6a32a611ef5c3

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tini lua5.4 lua-dkjson lua-socket python3 \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "${TARGETARCH}" in amd64) sha="${EMULATOR_SHA256_amd64}" ;; arm64) sha="${EMULATOR_SHA256_arm64}" ;; \
        *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; esac; \
    curl -fsSL -o /tmp/machine-emulator.deb \
        "https://github.com/cartesi/machine-emulator/releases/download/${EMULATOR_VERSION}/machine-emulator_${TARGETARCH}.deb"; \
    if [ "${EMULATOR_VERSION}" = "v0.23.0" ]; then echo "${sha}  /tmp/machine-emulator.deb" | sha256sum -c -; fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/machine-emulator.deb; \
    rm -rf /var/lib/apt/lists/* /tmp/machine-emulator.deb; \
    cartesi-machine --version | head -1

RUN set -eu; \
    version="${DAVE_VERSION#v}"; \
    curl -fsSL -o /tmp/dave.tar.gz \
        "https://github.com/cartesi/dave/releases/download/${DAVE_VERSION}/cartesi-rollups-prt-${version}-contract-artifacts.tar.gz"; \
    if [ -n "${DAVE_ARTIFACTS_SHA256}" ]; then echo "${DAVE_ARTIFACTS_SHA256}  /tmp/dave.tar.gz" | sha256sum -c -; fi; \
    mkdir -p /opt/dave; \
    tar -xzf /tmp/dave.tar.gz -C /opt/dave; \
    rm /tmp/dave.tar.gz; \
    # crisium loads the Application and InputBox artifacts; some Dave releases ship only their interfaces.
    out=/opt/dave/cartesi-rollups/contracts/out; \
    for name in Application InputBox; do \
        if [ ! -f "${out}/${name}.sol/${name}.json" ]; then \
            mkdir -p "${out}/${name}.sol"; \
            cp "${out}/I${name}.sol/I${name}.json" "${out}/${name}.sol/${name}.json"; \
            echo "using I${name}.json as ${name}.json"; \
        fi; \
    done

COPY machine-emulator/doc/recipes/*.lua /opt/crisium/recipes/
COPY handler/crisium_alerts.lua /opt/crisium/handler/
COPY sentinel/ /opt/crisium/sentinel/

ENV LUA_PATH="/opt/crisium/sentinel/?.lua;/opt/crisium/recipes/?.lua;/opt/crisium/handler/?.lua;;" \
    EMULATOR_VERSION=${EMULATOR_VERSION} \
    DAVE_VERSION=${DAVE_VERSION} \
    DAVE_DIR=/opt/dave \
    DATA_DIR=/data

RUN useradd --system --create-home --home-dir /home/sentinel sentinel \
    && mkdir -p /data && chown sentinel:sentinel /data \
    && chmod +x /opt/crisium/sentinel/entrypoint.sh /opt/crisium/sentinel/healthcheck.sh
USER sentinel
VOLUME /data
HEALTHCHECK --interval=60s --timeout=10s --start-period=30m --retries=3 CMD ["/opt/crisium/sentinel/healthcheck.sh"]
ENTRYPOINT ["tini", "--", "/opt/crisium/sentinel/entrypoint.sh"]
