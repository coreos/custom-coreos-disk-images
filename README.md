# custom-coreos-disk-images

This repo contains files and instructions for building customized RHCOS
(Red Hat CoreOS) disk images that are used for installation and
bootstrapping of OpenShift Clusters.

# Creating a custom RHCOS container Image

Some background context and some examples for creating layered RHCOS
container imags can be found in the
[OpenShift Documentation](https://docs.openshift.com/container-platform/4.14/post_installation_configuration/coreos-layering.html).
Some of that is reproduced here to provide a full example.

For this to work you will need a registry pull secret. If you have a
cluster up and running already then you most likely have that set up.
If not, then you should be log in and grab your pull secret from
[console.redhat.com](https://console.redhat.com/openshift/install/pull-secret).

In order to figure out what container image to base your layered
container on you can get that from your cluster like:

```
oc adm release info --image-for rhel-coreos
```

or from quay using a pull secret like:

```
oc adm release info --registry-config /path/to/pull-secret --image-for=rhel-coreos quay.io/openshift-release-dev/ocp-release:4.15.1-x86_64
```

where you can replace `4.15.1` with the version of OpenShift you are currently targeting.

Now you can do a container build. Here is an example `Containerfile`
that layers a single package from EPEL:

```
FROM scratch
#Enable EPEL (more info at https://docs.fedoraproject.org/en-US/epel/ ) and install htop
RUN rpm-ostree install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    rpm-ostree install podman-tui && \
    ostree container commit
```

Note that in RHCOS 4.16 and newer, you can also use `dnf install` instead of `rpm-ostree install`.

And the command to build the container would look like:


```
RHCOS_CONTAINER='quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:....'
PULL_SECRET=/path/to/pull-secret
podman build \
    --from $RHCOS_CONTAINER \
    --authfile $PULL_SECRET \
    --file Containerfile    \
    --tag quay.io/myorg/myrepo:mytag
```

# Creating disk boot images from the container image

First, we need to convert the image to an OCI archive:

```
# to pull from local storage
skopeo copy containers-storage:quay.io/myorg/myrepo:mytag oci-archive:my-custom-rhcos.ociarchive
# OR to pull from a registry
skopeo copy --authfile /path/to/pull-secret docker://registry.com/org/repo:latest oci-archive:./my-custom-rhcos.ociarchive
```

You can now take that ociarchive and create a disk image for a
platform (i.e. `qemu`, `metal` or `gcp`). First you need an
environment to run OSBuild in. Right now this needs to be a
fully up to date Fedora 41 machine with SELinux in permissive
mode and some software installed:

```
sudo dnf update -y
sudo setenforce 0
sudo sed -i -e 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
sudo dnf install -y osbuild osbuild-tools osbuild-ostree podman jq xfsprogs e2fsprogs zip
```

Now you should be able to generate an image with something like:

```
ociarchive=/path/to/my-custom-rhcos.ociarchive
platform=qemu
sudo ./custom-coreos-disk-images.sh --ociarchive $ociarchive --platforms $platform
```

Which will create the file `my-custom-rhcos.ociarchive.x86_64.qcow2` in
the current working directory that can then be used.

# Using the container image in the cluster

You will also want to [push](https://docs.podman.io/en/latest/markdown/podman-push.1.html)
the custom container image to a registry and point OpenShift at it using a
MachineConfig with the `osImageURL` field set to the image. Otherwise, upon
booting, the node will immediately be switched to the default OS image for
the target OpenShift version.

Create a MachineConfig like the following:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker 
  name: custom-image
spec:
  osImageURL: example.com/my/custom-image@sha256... 
```

If scaling up, you can specify this MachineConfig as usual using `oc apply -f`.

If installing a cluster, you can specify the MachineConfig at that point so
that it's part of the initial bootstrapping. For examples of this, see the
documentation at:

https://docs.openshift.com/container-platform/4.17/installing/installing_bare_metal/installing-bare-metal.html#installation-user-infra-generate-k8s-manifest-ignition_installing-bare-metal
