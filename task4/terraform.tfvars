# terraform.tfvars
# Конкретные значения для окружения production.
# Этот файл НЕ коммитится в Git — добавьте его в .gitignore.
# Вместо него коммитится terraform.tfvars.example с заглушками.
#
# Чувствительные значения (ssh_public_key) лучше передавать
# через переменные окружения: TF_VAR_ssh_public_key="..."

# ─── ОБЩЕЕ ────────────────────────────────────────────────────────────────────

project_id  = "future2"
region      = "ru-central1"
environment = "prod"

# ─── СЕТЬ ─────────────────────────────────────────────────────────────────────

vpc_cidr           = "10.0.0.0/16"
subnet_public_cidr = "10.0.1.0/24"
subnet_app_cidr    = "10.0.2.0/24"
subnet_data_cidr   = "10.0.3.0/24"
subnet_mgmt_cidr   = "10.0.4.0/24"

# ─── ОБРАЗ ВМ ─────────────────────────────────────────────────────────────────
# ID образа Ubuntu 22.04 LTS в Yandex Cloud (fd8...)
# Актуальный ID: yc compute image list --folder-id standard-images | grep ubuntu-22
vm_image_id = "fd8smb7fj0o91i68s15v"

# ─── API GATEWAY ──────────────────────────────────────────────────────────────

apigw_vm_count  = 2
apigw_vm_flavor = "standard-2-4" # 2 vCPU, 4 GB RAM

# ─── KAFKA ────────────────────────────────────────────────────────────────────

kafka_broker_count = 3
kafka_vm_flavor    = "standard-4-8" # 4 vCPU, 8 GB RAM
kafka_disk_size_gb = 30

# ─── ПРИЛОЖЕНИЯ ───────────────────────────────────────────────────────────────

app_vm_count  = 4
app_vm_flavor = "standard-2-4"

# ─── УПРАВЛЕНИЕ ───────────────────────────────────────────────────────────────

bastion_vm_flavor       = "standard-2-2"
monitoring_vm_flavor    = "standard-2-4"
monitoring_disk_size_gb = 50

# ─── POSTGRESQL ───────────────────────────────────────────────────────────────

pg_version      = "15"
pg_flavor       = "s2.micro" # Минимальный управляемый PostgreSQL в YC
pg_disk_size_gb = 50
pg_domains      = ["clinical", "fintech", "ai", "corporate"]

# ─── ОБЪЕКТНОЕ ХРАНИЛИЩЕ ──────────────────────────────────────────────────────
# Имена бакетов должны быть глобально уникальны в Yandex Cloud

lakehouse_bucket_name = "future2-prod-lakehouse"
phi_vault_bucket_name = "future2-prod-lakehouse"
tf_state_bucket_name  = "future2-prod-tf-state"

# ─── ДОСТУП ───────────────────────────────────────────────────────────────────
# Замените на реальный IP вашего офиса или VPN

allowed_ssh_cidr = "203.0.113.0/32" # Пример — замените на свой IP

# Публичный SSH-ключ. Лучше передавать через переменную окружения:
#   export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_rsa.pub)"
ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAA... engineer@company"
