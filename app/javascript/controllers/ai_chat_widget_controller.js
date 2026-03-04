// app/javascript/controllers/ai_chat_widget_controller.js
import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = ["conversationList", "thread", "input", "sendBtn"]
  static values = {
    listUrl: String,
    showUrl: String,     // contains ':id'
    createUrl: String,
    cableUrl: String
  }

  connect() {
    this.conversations = []
    this.currentConversationId = null
    this.sidebarOpen = true
    this.loadConversations()
  }

  toggleSidebar = () => {
    this.sidebarOpen = !this.sidebarOpen
    this.element.classList.toggle("ai-chat--sidebar-hidden", !this.sidebarOpen)
  }

  async loadConversations() {
    const res = await fetch(this.listUrlValue, { headers: { "Accept": "application/json" } })
    this.conversations = await res.json()
    this.renderConversationList()
    if (this.conversations.length) {
      this.openConversation(this.conversations[0].id)
    } else {
      await this.createConversation()
    }
  }

  renderConversationList() {
    this.conversationListTarget.innerHTML = ""
    this.conversations.forEach(c => {
      const li = document.createElement("li")
      li.className = "ai-chat__list-item" + (c.id === this.currentConversationId ? " is-active" : "")
      li.textContent = c.title
      li.dataset.id = c.id
      li.addEventListener("click", () => this.openConversation(c.id))
      this.conversationListTarget.appendChild(li)
    })
  }

  async createConversation() {
    const res = await fetch(this.createUrlValue, {
      method: "POST",
      headers: { "Accept": "application/json", "Content-Type": "application/json", "X-CSRF-Token": this.csrf() },
      body: JSON.stringify({ title: "New conversation" })
    })
    const conv = await res.json()
    this.conversations.unshift(conv)
    this.renderConversationList()
    await this.openConversation(conv.id)
  }

  async openConversation(id) {
    if (this.subscription) this.subscription.unsubscribe()
    this.currentConversationId = id
    this.renderConversationList()

    const url = this.showUrlValue.replace(":id", id)
    const res = await fetch(url, { headers: { "Accept": "application/json" } })
    const data = await res.json()

    this.threadTarget.innerHTML = ""
    data.messages.forEach(m => this.appendMessageBubble(m.role, m.content))

    this.subscription = consumer.subscriptions.create(
      { channel: "AiChat::ChatChannel", conversation_id: id },
      {
        received: (data) => {
          if (data.type === "token") {
            this.appendOrExtendAssistant(data.token)
          } else if (data.type === "error") {
            this.appendSystem(`[Error] ${data.message}`)
            this.sendBtnTarget.disabled = false
          } else if (data.type === "done") {
            if (data.content) {
              const last = this.threadTarget.lastElementChild
              if (last && last.dataset.role === "assistant") {
                last.innerText = data.content
              }
            }
            this.sendBtnTarget.disabled = false
            this.scrollToBottom()
          }
        }
      }
    )
  }

  async send(e) {
    e.preventDefault()
    const content = this.inputTarget.value.trim()
    if (!content || !this.subscription) return

    this.sendBtnTarget.disabled = true
    this.inputTarget.value = ""
    this.appendMessageBubble("user", content)
    this.appendMessageBubble("assistant", "") // placeholder, will be filled as tokens stream

    this.subscription.perform("send_message", { content: content, options: { timeframe: "last_14_days" } })
    this.scrollToBottom()
  }

  // --- UI helpers ---
  appendMessageBubble(role, text) {
    const bubble = document.createElement("div")
    bubble.className = role === "user" ? "ai-chat__bubble ai-chat__bubble--user" : "ai-chat__bubble ai-chat__bubble--assistant"
    bubble.innerText = text
    bubble.dataset.role = role
    this.threadTarget.appendChild(bubble)
    this.scrollToBottom()
  }

  appendOrExtendAssistant(token) {
    let last = this.threadTarget.lastElementChild
    if (!last || last.dataset.role !== "assistant") {
      this.appendMessageBubble("assistant", token)
    } else {
      last.innerText += token
    }
    this.scrollToBottom()
  }

  appendSystem(text) {
    const div = document.createElement("div")
    div.className = "ai-chat__system"
    div.innerText = text
    this.threadTarget.appendChild(div)
  }

  scrollToBottom() {
    this.threadTarget.scrollTop = this.threadTarget.scrollHeight
  }

  csrf() {
    const meta = document.querySelector("meta[name=csrf-token]")
    return meta && meta.content
  }

  // Exposed for the hamburger button
  toggleSidebar(event) {
    event.preventDefault()
    this.toggleSidebar()
  }

  createConversation(event) {
    event.preventDefault()
    this.createConversation()
  }
}
