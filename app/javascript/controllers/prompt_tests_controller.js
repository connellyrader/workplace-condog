// app/javascript/controllers/prompt_tests_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "insightForm",
    "insightResult",
    "overviewForm",
    "overviewResult",
    "historyList",
    "historyEmpty",
    "versionSelect"
  ]

  static values = {
    key: String,
    promptType: String,
    historyUrl: String,
    historyLimit: Number,
    insightPreviewUrl: String,
    overviewPreviewUrl: String
  }

  connect() {
    this.history = []
    this.loadHistory()
  }

  reloadHistory() {
    this.loadHistory()
  }

  async loadHistory() {
    if (!this.hasHistoryListTarget || !this.hasHistoryUrlValue) return

    try {
      const url = new URL(this.historyUrlValue, window.location.origin)
      if (this.keyValue) url.searchParams.set("prompt_key", this.keyValue)
      if (this.hasPromptTypeValue) url.searchParams.set("prompt_type", this.promptTypeValue)
      if (this.hasHistoryLimitValue) url.searchParams.set("limit", this.historyLimitValue)

      const res = await fetch(url.toString(), { headers: { Accept: "application/json" } })
      if (!res.ok) throw new Error(`History request failed (${res.status})`)
      const data = await res.json()
      this.history = data.runs || []
      this.renderHistory()
    } catch (err) {
      this.renderHistoryError(err)
    }
  }

  async runInsightPreview(event) {
    event.preventDefault()
    if (!this.hasInsightFormTarget) return

    await this.runPreview({
      form: this.insightFormTarget,
      target: this.insightResultTarget,
      kind: "insight",
      url: this.hasInsightPreviewUrlValue ? this.insightPreviewUrlValue : this.insightFormTarget.action
    })
  }

  async runOverviewPreview(event) {
    event.preventDefault()
    if (!this.hasOverviewFormTarget) return

    await this.runPreview({
      form: this.overviewFormTarget,
      target: this.overviewResultTarget,
      kind: "overview",
      url: this.hasOverviewPreviewUrlValue ? this.overviewPreviewUrlValue : this.overviewFormTarget.action
    })
  }

  // --- renderers ---
  renderHistory() {
    if (!this.hasHistoryListTarget) return

    this.historyListTarget.innerHTML = ""
    const runs = this.history || []

    if (this.hasHistoryEmptyTarget) {
      this.historyEmptyTarget.hidden = runs.length > 0
    }

    runs.forEach((run) => {
      const item = document.createElement("div")
      item.className = "prompt-test-history__item"

      const meta = document.createElement("div")
      meta.className = "prompt-test-history__meta"
      meta.textContent = [
        this.promptLabel(run),
        this.versionLabel(run),
        this.metaLabel(run),
        this.timestampLabel(run)
      ].filter(Boolean).join(" • ")
      item.appendChild(meta)

      const title = document.createElement("div")
      title.className = "prompt-test-history__title"
      title.textContent = run.title || "(no title)"
      item.appendChild(title)

      if (run.body) {
        const body = document.createElement("div")
        body.className = "prompt-test-history__body"
        body.textContent = this.truncate(run.body, 900)
        item.appendChild(body)
      }

      this.historyListTarget.appendChild(item)
    })
  }

  renderHistoryError(err) {
    if (!this.hasHistoryListTarget) return

    this.historyListTarget.innerHTML = ""
    const msg = document.createElement("div")
    msg.className = "admin-alert admin-alert--error"
    msg.textContent = err.message || "Unable to load history."
    this.historyListTarget.appendChild(msg)
    if (this.hasHistoryEmptyTarget) this.historyEmptyTarget.hidden = true
  }

  renderPreview(target, payload, kind) {
    if (!target) return
    target.innerHTML = ""

    if (!payload) {
      target.textContent = "No preview returned."
      return
    }

    const wrapper = document.createElement("div")
    wrapper.className = "admin-preview"

    const meta = document.createElement("div")
    meta.className = "admin-preview-meta"
    if (kind === "insight") {
      const bits = []
      if (payload.insight_id) bits.push(`Insight #${payload.insight_id}`)
      if (payload.detection_id) bits.push(`Detection #${payload.detection_id}`)
      if (payload.prompt_version_id) bits.push(`Prompt version #${payload.prompt_version_id}`)
      meta.textContent = bits.join(" • ")
    } else {
      const bits = []
      const metaPayload = payload.meta || {}
      if (metaPayload.workspace) bits.push(`Workspace: ${metaPayload.workspace.name || metaPayload.workspace}`)
      if (metaPayload.metric) bits.push(`Metric: ${metaPayload.metric.name || metaPayload.metric}`)
      if (metaPayload.range_start && metaPayload.range_end) {
        bits.push(`Window: ${metaPayload.range_start} → ${metaPayload.range_end}`)
      }
      meta.textContent = bits.join(" • ")
    }
    if (meta.textContent.length) wrapper.appendChild(meta)

    const body = document.createElement("pre")
    body.className = "admin-preview-body"
    body.textContent = kind === "insight" ? `${payload.title || ""}\n\n${payload.body || ""}` : (payload.text || "")
    wrapper.appendChild(body)

    target.appendChild(wrapper)
  }

  showError(target, message) {
    if (!target) return
    target.innerHTML = ""
    const alert = document.createElement("div")
    alert.className = "admin-alert admin-alert--error"
    alert.textContent = message
    target.appendChild(alert)
  }

  showLoading(target) {
    if (!target) return
    target.innerHTML = ""
    const div = document.createElement("div")
    div.className = "admin-muted"
    div.textContent = "Running preview..."
    target.appendChild(div)
  }

  prependHistory(run) {
    if (!run) return
    this.history = [run, ...(this.history || [])].slice(0, 25)
    this.renderHistory()
  }

  versionLabel(run) {
    const pv = run.prompt_version
    if (!pv) return "Active/default"
    const label = pv.label ? ` - ${pv.label}` : ""
    return `v${pv.version}${label}`
  }

  promptLabel(run) {
    if (!run.prompt_key) return null
    const type = run.prompt_type ? ` (${run.prompt_type})` : ""
    return `${run.prompt_key}${type}`
  }

  metaLabel(run) {
    const meta = run.metadata || {}
    const pieces = []
    if (meta.candidate_source === "insight") pieces.push("Existing insight")
    if (meta.candidate_source === "detection") pieces.push("Detection preview")
    if (meta.detection_id) pieces.push(`det ${meta.detection_id}`)
    if (meta.insight_id) pieces.push(`insight ${meta.insight_id}`)
    return pieces.join(" • ")
  }

  timestampLabel(run) {
    if (!run.created_at) return null
    try {
      const d = new Date(run.created_at)
      return d.toLocaleString()
    } catch (_e) {
      return run.created_at
    }
  }

  currentVersionId() {
    const select = this.versionSelectTargets.find((el) => el.value !== undefined)
    const val = select && select.value
    return val && val.length ? val : null
  }

  truncate(text, max) {
    if (!text || text.length <= max) return text
    return `${text.slice(0, max)}…`
  }

  async runPreview({ form, target, kind, url }) {
    this.showLoading(target)
    const formData = new FormData(form)

    try {
      const res = await fetch(url, {
        method: (form.method || "POST").toUpperCase(),
        headers: { "Accept": "application/json", "X-CSRF-Token": this.csrfToken() },
        body: formData
      })
      const data = await res.json()
      if (!res.ok || data.error) {
        throw new Error(data.error || `Request failed (${res.status})`)
      }

      // We no longer render the preview inline; history panel handles it.
      if (target) target.innerHTML = ""
      if (data.run) this.prependHistory(data.run)
    } catch (err) {
      this.showError(target, err.message || "Preview failed.")
    }
  }

  csrfToken() {
    const meta = document.querySelector("meta[name=csrf-token]")
    return meta && meta.content
  }
}
