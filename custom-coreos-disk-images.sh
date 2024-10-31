#!/usr/bin/bash
set -eux -o pipefail

# Run this script on a fully up to date Fedora 41 VM with SELinux
# in permissive mode and the following tools installed:
# sudo dnf install -y osbuild osbuild-tools osbuild-ostree podman jq xfsprogs e2fsprogs
#
# Invocation of the script would look something like this:
#
# sudo ./custom-coreos-disk-images.sh \
#   --ociarchive /path/to/coreos.ociarchive --platforms qemu
#
# And it will create the output file in the current directory:
# - coreos.ociarchive.x86_64.qemu.qcow2
#
# Passing multple platforms will yield multiple disk images:
#
# sudo ./custom-coreos-disk-images.sh \
#   --ociarchive /path/to/coreos.ociarchive --platforms qemu,metal
#
# - coreos.ociarchive.x86_64.qemu.qcow2
# - coreos.ociarchive.x86_64.metal.qcow2

ARCH=$(arch)

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

    # Call getopt to validate the provided input.
    options=$(getopt --options - --longoptions 'imgref:,ociarchive:,osname:,platforms:' -- "$@")
    if [ $? -ne 0 ]; then
        echo "Incorrect options provided"
        exit 1
    fi
    eval set -- "$options"
    while true; do
        case "$1" in
        --imgref)
            shift # The arg is next in position args
            IMGREF=$1
            ;;
        --ociarchive)
            shift; # The arg is next in position args
            OCIARCHIVE=$1
            ;;
        --osname)
            shift # The arg is next in position args
            OSNAME=$1
            if [ $OSNAME !~ rhcos|fedora-coreos ]; then
                echo "--osname must be rhcos or fedora-coreos" >&2
                exit 1
            fi
            ;;
        --platforms)
            shift # The arg is next in position args
            # Split the comma separated string of platforms into an array
            IFS=, read -ra PLATFORMS <<<"$1"
            ;;
        --)
            shift
            break
            ;;
        esac
        shift
    done

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

    # Let's set the imgref. If no --imgref was provided then for cosmetic
    # purposes let's set a sane looking one.
    imgref="${IMGREF:-ostree-image-signed:oci-archive:/$(basename "${OCIARCHIVE}")}"

    # Let's default to `rhcos` for the OS Name for backwards compat
    osname="${OSNAME:-rhcos}"

    # FCOS/RHCOS have different default disk image sizes
    # In the future should pull this from the container image
    # (/usr/share/coreos-assembler/image.json)
    image_size=10240 # FCOS
    if [ $osname == 'rhcos' ]; then
        image_size=16384 # RHCOS
    fi

    # Make a local tmpdir
    tmpdir=$(mktemp -d ./tmp-osbuild-XXX)

    # Freeze on specific version for now to increase stability.
    #gitreporef="main"
    gitreporef="3a76784b37fe073718a7f9d9d67441d9d8b34c10"
    gitrepotld="https://raw.githubusercontent.com/coreos/coreos-assembler/${gitreporef}/"
    pushd "${tmpdir}"
    curl -LO --fail "${gitrepotld}/src/runvm-osbuild"
    chmod +x runvm-osbuild
    for manifest in "coreos.osbuild.${ARCH}.mpp.yaml" platform.{applehv,gcp,hyperv,metal,qemu}.ipp.yaml; do
        curl -LO --fail "${gitrepotld}/src/osbuild-manifests/${manifest}"
    done
    popd


    for platform in "${PLATFORMS[@]}"; do

        suffix=
        case $platform in 
            applehv)
                suffix=raw
                ;;
            gcp)
                suffix=tar.gz
                ;;
            hyperv)
                suffix=vhdx
                ;;
            metal)
                suffix=raw
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

        # - rootfs size is only used on s390x secex so we pass "0" here
        # - extra-kargs from image.yaml/image.json is currently empty
        #   on RHCOS but we may want to start picking it up from inside
        #   the container image (/usr/share/coreos-assembler/image.json)
        #   in the future. https://github.com/openshift/os/blob/master/image.yaml
        cat > "${tmpdir}/diskvars.json" << EOF
{
	"osname": "${osname}",
	"deploy-via-container": "true",
	"ostree-container": "${OCIARCHIVE}",
	"image-type": "${platform}",
	"container-imgref": "${imgref}",
	"metal-image-size": "3072",
	"cloud-image-size": "${image_size}",
	"rootfs-size": "0",
	"extra-kargs-string": ""
}
EOF
        "${tmpdir}/runvm-osbuild"              \
            --config "${tmpdir}/diskvars.json" \
            --filepath "./${outfile}"          \
            --mpp "${tmpdir}/coreos.osbuild.${ARCH}.mpp.yaml"
        echo "Created $platform image file at: ${outfile}"
    done

    rm -f "${tmpdir}"/*; rmdir "${tmpdir}" # Cleanup
}

main "$@"
