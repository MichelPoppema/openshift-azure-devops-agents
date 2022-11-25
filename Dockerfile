ARG BASE=centos:stream8
FROM $BASE

RUN yum module enable -y maven:3.6 nodejs:16 \
    && yum update -y \
    && yum install -y --nobest \
       ca-certificates \
       jq \
       tar \
       git \
       openssl-libs \
       krb5-libs \
       zlib \
       libicu \
       lttng-ust \
       java-11-openjdk-headless \
       java-11-openjdk-devel \
       java-17-openjdk-headless \
       java-17-openjdk-devel \
       maven \
       nodejs \
       dotnet-sdk-6.0 \
       zip \
       python39 \
       findutils \
    && yum clean all -y

# From https://manuals.gfi.com/en/kerio/connect/content/server-configuration/ssl-certificates/adding-trusted-root-certificates-to-the-server-1605.html
## Linux (CentOs 6)
COPY site/ca /tmp/ca
RUN update-ca-trust force-enable \
    && find /tmp/ca -type f ! -name '.gitignore' | sed 's/\/tmp\/ca/http:/' | xargs -n1 -r curl -s > /etc/pki/ca-trust/source/anchors/internal.crt \; \
    && update-ca-trust extract \
    && rm -rf /tmp/ca

ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk \
    JAVA_HOME_11_X64=/usr/lib/jvm/java-11-openjdk \
    JAVA_HOME_17_X64=/usr/lib/jvm/java-17-openjdk \
    NODE_EXTRA_CA_CERTS=/etc/pki/ca-trust/source/anchors/internal.crt 

# Can be 'linux-x64', 'linux-arm64', 'linux-arm', 'rhel.6-x64'.
ENV TARGETARCH=linux-x64

WORKDIR /azp

# RHEL8's /etc/java/maven.conf hardcoded sets JAVA_HOME to openjdk 11 preventing overruling jdkVersion in Maven task
RUN echo '[[ ! -z "${JAVA_HOME}" ]] || JAVA_HOME=/usr/lib/jvm/java-11-openjdk' > /etc/java/maven.conf

COPY ./start.sh .
RUN chmod +x start.sh

RUN python3.9 -m venv .python 
COPY site/home .
RUN  /azp/.python/bin/python -m pip install --upgrade pip

# From https://docs.openshift.com/container-platform/4.10/openshift_images/create-images.html#images-create-guide-openshift_create-images
## Support arbitrary user ids
RUN chgrp -R 0 /azp \
    && chmod -R g+rwX /azp

USER 10001

ENV HOME=/azp BASH_ENV=/azp/.bashrc

ENTRYPOINT ["./start.sh", "agent"]