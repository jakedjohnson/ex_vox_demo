const AudioRecorder = {
  mounted() {
    this.mediaRecorder = null
    this.chunks = []
    this.recording = false

    this.el.querySelector("[data-toggle-record]")
      .addEventListener("click", () => this.toggle())
  },

  toggle() {
    if (this.recording) {
      this.stopRecording()
    } else {
      this.startRecording()
    }
  },

  async startRecording() {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({audio: true})
      this.mediaRecorder = new MediaRecorder(stream, {mimeType: "audio/webm"})
      this.chunks = []

      this.mediaRecorder.ondataavailable = e => this.chunks.push(e.data)
      this.mediaRecorder.onstop = () => {
        const blob = new Blob(this.chunks, {type: "audio/webm"})
        const reader = new FileReader()
        reader.onloadend = () => {
          const base64 = reader.result.split(",")[1]
          this.pushEvent("audio_recorded", {data: base64})
        }
        reader.readAsDataURL(blob)
      }

      this.mediaRecorder.start()
      this.recording = true
      this.pushEvent("recording_started", {})
    } catch (e) {
      this.pushEvent("recording_error", {message: e.message})
    }
  },

  stopRecording() {
    if (this.mediaRecorder && this.mediaRecorder.state === "recording") {
      this.mediaRecorder.stop()
      this.mediaRecorder.stream.getTracks().forEach(t => t.stop())
      this.recording = false
      this.pushEvent("recording_stopped", {})
    }
  },
}

export default AudioRecorder
