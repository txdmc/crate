# Pelico

Pelico is an inventory tracking application designed to run on a secure Kubernetes-based appliance. The appliance can be deployed on various hypervisors and cloud platforms, including VMware, Xen, VirtualBox, AWS, Azure, and GCP.

## Structure

- **charts/**: Kubernetes Helm charts for the Pelico application.
- **packer/**: Packer image templates for creating the appliance.
- **docs/**: Documentation for configuring and deploying the appliance.
- **application/**: Source code for the containerized inventory tracking application.

## Getting Started
1. Build the appliance image using Packer.
2. Deploy the appliance in your preferred environment.
3. Access the application at <http://pelico> to complete the configuration.