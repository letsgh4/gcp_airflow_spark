variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "europe-west1-b"
}

variable "course_name" {
  type    = string
  default = "airflow-spark-course"
}

variable "analitycy" {
  description = "Lista loginów analityków — tworzone jako konta Airflow"
  type        = list(string)
  default = [
    "analityk01", "analityk02", "analityk03", "analityk04",
    "analityk05", "analityk06", "analityk07", "analityk08",
    "analityk09", "analityk10", "analityk11", "analityk12",
    "analityk13", "analityk14", "analityk15", "analityk16"
  ]
}

# control-plane: potrzebuje tylko zarządzać klastrem, nie uruchamia podów
variable "master_machine_type" {
  type    = string
  default = "e2-standard-2" # 2 vCPU, 8 GB
}

# workerzy: Airflow workery + Spark executory
variable "worker_machine_type" {
  type = string
  # 2 vCPU, 8 GB × 2 nody. Razem z masterem 6 vCPU — mieści się w limicie
  # CPUS_ALL_REGIONS = 8 projektu kursowego (e2-standard-4 dawało 10 i apply padał na QUOTA_EXCEEDED).
  default = "e2-standard-2"
}

variable "allowed_cidr" {
  description = "CIDR skąd dostęp do UI (np. IP sali/instruktora). 0.0.0.0/0 = wszyscy."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_pub_key" {
  description = "Publiczny klucz SSH (treść). W CI z vars.SSH_PUBLIC_KEY; puste = odczyt z ssh_pub_key_path."
  type        = string
  default     = ""

  validation {
    condition     = var.ssh_pub_key == "" || can(regex("^(ssh-|ecdsa-)", trimspace(var.ssh_pub_key)))
    error_message = "ssh_pub_key musi być publicznym kluczem OpenSSH (np. \"ssh-ed25519 AAAA...\")."
  }
}

variable "ssh_pub_key_path" {
  description = "Ścieżka do publicznego klucza SSH — fallback dla lokalnego developmentu, gdy ssh_pub_key jest puste"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "airflow_admin_password" {
  description = "Hasło admina Airflow"
  type        = string
  sensitive   = true
}

variable "airflow_analyst_password" {
  description = "Hasło dla analityków w Airflow"
  type        = string
  sensitive   = true
}

variable "jupyterhub_admin_password" {
  description = "Hasło admina JupyterHub"
  type        = string
  sensitive   = true
}

variable "jupyterhub_analyst_password" {
  description = "Hasło dla analityków w JupyterHub"
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Hasło admina Grafana"
  type        = string
  sensitive   = true
}
