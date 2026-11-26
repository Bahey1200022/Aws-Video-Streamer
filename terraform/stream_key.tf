# Secret the Video Streamer must present to publish on the frontend's RTMP
# server. Generated here so it never lives in git; delivered by Ansible.
resource "random_password" "stream_key" {
  length  = 32
  special = false # used in an RTMP URL query string
}

# Password the phone needs to publish over WebRTC (MediaMTX user "phone").
# Watching needs no password
resource "random_password" "webrtc_publish" {
  length  = 32
  special = false # typed into the phone app's URL field
}

# The phone camera's own RTMP key (channel "phone", through WireGuard):
# revoking the phone never touches the streamer, and the logs show which
# camera published
resource "random_password" "phone_stream_key" {
  length  = 32
  special = false
}
