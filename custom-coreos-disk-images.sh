#!/usr/bin/bash
set -euo pipefail

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
# - coreos-qemu.x86_64.qcow2
# - coreos-metal.x86_64.raw

ARCH=$(arch)

# A list of supported platforms and the filename suffix of the main
# artifact that platform produces.
declare -A SUPPORTED_PLATFORMS=(
    ['applehv']='raw.gz'
    ['gcp']='tar.gz'
    ['hyperv']='vhdx.zip'
    ['metal4k']='raw'
    ['metal']='raw'
    ['qemu']='qcow2'
)

check_rpm() {
    req=$1
    if ! rpm -q "$req" &>/dev/null; then
        echo "No $req. Can't continue" 1>&2
        return 1
    fi
}

check_rpms() {
    reqs=(osbuild osbuild-tools osbuild-ostree jq xfsprogs e2fsprogs zip)
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

    # Make a local tmpdir and outidr
    tmpdir=$(mktemp -d ./tmp-osbuild-XXX)
    outdir="${tmpdir}/out"
    mkdir $outdir

    # Freeze on specific version for now to increase stability.
    #gitreporef="main"
    gitreporef="10e397bfd966a60e5e43ec3ad49443c0c9323d74"
    gitrepotld="https://raw.githubusercontent.com/coreos/coreos-assembler/${gitreporef}/"
    pushd "${tmpdir}"
    curl -LO --fail "${gitrepotld}/src/runvm-osbuild"
    chmod +x runvm-osbuild
    for manifest in "coreos.osbuild.${ARCH}.mpp.yaml" platform.{applehv,gcp,hyperv,metal,qemu,qemu-secex}.ipp.yaml; do
        curl -LO --fail "${gitrepotld}/src/osbuild-manifests/${manifest}"
    done
    popd


    # - rootfs size is only used on s390x secex so we pass "0" here
    # - extra-kargs from image.yaml/image.json is currently empty
    #   on RHCOS but we may want to start picking it up from inside
    #   the container image (/usr/share/coreos-assembler/image.json)
    #   in the future. https://github.com/openshift/os/blob/master/image.yaml
    runvm_osbuild_config_json="${tmpdir}/runvm-osbuild-config.json"
    cat > "${runvm_osbuild_config_json}" << EOF
{
    "artifact-name-prefix": "$(basename -s .ociarchive $OCIARCHIVE)",
	"osname": "${osname}",
	"deploy-via-container": "true",
	"ostree-container": "${OCIARCHIVE}",
	"container-imgref": "${imgref}",
	"metal-image-size": "3072",
	"cloud-image-size": "${image_size}",
	"rootfs-size": "0",
	"extra-kargs-string": ""
}
EOF
    "${tmpdir}/runvm-osbuild"                             \
        --config "${runvm_osbuild_config_json}"           \
        --mpp "${tmpdir}/coreos.osbuild.${ARCH}.mpp.yaml" \
        --outdir "${outdir}"                              \
        --platforms "$(IFS=,; echo "${PLATFORMS[*]}")"

    for platform in "${PLATFORMS[@]}"; do
        # Set the filename of the artifact and the local image path
        # where from the OSBuild out directory where it resides.
        suffix="${SUPPORTED_PLATFORMS[$platform]}"
        imgname=$(basename -s .ociarchive $OCIARCHIVE)-${platform}.${ARCH}.${suffix}
        imgpath="${outdir}/${platform}/${imgname}"
        mv "${imgpath}" ./
        echo "Created $platform image file at: ${imgname}"
    done

    rm -rf "${outdir}"; rm -f "${tmpdir}"/*; rmdir "${tmpdir}" # Cleanup
}

main "$@"
