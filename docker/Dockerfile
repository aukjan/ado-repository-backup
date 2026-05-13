FROM debian:bullseye-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends --fix-missing \
         ca-certificates curl gnupg lsb-release tar jq git \
    && mkdir -p /etc/apt/keyrings \
    && curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
         | gpg --dearmor > /etc/apt/keyrings/microsoft.gpg \
    && chmod go+r /etc/apt/keyrings/microsoft.gpg \
    && echo "Types: deb\nURIs: https://packages.microsoft.com/repos/azure-cli/\nSuites: $(lsb_release -cs)\nComponents: main\nArchitectures: $(dpkg --print-architecture)\nSigned-by: /etc/apt/keyrings/microsoft.gpg" \
         > /etc/apt/sources.list.d/azure-cli.sources \
    && apt-get update \
    && apt-get install -y azure-cli \
    && az extension add --name azure-devops \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash devops
USER devops
COPY --chown=devops --chmod=744 src/backup-devops.sh /home/devops
COPY --chown=devops --chmod=744 docker/starter.sh /home/devops
WORKDIR /home/devops
VOLUME ["/data"]
ENTRYPOINT ["/bin/bash", "./starter.sh"]