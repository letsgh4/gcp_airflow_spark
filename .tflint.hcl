# Konfiguracja TFLint dla katalogu terraform/.
# Uruchomienie: tflint --chdir=terraform --config="$PWD/.tflint.hcl"
#
# Wtyczka Google działa bez poświadczeń GCP (deep_check domyślnie wyłączony),
# więc lint nie potrzebuje sekretów.

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "google" {
  enabled = true
  version = "0.41.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
