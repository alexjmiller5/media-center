import MediaKit
import SwiftUI

struct MediaCaptureView: View {
  @Bindable var library: MediaLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var input = ""
  @State private var requestID = UUID()
  @State private var submitted = false
  @State private var sending = false
  @State private var error: String?
  private let recovered: Bool
  init(library: MediaLibrary, draft: MediaDraft? = nil) {
    self.library = library
    if let draft, case .capture(let input, _) = draft.content {
      _input = State(initialValue: input); _requestID = State(initialValue: draft.id); recovered = true
    } else { recovered = false }
  }
  var body: some View {
    ScrollView {
    VStack(alignment: .leading, spacing: 18) {
      Text("Add to Media Center").font(.title2.bold())
      Text("Paste a link or describe something to save. It joins your queue after the service confirms the saved item.").foregroundStyle(.secondary)
      TextEditor(text: $input).frame(minHeight: 140).accessibilityLabel("Link or description to save").accessibilityIdentifier("capture.input").disabled(submitted || recovered)
      if let receipt = library.workspace.captureReceipts[requestID] {
        Text(receipt.state == "saved" ? "Saved" : receipt.state == "needs_review" ? "Needs review" : "Awaiting confirmation").font(.headline).accessibilityIdentifier("capture.receipt")
        if receipt.state != "saved" { Text("The request is preserved. Acceptance alone does not mean the item was saved.").foregroundStyle(.secondary) }
      }
      if let message = library.message { Text(message).foregroundStyle(.red) }
      if let error { Text(error).foregroundStyle(.red) }
      if recovered { Text("This draft keeps its original request identity. Checking its receipt does not submit it.").font(.footnote).foregroundStyle(.secondary) }
      HStack {
        Button("Done") { Task { if await preserve() { dismiss() } } }.accessibilityIdentifier("capture.done")
        Spacer()
        if !submitted && library.workspace.captureReceipts[requestID] == nil {
          Button("Save") {
            sending = true; submitted = true
            Task { submitted = await library.capture(MediaDraft(id: requestID, input: input, intent: .save)); sending = false }
          }.buttonStyle(.borderedProminent).accessibilityIdentifier("capture.save").disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || !library.workspace.isOnline)
        }
        if let draft = library.workspace.drafts.first(where: { $0.id == requestID }), (submitted || recovered), library.workspace.captureReceipts[requestID]?.state != "saved" {
          Button("Check receipt") { Task { await library.workspace.reconcile(draft); if library.workspace.captureReceipts[requestID]?.state == "saved" { await library.refresh() } } }.disabled(!library.workspace.isOnline)
        }
      }
    }.padding(28)
    }.frame(minWidth: 320, idealWidth: 520, minHeight: 360).scrollDismissesKeyboard(.interactively)
      .task(id: input) {
        do { try await Task.sleep(for: .milliseconds(200)); try Task.checkCancellation(); _ = await preserve() }
        catch { }
      }
  }
  private func preserve() async -> Bool {
    guard !submitted, !recovered else { return true }
    if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !library.workspace.drafts.contains(where: { $0.id == requestID }) { return true }
    do { try await library.workspace.keep(MediaDraft(id: requestID, input: input, intent: .save)); error = nil; return true }
    catch { self.error = "Could not preserve this draft. Keep this window open and try again."; return false }
  }

}

struct MediaDraftsView: View {
  @Bindable var library: MediaLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var capture: MediaDraft?
  @State private var discarding: MediaDraft?
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text("Your drafts").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
      Text("Drafts stay on this device. Nothing is submitted automatically.").foregroundStyle(.secondary)
      if !library.workspace.isOnline { Text("Reconnect to validate access before recovering drafts.") }
      if library.workspace.drafts.isEmpty { Text("No drafts on this connection.") }
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          ForEach(library.workspace.drafts) { draft in
            VStack(alignment: .leading, spacing: 10) {
              switch draft.content {
              case .capture(let input, _):
                Button(input.isEmpty ? "Empty capture" : String(input.prefix(160))) { capture = draft }.accessibilityIdentifier("draft.capture." + draft.id.uuidString)
                if library.workspace.captureReceipts[draft.id]?.state == "saved" { Text("Saved").foregroundStyle(.secondary) }
              case .edit(let edit):
                Text("Item or source change").font(.headline)
                ForEach(edit.values.keys.sorted(), id: \.self) { column in
                  HStack(alignment: .top) {
                    Text(column).font(.caption.weight(.semibold))
                    Text(display(edit.values[column]))
                  }
                  if let current = library.workspace.currentValues[draft.id] { Text("Current: " + display(current[column])).foregroundStyle(.secondary) }
                }
                Button("Read current values") { Task { await library.workspace.reconcile(draft) } }.disabled(!library.workspace.isOnline)
                Text("Review the item’s fields before applying a new change. This draft will not be retried automatically.").font(.footnote).foregroundStyle(.secondary)
              }
              Button("Discard draft", role: .destructive) { discarding = draft }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }
      if let error { Text(error).foregroundStyle(.red) }
    }.padding(24).frame(minWidth: 320, idealWidth: 540, minHeight: 400)
      .sheet(item: $capture) { MediaCaptureView(library: library, draft: $0) }
      .confirmationDialog("Discard this draft from this device?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
        Button("Discard", role: .destructive) {
          if let draft = discarding { Task { do { try await library.workspace.discard(draft.id) } catch { self.error = "Could not discard this draft." } } }
          discarding = nil
        }
      }
  }
  private func display(_ value: CoreJSONValue?) -> String {
    guard let value, value != .null else { return "Not set" }
    if case .string(let text) = value { return text }
    guard let data = try? JSONEncoder().encode(value) else { return "Unavailable" }
    return String(data: data, encoding: .utf8) ?? "Unavailable"
  }
}
