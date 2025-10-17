# vi: set et ts=2 sw=2 :
#
# This file is for creating the build environment docker image
# for ipmitool
#
ARG ostype=fedora
ARG osver=latest
FROM $ostype:$osver
ARG ostype
ARG osver
ENV osver=$osver
ENV ostype=$ostype
RUN case "$ostype" in \
      fedora) \
        echo Building for Fedora $osver; \
        yum install -y \
        bzip2 \
        gawk \
        make \
        automake \
        gcc \
        glibc-static \
        openssl-devel \
        systemd-devel \
        readline-devel \
        freeipmi-devel \
        libusb-compat-0.1-devel \
        libtool \
        wget \
        doxygen \
        graphviz \
        git \
        ;;\
      \
      ubuntu) \
        echo Building for Ubuntu $osver; \
        export DEBIAN_FRONTEND=noninteractive; \
        apt-get update; \
        apt-get -y install \
                   git \
                   build-essential \
                   automake \
                   libtool \
                   pkg-config \
                   libsystemd-dev \
                   libreadline-dev \
                   libfreeipmi-dev \
                   libusb-dev \
                   libssl-dev \
                   wget \
                   mingw-w64 \
                   doxygen \
                   graphviz \
       ;; \
       \
       *) \
         echo "Aborted: OS Name is NOT defined!"; \
         exit 1 \
       ;; \
     esac

