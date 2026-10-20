# Secret the Video Streamer must present to publish on the frontend's RTMP
# server. Generated here so it never lives in git; delivered by Ansible.
resource "random_password" "stream_key" {
  length  = 32
  special = false # used in an RTMP URL query string
}
