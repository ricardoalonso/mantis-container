#!/bin/bash
podman build --pull=newer -t quay.io/ricardoalonsos/mantis:2.25.5 .
#podman build --pull=newer -t quay.io/ricardoalonsos/mantis:1.3.20 -f Containerfile.1.3.35 . 
