path "secret/data/mongodb/auth" {
  capabilities = ["read"]
}

path "secret/data/mongodb/internal-auth" {
  capabilities = ["read"]
}

path "secret/data/mongodb/tls/*" {
  capabilities = ["read"]
}
