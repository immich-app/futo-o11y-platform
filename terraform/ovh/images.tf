# The control planes boot from this image. OVH's Glance imports nothing from a
# URL (its only import method copies between regions), so the provider
# downloads the factory image, decompresses it and uploads the 4.4 GiB raw
# image to each control-plane region from the machine that applies. The name
# carries the version and the schematic, and both force a new image: the new
# one uploads first, then the old one is deleted. A running control plane keeps
# its own disk, so the deletion does not affect it. The workers need no image:
# they are BYOI servers, and OVH pulls theirs from the factory at order time
# (workers.tf).
resource "openstack_images_image_v2" "controlplane" {
  for_each = toset([for node in var.controlplane_nodes : node.region])

  region           = each.key
  name             = "talos-${var.talos_version}-${substr(var.talos_schematic_id, 0, 8)}"
  image_source_url = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/openstack-amd64.raw.xz"
  decompress       = true
  # Under the working directory rather than the provider's default in $HOME.
  image_cache_path = "${path.root}/.terraform/image_cache"
  disk_format      = "raw"
  container_format = "bare"
  visibility       = "shared"

  properties = {
    hw_qemu_guest_agent = "yes"
    img_config_drive    = "mandatory"
  }

  # The provider's default of 30 minutes is shorter than one upload.
  timeouts {
    create = "2h"
  }

  lifecycle {
    create_before_destroy = true
  }
}
