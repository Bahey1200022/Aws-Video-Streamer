# Secrets for the Stream Studio, generated here so none of them live in git
resource "random_password" "studio_admin" {
  length  = 24
  special = false
}

# Signs Flask session cookies and share links
resource "random_password" "studio_secret_key" {
  length  = 48
  special = false
}

# Shared by the Studio and nginx secure_link for private-channel playback URLs
resource "random_password" "link_secret" {
  length  = 32
  special = false
}
