# main.tf
# Основной файл инфраструктуры. Описывает все ресурсы в порядке зависимостей:
# провайдер → сеть → безопасность → ВМ → БД → хранилища.
#
# Конфигурация написана под провайдер Yandex Cloud как наиболее актуальный
# для российских компаний. Логика переносится на AWS/GCP заменой блоков ресурсов —
# структура файлов остаётся той же.

terraform {
  required_version = ">= 1.5"

  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.96"
    }
  }

  # Backend намеренно убран для локального тестирования.
  # State хранится в terraform.tfstate рядом с конфигурацией.
  # В production backend подключается отдельно:
  #   terraform init -backend-config="bucket=future2-prod-tf-state" ...
}

# ─────────────────────────────────────────────
# ПРОВАЙДЕР
# Terraform использует credentials из переменных окружения:
#   YC_TOKEN — OAuth-токен
#   YC_CLOUD_ID — ID облака
#   YC_FOLDER_ID — ID каталога
# Не передавайте токены через переменные Terraform — они попадут в state.
# ─────────────────────────────────────────────
provider "yandex" {
  zone               = "${var.region}-a"
  storage_access_key = var.storage_access_key
  storage_secret_key = var.storage_secret_key
}

# Локальные значения — вычисляемые константы.
# Использую locals, чтобы не повторять одни и те же выражения по всему коду.
locals {
  name_prefix = "${var.project_id}-${var.environment}"

  common_labels = {
    project     = var.project_id
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ═════════════════════════════════════════════
# СЕТЬ
# ═════════════════════════════════════════════

# Виртуальная сеть — контейнер для всех подсетей.
# Один VPC на весь проект: домены изолированы группами безопасности, а не отдельными VPC.
# Отдельные VPC усложняют маршрутизацию и оправданы только при жёстких требованиях
# к разделению (например, если банк должен быть полностью отделён на сетевом уровне).
resource "yandex_vpc_network" "main" {
  name   = "${local.name_prefix}-network"
  labels = local.common_labels
}

# Публичная подсеть: балансировщик нагрузки и NAT-шлюз.
# Только эти ресурсы смотрят в интернет — всё остальное в приватных подсетях.
resource "yandex_vpc_subnet" "public" {
  name           = "${local.name_prefix}-subnet-public"
  zone           = "${var.region}-a"
  network_id     = yandex_vpc_network.main.id
  v4_cidr_blocks = [var.subnet_public_cidr]
  labels         = local.common_labels
}

# Приватная подсеть приложений: API Gateway, Kafka, сервисы доменов.
# Нет прямого выхода в интернет — трафик идёт через NAT.
resource "yandex_vpc_subnet" "app" {
  name           = "${local.name_prefix}-subnet-app"
  zone           = "${var.region}-a"
  network_id     = yandex_vpc_network.main.id
  v4_cidr_blocks = [var.subnet_app_cidr]
  route_table_id = yandex_vpc_route_table.private.id
  labels         = local.common_labels
}

# Приватная подсеть данных: PostgreSQL и объектное хранилище.
# Отдельная от подсети приложений — это требование изоляции PHI и ЦБ.
# Группы безопасности дополнительно ограничивают доступ только из подсети приложений.
resource "yandex_vpc_subnet" "data" {
  name           = "${local.name_prefix}-subnet-data"
  zone           = "${var.region}-a"
  network_id     = yandex_vpc_network.main.id
  v4_cidr_blocks = [var.subnet_data_cidr]
  route_table_id = yandex_vpc_route_table.private.id
  labels         = local.common_labels
}

# Подсеть управления: Bastion и мониторинг.
# Bastion имеет публичный IP — единственная точка SSH-доступа.
resource "yandex_vpc_subnet" "mgmt" {
  name           = "${local.name_prefix}-subnet-mgmt"
  zone           = "${var.region}-a"
  network_id     = yandex_vpc_network.main.id
  v4_cidr_blocks = [var.subnet_mgmt_cidr]
  labels         = local.common_labels
}

# NAT-шлюз: позволяет ВМ в приватных подсетях делать исходящие запросы в интернет
# (скачать пакеты, обратиться к внешнему API), не имея публичного IP.
resource "yandex_vpc_gateway" "nat" {
  name = "${local.name_prefix}-nat-gateway"

  shared_egress_gateway {}
}

# Таблица маршрутов для приватных подсетей.
# Весь исходящий трафик (0.0.0.0/0) направляется через NAT-шлюз.
resource "yandex_vpc_route_table" "private" {
  name       = "${local.name_prefix}-route-private"
  network_id = yandex_vpc_network.main.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat.id
  }
}

# ═════════════════════════════════════════════
# ГРУППЫ БЕЗОПАСНОСТИ (FIREWALL)
# ═════════════════════════════════════════════

# Группа безопасности для Bastion-хоста.
# Разрешает SSH только с указанного IP (офис или VPN инженеров).
# Изнутри Bastion может подключаться к ВМ в подсетях приложений и управления.
resource "yandex_vpc_security_group" "bastion" {
  name       = "${local.name_prefix}-sg-bastion"
  network_id = yandex_vpc_network.main.id
  labels     = local.common_labels

  ingress {
    description    = "SSH только с доверенного IP"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    description    = "Исходящий трафик внутри сети"
    protocol       = "ANY"
    v4_cidr_blocks = [var.vpc_cidr]
  }
}

# Группа безопасности для ВМ приложений.
# Входящий трафик: только от балансировщика и из подсети управления (Bastion).
# Исходящий: к БД (подсеть данных) и к Kafka.
resource "yandex_vpc_security_group" "app" {
  name       = "${local.name_prefix}-sg-app"
  network_id = yandex_vpc_network.main.id
  labels     = local.common_labels

  ingress {
    description            = "HTTP/HTTPS от балансировщика"
    protocol               = "TCP"
    port                   = 8080
    security_group_id      = yandex_vpc_security_group.alb.id
  }

  ingress {
    description    = "SSH от Bastion"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = [var.subnet_mgmt_cidr]
  }

  egress {
    description    = "Доступ к БД"
    protocol       = "TCP"
    port           = 5432
    v4_cidr_blocks = [var.subnet_data_cidr]
  }

  egress {
    description    = "Доступ к Kafka"
    protocol       = "TCP"
    from_port      = 9092
    to_port        = 9093
    v4_cidr_blocks = [var.subnet_app_cidr]
  }

  egress {
    description    = "HTTPS наружу (через NAT): обновления, внешние API"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Группа безопасности для балансировщика.
# Принимает HTTPS снаружи, отправляет трафик в подсеть приложений.
resource "yandex_vpc_security_group" "alb" {
  name       = "${local.name_prefix}-sg-alb"
  network_id = yandex_vpc_network.main.id
  labels     = local.common_labels

  ingress {
    description    = "HTTPS от всех (публичный балансировщик)"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "HTTP (редирект на HTTPS)"
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # Обязательное правило: Yandex ALB шлёт health-check с этих диапазонов.
  # Yandex требует открыть весь диапазон портов (from_port/to_port),
  # иначе ALB отклоняет создание балансировщика с ошибкой InvalidArgument.
  ingress {
    description    = "Health check от Yandex ALB"
    protocol       = "TCP"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["198.18.235.0/24", "198.18.248.0/24"]
  }

  egress {
    description    = "К ВМ приложений"
    protocol       = "TCP"
    port           = 8080
    v4_cidr_blocks = [var.subnet_app_cidr]
  }
}

# Группа безопасности для PostgreSQL.
# Только приложения из подсети app могут подключаться к БД.
resource "yandex_vpc_security_group" "db" {
  name       = "${local.name_prefix}-sg-db"
  network_id = yandex_vpc_network.main.id
  labels     = local.common_labels

  ingress {
    description    = "PostgreSQL только из подсети приложений"
    protocol       = "TCP"
    port           = 5432
    v4_cidr_blocks = [var.subnet_app_cidr]
  }
}

# Группа безопасности для Kafka.
# Брокеры общаются между собой (репликация), приложения подключаются как клиенты.
resource "yandex_vpc_security_group" "kafka" {
  name       = "${local.name_prefix}-sg-kafka"
  network_id = yandex_vpc_network.main.id
  labels     = local.common_labels

  ingress {
    description    = "Kafka от приложений"
    protocol       = "TCP"
    port           = 9092
    v4_cidr_blocks = [var.subnet_app_cidr]
  }

  ingress {
    description    = "Kafka TLS от приложений"
    protocol       = "TCP"
    port           = 9093
    v4_cidr_blocks = [var.subnet_app_cidr]
  }

  ingress {
    description    = "Репликация между брокерами"
    protocol       = "TCP"
    port           = 9091
    v4_cidr_blocks = [var.subnet_app_cidr]
  }

  ingress {
    description    = "SSH от Bastion"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = [var.subnet_mgmt_cidr]
  }

  egress {
    description    = "Исходящий внутри сети"
    protocol       = "ANY"
    v4_cidr_blocks = [var.vpc_cidr]
  }
}

# ═════════════════════════════════════════════
# SSH-КЛЮЧ
# В Yandex Cloud нет отдельного ресурса для SSH-ключей.
# Публичный ключ передаётся в metadata каждой ВМ напрямую.
# ═════════════════════════════════════════════

# ═════════════════════════════════════════════
# БАЛАНСИРОВЩИК НАГРУЗКИ
# Application Load Balancer принимает HTTPS и распределяет запросы
# между инстансами API Gateway.
# ═════════════════════════════════════════════

# Целевая группа — список ВМ, между которыми балансирует трафик.
# Создаётся динамически из списка ВМ API Gateway.
resource "yandex_alb_target_group" "apigw" {
  name   = "${local.name_prefix}-tg-apigw"
  labels = local.common_labels

  dynamic "target" {
    for_each = yandex_compute_instance.apigw
    content {
      subnet_id  = yandex_vpc_subnet.app.id
      ip_address = target.value.network_interface[0].ip_address
    }
  }
}

# Группа бэкендов — привязывает целевую группу к балансировщику.
# health_check следит за тем, что ВМ отвечает на запросы.
resource "yandex_alb_backend_group" "apigw" {
  name   = "${local.name_prefix}-bg-apigw"
  labels = local.common_labels

  http_backend {
    name             = "apigw-backend"
    weight           = 1
    port             = 8080
    target_group_ids = [yandex_alb_target_group.apigw.id]

    healthcheck {
      timeout             = "10s"
      interval            = "15s"
      healthy_threshold   = 2
      unhealthy_threshold = 3

      http_healthcheck {
        path = "/health"
      }
    }
  }
}

# HTTP-роутер определяет, куда направить запрос.
# Здесь один маршрут — все запросы идут в API Gateway.
# При необходимости можно добавить маршруты по пути (/api/clinical → clinical-backend).
resource "yandex_alb_http_router" "main" {
  name   = "${local.name_prefix}-router"
  labels = local.common_labels
}

resource "yandex_alb_virtual_host" "main" {
  name           = "${local.name_prefix}-vhost"
  http_router_id = yandex_alb_http_router.main.id

  route {
    name = "default"
    http_route {
      http_route_action {
        backend_group_id = yandex_alb_backend_group.apigw.id
        timeout          = "60s"
      }
    }
  }
}

# Сам балансировщик. Располагается в публичной подсети.
# SSL-сертификат привязывается вручную после выпуска (см. infra_rationale.md).
resource "yandex_alb_load_balancer" "main" {
  name               = "${local.name_prefix}-alb"
  network_id         = yandex_vpc_network.main.id
  security_group_ids = [yandex_vpc_security_group.alb.id]
  labels             = local.common_labels

  allocation_policy {
    location {
      zone_id   = "${var.region}-a"
      subnet_id = yandex_vpc_subnet.public.id
    }
  }

  listener {
    name = "https-listener"

    endpoint {
      address {
        external_ipv4_address {}
      }
      ports = [443]
    }

    http {
      handler {
        http_router_id = yandex_alb_http_router.main.id
        # tls — настраивается вручную после выпуска сертификата
      }
    }
  }

  # HTTP → HTTPS редирект
  listener {
    name = "http-redirect"

    endpoint {
      address {
        external_ipv4_address {}
      }
      ports = [80]
    }

    http {
      redirects {
        http_to_https = true
      }
    }
  }
}

# ═════════════════════════════════════════════
# ВИРТУАЛЬНЫЕ МАШИНЫ: API GATEWAY
# Создаётся count инстансов — количество задаётся переменной apigw_vm_count.
# count.index используется для уникальных имён.
# ═════════════════════════════════════════════
resource "yandex_compute_instance" "apigw" {
  count       = var.apigw_vm_count
  name        = "${local.name_prefix}-apigw-${count.index}"
  platform_id = "standard-v3"
  zone        = "${var.region}-a"
  labels      = local.common_labels

  resources {
    cores  = split("-", var.apigw_vm_flavor)[1]
    memory = split("-", var.apigw_vm_flavor)[2]
  }

  boot_disk {
    initialize_params {
      image_id = var.vm_image_id
      size     = 20 # GB — достаточно для ОС и Kong
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.app.id
    security_group_ids = [yandex_vpc_security_group.app.id]
    # nat = false — нет публичного IP, трафик через балансировщик и NAT
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
    # user_data можно использовать для cloud-init:
    # установки Kong, настройки systemd-сервиса и т.д.
  }
}

# ═════════════════════════════════════════════
# ВИРТУАЛЬНЫЕ МАШИНЫ: KAFKA
# Три брокера — минимум для кворума. Каждый имеет отдельный диск для логов.
# ═════════════════════════════════════════════
resource "yandex_compute_instance" "kafka" {
  count       = var.kafka_broker_count
  name        = "${local.name_prefix}-kafka-${count.index}"
  platform_id = "standard-v3"
  zone        = "${var.region}-a"
  labels      = merge(local.common_labels, { role = "kafka-broker", broker_id = tostring(count.index) })

  resources {
    cores  = split("-", var.kafka_vm_flavor)[1]
    memory = split("-", var.kafka_vm_flavor)[2]
  }

  boot_disk {
    initialize_params {
      image_id = var.vm_image_id
      size     = 20
    }
  }

  # Отдельный диск для логов Kafka.
  # Это важно: логи Kafka пишутся интенсивно, отделение от системного диска
  # предотвращает ситуацию, когда полный диск кладёт всю ВМ.
  secondary_disk {
    disk_id = yandex_compute_disk.kafka_data[count.index].id
    mode    = "READ_WRITE"
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.app.id
    security_group_ids = [yandex_vpc_security_group.kafka.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

# Диски для данных Kafka. Создаются отдельно, чтобы пережить пересоздание ВМ.
resource "yandex_compute_disk" "kafka_data" {
  count = var.kafka_broker_count
  name  = "${local.name_prefix}-kafka-data-${count.index}"
  zone  = "${var.region}-a"
  size  = var.kafka_disk_size_gb
  type  = "network-hdd" # SSD важен для Kafka: задержки записи критичны
  labels = local.common_labels
}

# ═════════════════════════════════════════════
# ВИРТУАЛЬНЫЕ МАШИНЫ: ПРИЛОЖЕНИЯ ДОМЕНОВ
# Одна ВМ на домен (Clinical, Fintech, AI, Corporate).
# В production можно заменить на группы ВМ с автомасштабированием.
# ═════════════════════════════════════════════
resource "yandex_compute_instance" "app" {
  count       = var.app_vm_count
  name        = "${local.name_prefix}-app-${var.pg_domains[count.index]}"
  platform_id = "standard-v3"
  zone        = "${var.region}-a"
  labels      = merge(local.common_labels, { domain = var.pg_domains[count.index] })

  resources {
    cores  = split("-", var.app_vm_flavor)[1]
    memory = split("-", var.app_vm_flavor)[2]
  }

  boot_disk {
    initialize_params {
      image_id = var.vm_image_id
      size     = 30
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.app.id
    security_group_ids = [yandex_vpc_security_group.app.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

# ═════════════════════════════════════════════
# BASTION-ХОТ
# Единственная ВМ с публичным IP. Точка входа для SSH.
# ═════════════════════════════════════════════
resource "yandex_compute_instance" "bastion" {
  name        = "${local.name_prefix}-bastion"
  platform_id = "standard-v3"
  zone        = "${var.region}-a"
  labels      = merge(local.common_labels, { role = "bastion" })

  resources {
    cores  = split("-", var.bastion_vm_flavor)[1]
    memory = split("-", var.bastion_vm_flavor)[2]
  }

  boot_disk {
    initialize_params {
      image_id = var.vm_image_id
      size     = 10
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.mgmt.id
    nat                = true # Публичный IP — только у Bastion
    security_group_ids = [yandex_vpc_security_group.bastion.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

# ═════════════════════════════════════════════
# МОНИТОРИНГ (Prometheus + Grafana)
# ВМ в подсети управления. Собирает метрики со всех ВМ через Node Exporter.
# ═════════════════════════════════════════════
resource "yandex_compute_instance" "monitoring" {
  name        = "${local.name_prefix}-monitoring"
  platform_id = "standard-v3"
  zone        = "${var.region}-a"
  labels      = merge(local.common_labels, { role = "monitoring" })

  resources {
    cores  = split("-", var.monitoring_vm_flavor)[1]
    memory = split("-", var.monitoring_vm_flavor)[2]
  }

  boot_disk {
    initialize_params {
      image_id = var.vm_image_id
      size     = 20
    }
  }

  # Отдельный диск для хранения метрик Prometheus.
  secondary_disk {
    disk_id = yandex_compute_disk.monitoring_data.id
    mode    = "READ_WRITE"
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.mgmt.id
    # Нет публичного IP — доступ только через Bastion
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

resource "yandex_compute_disk" "monitoring_data" {
  name   = "${local.name_prefix}-monitoring-data"
  zone   = "${var.region}-a"
  size   = var.monitoring_disk_size_gb
  type   = "network-hdd" # HDD достаточно для метрик — дешевле SSD
  labels = local.common_labels
}

# ═════════════════════════════════════════════
# УПРАВЛЯЕМЫЙ POSTGRESQL
# Создаётся отдельный кластер на каждый домен.
# for_each по списку доменов — чище, чем count, когда ресурсы именованные.
# ═════════════════════════════════════════════
resource "yandex_mdb_postgresql_cluster" "domain" {
  for_each = toset(var.pg_domains)

  name        = "${local.name_prefix}-pg-${each.key}"
  # Yandex Cloud принимает только PRODUCTION или PRESTABLE — не PROD
  environment = var.environment == "prod" ? "PRODUCTION" : "PRESTABLE"
  network_id  = yandex_vpc_network.main.id
  labels      = merge(local.common_labels, { domain = each.key })

  # security_group_ids — ограничивает доступ к кластеру только из подсети приложений
  security_group_ids = [yandex_vpc_security_group.db.id]

  config {
    version = var.pg_version

    resources {
      resource_preset_id = var.pg_flavor
      disk_type_id       = "network-ssd"
      disk_size          = var.pg_disk_size_gb
    }
  }

  host {
    zone      = "${var.region}-a"
    subnet_id = yandex_vpc_subnet.data.id
    # assign_public_ip = false — БД не доступна из интернета
  }
}

# Пользователь PostgreSQL — должен быть создан ДО базы данных.
# Yandex Cloud требует чтобы owner существовал на момент создания БД.
# Пароль задан фиктивный — в production меняется через хранилище секретов.
resource "yandex_mdb_postgresql_user" "domain" {
  for_each = toset(var.pg_domains)

  cluster_id = yandex_mdb_postgresql_cluster.domain[each.key].id
  name       = each.key
  password   = var.pg_default_password
}

# База данных создаётся после пользователя через depends_on.
resource "yandex_mdb_postgresql_database" "domain" {
  for_each = toset(var.pg_domains)

  cluster_id = yandex_mdb_postgresql_cluster.domain[each.key].id
  name       = each.key
  owner      = each.key

  depends_on = [yandex_mdb_postgresql_user.domain]
}

# ═════════════════════════════════════════════
# ОБЪЕКТНОЕ ХРАНИЛИЩЕ
# ═════════════════════════════════════════════

# Бакет для Data Lakehouse: Iceberg-таблицы, dbt-артефакты, логи Kafka Connect.
resource "yandex_storage_bucket" "lakehouse" {
  access_key = var.storage_access_key
  secret_key = var.storage_secret_key
  bucket     = var.lakehouse_bucket_name
  acl        = "private"

  # Версионирование объектов позволяет восстановить случайно удалённые данные.
  # Для Lakehouse это особенно важно — Iceberg использует версионирование нативно.
  versioning {
    enabled = true
  }

  # Lifecycle: удалять нетекущие версии через 90 дней — экономия места
  lifecycle_rule {
    enabled = true
    noncurrent_version_expiration {
      days = 90
    }
  }

}

# Бакет для состояния Terraform.
# Создаётся первым — но есть проблема: бэкенд уже ссылается на этот бакет.
# Решение: первый запуск делается с локальным бэкендом (без блока backend),
# бакет создаётся, затем backend добавляется и выполняется terraform init -migrate-state.
resource "yandex_storage_bucket" "tf_state" {
  bucket = var.tf_state_bucket_name
  acl    = "private"

  versioning {
    enabled = true # Позволяет откатить состояние при ошибке
  }
}

# ═════════════════════════════════════════════
# DNS
# Внутренняя DNS-зона для обращений сервисов друг к другу по именам,
# а не по IP-адресам. Это позволяет менять IP без изменения конфигурации сервисов.
# ═════════════════════════════════════════════
resource "yandex_dns_zone" "internal" {
  name        = "${local.name_prefix}-internal-zone"
  zone        = "${var.project_id}.internal."
  public      = false # Только внутри VPC — снаружи не виден
  private_networks = [yandex_vpc_network.main.id]
  labels      = local.common_labels
}

# DNS-записи для каждого кластера PostgreSQL.
# Приложения обращаются к pg.clinical.future2.internal — не к IP.
resource "yandex_dns_recordset" "pg" {
  for_each = toset(var.pg_domains)

  zone_id = yandex_dns_zone.internal.id
  name    = "pg.${each.key}.${var.project_id}.internal."
  type    = "CNAME"  # fqdn — это hostname, не IP, поэтому CNAME а не A
  ttl     = 300
  data    = ["${yandex_mdb_postgresql_cluster.domain[each.key].host[0].fqdn}."]
}

# DNS-запись для Bastion — удобно подключаться по имени, а не по IP.
resource "yandex_dns_recordset" "bastion" {
  zone_id = yandex_dns_zone.internal.id
  name    = "bastion.${var.project_id}.internal."
  type    = "A"
  ttl     = 300
  data    = [yandex_compute_instance.bastion.network_interface[0].nat_ip_address]
}
