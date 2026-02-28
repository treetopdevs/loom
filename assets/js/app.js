// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// --- Hooks ---

let Hooks = {}

// ShiftEnterSubmit: submits the form on Enter, allows Shift+Enter for newlines
Hooks.ShiftEnterSubmit = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        this.el.closest("form").dispatchEvent(
          new Event("submit", { bubbles: true, cancelable: true })
        )
      }
    })

    // Clear input when server pushes clear-input event
    this.handleEvent("clear-input", () => {
      this.el.value = ""
    })
  }
}

// ScrollToBottom: auto-scrolls container to bottom when content updates
Hooks.ScrollToBottom = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.scrollToBottom())
    this.observer.observe(this.el, { childList: true, subtree: true })
  },
  updated() {
    this.scrollToBottom()
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#818cf8"}, shadowColor: "rgba(0,0,0,.3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
