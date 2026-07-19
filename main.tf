provider "oci" {}

resource "oci_core_instance" "generated_oci_core_instance" {
	agent_config {
		is_management_disabled = "false"
		is_monitoring_disabled = "false"
		plugins_config {
			desired_state = "DISABLED"
			name = "Vulnerability Scanning"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "OS Management Hub Agent"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Management Agent"
		}
		plugins_config {
			desired_state = "ENABLED"
			name = "Custom Logs Monitoring"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Compute RDMA GPU Monitoring"
		}
		plugins_config {
			desired_state = "ENABLED"
			name = "Compute Instance Monitoring"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Compute HPC RDMA Auto-Configuration"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Compute HPC RDMA Authentication"
		}
		plugins_config {
			desired_state = "ENABLED"
			name = "Cloud Guard Workload Protection"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Block Volume Management"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Bastion"
		}
	}
	availability_config {
		recovery_action = "RESTORE_INSTANCE"
	}
	availability_domain = "qUCo:AP-MUMBAI-1-AD-1"
	compartment_id = "ocid1.tenancy.oc1..aaaaaaaagizwbzjni26sugggo4khoud7j3xayofgefphqi2ls22cduc4weea"
	create_vnic_details {
		assign_ipv6ip = "false"
		assign_private_dns_record = "true"
		assign_public_ip = "false"
		display_name = "market-genie"
		subnet_id = "${oci_core_subnet.generated_oci_core_subnet.id}"
	}
	display_name = "instance-20260614-2012"
	instance_options {
		are_legacy_imds_endpoints_disabled = "true"
	}
	is_pv_encryption_in_transit_enabled = "true"
	metadata = {
		"ssh_authorized_keys" = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDZIchr0C3CJwK6sFvksfit13Q4cGG8SxrC00KONSl1HjT89Rl3q3jC8aH+nWNsfchBb5xbR0Vyd+0P2UGp/sOGA2aVP9CTmD657nI1oNxfbx6h7/+v2N2YRaLAXstv2QrBAozi9luFcJkwWTNnkTplDHEWoF4TSZJkVfT5M+i7Al+NG8FnJVgfYwpoS1y3AiXfLTBY6A3080BNvQaz47+THECDbbH5heLms0Q5g8O9BkENSZ43/ydPIPM4kqWmerxDpMdXOd24g3Wm/N2S/Vxdv7CI3ea9GrsfdO7yQ2pfcDWVkTuW9SvXueo1jJrW5SlW/drSjrLQqU8xNyJux7JB ssh-key-2026-06-14"
	}
	shape = "VM.Standard.A1.Flex"
	shape_config {
		memory_in_gbs = "12"
		ocpus = "2"
	}
	source_details {
		source_id = "ocid1.image.oc1.ap-mumbai-1.aaaaaaaalh3kwqptzhc64v73fv2zh5uw65ih54tnmfjaq2mlu3mo4me2dd5a"
		source_type = "image"
	}
}

resource "oci_core_vcn" "generated_oci_core_vcn" {
	cidr_block = "10.0.0.0/16"
	compartment_id = "ocid1.tenancy.oc1..aaaaaaaagizwbzjni26sugggo4khoud7j3xayofgefphqi2ls22cduc4weea"
	display_name = "vcn-20260614-2022"
	dns_label = "vcn06142032"
}

resource "oci_core_subnet" "generated_oci_core_subnet" {
	cidr_block = "10.0.0.0/24"
	compartment_id = "ocid1.tenancy.oc1..aaaaaaaagizwbzjni26sugggo4khoud7j3xayofgefphqi2ls22cduc4weea"
	display_name = "subnet-20260614-2022"
	dns_label = "subnet06142032"
	route_table_id = "${oci_core_vcn.generated_oci_core_vcn.default_route_table_id}"
	vcn_id = "${oci_core_vcn.generated_oci_core_vcn.id}"
}

resource "oci_core_internet_gateway" "generated_oci_core_internet_gateway" {
	compartment_id = "ocid1.tenancy.oc1..aaaaaaaagizwbzjni26sugggo4khoud7j3xayofgefphqi2ls22cduc4weea"
	display_name = "Internet Gateway vcn-20260614-2022"
	enabled = "true"
	vcn_id = "${oci_core_vcn.generated_oci_core_vcn.id}"
}

resource "oci_core_default_route_table" "generated_oci_core_default_route_table" {
	route_rules {
		destination = "0.0.0.0/0"
		destination_type = "CIDR_BLOCK"
		network_entity_id = "${oci_core_internet_gateway.generated_oci_core_internet_gateway.id}"
	}
	manage_default_resource_id = "${oci_core_vcn.generated_oci_core_vcn.default_route_table_id}"
}
