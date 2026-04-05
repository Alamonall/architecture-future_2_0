# outputs.tf

output "vpc_id" {
  description = "ID виртуальной сети"
  value       = yandex_vpc_network.main.id
}

output "subnet_ids" {
  description = "ID всех подсетей"
  value = {
    public = yandex_vpc_subnet.public.id
    app    = yandex_vpc_subnet.app.id
    data   = yandex_vpc_subnet.data.id
    mgmt   = yandex_vpc_subnet.mgmt.id
  }
}

output "bastion_public_ip" {
  description = "Публичный IP Bastion-хоста для SSH-доступа"
  value       = yandex_compute_instance.bastion.network_interface[0].nat_ip_address
}

output "apigw_private_ips" {
  description = "Приватные IP ВМ API Gateway"
  value       = [for vm in yandex_compute_instance.apigw : vm.network_interface[0].ip_address]
}

output "kafka_private_ips" {
  description = "Приватные IP брокеров Kafka"
  value       = [for vm in yandex_compute_instance.kafka : vm.network_interface[0].ip_address]
}

output "app_vm_ips" {
  description = "Приватные IP ВМ приложений по доменам"
  value = {
    for i, domain in var.pg_domains :
    domain => yandex_compute_instance.app[i].network_interface[0].ip_address
  }
}

output "monitoring_private_ip" {
  description = "Приватный IP сервера мониторинга"
  value       = yandex_compute_instance.monitoring.network_interface[0].ip_address
}

output "pg_fqdns" {
  description = "FQDN кластеров PostgreSQL по доменам"
  value = {
    for domain in var.pg_domains :
    domain => yandex_mdb_postgresql_cluster.domain[domain].host[0].fqdn
  }
}

output "lakehouse_bucket" {
  description = "Имя бакета Data Lakehouse"
  value       = yandex_storage_bucket.lakehouse.bucket
}

output "phi_vault_bucket" {
  description = "Имя бакета PHI Vault (совмещён с lakehouse)"
  value       = yandex_storage_bucket.lakehouse.bucket
}

output "next_steps" {
  description = "Что сделать вручную после terraform apply"
  value = <<-EOT
    1. ALB (балансировщик): создать вручную в консоли Yandex Cloud,
       подключить к ВМ API Gateway: ${join(", ", [for vm in yandex_compute_instance.apigw : vm.network_interface[0].ip_address])}

    2. SSL-сертификат: выпустить и привязать к балансировщику.

    3. Сервисные аккаунты: создать и выдать права на бакеты хранилища.

    4. Kafka: установить на брокерах через Ansible или cloud-init.
       IP брокеров: ${join(", ", [for vm in yandex_compute_instance.kafka : vm.network_interface[0].ip_address])}
  EOT
}
