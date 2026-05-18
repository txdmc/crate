#!/usr/bin/env bash
# create-ova.sh — Convert a QCOW2 image to an OVA (VirtualBox / VMware).
#
# Usage:
#   bash create-ova.sh <input.qcow2> <output.ova> [version]
#
# Requires: qemu-img, sha256sum (GNU coreutils)
set -euo pipefail

INPUT_QCOW2="${1:?Usage: $0 <input.qcow2> <output.ova> [version]}"
OUTPUT_OVA="${2:?Usage: $0 <input.qcow2> <output.ova> [version]}"
VERSION="${3:-unknown}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

NAME="pelico"
VMDK="${WORK_DIR}/${NAME}.vmdk"
OVF="${WORK_DIR}/${NAME}.ovf"
MF="${WORK_DIR}/${NAME}.mf"

echo "==> Converting QCOW2 → VMDK (streamOptimized)…"
qemu-img convert -p -O vmdk -o subformat=streamOptimized \
  "$INPUT_QCOW2" "$VMDK"

DISK_BYTES=$(qemu-img info --output json "$INPUT_QCOW2" | python3 -c "import sys,json; print(json.load(sys.stdin)['virtual-size'])")
VMDK_BYTES=$(stat -c %s "$VMDK")

echo "==> Generating OVF descriptor…"
cat > "$OVF" << XML
<?xml version="1.0" encoding="UTF-8"?>
<Envelope
    xmlns="http://schemas.dmtf.org/ovf/envelope/1"
    xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
    xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
    xmlns:vmw="http://www.vmware.com/schema/ovf"
    xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

  <References>
    <File ovf:id="file1" ovf:href="${NAME}.vmdk" ovf:size="${VMDK_BYTES}"/>
  </References>

  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:diskId="disk1"
          ovf:fileRef="file1"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"
          ovf:capacity="${DISK_BYTES}"
          ovf:capacityAllocationUnits="byte"/>
  </DiskSection>

  <NetworkSection>
    <Info>Logical networks used in the package</Info>
    <Network ovf:name="NAT">
      <Description>The NAT network used by this Pelico appliance</Description>
    </Network>
  </NetworkSection>

  <VirtualSystem ovf:id="${NAME}">
    <Info>Pelico Inventory Appliance ${VERSION}</Info>
    <Name>${NAME}</Name>

    <OperatingSystemSection ovf:id="101" vmw:osType="ubuntu64Guest">
      <Info>The operating system installed</Info>
      <Description>Ubuntu Linux 64-bit (24.04 LTS)</Description>
    </OperatingSystemSection>

    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>${NAME}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-19</vssd:VirtualSystemType>
      </System>

      <!-- 2 vCPUs -->
      <Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:Description>Number of virtual CPUs</rasd:Description>
        <rasd:ElementName>2 virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>2</rasd:VirtualQuantity>
      </Item>

      <!-- 2 GB RAM -->
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory size</rasd:Description>
        <rasd:ElementName>2048 MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>2048</rasd:VirtualQuantity>
      </Item>

      <!-- SCSI controller -->
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>SCSI Controller</rasd:Description>
        <rasd:ElementName>SCSI Controller 0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>lsilogic</rasd:ResourceSubType>
        <rasd:ResourceType>6</rasd:ResourceType>
      </Item>

      <!-- Disk -->
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>Hard Disk 1</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/disk1</rasd:HostResource>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>

      <!-- Network adapter -->
      <Item>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>NAT</rasd:Connection>
        <rasd:Description>VM Network adapter</rasd:Description>
        <rasd:ElementName>Ethernet adapter on NAT</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceSubType>VMXNET3</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
XML

echo "==> Generating manifest (.mf) with SHA256 checksums…"
OVF_SHA=$(sha256sum "$OVF" | awk '{print $1}')
VMDK_SHA=$(sha256sum "$VMDK" | awk '{print $1}')
cat > "$MF" << MF
SHA256(${NAME}.ovf)= ${OVF_SHA}
SHA256(${NAME}.vmdk)= ${VMDK_SHA}
MF

echo "==> Assembling OVA (TAR: ovf first, then mf, then vmdk)…"
# OVA spec requires OVF header first, then manifest, then disk image
tar --format=ustar -cf "$OUTPUT_OVA" \
    -C "$WORK_DIR" \
    "${NAME}.ovf" "${NAME}.mf" "${NAME}.vmdk"

echo "==> OVA written to ${OUTPUT_OVA} ($(du -sh "$OUTPUT_OVA" | cut -f1))"
