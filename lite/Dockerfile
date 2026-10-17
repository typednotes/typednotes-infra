# syntax=docker/dockerfile:1
# Named BuildKit contexts are external source-build targets, not local stages.
# hadolint global ignore=DL3022
# The six named contexts are source builds supplied by docker-bake.hcl.
# Trixie satisfies the app's glibc requirement and runs the older service
# binaries too. Lean and the native dependencies are still needed at runtime.
FROM docker.io/library/debian:trixie-slim
ARG LINEN_REF=v1.12.0
ADD https://raw.githubusercontent.com/typednotes/linen/${LINEN_REF}/ci/native-deps/apt.txt /tmp/linen-apt.txt
# Versions and intentional word splitting come from Linen's canonical apt list.
# hadolint ignore=DL3008,SC2046
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 tini bash tar gzip $(sed 's/#.*//' /tmp/linen-apt.txt) \
    && rm -rf /var/lib/apt/lists/* \
    && for service in app ledger liaison vault lode lun; do \
         useradd --system --create-home --home-dir "/var/lib/$service" "$service" \
           && chmod 700 "/var/lib/$service" || exit 1; \
       done
COPY --from=app /usr/local/app /usr/local/app
COPY --from=ledger /usr/local/bin/ledger /usr/local/bin/ledger
COPY --from=liaison /usr/local/bin/liaison /usr/local/bin/liaison
COPY --from=vault /usr/local/bin/secrets-server /usr/local/bin/secrets-server
COPY --from=lun /usr/local/bin/lun /usr/local/bin/lun
COPY --from=lode /usr/local/bin/lode /usr/local/bin/lode
# Both pinned workers use the same toolchain and Linen revision. Refuse drift
# rather than silently duplicating gigabytes of tooling. Lun's warm package
# cache includes the modules Lode warms, plus the reactive runtime modules.
COPY --from=lode /tmp/lean-toolchain /tmp/lode-lean-toolchain
COPY --from=lun /tmp/lean-toolchain /tmp/lun-lean-toolchain
RUN cmp /tmp/lode-lean-toolchain /tmp/lun-lean-toolchain
COPY --from=lun /opt/elan /opt/elan
COPY --from=lun /opt/lun/cache /opt/lun/cache
COPY lite/runtime.py /usr/local/lib/typednotes-lite/runtime.py
ENV PATH=/opt/elan/bin:${PATH} \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    PORT=8080
WORKDIR /usr/local/app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=15s --start-period=180s --retries=3 \
  CMD ["python3", "/usr/local/lib/typednotes-lite/runtime.py", "--healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "--", "python3", "/usr/local/lib/typednotes-lite/runtime.py"]
