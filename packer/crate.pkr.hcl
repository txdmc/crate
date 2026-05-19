################################################################################
# Crate Appliance - Packer Build Template (HCL2)
#
# Supported platforms:
#   On-prem : VMware (Workstation/ESXi), vSphere, VirtualBox, Hyper-V, QEMU/Xen
#   Cloud   : AWS, Azure, GCP
#
# Usage:
#   # All on-prem targets (requires local hypervisor):
#   packer build -only='*.crate_vmware,*.crate_virtualbox,...' .
#
#   # Single target:
#   packer build -only='virtualbox-iso.crate_virtualbox' .
#
#   # Cloud targets (requires credentials):
#   packer build -only='amazon-ebs.crate_aws' -var-file=cloud.pkrvars.hcl .
################################################################################

packer {
  required_version = ">= 1.10.0"

  required_plugins {
    vmware = {
      source  = "github.com/hashicorp/vmware"
      version = "~> 1"
    }
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = "~> 1"
    }
    virtualbox = {
      source  = "github.com/hashicorp/virtualbox"
      version = "~> 1"
    }
    hyperv = {
      source  = "github.com/hashicorp/hyperv"
      version = "~> 1"
    }
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2"
    }
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1"
    }
  }
}

################################################################################
# Locals
################################################################################

locals {
  # Passed to every post-processor and manifest
  image_name    = "crate-${var.appliance_version}"
  build_date    = formatdate("YYYY-MM-DD", timestamp())
  output_prefix = "${path.root}/output"

  # Common metadata tags applied to cloud images
  common_tags = {
    Application = "crate"
    Version     = var.appliance_version
    BuildDate   = local.build_date
    ManagedBy   = "packer"
  }

  # Boot command used by all ISO-based (on-prem) builders.
  # Ubuntu 24.04 live-server ISO: edit grub entry to inject autoinstall kernel args.
  iso_boot_command = [
    "c<wait3>",
    "linux /casper/vmlinuz --- autoinstall 'ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/'<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait>"
  ]

  # Scripts run on every platform in order
  provision_scripts = [
    "${path.root}/scripts/01-base.sh",
    "${path.root}/scripts/02-k3s.sh",
    "${path.root}/scripts/03-app.sh",
    "${path.root}/scripts/04-network.sh",
    "${path.root}/scripts/05-firstrun.sh",
    "${path.root}/scripts/99-cleanup.sh",
  ]
}

################################################################################
# Sources — On-Prem
################################################################################

# ── VMware Workstation / Fusion / ESXi ───────────────────────────────────────
source "vmware-iso" "crate_vmware" {
  vm_name          = local.image_name
  iso_url          = var.ubuntu_iso_url
  iso_checksum     = var.ubuntu_iso_checksum
  output_directory = "${local.output_prefix}/vmware"

  # Hardware
  cpus       = var.cpus
  memory     = var.memory
  disk_size  = var.disk_size
  disk_type_id = 1 # thin provisioned

  guest_os_type = "ubuntu-64"

  # Networking
  network_adapter_type = "vmxnet3"
  network              = "nat"

  # USB / firmware
  usb                  = true

  # HTTP server for autoinstall seed
  http_directory = "${path.root}/http"
  http_port_min  = 8100
  http_port_max  = 8199

  boot_wait    = "5s"
  boot_command = local.iso_boot_command

  # SSH (used by Packer provisioners)
  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_timeout          = "45m"
  ssh_handshake_attempts = 50

  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"

  # VMX tuning for performance + compatibility
  vmx_data = {
    "virtualHW.version"         = "19"
    "cpuid.coresPerSocket"      = "2"
    "ethernet0.pciSlotNumber"   = "32"
    "scsi0.pcislotnumber"       = "16"
    "tools.syncTime"            = "FALSE"
    "tools.upgrade.policy"      = "manual"
    "RemoteDisplay.vnc.enabled" = "FALSE"
  }

  # Optional: push directly to ESXi
  remote_type          = var.vmware_remote_host != "" ? "esx5" : null
  remote_host          = var.vmware_remote_host != "" ? var.vmware_remote_host : null
  remote_username      = var.vmware_remote_host != "" ? var.vmware_remote_username : null
  remote_password      = var.vmware_remote_host != "" ? var.vmware_remote_password : null
  skip_export          = var.vmware_remote_host != "" ? true : false
}

