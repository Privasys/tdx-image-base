# Deploying to OVHcloud bare metal

Launch tdx-image-base as a TDX VM on OVHcloud dedicated servers with Intel Sapphire Rapids CPUs.

Tested on **Scale-i1** (Intel Xeon Gold 6426Y). Any OVHcloud server with a 4th Gen Xeon (Sapphire Rapids) or newer should work.

## Prerequisites

- An OVHcloud bare-metal server with a TDX-capable CPU
- Ubuntu 24.04 installed on the host
- The built image (`privasys-tdx-base_0.1.0.raw`) — see [Building from source](../README.md#building-from-source)

## 1. Prepare the host

On bare metal the operator controls both the **host** and the **guest**, so the TDX host stack must be set up before launching VMs.

Install the TDX host stack using [canonical/tdx](https://github.com/canonical/tdx):

```bash
git clone https://github.com/canonical/tdx.git
cd tdx
sudo ./setup-host.sh

# Reboot into the TDX-enabled kernel
sudo reboot
```

After reboot, verify TDX is active:

```bash
dmesg | grep -i tdx
# Expected: "TDX module initialized"

ls /dev/tdx_host
# Should exist
```

## 2. Install guest tooling

```bash
sudo apt install -y qemu-system-x86 libvirt-daemon-system virtinst swtpm
```

## 3. Launch the image as a TDX VM

### Option A: QEMU directly

```bash
cp privasys-tdx-base_0.1.0.raw /var/lib/libvirt/images/

qemu-system-x86_64 \
    -accel kvm \
    -cpu host \
    -machine q35,kernel-irqchip=split,confidential-guest-support=tdx0,memory-backend=ram1 \
    -object tdx-guest,id=tdx0 \
    -object memory-backend-memfd,id=ram1,size=4G,share=true \
    -m 4G \
    -smp 4 \
    -bios /usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive file=/var/lib/libvirt/images/privasys-tdx-base_0.1.0.raw,format=raw,if=virtio \
    -chardev socket,id=chrtpm,path=/tmp/vtpm/swtpm.sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-crb,tpmdev=tpm0 \
    -netdev bridge,id=net0,br=virbr0 \
    -device virtio-net-pci,netdev=net0 \
    -nographic
```

### Option B: libvirt (recommended for production)

```bash
virt-install \
    --name privasys-tdx \
    --ram 4096 --vcpus 4 \
    --cpu host \
    --machine q35 \
    --boot uefi \
    --disk /var/lib/libvirt/images/privasys-tdx-base_0.1.0.raw,format=raw \
    --network bridge=virbr0 \
    --tpm model=tpm-crb,type=emulator,version=2.0 \
    --launchSecurity type=tdx \
    --import --noautoconsole

virsh console privasys-tdx
```

## 4. Verify inside the VM

```bash
ls -l /dev/tdx_guest          # TDX device present
dmesg | grep -i tdx           # TDX guest messages
mount | grep verity            # dm-verity on root
touch /test 2>&1               # Read-only file system
tpm2_pcrread sha256:0,1,2,3,4,5,7,11
```

## Bare-metal notes

- **BIOS settings:** Ensure TDX, TME-MK (Total Memory Encryption Multi-Key), and SGX are enabled in the UEFI/BIOS. OVHcloud may require a support ticket to enable these on Scale-i1.
- **Kernel version:** The host needs kernel 6.7+ for TDX host support. The `canonical/tdx` setup script handles this.
- **Multiple VMs:** You can run many TDX VMs on a single host. Each gets its own isolated Trust Domain with independent measurements.
- **Attestation:** On bare metal, attestation goes through the [Intel PCS](https://api.portal.trustedservices.intel.com/) (Provisioning Certification Service) or your own PCCS. This differs from GCP, which wraps attestation in its Confidential Computing API.
- **Networking:** The examples use libvirt's default bridge (`virbr0`). For production, configure a dedicated bridge on the OVHcloud public/private network interface.
