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

// TabTransition: adds fade-in animation class when tab content appears
Hooks.TabTransition = {
  mounted() {
    this.el.classList.add("tab-content-enter")
  },
  updated() {
    // Re-trigger animation on content change
    this.el.classList.remove("tab-content-enter")
    // Force reflow to restart animation
    void this.el.offsetWidth
    this.el.classList.add("tab-content-enter")
  }
}

// ModelSelector: handles dropdown open/close, click-outside, escape, keyboard nav
Hooks.ModelSelector = {
  mounted() {
    // Close on Escape
    this._onKeydown = (e) => {
      if (e.key === "Escape") {
        this.pushEventTo(this.el, "close_dropdown", {})
      }
      // Keyboard navigation within model list
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        const list = this.el.querySelector("#model-list")
        if (!list) return
        const items = Array.from(list.querySelectorAll("button[phx-click='select_model']"))
        if (items.length === 0) return

        e.preventDefault()
        const focused = list.querySelector("button:focus")
        let idx = items.indexOf(focused)

        if (e.key === "ArrowDown") {
          idx = idx < items.length - 1 ? idx + 1 : 0
        } else {
          idx = idx > 0 ? idx - 1 : items.length - 1
        }
        items[idx].focus()
      }
      if (e.key === "Enter") {
        const list = this.el.querySelector("#model-list")
        if (!list) return
        const focused = list.querySelector("button:focus")
        if (focused) {
          focused.click()
        }
      }
    }
    document.addEventListener("keydown", this._onKeydown)
  },
  updated() {
    // Focus search input when dropdown opens
    const searchInput = this.el.querySelector("#model-search-input")
    if (searchInput) {
      requestAnimationFrame(() => searchInput.focus())
    }
  },
  destroyed() {
    document.removeEventListener("keydown", this._onKeydown)
  }
}

// CopyToClipboard: copies data-copy-text content to clipboard, shows brief "Copied!" feedback
Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      const text = this.el.getAttribute("data-copy-text") || ""
      navigator.clipboard.writeText(text).then(() => {
        this.showCopied()
      }).catch(() => {
        // Fallback for older browsers
        const ta = document.createElement("textarea")
        ta.value = text
        ta.style.position = "fixed"
        ta.style.opacity = "0"
        document.body.appendChild(ta)
        ta.select()
        document.execCommand("copy")
        document.body.removeChild(ta)
        this.showCopied()
      })
    })
  },
  showCopied() {
    const originalText = this.el.textContent
    this.el.textContent = "Copied!"
    this.el.classList.add("text-emerald-400")
    setTimeout(() => {
      this.el.textContent = originalText
      this.el.classList.remove("text-emerald-400")
    }, 1500)
  }
}

// AutoResizeTextarea: auto-grows textarea as user types
Hooks.AutoResizeTextarea = {
  mounted() {
    this.el.addEventListener("input", () => this.resize())
    this.resize()

    // Clear and reset on server push
    this.handleEvent("clear-input", () => {
      this.el.value = ""
      this.el.style.height = "auto"
      this.resize()
    })
  },
  resize() {
    this.el.style.height = "auto"
    const maxHeight = 160 // ~6 lines
    this.el.style.height = Math.min(this.el.scrollHeight, maxHeight) + "px"
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
