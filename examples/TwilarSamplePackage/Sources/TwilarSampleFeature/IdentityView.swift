import SwiftUI
import GTMEasyGrowth

/// Demonstrates the identity surface area:
///
///  - `getAnonymousId()` — durable per-install UUID; the SDK lazily
///    generates and persists this on first read.
///  - `setUserId(_:)` — promotes the install to an authenticated identity
///    without immediately fanning out an identify event.
///  - `identify(...)` — explicit upsert with traits; powers Meta CAPI's
///    Enhanced Matching and PostHog `$identify`.
struct IdentityView: View {
  @State private var anonymousId: String = ""
  @State private var userIdInput: String = ""
  @State private var emailInput: String = ""
  @State private var phoneInput: String = ""
  @State private var status: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Anonymous id") {
          Text(anonymousId.isEmpty ? "(loading…)" : anonymousId)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
          Button("Refresh") {
            Task { anonymousId = await GrowthClient.analytics.getAnonymousId() }
          }
        }

        Section("Authenticated user") {
          TextField("user id (e.g. usr_42)", text: $userIdInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          TextField("email (optional)", text: $emailInput)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          TextField("phone (E.164, optional)", text: $phoneInput)
            .keyboardType(.phonePad)

          Button("Identify (fires identify event)") {
            Task {
              do {
                var traits: [String: GrowthJSONValue] = [
                  "signed_up": .bool(true),
                ]
                if !emailInput.isEmpty { traits["email"] = .string(emailInput) }
                if !phoneInput.isEmpty { traits["phone"] = .string(phoneInput) }
                _ = try await GrowthClient.analytics.identify(
                  userId: userIdInput.isEmpty ? nil : userIdInput,
                  traits: traits
                )
                status = "✓ identify(userId: \(userIdInput.isEmpty ? "nil" : userIdInput))"
              } catch {
                status = "✗ identify failed: \(error)"
              }
            }
          }
          .disabled(userIdInput.isEmpty && emailInput.isEmpty && phoneInput.isEmpty)

          Button("Set user id only (no event)") {
            Task {
              await GrowthClient.analytics.setUserId(userIdInput.isEmpty ? nil : userIdInput)
              status = "✓ setUserId(\(userIdInput.isEmpty ? "nil" : userIdInput))"
            }
          }
        }

        if !status.isEmpty {
          Section("Last action") {
            Text(status).font(.footnote.monospaced()).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Identity")
      .task { anonymousId = await GrowthClient.analytics.getAnonymousId() }
    }
  }
}
