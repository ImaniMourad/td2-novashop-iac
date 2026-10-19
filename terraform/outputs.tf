output "vm_name" {
  value = openstack_compute_instance_v2.k3s.name
}

output "floating_ip" {
  value = openstack_networking_floatingip_v2.k3s_fip.address
}

output "private_ip" {
  value = openstack_compute_instance_v2.k3s.network[0].fixed_ip_v4
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/asl-key ubuntu@${openstack_networking_floatingip_v2.k3s_fip.address}"
}

output "ansible_inventory" {
  description = "Inventaire Ansible genere depuis l'IP flottante."

  value = <<-EOT
[k3s]
${openstack_compute_instance_v2.k3s.name} ansible_host=${openstack_networking_floatingip_v2.k3s_fip.address}

[k3s:vars]
ansible_user=ubuntu
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o PreferredAuthentications=password -o PubkeyAuthentication=no'
EOT
}
