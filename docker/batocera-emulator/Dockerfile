FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    qemu-system-x86 \
    qemu-utils \
    iproute2 \
    net-tools \
    openssh-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /vms

COPY entrypoint.sh /vms/entrypoint.sh

RUN chmod +x /vms/entrypoint.sh

EXPOSE 2222 5901

ENTRYPOINT ["/vms/entrypoint.sh"]