const BrowserCheck = {
  mounted() {
    const userAgent = navigator.userAgent || ""
    const vendor = navigator.vendor || ""
    const isSafari =
      /safari/i.test(userAgent) &&
      /apple/i.test(vendor) &&
      !/(chrome|crios|edg|edgios|opr|fxios|firefox|android)/i.test(userAgent)

    // eslint-disable-next-line no-console
    console.info("[BrowserCheck] ua=%o vendor=%o isSafari=%o", userAgent, vendor, isSafari)

    // Hide warning if using Safari
    if (isSafari) {
      this.el.style.display = "none"
    }
  }
}

export default BrowserCheck
