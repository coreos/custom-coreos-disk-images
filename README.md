# build-custom-rhcos-disks

This repos contains files and instructions for building customized RHCOS
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

And the command to build the container would look like:


```
RHCOS_CONTAINER='quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:....'
podman build \
    --from $RHCOS_CONTAINER \
    --file Containerfile    \
    --tag oci-archive:./my-custom-rhcos-415.ociarchive

```


Now the layered container OCI archive is in the `my-custom-rhcos.ociarchive` file in the current working directory.


# Creating disk boot images from the container image


You can now take that ociarchive and create a disk image for a
platform (i.e. `qemu`, `metal` or `gcp`). First you need an
environment to run OSBuild in. Right now this needs to be a
fully up to date Fedora 39 machine with SELinux in permissive
mode and some software installed:

```
sudo dnf update -y
sudo setenforce 0
sudo sed -i -e 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
sudo dnf install --enablerepo=updates-testing -y osbuild osbuild-tools osbuild-ostree jq xfsprogs e2fsprogs
```

Now you should be able to generate an image with something like:
ociarchive=/path/to/my-custom-rhcos-415.ociarchive
platform=qemu
sudo ./build-custom-rhcos-disks.sh $ociarchive $platform
```

Which will create the file `my-custom-rhcos-415.ociarchive.x86_64.qcow2` in
the current working directory that can then be used.

NOTE: you can also pull an image from a registry into a local
ociarchive file with `skopeo copy docker://registry.com/org/repo:latest oci-archive:./my-custom-rhcos.ociarchive`.
