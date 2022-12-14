#!/bin/bash
podman build -t quay.io/ricardoalonsos/mantis:2.25.5 -f Containerfile.php80 .
podman build -t quay.io/ricardoalonsos/mantis:1.3.20 . 
