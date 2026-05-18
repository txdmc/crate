# Packer Templates

This folder contains the Packer configuration for creating the Pelico appliance image. Packer automates the creation of the appliance for various hypervisors and platforms.

## Steps to Build the Appliance

### Prerequisites
- Install [Packer](https://www.packer.io/downloads).
- Download the required ISO (e.g., Ubuntu minimal image).
- Update the `template.json` with the correct ISO URL and checksum.

### Building the Appliance
Run the following command to build the image:

```bash
packer build template.json
```

This will create an image that includes Kubernetes pre-installed with the Pelico application dependencies.

## Customization
- The `http_directory` can be updated with additional files to host for bootstrap tasks.
- `provisioners` section in `template.json` can be modified to install additional dependencies.