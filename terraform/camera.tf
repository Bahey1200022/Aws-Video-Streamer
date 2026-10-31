# Secrets for the camera channel, generated here so none of them live in git
resource "random_password" "camera_key" {
  length  = 32
  special = false # used in an RTMP URL query string
}

# Password viewers need to watch the camera (it's a private space, not public content)
resource "random_password" "camera_view" {
  length  = 20
  special = false
}
