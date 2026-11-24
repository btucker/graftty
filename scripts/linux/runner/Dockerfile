FROM ubuntu:24.04

LABEL org.opencontainers.image.title="graftty-runner" \
      org.opencontainers.image.description="Graftty remote runner and persistent terminal runtime" \
      org.opencontainers.image.source="https://github.com/btucker/graftty" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=20 update \
    && apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=20 install -y --no-install-recommends \
        bash ca-certificates curl git openssh-client tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home --shell /bin/bash runner \
    && install -d -o runner -g runner /home/runner/projects

# The build context contains only this recipe and a trusted Linux archive.
# Reuse its launchers, Swift libraries, resources, and Graftty-patched zmx.
ADD graftty-linux.tar.gz /opt/graftty/

ENV HOME=/home/runner \
    SHELL=/bin/bash \
    PATH=/opt/graftty/bin:/home/runner/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    GRAFTTY_STATE_DIR=/home/runner/.local/share/graftty \
    XDG_RUNTIME_DIR=/tmp/graftty-runtime \
    GRAFTTY_SOCK=/tmp/graftty-runtime/graftty/graftty.sock

USER runner
WORKDIR /home/runner/projects
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 \
    CMD graftty-runner status --json | grep -q '"running":true'

# zmx daemons fork; tini reaps them and forwards termination to the runner.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/graftty/bin/graftty-runner"]
# Macs reach the runner over Tailcat. The direct listener stays on all
# interfaces inside the container's own namespace, so a container paired
# earlier through a published port keeps working; nothing is reachable unless
# the operator publishes it.
CMD ["serve", "--bind-address", "0.0.0.0"]
