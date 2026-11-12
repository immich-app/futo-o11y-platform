# One-shot migration of the deprecated ovh_cloud_project_* resources to the
# ovh_cloud_* family (API v2): the imports hand the existing objects to the new
# resources, and the removed blocks forget the legacy addresses without
# destroying anything. The plan must show only imports and forgotten objects.
# While this file exists, a new environment cannot be created: an import of an
# object that does not exist fails the plan. Once both environments are
# migrated, delete this file, var.legacy in variables.tf, and both
# legacy_by_env and the `legacy` input in terragrunt.hcl.
import {
  for_each = var.legacy.networks
  to       = ovh_cloud_network_private_vrack.cluster[each.key]
  id       = "${var.legacy.project_id}/${each.value}"
}

import {
  for_each = var.legacy.subnets
  to       = ovh_cloud_network_private_vrack_subnet.cluster[each.key]
  id       = "${var.legacy.project_id}/${each.value}"
}

import {
  for_each = var.legacy.instances
  to       = ovh_cloud_instance.controlplane[each.key]
  id       = "${var.legacy.project_id}/${each.value}"
}

removed {
  from = ovh_cloud_project_instance.controlplane

  lifecycle {
    destroy = false
  }
}

removed {
  from = ovh_cloud_project_network_private_subnet_v2.cluster

  lifecycle {
    destroy = false
  }
}

removed {
  from = ovh_cloud_project_network_private.cluster

  lifecycle {
    destroy = false
  }
}
