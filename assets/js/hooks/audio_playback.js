const AudioPlayback = {
  mounted() {
    this.audio = null

    this.handleEvent("audio_playback", ({base64, format}) => {
      if (!base64) return

      if (this.audio) {
        this.audio.pause()
        this.audio = null
      }

      const mime = format === "mp3" ? "audio/mpeg" : `audio/${format || "mpeg"}`
      this.audio = new Audio(`data:${mime};base64,${base64}`)
      this.audio.play().catch(() => {})
    })
  },
}

export default AudioPlayback
