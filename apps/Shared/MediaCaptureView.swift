import MediaKit
import SwiftUI

struct MediaCaptureView: View {
  @Bindable var library: MediaLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var input = ""
  @State private var requestID = UUID()
  @State private var submitted = false
  @State private var sending = false
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Add to Media Center").font(.title2.bold())
      Text("Paste a link or describe something to save. It joins your queue after the service confirms the saved item.").foregroundStyle(.secondary)
      TextEditor(text: $input).frame(minHeight: 140).accessibilityIdentifier("capture.input").disabled(submitted)
      if let receipt = library.workspace.captureReceipts[requestID] {
        Text(receipt.state == "saved" ? "Saved" : receipt.state == "needs_review" ? "Needs review" : "Awaiting confirmation").font(.headline)
        if receipt.state != "saved" { Text("The request is preserved. Acceptance alone does not mean the item was saved.").foregroundStyle(.secondary) }
      }
      if let message = library.message { Text(message).foregroundStyle(.red) }
      HStack {
        Button("Done") { dismiss() }.accessibilityIdentifier("capture.done")
        Spacer()
        if !submitted {
          Button("Save") {
            sending = true; submitted = true
            Task { await library.capture(MediaDraft(id: requestID, input: input, intent: .save)); sending = false }
          }.buttonStyle(.borderedProminent).accessibilityIdentifier("capture.save").disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || !library.workspace.isOnline)
        } else if let draft = library.workspace.drafts.first(where: { $0.id == requestID }), library.workspace.captureReceipts[requestID]?.state != "saved" {
          Button("Check receipt") { Task { await library.workspace.reconcile(draft) } }.disabled(!library.workspace.isOnline)
        }
      }
    }.padding(28).frame(minWidth: 320, idealWidth: 520)
  }
}
