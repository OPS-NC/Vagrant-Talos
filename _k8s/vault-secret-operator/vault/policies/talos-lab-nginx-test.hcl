# Policy Vault : lecture seule des secrets de l'appli nginx-test dans le moteur talos-lab/.
# Moindre privilège : l'appli ne voit QUE son sous-dossier nginx-test/, rien d'autre.
# KV-v2 => les données sont sous <mount>/data/<path> et les métadonnées sous <mount>/metadata/<path>.

path "talos-lab/data/nginx-test/*" {
  capabilities = ["read"]
}

path "talos-lab/metadata/nginx-test/*" {
  capabilities = ["read"]
}
