include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "."
}

locals {
  env = get_env("TF_VAR_env")

  topology_by_env = {
    staging = {
      controlplane_nodes = {
        rbx = {
          region      = "RBX-A"
          flavor_name = "b3-8"
          private_ip  = "10.150.200.10"
        }
        gra = {
          region      = "GRA9"
          flavor_name = "b3-8"
          private_ip  = "10.150.200.11"
        }
        par = {
          region      = "EU-WEST-PAR"
          flavor_name = "b3-8"
          private_ip  = "10.150.200.12"
        }
      }
      worker_nodes = {
        rbx = {
          datacenter              = "rbx"
          plan_code               = "24sys022"
          storage_option          = "softraid-2x512nvme-24sys"
          ram_option              = "ram-32g-ecc-2133-24sys"
          bandwidth_option        = "vrack-bandwidth-1000-24sys"
          public_bandwidth_option = "bandwidth-1000-24sys"
          private_ip              = "10.150.200.20"
        }
        gra = {
          datacenter              = "gra"
          plan_code               = "24sys022"
          storage_option          = "softraid-2x512nvme-24sys"
          ram_option              = "ram-32g-ecc-2133-24sys"
          bandwidth_option        = "vrack-bandwidth-1000-24sys"
          public_bandwidth_option = "bandwidth-1000-24sys"
          private_ip              = "10.150.200.21"
        }
        sbg = {
          datacenter              = "sbg"
          plan_code               = "24sys022"
          storage_option          = "softraid-2x512nvme-24sys"
          ram_option              = "ram-32g-ecc-2133-24sys"
          bandwidth_option        = "vrack-bandwidth-1000-24sys"
          public_bandwidth_option = "bandwidth-1000-24sys"
          private_ip              = "10.150.200.22"
        }
      }
      private_network_cidr = "10.150.200.0/24"
      loadbalancer_zones   = ["gra"]
    }

    production = {
      controlplane_nodes = {
        rbx = {
          region      = "RBX-A"
          flavor_name = "b3-8"
          private_ip  = "10.150.100.10"
        }
        gra = {
          region      = "GRA9"
          flavor_name = "b3-8"
          private_ip  = "10.150.100.11"
        }
        par = {
          region      = "EU-WEST-PAR"
          flavor_name = "b3-8"
          private_ip  = "10.150.100.12"
        }
      }
      worker_nodes = {
        rbx = {
          datacenter              = "rbx"
          plan_code               = "24rise02-v1"
          storage_option          = "softraid-3x1920nvme-24rise02-v1"
          ram_option              = "ram-128g-ecc-2933-24rise02-v1"
          bandwidth_option        = "vrack-bandwidth-2000-upto-4000-24rise02-v1"
          public_bandwidth_option = "bandwidth-1000-rise-gen2"
          private_ip              = "10.150.100.20"
        }
        gra = {
          datacenter              = "gra"
          plan_code               = "24rise02-v1"
          storage_option          = "softraid-3x1920nvme-24rise02-v1"
          ram_option              = "ram-128g-ecc-2933-24rise02-v1"
          bandwidth_option        = "vrack-bandwidth-2000-upto-4000-24rise02-v1"
          public_bandwidth_option = "bandwidth-1000-rise-gen2"
          private_ip              = "10.150.100.21"
        }
        sbg = {
          datacenter              = "sbg"
          plan_code               = "24rise02-v1"
          storage_option          = "softraid-3x1920nvme-24rise02-v1"
          ram_option              = "ram-128g-ecc-2933-24rise02-v1"
          bandwidth_option        = "vrack-bandwidth-2000-upto-4000-24rise02-v1"
          public_bandwidth_option = "bandwidth-1000-rise-gen2"
          private_ip              = "10.150.100.22"
        }
      }
      private_network_cidr = "10.150.100.0/24"
      loadbalancer_zones   = ["gra", "rbx", "sbg"]
    }
  }

  topology = local.topology_by_env[local.env]

  # Import IDs for migration.tf; delete with it.
  legacy_by_env = {
    staging = {
      project_id = "7e6eb4b3f703423babb33eb445206e64"
      networks = {
        "GRA9"        = "12b75b00-b80a-4f37-9519-d1607c026aa5"
        "EU-WEST-PAR" = "f3dec140-d165-492e-ac10-ae414fb2a7f7"
        "RBX-A"       = "ee633b5c-42c5-43a7-b882-bc94e53f93c7"
      }
      subnets = {
        gra = "12b75b00-b80a-4f37-9519-d1607c026aa5/0cc16cbc-805b-4c35-a5bd-e31709dcfbc0"
        par = "f3dec140-d165-492e-ac10-ae414fb2a7f7/d6d507e9-c560-4dc4-b8ce-8cfd41350593"
        rbx = "ee633b5c-42c5-43a7-b882-bc94e53f93c7/4dc187a0-aa62-47c2-9488-673d8b811fa7"
      }
      instances = {
        gra = "62f607b3-bda4-4fa5-926f-7eceaa73dffa"
        par = "ac1a261a-66e8-455c-870c-710706454e7b"
        rbx = "0c080c1b-053b-45da-ae25-ebd76eac56af"
      }
    }
    production = {
      project_id = "d1186ed661184cbf8672a2091daeeb8a"
      networks = {
        "GRA9"        = "c9cebdfc-ac6c-4e58-8014-850b24ff124a"
        "EU-WEST-PAR" = "752181e0-37d0-46b7-9b99-126058c9dcf5"
        "RBX-A"       = "d65b3751-534f-41bc-8c58-a3e1906e9c0b"
      }
      subnets = {
        gra = "c9cebdfc-ac6c-4e58-8014-850b24ff124a/9b2d67b8-a457-4aec-8dd8-f82ed47ad341"
        par = "752181e0-37d0-46b7-9b99-126058c9dcf5/d02d7919-822e-425a-8d43-8cbae4afeeba"
        rbx = "d65b3751-534f-41bc-8c58-a3e1906e9c0b/276e5777-84fd-427c-b24e-bc532eacd06f"
      }
      instances = {
        gra = "b93ae45b-bd50-4b5d-96da-234cf67f5c27"
        par = "5e322f50-df25-46da-a46a-cd37ec1718d1"
        rbx = "4e66c3cc-aafb-44b3-9304-fca0ae50b5c8"
      }
    }
  }
}

dependency "rootly" {
  config_path = "../rootly"

  mock_outputs = {
    status_page_cname_records = {}
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

inputs = {
  controlplane_nodes   = local.topology.controlplane_nodes
  worker_nodes         = local.topology.worker_nodes
  private_network_cidr = local.topology.private_network_cidr
  loadbalancer_zones   = local.topology.loadbalancer_zones
  legacy               = local.legacy_by_env[local.env]
  # lookup: the attribute is missing entirely while the rootly module's state
  # predates the status page (mocks only cover a dependency with no outputs).
  status_page_cname_records = lookup(dependency.rootly.outputs, "status_page_cname_records", {})
}
