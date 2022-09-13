resource "random_string" "name_suffix" {
  length  = 6
  upper   = false
  special = false
}
locals {
  release_channel    = var.release_channel == "" ? [] : [var.release_channel]
  min_master_version = var.release_channel == "" ? var.min_master_version : ""
  identity_namespace = var.identity_namespace == "" ? [] : [var.identity_namespace]
}
locals {
  authenticator_security_group = var.authenticator_security_group == "" ? [] : [var.authenticator_security_group]
}

resource "google_container_cluster" "cluster" {
  name                     = "${var.cluster_name}-${random_string.name_suffix.result}"
  location                 = var.gcp_location
  remove_default_node_pool = true
  initial_node_count       = 1
  network                  = var.vpc_network_name
  subnetwork               = var.vpc_subnetwork_name
  logging_service          = var.stackdriver_logging != "false" ? "logging.googleapis.com/kubernetes" : ""
  monitoring_service       = var.stackdriver_monitoring != "false" ? "monitoring.googleapis.com/kubernetes" : ""
  networking_mode          = "VPC_NATIVE"
  dynamic "release_channel" {
    for_each = toset(local.release_channel)

    content {
      channel = release_channel.value
    }
  }
  dynamic "authenticator_groups_config" {
    for_each = toset(local.authenticator_security_group)

    content {
      security_group = authenticator_groups_config.value
    }
  }

  maintenance_policy {
    daily_maintenance_window {
      start_time = var.daily_maintenance_window_start_time
    }
  }

  # A set of options for creating a private cluster.
  private_cluster_config {
    enable_private_endpoint = var.private_endpoint
    enable_private_nodes    = var.private_nodes

    master_ipv4_cidr_block = var.master_ipv4_cidr_block
  }

  # Enable the PodSecurityPolicy admission controller for the cluster.
  #  pod_security_policy_config {
  #    enabled = var.pod_security_policy_enabled
  #  }

  #  network_policy {
  #    # Whether network policy is enabled on the cluster. Defaults to false.
  #    # In GKE this also enables the ip masquerade agent
  #    # https://cloud.google.com/kubernetes-engine/docs/how-to/ip-masquerade-agent
  #    enabled  = "${var.disable_network_policy == "true" ? "false" : "true" }"
  #    provider = "${var.network_policy_provider}"
  #  }

  master_auth {
    # Whether client certificate authorization is enabled for this cluster.
    client_certificate_config {
      issue_client_certificate = false
    }
  }


  addons_config {
    http_load_balancing {
      disabled = var.http_load_balancing_disabled
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }
  ip_allocation_policy {
    cluster_secondary_range_name  = var.cluster_secondary_range_name
    services_secondary_range_name = var.services_secondary_range_name
  }

  dynamic "workload_identity_config" {
    for_each = toset(local.identity_namespace)

    content {
      workload_pool = workload_identity_config.value
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks_cidr_blocks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

}
resource "google_container_node_pool" "node_pool" {

  # The location (region or zone) in which the cluster resides
  location = google_container_cluster.cluster.location

  count = length(var.node_pools)

  # The name of the node pool. Instance groups created will have the cluster
  # name prefixed automatically.
  name = format("%s-pool", lookup(var.node_pools[count.index], "name", format("%03d", count.index + 1)))

  # The cluster to create the node pool for.
  cluster = google_container_cluster.cluster.name

  initial_node_count = lookup(var.node_pools[count.index], "initial_node_count", 1)

  # Configuration required by cluster autoscaler to adjust the size of the node pool to the current cluster usage.
  autoscaling {
    # Minimum number of nodes in the NodePool. Must be >=0 and <= max_node_count.
    min_node_count = lookup(var.node_pools[count.index], "autoscaling_min_node_count", 2)

    # Maximum number of nodes in the NodePool. Must be >= min_node_count.
    max_node_count = lookup(var.node_pools[count.index], "autoscaling_max_node_count", 3)
  }

  # Target a specific Kubernetes version.
  version = lookup(var.node_pools[count.index], "version", "")

  # Node management configuration, wherein auto-repair and auto-upgrade is configured.
  management {
    # Whether the nodes will be automatically repaired.
    auto_repair = lookup(var.node_pools[count.index], "auto_repair", true)

    # Whether the nodes will be automatically upgraded.
    auto_upgrade = lookup(var.node_pools[count.index], "version", "") == "" ? lookup(var.node_pools[count.index], "auto_upgrade", true) : false
  }

  # Parameters used in creating the cluster's nodes.
  node_config {
    # The name of a Google Compute Engine machine type. Defaults to
    # n1-standard-1.
    machine_type = lookup(
      var.node_pools[count.index],
      "node_config_machine_type",
      "n1-standard-1",
    )

    service_account = google_service_account.default.email

    # Size of the disk attached to each node, specified in GB. The smallest
    # allowed disk size is 10GB. Defaults to 100GB.
    disk_size_gb = lookup(
      var.node_pools[count.index],
      "node_config_disk_size_gb",
      100
    )

    # Type of the disk attached to each node (e.g. 'pd-standard' or 'pd-ssd').
    # If unspecified, the default disk type is 'pd-standard'
    disk_type = lookup(
      var.node_pools[count.index],
      "node_config_disk_type",
      "pd-standard",
    )

    # A boolean that represents whether or not the underlying node VMs are
    # preemptible. See the official documentation for more information.
    # Defaults to false.
    preemptible = lookup(
      var.node_pools[count.index],
      "node_config_preemptible",
      false,
    )

    # The set of Google API scopes to be made available on all of the node VMs
    # under the "default" service account. These can be either FQDNs, or scope
    # aliases. The cloud-platform access scope authorizes access to all Cloud
    # Platform services, and then limit the access by granting IAM roles
    # https://cloud.google.com/compute/docs/access/service-accounts#service_account_permissions
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # The metadata key/value pairs assigned to instances in the cluster.
    metadata = {
      # https://cloud.google.com/kubernetes-engine/docs/how-to/protecting-cluster-metadata
      disable-legacy-endpoints = "true"
    }
  }

  # Change how long update operations on the node pool are allowed to take
  # before being considered to have failed. The default is 10 mins.
  # https://www.terraform.io/docs/configuration/resources.html#operation-timeouts
  timeouts {
    update = "20m"
  }
}
data "google_client_config" "google_client" {}
