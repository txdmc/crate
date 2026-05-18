################################################################################
# Crate Appliance - Packer Variable Definitions
################################################################################

# ── ISO / Base Image ──────────────────────────────────────────────────────────
variable "ubuntu_iso_url" {
  type        = string
  description = "URL to the Ubuntu 24.04 LTS Server ISO"
  default     = "https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso"
}

variable "ubuntu_iso_checksum" {
  type        = string
  description = "SHA256 checksum of the ISO. Verify at https://releases.ubuntu.com/24.04/"
  # Update this value after verifying against the official SHA256SUMS file
  default     = "sha256:d6dab0c3a657988501b4bd76f1297c053df710e06e0c3aece60dead24f270b4d"
}

# ── Appliance Identity ────────────────────────────────────────────────────────
variable "appliance_version" {
  type        = string
  description = "Crate appliance version tag baked into the image"
  default     = "1.0.0"
}

variable "hostname" {
  type        = string
  description = "Default hostname of the appliance"
  default     = "crate"
}

# ── VM Sizing ─────────────────────────────────────────────────────────────────
variable "disk_size" {
  type        = number
  description = "Disk size in MiB for on-prem images"
  default     = 40960 # 40 GiB
}

variable "memory" {
  type        = number
  description = "RAM in MiB"
  default     = 4096
}

variable "cpus" {
  type        = number
  description = "vCPUs"
  default     = 2
}

# ── SSH Access (used during provisioning only) ────────────────────────────────
variable "ssh_username" {
  type      = string
  default   = "crate"
  sensitive = false
}

variable "ssh_password" {
  type      = string
  default   = "CrateTemp1!" # Changed on first boot by firstrun service
  sensitive = true
}

# ── VMware ────────────────────────────────────────────────────────────────────
variable "vmware_remote_host" {
  type        = string
  description = "ESXi host for remote VMware builds (leave empty for local Workstation/Fusion)"
  default     = ""
}

variable "vmware_remote_username" {
  type      = string
  default   = ""
  sensitive = true
}

variable "vmware_remote_password" {
  type      = string
  default   = ""
  sensitive = true
}

# ── vSphere (vCenter) ─────────────────────────────────────────────────────────
variable "vsphere_vcenter_server" {
  type    = string
  default = ""
}

variable "vsphere_username" {
  type      = string
  default   = ""
  sensitive = true
}

variable "vsphere_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "vsphere_datacenter" {
  type    = string
  default = ""
}

variable "vsphere_cluster" {
  type    = string
  default = ""
}

variable "vsphere_datastore" {
  type    = string
  default = ""
}

variable "vsphere_network" {
  type    = string
  default = "VM Network"
}

variable "vsphere_folder" {
  type    = string
  default = "Crate"
}

# ── Hyper-V ───────────────────────────────────────────────────────────────────
variable "hyperv_switch_name" {
  type        = string
  description = "Name of the Hyper-V virtual switch to attach the NIC to"
  default     = "Default Switch"
}

# ── AWS ───────────────────────────────────────────────────────────────────────
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "aws_source_ami_filter_name" {
  type    = string
  default = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
}

variable "aws_ami_regions" {
  type        = list(string)
  description = "Additional regions to copy the AMI to after build"
  default     = []
}

# ── Azure ─────────────────────────────────────────────────────────────────────
variable "azure_subscription_id" {
  type      = string
  default   = ""
  sensitive = true
}

variable "azure_client_id" {
  type      = string
  default   = ""
  sensitive = true
}

variable "azure_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "azure_resource_group" {
  type    = string
  default = "crate-images"
}

variable "azure_location" {
  type    = string
  default = "East US"
}

# ── GCP ───────────────────────────────────────────────────────────────────────
variable "gcp_project_id" {
  type    = string
  default = ""
}

variable "gcp_zone" {
  type    = string
  default = "us-central1-a"
}

variable "gcp_machine_type" {
  type    = string
  default = "n2-standard-2"
}

# ── Application Image ─────────────────────────────────────────────────────────
variable "app_image" {
  type        = string
  description = "Full application container image reference (e.g. ghcr.io/txdmc/crate:v1.0.0)"
  default     = "ghcr.io/txdmc/crate:latest"
}

variable "app_version" {
  type        = string
  description = "Application version tag, written into values-appliance.yaml"
  default     = "latest"
}
