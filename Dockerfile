FROM ubuntu:18.04

# To make it easier for build and release pipelines to run apt-get,
# configure apt to not require confirmation (assume the -y argument by default)

ENV DEBIAN_FRONTEND=noninteractive
# If your company uses a proxy:
ENV http_proxy=http://company.proxy.url:8080/
ENV https_proxy=http://company.proxy.url:8080/
ENV no_proxy=.company.internal.net
RUN echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes

RUN apt-get update \
&& apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        git \
        iputils-ping \
        libcurl4 \
        libicu60 \
        libunwind8 \
        netcat \
        default-jdk \
        maven

# If your company uses its own Root Certificate Authority create site files (site/company.pki.url/ROOTCA.crt transforms to http://company.pki.url/ROOTCA.crt)
WORKDIR /certtemp
COPY site /tmp/ca
RUN find /tmp/ca -type f ! -name '.gitignore' | sed 's/\/tmp\/ca/http:/' | while read CERT; \
        do curl ${CERT} --output /certtemp/$(basename ${CERT}); \
            openssl x509 -in /certtemp/$(basename ${CERT}) -inform DER -out /usr/local/share/ca-certificates/$(basename ${CERT}); \
        done;
RUN update-ca-certificates

# Add Microsoft debian repo
RUN curl https://packages.microsoft.com/config/ubuntu/18.04/packages-microsoft-prod.deb --output packages-microsoft-prod.deb
RUN dpkg -i packages-microsoft-prod.deb

# Install dotnet core 2.1, 3.1 and 5.0
RUN apt-get update \
&& apt-get install -y --no-install-recommends \
        powershell \
        apt-transport-https \
        dotnet-sdk-5.0 \
        dotnet-sdk-3.1 \
        dotnet-sdk-2.1

# Add Node.js 14.x LTS
RUN curl -sL https://deb.nodesource.com/setup_lts.x | bash -

# Install nodejs, npm and typescript
RUN apt-get update \
&& apt-get install -y nodejs \
        node-typescript

# Can be 'linux-x64', 'linux-arm64', 'linux-arm', 'rhel.6-x64'.
ENV TARGETARCH=linux-x64

WORKDIR /azp
RUN chgrp -R 0 /azp && \
    chmod -R g=u /azp

# Make company Root CA available for the agent process (NodeJS)
RUN mkdir /azp/certchain
RUN find /usr/local/share/ca-certificates -type f -name '*.crt' -exec cat {} \; > /azp/certchain/combined.pem

COPY ./start.sh .
RUN chmod +x start.sh

# From: https://github.com/RHsyseng/container-rhel-examples/tree/master/starter-arbitrary-uid
### Setup user for build execution and application runtime
ENV APP_ROOT=/opt/app-root
ENV PATH=${APP_ROOT}/bin:${PATH}
ENV HOME=/home
COPY bin/ ${APP_ROOT}/bin/
RUN chmod -R u+x ${APP_ROOT}/bin && \
    chgrp -R 0 ${APP_ROOT} && \
    chmod -R g=u ${APP_ROOT} /etc/passwd

# Give user access to
RUN chgrp -R 0 /home && \
    chmod -R g=u /home

### Containers should NOT run as root as a good practice
USER 10001

ENV AGENT_ALLOW_RUNASROOT="1"
ENV NODE_EXTRA_CA_CERTS='/azp/certchain/jst_combined.pem'
ENV HOME='/home'
ENV JAVA_HOME_11_X64='/usr/lib/jvm/java-11-openjdk-amd64'


ENTRYPOINT ["./start.sh", "agent"]
