FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client openssh-server python3 sudo procps && rm -rf /var/lib/apt/lists/* && useradd -m -s /bin/bash developer && echo 'developer ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/developer
COPY .devcontainer/curl-orca-release /usr/local/bin/curl
COPY identity.txt /tmp/orca-e2e-image-source