# ── vSphere / vCenter ─────────────────────────────────────────────────────────
source "vsphere-iso" "crate_vsphere" {
  vcenter_server      = var.vsphere_vcenter_server
  username            = var.vsphere_username
  password            = var.vsphere_password
  insecure_connection = false
  datacenter          = var.vsphere_datacenter
  cluster             = var.vsphere_cluster
  datastore           = var.vsphere_datastore
  folder              = var.vsphere_folder

  vm_name   = local.image_name
  iso_paths = ["[${var.vsphere_datastore}] ISO/ubuntu-24.04.2-live-server-amd64.iso"]

  # Hardware
  CPUs     = var.cpus
  RAM      = var.memory
  firmware = "efi-secure" # Secure Boot

  storage {
    disk_size             = var.disk_size
    disk_thin_provisioned = true
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  guest_os_type = "ubuntu64Guest"
  convert_to_template = true

  # HTTP server for autoinstall seed
  http_directory = "${path.root}/http"
  http_port_min  = 8100
  http_port_max  = 8199

  boot_wait    = "5s"
  boot_command = local.iso_boot_command

  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_timeout          = "45m"
  ssh_handshake_attempts = 50
  shutdown_command     = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
}

# ── VirtualBox ────────────────────────────────────────────────────────────────
source "virtualbox-iso" "crate_virtualbox" {
  vm_name          = local.image_name
  iso_url          = var.ubuntu_iso_url
  iso_checksum     = var.ubuntu_iso_checksum
  output_directory = "${local.output_prefix}/virtualbox"
  format           = "ova" # Portable OVA

  # Hardware
  cpus      = var.cpus
  memory    = var.memory
  disk_size = var.disk_size

  guest_os_type        = "Ubuntu_64"
  hard_drive_interface = "sata"
  gfx_controller       = "vmsvga"
  gfx_vram_size        = 32

  # EFI firmware
  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--firmware", "efi"],
    ["modifyvm", "{{.Name}}", "--nat-localhostreachable1", "on"],
    ["modifyvm", "{{.Name}}", "--nictype1", "virtio"],
    ["modifyvm", "{{.Name}}", "--audio", "none"],
    ["modifyvm", "{{.Name}}", "--usb", "off"],
  ]

  # HTTP server for autoinstall seed
  http_directory = "${path.root}/http"
  http_port_min  = 8100
  http_port_max  = 8199

  boot_wait    = "5s"
  boot_command = local.iso_boot_command

  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_timeout          = "45m"
  ssh_handshake_attempts = 50
  shutdown_command     = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
}

# ── Hyper-V ───────────────────────────────────────────────────────────────────
source "hyperv-iso" "crate_hyperv" {
  vm_name          = local.image_name
  iso_url          = var.ubuntu_iso_url
  iso_checksum     = var.ubuntu_iso_checksum
  output_directory = "${local.output_prefix}/hyperv"

  # Hardware (Generation 2 = UEFI + Secure Boot)
  generation       = 2
  cpus             = var.cpus
  ram_size         = var.memory
  disk_size        = var.disk_size
  disk_block_size  = 1  # MiB, 1 MiB for dynamic VHDX

  switch_name      = var.hyperv_switch_name
  enable_secure_boot     = true
  secure_boot_template   = "MicrosoftUEFICertificateAuthority"
  enable_dynamic_memory  = false

  # HTTP server for autoinstall seed
  http_directory = "${path.root}/http"
  http_port_min  = 8100
  http_port_max  = 8199

  boot_wait    = "5s"
  boot_command = local.iso_boot_command

  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_timeout          = "45m"
  ssh_handshake_attempts = 50
  shutdown_command     = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
}

# ── QEMU / KVM → Xen / XCP-ng / CI ──────────────────────────────────────────
# Output: QCOW2. GitHub Actions runs with KVM (/dev/kvm available).
# CI converts to OVA and VHDX after this build via create-ova.sh + qemu-img.
source "qemu" "crate_qemu" {
  iso_url          = var.ubuntu_iso_url
  iso_checksum     = var.ubuntu_iso_checksum
  output_directory = "${local.output_prefix}/qemu"
  vm_name          = "${local.image_name}.qcow2"

  # Hardware
  cpus        = var.cpus
  memory      = var.memory
  disk_size   = "${var.disk_size}M"
  format      = "qcow2"
  accelerator = var.qemu_accelerator

  # VirtIO devices for better compatibility
  disk_interface = "virtio"
  net_device     = "virtio-net"

  # HTTP server for autoinstall seed
  http_directory = "${path.root}/http"
  http_port_min  = 8100
  http_port_max  = 8199

  headless     = true
  boot_wait    = "5s"
  boot_command = local.iso_boot_command

  qemuargs = [
    ["-m", "${var.memory}M"],
    ["-smp", "${var.cpus}"],
  ]

  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = "240m" # TCG emulation on macOS ARM can take 2-4h
  ssh_handshake_attempts = 100
  shutdown_command       = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
}

################################################################################
# Sources — Cloud
################################################################################

