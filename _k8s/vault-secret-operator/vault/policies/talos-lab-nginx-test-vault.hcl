# Policy Vault : lecture seule des secrets de l'appli nginx-test-vault dans le moteur talos-lab/.
# Moindre privilège : l'appli ne voit QUE son sous-dossier nginx-test-vault/, rien d'autre.
# KV-v2 => les données sont sous <mount>/data/<path> et les métadonnées sous <mount>/metadata/<path>.

path "talos-lab/data/nginx-test-vault/*" {
  capabilities = ["read"]
}

path "talos-lab/metadata/nginx-test-vault/*" {
  capabilities = ["read"]
}
