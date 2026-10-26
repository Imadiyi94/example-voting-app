# Capstone 1 - The Voting App
# Kind Cluster Module
# Creates/manages a local multi-node Kind cluster (EKS emulation) via Terraform.

resource "null_resource" "kind_cluster" {
  count = var.create_cluster ? 1 : 0

  triggers = {
    config_hash  = filebase64sha256(var.config_path)
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "Checking if Kind cluster '${var.cluster_name}' exists..."
      if kind get clusters | grep -q "^${var.cluster_name}$"; then
        echo "Cluster '${var.cluster_name}' already exists. Deleting and recreating..."
        kind delete cluster --name ${var.cluster_name}
      fi
      echo "Creating Kind cluster '${var.cluster_name}'..."
      kind create cluster --config ${var.config_path} --name ${var.cluster_name} --wait 180s
      echo "Kind cluster '${var.cluster_name}' created."
    EOT
    interpreter = ["C:/Program Files/Git/bin/bash.exe", "-c"]
  }
}

# Wait for the cluster control plane to be fully settled
resource "time_sleep" "wait_for_cluster" {
  depends_on      = [null_resource.kind_cluster]
  create_duration = "20s"
}

# Export kubeconfig next to the Terraform root so it is easy to find on Windows
resource "null_resource" "generate_kubeconfig" {
  depends_on = [time_sleep.wait_for_cluster]
  count      = var.create_cluster ? 1 : 0

  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "Exporting kubeconfig for cluster '${var.cluster_name}'..."
      kind export kubeconfig --name ${var.cluster_name}
      kind get kubeconfig --name ${var.cluster_name} > "${var.kubeconfig_output}"
      echo "Kubeconfig written to ${var.kubeconfig_output}"
    EOT
    interpreter = ["C:/Program Files/Git/bin/bash.exe", "-c"]
  }
}
