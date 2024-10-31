#!/usr/bin/bash
set -x -euo pipefail

# Run this script on a fully up to date Fedora 41 VM with SELinux
# in permissive mode and the following tools installed:
# sudo dnf install -y osbuild osbuild-tools osbuild-ostree podman jq xfsprogs e2fsprogs
#
# Invocation of the script would look something like this:
#
# sudo ./custom-coreos-disk-images.sh \
#   /path/to/coreos.ociarchive qemu
#
# And it will create the output file in the current directory:
#   coreos.ociarchive.x86_64.qemu.qcow2

ARCH=$(arch)
OCIARCHIVE=$1
PLATFORM=$2

check_rpm() {
    req=$1
    if ! rpm -q "$req" &>/dev/null; then
        echo "No $req. Can't continue" 1>&2
        return 1
    fi
}

check_rpms() {
    reqs=(osbuild osbuild-tools osbuild-ostree jq xfsprogs e2fsprogs)
    for req in "${reqs[@]}"; do
        check_rpm "$req"
    done
}

main() {

    # Make sure RPMs are installed
    check_rpms
    # Make sure SELinux is permissive
    if [ "$(getenforce)" != "Permissive" ]; then
        echo "SELinux needs to be set to permissive mode"
        exit 1
    fi
    # Make sure we are effectively `root`
    if [ $UID -ne 0 ]; then
        echo "OSBuild needs to run with root permissions"
        exit 1
    fi
    # Make sure the given file exists
    if [ ! -f $OCIARCHIVE ]; then
        echo "need to pass in the path to .ociarchive file"
        exit 1
    fi
    # Convert it to an absolute path
    OCIARCHIVE=$(readlink -f $OCIARCHIVE)

    # Make a local tmpdir
    mkdir -p tmp; rm -f tmp/*

    # Freeze on specific version for now to increase stability.
    #gitreporef="main"
    gitreporef="3a76784b37fe073718a7f9d9d67441d9d8b34c10"
    gitrepotld="https://raw.githubusercontent.com/coreos/coreos-assembler/${gitreporef}/"
    pushd ./tmp
    curl -LO --fail "${gitrepotld}/src/runvm-osbuild"
    chmod +x runvm-osbuild
    for manifest in "coreos.osbuild.${ARCH}.mpp.yaml" platform.{applehv,gcp,hyperv,metal,qemu}.ipp.yaml; do
        curl -LO --fail "${gitrepotld}/src/osbuild-manifests/${manifest}"
    done
    popd

    platforms=($PLATFORM)

    # It's mostly cosmetic, but let's set a sane looking container-imgref
    imgref="ostree-image-signed:oci-archive:/$(basename "${OCIARCHIVE}")"

    for platform in "${platforms[@]}"; do

        suffix=
        case $platform in 
            metal)
                suffix=raw
                ;;
            gcp)
                suffix=tar.gz
                ;;
            qemu)
                suffix=qcow2
                ;;
            *)
                echo "unknown platform provided"
                exit 1
                ;;
        esac
        outfile="./$(basename $OCIARCHIVE).${ARCH}.${platform}.${suffix}"

        # - rootfs size is only used on s390x secex so we pass "" here
        # - extra-kargs from image.yaml/image.json is currently empty
        #   on RHCOS but we may want to start picking it up from inside
        #   the container image (/usr/share/coreos-assembler/image.json)
        #   in the future. https://github.com/openshift/os/blob/master/image.yaml
        cat > tmp/diskvars.json << EOF
{
	"osname": "rhcos",
	"deploy-via-container": "true",
	"ostree-container": "${OCIARCHIVE}",
	"image-type": "${platform}",
	"container-imgref": "${imgref}",
	"metal-image-size": "3072",
	"cloud-image-size": "16384",
	"rootfs-size": "0",
	"extra-kargs-string": ""
}
EOF
        ./tmp/runvm-osbuild            \
            --config tmp/diskvars.json \
            --filepath "./${outfile}"  \
            --mpp "tmp/coreos.osbuild.${ARCH}.mpp.yaml"
        echo "Created $platform image file at: ${outfile}"
    done

    rm -f tmp/*; rmdir tmp # Cleanup
}

main "$@"
