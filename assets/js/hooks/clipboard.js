const Clipboard = {
  mounted() {
    this.handleEvent("copy_to_clipboard", ({text}) => {
      if (!text) return
      navigator.clipboard.writeText(text)
    })
  },
}

export default Clipboard