# ── AWS ───────────────────────────────────────────────────────────────────────
source "amazon-ebs" "crate_aws" {
  region        = var.aws_region
  instance_type = var.aws_instance_type
  ami_name      = "${local.image_name}-{{timestamp}}"
  ami_description = "Crate Inventory Appliance ${var.appliance_version}"

  # Find the latest Ubuntu 24.04 LTS AMI published by Canonical
  source_ami_filter {
    filters = {
      name                = var.aws_source_ami_filter_name
      root-device-type    = "ebs"
      virtualization-type = "hvm"
      architecture        = "x86_64"
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }

  # Block device (gp3 for cost/performance)
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 40
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # Copy to additional regions after build
  ami_regions = var.aws_ami_regions

  # Encrypt AMI copies
  ami_groups     = [] # private AMI by default
  encrypt_boot   = true

  # IMDSv2 required
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  # SSH access
  ssh_username                = "ubuntu"
  ssh_timeout                 = "15m"
  ssh_clear_authorized_keys   = true

  tags = local.common_tags
}

# ── Azure ─────────────────────────────────────────────────────────────────────
source "azure-arm" "crate_azure" {
  client_id       = var.azure_client_id
  client_secret   = var.azure_client_secret
  subscription_id = var.azure_subscription_id

  managed_image_name                = local.image_name
  managed_image_resource_group_name = var.azure_resource_group
  location                          = var.azure_location

  os_type         = "Linux"
  image_publisher = "Canonical"
  image_offer     = "ubuntu-24_04-lts"
  image_sku       = "server"
  image_version   = "latest"

  vm_size = "Standard_D2s_v3"

  os_disk_size_gb = 40

  # Shared Image Gallery (optional — comment out if not using SIG)
  # shared_image_gallery_destination {
  #   resource_group = var.azure_resource_group
  #   gallery_name   = "CrateGallery"
  #   image_name     = "crate"
  #   image_version  = var.appliance_version
  # }

  azure_tags = local.common_tags

  ssh_username               = "crate"
  ssh_timeout                = "15m"
  ssh_clear_authorized_keys  = true
}

# ── GCP ───────────────────────────────────────────────────────────────────────
source "googlecompute" "crate_gcp" {
  project_id   = var.gcp_project_id
  zone         = var.gcp_zone
  machine_type = var.gcp_machine_type
  image_name   = replace("${local.image_name}-{{timestamp}}", ".", "-")
  image_description = "Crate Inventory Appliance ${var.appliance_version}"
  image_family = "crate"

  source_image_family  = "ubuntu-2404-lts-amd64"
  source_image_project_id = ["ubuntu-os-cloud"]

  disk_size = 40
  disk_type = "pd-ssd"

  # Shielded VM security
  enable_secure_boot          = true
  enable_vtpm                 = true
  enable_integrity_monitoring = true

  image_labels = local.common_tags

  ssh_username              = "crate"
  ssh_timeout               = "15m"
  ssh_clear_authorized_keys = true
}

################################################################################
# Build
################################################################################

build {
  name = "crate-appliance"

  sources = [
    "source.vmware-iso.crate_vmware",
    "source.vsphere-iso.crate_vsphere",
    "source.virtualbox-iso.crate_virtualbox",
    "source.hyperv-iso.crate_hyperv",
    "source.qemu.crate_qemu",
    "source.amazon-ebs.crate_aws",
    "source.azure-arm.crate_azure",
    "source.googlecompute.crate_gcp",
  ]

  # ── Upload Helm chart and app artifacts ─────────────────────────────────────
  provisioner "file" {
    source      = "${path.root}/../charts"
    destination = "/tmp/crate-charts"
  }

  # ── Run provisioning scripts ─────────────────────────────────────────────────
  provisioner "shell" {
    environment_vars = [
      "CRATE_VERSION=${var.appliance_version}",
      "CRATE_HOSTNAME=${var.hostname}",
      "APP_IMAGE=${var.app_image}",
      "APP_VERSION=${var.app_version}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    execute_command  = "echo '${var.ssh_password}' | sudo -S env {{ .Vars }} bash '{{ .Path }}'"
    scripts          = local.provision_scripts
    # Give each script up to 20 minutes
    timeout          = "20m"
  }

  # ── On-prem post-processing: produce OVA from VMware build ──────────────────
  post-processor "shell-local" {
    only   = ["vmware-iso.crate_vmware"]
    inline = [
      "echo 'VMware build complete: ${local.output_prefix}/vmware'",
      "echo 'To convert to OVA, run: ovftool --compress=9 output/vmware/${local.image_name}.vmx output/crate-${var.appliance_version}.ova'",
    ]
  }

  # ── Manifest: record artifact details ────────────────────────────────────────
  post-processor "manifest" {
    output     = "${local.output_prefix}/manifest.json"
    strip_path = true
    custom_data = {
      version    = var.appliance_version
      build_date = local.build_date
    }
  }
}
