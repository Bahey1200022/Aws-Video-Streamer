(() => {
  const video = document.getElementById('video');
  const status = document.getElementById('status');
  const src = video.dataset.src;
  const show = (text) => { status.textContent = text; status.hidden = false; };

  function start() {
    if (window.Hls && Hls.isSupported()) {
      const hls = new Hls({ liveSyncDurationCount: 3 });
      hls.on(Hls.Events.ERROR, (_, data) => {
        if (data.fatal) {
          show(data.response && data.response.code === 403
            ? 'This link has expired or is invalid.'
            : 'Channel offline. Retrying…');
          hls.destroy();
          setTimeout(start, 5000);
        }
      });
      hls.loadSource(src);
      hls.attachMedia(video);
    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = src;
    }
  }

  video.addEventListener('playing', () => { status.hidden = true; });
  start();
})();
