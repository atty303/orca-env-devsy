FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends git python3 ca-certificates && rm -rf /var/lib/apt/lists/* && mkdir -p /srv/fixture
COPY server.py /usr/local/bin/git-fixture.py
COPY source.git /opt/fixture/source.git
