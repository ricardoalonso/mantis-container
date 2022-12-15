#!/bin/bash
podman push quay.io/ricardoalonsos/mantis:2.25.5
#podman push quay.io/ricardoalonsos/mantis:1.3.20
skopeo copy docker://quay.io/ricardoalonsos/mantis:2.25.5 docker://quay.io/ricardoalonsos/mantis:latest
