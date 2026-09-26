import SwiftUI
import NotificationQueue

struct DemoView: View {
    @ObservedObject var model: DemoModel
    @State private var section = QueueSection.pending
    @State private var editor: EditorDestination?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image("icon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                        Text("NotificationQueue").font(.title2.bold())
                    }
                    Text("See what is pending, what is waiting, and what happened when scheduling could not finish.")
                        .foregroundStyle(.secondary)
                    LabeledContent("Notifications", value: model.permissionLabel)
                    Button("Allow notifications") { Task { await model.requestPermission() } }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).textSelection(.enabled)
                    } else {
                        Text(model.message).font(.footnote).textSelection(.enabled)
                    }
                    if model.busy { ProgressView("Updating queue…") }
                }

                Section("Try it") {
                    Button {
                        editor = EditorDestination(reminder: nil)
                    } label: { Label("Schedule a reminder", systemImage: "plus") }
                    Button("Schedule a batch of 5") { Task { await model.createBatch(count: 5) } }
                    Button("Schedule 80 to explore overflow") { Task { await model.createBatch(count: 80) } }
                    Text("Batches begin in five minutes, with one reminder every five minutes. They schedule real local notifications.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let batch = model.failedBatch {
                        Button("Retry batch \(batch.id)") { Task { await model.retryBatch() } }
                    }
                    Button { Task { await model.refresh() } } label: {
                        Label("Refresh and refill", systemImage: "arrow.clockwise")
                    }
                    Button { Task { await model.inspect() } } label: {
                        Label("Inspect without refilling", systemImage: "eye")
                    }
                }

                Section {
                    Picker("Show", selection: $section) {
                        ForEach(QueueSection.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu)
                    switch section {
                    case .pending:
                        Text("\(model.pending.count) requests currently reported by Apple, including any coverage warning.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.pending.isEmpty { Text("No pending requests.") }
                        ForEach(model.pending, id: \.id) { reminder in
                            reminderRow(reminder, editable: model.reminders.contains { $0.id == reminder.id })
                        }
                    case .waiting:
                        Text("Saved future reminders absent from the pending snapshot. Check diagnostics for capacity or scheduling errors.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.waiting.isEmpty { Text("Nothing waiting.") }
                        ForEach(model.waiting, id: \.id) { reminderRow($0, editable: true) }
                    case .batches:
                        if model.batches.isEmpty { Text("No named or generated batches. Individual reminders appear in Pending or Waiting.") }
                        ForEach(model.batches, id: \.id) { batch in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(batch.reminders.count) saved reminders").font(.headline)
                                Text(batch.id).font(.caption.monospaced()).textSelection(.enabled)
                                DisclosureGroup("View reminders") {
                                    ForEach(batch.reminders.sorted { $0.date < $1.date }, id: \.id) {
                                        reminderRow($0, editable: true)
                                    }
                                }
                                Button("Replace with first 3 future reminders") { Task { await model.replaceBatch(batch) } }
                                Button("Cancel batch", role: .destructive) { Task { await model.removeBatch(batch) } }
                            }
                        }
                    case .diagnostics:
                        Text("Retained evidence, not delivery receipts. Missed deadlines are detected on the next refresh.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.diagnostics.isEmpty { Text("No diagnostics yet.") }
                        ForEach(model.diagnostics, id: \.reminderID) { diagnostic in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(stateLabel(diagnostic.state)).font(.headline)
                                Text(diagnostic.reminderID).font(.caption.monospaced()).textSelection(.enabled)
                                Text(diagnostic.requestedDate, format: .dateTime.month().day().hour().minute().second())
                                if let reason = diagnostic.reason { Text(reasonLabel(reason)).font(.subheadline) }
                                if let detail = diagnostic.detail { Text(detail).font(.caption).foregroundStyle(.red) }
                                Text("Observed \(diagnostic.observedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Explore the queue") }

                Section("Coverage") {
                    if let date = model.journal.coverageEnd {
                        LabeledContent("Coverage boundary", value: date.formatted())
                    } else { Text("No known coverage boundary.") }
                    if let warning = model.journal.lastOutcome?.warningStatus {
                        LabeledContent("Warning", value: warningLabel(warning))
                    }
                    if let date = model.journal.lastSuccessfulRefill {
                        LabeledContent("Last verified refill", value: date.formatted())
                    }
                    if let date = model.snapshotDate {
                        LabeledContent("Pending snapshot", value: date.formatted())
                    }
                    if model.journal.needsReconciliation {
                        Label("Saved work needs reconciliation", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Text("This demo refills when opened or when you tap Refresh. It does not register background refresh tasks. Pending notifications are delivered by the system; delivery does not run the coordinator.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Cancel all demo reminders", role: .destructive) { confirmClear = true }
                }
            }
            .navigationTitle("Queue Explorer")
            .disabled(model.busy)
            .sheet(item: $editor) { destination in
                ReminderEditor(model: model, reminder: destination.reminder)
            }
            .confirmationDialog("Cancel all demo reminders?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Cancel all demo reminders", role: .destructive) { Task { await model.cancelAll() } }
            }
        }
    }

    @ViewBuilder
    private func reminderRow(_ reminder: LocalReminder, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(reminder.id == model.warningID ? "Coverage warning" : reminder.title).font(.headline)
            Text(reminder.body).font(.subheadline)
            Text(reminder.date, format: .dateTime.month().day().hour().minute().second())
            Text(reminder.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if editable {
                HStack {
                    Button("Edit") { editor = EditorDestination(reminder: reminder) }
                    Spacer()
                    Button("Cancel", role: .destructive) { Task { await model.cancel(reminder) } }
                }.buttonStyle(.borderless)
            }
        }
    }

    private func stateLabel(_ state: ReminderSchedulingState) -> String {
        switch state {
        case .awaitingScheduling: return "Awaiting scheduling"
        case .deferred: return "Waiting for capacity"
        case .scheduled: return "Verified as pending"
        case .elapsed: return "Reminder time passed"
        }
    }
    private func reasonLabel(_ reason: ReminderDiagnosticReason) -> String {
        switch reason {
        case .capacity: return "No available slot in the queue budget."
        case .submissionFailed: return "The system rejected submission."
        case .schedulingUnconfirmed: return "Scheduling did not finish verification."
        case .noVerifiedRefillBeforeDeadline: return "No verified refill before the deadline; the cause is unknown."
        case .deliveryUnknown: return "Previously scheduled; delivery is unknown."
        }
    }
    private func warningLabel(_ warning: ReminderWarningStatus) -> String {
        switch warning {
        case .scheduled: return "Scheduled"
        case .elapsed: return "Time passed; delivery unknown"
        case .notNeeded: return "Not needed"
        case .disabled: return "Disabled"
        case .alreadyAttempted: return "Already attempted this coverage period"
        }
    }
}

private enum QueueSection: String, CaseIterable, Identifiable {
    case pending = "Pending", waiting = "Waiting", batches = "Batches", diagnostics = "Diagnostics"
    var id: String { rawValue }
}
private struct EditorDestination: Identifiable {
    let id = UUID()
    let reminder: LocalReminder?
}

private struct ReminderEditor: View {
    @ObservedObject var model: DemoModel
    @Environment(\.dismiss) private var dismiss
    let original: LocalReminder?
    @State private var title: String
    @State private var message: String
    @State private var date: Date
    @State private var identifier: String
    // Generate once per editor, so retrying after a failure keeps the same identity.
    @State private var generatedID = UUID().uuidString

    init(model: DemoModel, reminder: LocalReminder?) {
        self.model = model
        original = reminder
        _title = State(initialValue: reminder?.title ?? "Demo reminder")
        _message = State(initialValue: reminder?.body ?? "Your reminder is ready.")
        _date = State(initialValue: reminder?.date ?? Date().addingTimeInterval(60))
        _identifier = State(initialValue: reminder?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminder") {
                    TextField("Title", text: $title)
                    TextField("Message", text: $message)
                    DatePicker("When", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
                Section("Identity") {
                    TextField("Optional ID", text: $identifier).disabled(original != nil)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(original == nil ? "Leave blank to use a generated ID. Reusing an existing ID updates that reminder." : "Editing preserves this reminder's ID and its batch.")
                        .font(.caption).foregroundStyle(.secondary)
                    if identifier.isEmpty { Text(generatedID).font(.caption.monospaced()).textSelection(.enabled) }
                }
                if let error = model.errorMessage {
                    Section("Could not finish") { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .navigationTitle(original == nil ? "New reminder" : "Edit reminder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(model.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let success = await model.save(id: identifier.isEmpty ? generatedID : identifier,
                                title: title, body: message, date: date, editing: original != nil)
                            if success { dismiss() }
                        }
                    }.disabled(model.busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || date <= Date())
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
    }
}
