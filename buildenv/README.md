== Build Environment

This directory contains docker configuration for building the environment
in which ipmitool builds can be tested

Example:
```
OST=ubuntu
OSV=noble
docker --build-arg ostype=$OST --build-arg osver=$OSV -t ipmitool-buildenv:$OST-$OSV .
```

Supported OS types:

  - fedora
  - ubuntu

The above example builds an image based on Ubuntu Noble Numbat.

By default (if no build args are specified), the image will be built for the
latest Fedora.
