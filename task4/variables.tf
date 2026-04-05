# variables.tf
# Все входные параметры проекта собраны здесь.
# Значения задаются в terraform.tfvars — в этом файле только объявления и описания.

# ─── ОБЩЕЕ ────────────────────────────────────────────────────────────────────

variable "project_id" {
  description = "ID проекта в облаке (используется как префикс для имён ресурсов)"
  type        = string
}

variable "region" {
  description = "Регион развёртывания инфраструктуры"
  type        = string
  default     = "ru-central1"
}

variable "environment" {
  description = "Окружение: prod, staging, dev. Используется в тегах и именах."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "Допустимые значения: prod, staging, dev."
  }
}

# ─── СЕТЬ ─────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR-блок всей виртуальной сети"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_public_cidr" {
  description = "CIDR публичной подсети (балансировщик, NAT)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "subnet_app_cidr" {
  description = "CIDR приватной подсети приложений (API Gateway, Kafka, домены)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "subnet_data_cidr" {
  description = "CIDR приватной подсети данных (PostgreSQL, объектное хранилище)"
  type        = string
  default     = "10.0.3.0/24"
}

variable "subnet_mgmt_cidr" {
  description = "CIDR подсети управления (Bastion, мониторинг)"
  type        = string
  default     = "10.0.4.0/24"
}

# ─── ВИРТУАЛЬНЫЕ МАШИНЫ ───────────────────────────────────────────────────────

variable "vm_image_id" {
  description = "ID образа ВМ (Ubuntu 22.04 или аналог в выбранном облаке)"
  type        = string
}

variable "apigw_vm_count" {
  description = "Количество инстансов API Gateway (минимум 2 для отказоустойчивости)"
  type        = number
  default     = 2
}

variable "apigw_vm_flavor" {
  description = "Тип инстанса для API Gateway"
  type        = string
  default     = "standard-2-4" # 2 vCPU, 4 GB RAM
}

variable "kafka_broker_count" {
  description = "Количество брокеров Kafka (нечётное число, минимум 3)"
  type        = number
  default     = 1
}

variable "kafka_vm_flavor" {
  description = "Тип инстанса для брокеров Kafka"
  type        = string
  default     = "standard-4-8" # 4 vCPU, 8 GB RAM
}

variable "kafka_disk_size_gb" {
  description = "Размер диска каждого брокера Kafka в ГБ"
  type        = number
  default     = 20  # Минимум для старта: лимит SSD на новом аккаунте ограничен
}

variable "app_vm_count" {
  description = "Количество ВМ приложений доменов (Clinical, Fintech, AI, Corporate)"
  type        = number
  default     = 4
}

variable "app_vm_flavor" {
  description = "Тип инстанса для ВМ приложений"
  type        = string
  default     = "standard-2-4"
}

variable "bastion_vm_flavor" {
  description = "Тип инстанса Bastion-хоста (достаточно минимального)"
  type        = string
  default     = "standard-1-2" # 1 vCPU, 2 GB RAM
}

variable "monitoring_vm_flavor" {
  description = "Тип инстанса для сервера мониторинга (Prometheus + Grafana)"
  type        = string
  default     = "standard-2-4"
}

variable "monitoring_disk_size_gb" {
  description = "Размер диска для хранения метрик мониторинга в ГБ"
  type        = number
  default     = 50
}

# ─── БАЗЫ ДАННЫХ ──────────────────────────────────────────────────────────────

variable "pg_version" {
  description = "Версия PostgreSQL"
  type        = string
  default     = "15"
}

variable "pg_flavor" {
  description = "Тип инстанса управляемого PostgreSQL"
  type        = string
  default     = "db-standard-2-8" # 2 vCPU, 8 GB RAM
}

variable "pg_disk_size_gb" {
  description = "Размер диска каждого кластера PostgreSQL в ГБ"
  type        = number
  default     = 50
}

variable "pg_domains" {
  description = "Список доменов, для каждого из которых создаётся отдельный кластер PostgreSQL"
  type        = list(string)
  default     = ["clinical", "fintech", "ai", "corporate"]
}

# ─── ОБЪЕКТНОЕ ХРАНИЛИЩЕ ──────────────────────────────────────────────────────

variable "lakehouse_bucket_name" {
  description = "Имя бакета для Data Lakehouse (Iceberg-таблицы, dbt-артефакты)"
  type        = string
}

variable "phi_vault_bucket_name" {
  description = "Имя бакета для PHI Vault (медицинские снимки и данные пациентов)"
  type        = string
}

variable "tf_state_bucket_name" {
  description = "Имя бакета для хранения состояния Terraform"
  type        = string
}

variable "storage_access_key" {
  description = "Статический ключ доступа (key_id) для Yandex Object Storage"
  type        = string
  sensitive   = true
}

variable "storage_secret_key" {
  description = "Секретный ключ для Yandex Object Storage"
  type        = string
  sensitive   = true
}

# ─── ДОСТУП ───────────────────────────────────────────────────────────────────

variable "allowed_ssh_cidr" {
  description = "CIDR, с которого разрешён SSH к Bastion-хосту (IP вашего офиса или VPN)"
  type        = string
  # Намеренно нет default — инженер должен указать явно
}

variable "ssh_public_key" {
  description = "Публичный SSH-ключ для доступа к ВМ"
  type        = string
  sensitive   = true
}

variable "pg_default_password" {
  description = "Начальный пароль пользователей PostgreSQL. Менять после первого apply."
  type        = string
  sensitive   = true
  default     = "ChangeMe123!"
}
