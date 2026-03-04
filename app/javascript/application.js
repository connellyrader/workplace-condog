// app/javascript/application.js
import { Turbo } from "@hotwired/turbo-rails"
Turbo.session.drive = false
window.Turbo = Turbo

import "controllers"
