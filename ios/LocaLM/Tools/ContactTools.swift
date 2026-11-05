import Contacts
import Foundation

/// Contacts lookup plus call / text / email through Apple's own UI. The model never sends anything:
/// iOS asks before calling, and the compose sheets need the user to tap Send.
final class ContactsService {
    static let shared = ContactsService()
    private let store = CNContactStore()

    struct Person {
        var name: String
        var phones: [(label: String, value: String)]
        var emails: [(label: String, value: String)]
        var birthday: DateComponents?
        var organization: String
    }

    private static let keys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
    ]

    static let accessDenied = "Contacts access is off. The user can enable it in Settings > Privacy & Security > Contacts > LocaLM."

    private func ensureAccess() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return true
        case .notDetermined: return (try? await store.requestAccess(for: .contacts)) ?? false
        default: return false
        }
    }

    /// nil when access is denied.
    func search(_ name: String) async -> [Person]? {
        guard await ensureAccess() else { return nil }
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let store = self.store
        return await Task.detached {
            var found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: Self.keys)) ?? []
            if found.isEmpty {
                // Nicknames and relationship words ("Mom") often live in the nickname field.
                let request = CNContactFetchRequest(keysToFetch: Self.keys)
                let q = query.lowercased()
                try? store.enumerateContacts(with: request) { c, stop in
                    if c.nickname.lowercased() == q || c.organizationName.lowercased() == q { found.append(c) }
                    if found.count >= 10 { stop.pointee = true }
                }
            }
            return found.prefix(10).map { c in
                Person(
                    name: CNContactFormatter.string(from: c, style: .fullName) ?? (c.nickname.isEmpty ? c.organizationName : c.nickname),
                    phones: c.phoneNumbers.map { (CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? ""), $0.value.stringValue) },
                    emails: c.emailAddresses.map { (CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? ""), $0.value as String) },
                    birthday: c.birthday,
                    organization: c.organizationName)
            }
        }.value
    }

    static func payload(_ p: Person) -> JSONValue {
        var pairs: [(String, JSONValue)] = [("name", .string(p.name))]
        if !p.phones.isEmpty { pairs.append(("phones", .array(p.phones.map { .string("\($0.label): \($0.value)") }))) }
        if !p.emails.isEmpty { pairs.append(("emails", .array(p.emails.map { .string("\($0.label): \($0.value)") }))) }
        if let b = p.birthday, let m = b.month, let d = b.day {
            let f = DateFormatter()
            pairs.append(("birthday", .string("\(f.monthSymbols[m - 1]) \(d)" + (b.year.map { ", \($0)" } ?? ""))))
        }
        if !p.organization.isEmpty { pairs.append(("organization", .string(p.organization))) }
        return .object(pairs)
    }

    /// One person by name, or an error message for the model.
    func person(_ name: String) async throws -> Person {
        guard let people = await search(name) else { throw ToolPreparationError.invalidArguments(Self.accessDenied) }
        if people.isEmpty {
            throw ToolPreparationError.invalidArguments("No contact named '\(name)'. Ask the user for the full name or number.")
        }
        if people.count > 1, people.filter({ $0.name.lowercased() == name.lowercased() }).count != 1 {
            throw ToolPreparationError.invalidArguments("Several contacts match '\(name)': "
                + people.prefix(5).map { "'\($0.name)'" }.joined(separator: ", ") + ". Ask which one.")
        }
        return people.count == 1 ? people[0] : people.first { $0.name.lowercased() == name.lowercased() }!
    }

    static func looksLikePhone(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber)
        return digits.count >= 5 && s.allSatisfy { $0.isNumber || " +-().".contains($0) }
    }
}

struct FindContactTool: AssistantTool {
    let group = ToolGroup.contacts
    let spec = ToolSpec(
        name: "find_contact",
        description: "Look up a person in the user's contacts (phone, email, birthday).",
        parameters: Schema.object([("name", Schema.string("The person's name as the user said it"))], required: ["name"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let name = (call["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'name'. Ask who to look up.") }
        return PreparedAction(title: "Look up contact", summary: name, icon: "person.crop.circle", requiresConfirmation: false) {
            guard let people = await ContactsService.shared.search(name) else { return .failure(ContactsService.accessDenied) }
            let display = people.isEmpty ? "No contact named “\(name)”."
                : people.map { p in "• \(p.name)" + (p.phones.first.map { " · \($0.value)" } ?? "") }.joined(separator: "\n")
            return ToolOutcome(success: true, display: display, payload: .object([
                ("status", .string("ok")), ("contacts", .array(people.map(ContactsService.payload))),
            ]))
        }
    }
}

struct CallContactTool: AssistantTool {
    let group = ToolGroup.contacts
    let spec = ToolSpec(
        name: "call_contact",
        description: "Start a phone call to a contact or number. iOS asks the user before dialing.",
        parameters: Schema.object([("name", Schema.string("Contact name or phone number"))], required: ["name"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let target = (call["name"] ?? call["number"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'name'. Ask who to call.") }
        var label = target
        var number = target
        if !ContactsService.looksLikePhone(target) {
            let person = try await ContactsService.shared.person(target)
            guard let phone = person.phones.first(where: { $0.label.lowercased().contains("mobile") || $0.label.lowercased().contains("iphone") })
                    ?? person.phones.first else {
                throw ToolPreparationError.invalidArguments("\(person.name) has no phone number saved. Tell the user.")
            }
            label = person.name
            number = phone.value
        }
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digits)") else { throw ToolPreparationError.invalidArguments("Invalid phone number.") }
        return PreparedAction(title: "Call", summary: "\(label) · \(number)", icon: "phone", requiresConfirmation: false) {
            var outcome = ToolOutcome(success: true, display: "Opening the call prompt for \(label). iOS asks before dialing.",
                                      payload: .object([("status", .string("call_prompt_opening")), ("to", .string(label)),
                                                        ("note", .string("iOS will ask the user to confirm the call. Do not say the call happened."))]))
            outcome.openAfterReply = url
            return outcome
        }
    }
}

struct DraftMessageTool: AssistantTool {
    let group = ToolGroup.contacts
    let spec = ToolSpec(
        name: "draft_message",
        description: "Open a text message draft to a contact. The user reviews it and taps Send themselves.",
        parameters: Schema.object([
            ("to", Schema.string("Contact name or phone number")),
            ("body", Schema.string("The message text")),
        ], required: ["to", "body"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let to = (call["to"] ?? call["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (call["body"] ?? call["message"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'to'. Ask who the message is for.") }
        guard !body.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'body'. Ask what the message should say.") }
        var label = to
        var recipient = to
        if !ContactsService.looksLikePhone(to) {
            let person = try await ContactsService.shared.person(to)
            guard let phone = person.phones.first(where: { $0.label.lowercased().contains("mobile") || $0.label.lowercased().contains("iphone") })
                    ?? person.phones.first else {
                throw ToolPreparationError.invalidArguments("\(person.name) has no phone number saved. Tell the user.")
            }
            label = person.name
            recipient = phone.value
        }
        return PreparedAction(title: "Text message draft", summary: "To \(label): “\(body)”", icon: "message",
                              requiresConfirmation: false) {
            let result = await SystemUI.composeMessage(to: [recipient], body: body)
            return Self.outcome(result, kind: "message", to: label)
        }
    }

    static func outcome(_ result: SystemUI.ComposeResult, kind: String, to: String) -> ToolOutcome {
        switch result {
        case .sent:
            return ToolOutcome(success: true, display: "The user sent the \(kind) to \(to).",
                               payload: .object([("status", .string("sent_by_user")), ("to", .string(to))]))
        case .saved:
            return ToolOutcome(success: true, display: "Saved the \(kind) draft.",
                               payload: .object([("status", .string("saved_as_draft")), ("to", .string(to))]))
        case .cancelled:
            return ToolOutcome(success: false, display: "The user closed the draft without sending.",
                               payload: .object([("status", .string("not_sent")), ("message", .string("The user closed the draft without sending."))]))
        case .failed:
            return .failure("The \(kind) failed to send.")
        case .unavailable:
            return .failure(kind == "email" ? "Mail isn't set up on this iPhone." : "This device can't send text messages.")
        }
    }
}

struct DraftEmailTool: AssistantTool {
    let group = ToolGroup.contacts
    let spec = ToolSpec(
        name: "draft_email",
        description: "Open an email draft. The user reviews it and taps Send themselves.",
        parameters: Schema.object([
            ("to", Schema.string("Contact name or email address")),
            ("subject", Schema.string("Subject line")),
            ("body", Schema.string("Email text")),
        ], required: ["to", "body"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let to = (call["to"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (call["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = (call["subject"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'to'. Ask who the email is for.") }
        guard !body.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'body'. Ask what the email should say.") }
        var label = to
        var address = to
        if !to.contains("@") {
            let person = try await ContactsService.shared.person(to)
            guard let email = person.emails.first else {
                throw ToolPreparationError.invalidArguments("\(person.name) has no email address saved. Tell the user.")
            }
            label = person.name
            address = email.value
        }
        return PreparedAction(title: "Email draft", summary: "To \(label)" + (subject.isEmpty ? "" : " · \(subject)") + "\n\(body)",
                              icon: "envelope", requiresConfirmation: false) {
            let result = await SystemUI.composeMail(to: [address], subject: subject, body: body)
            if result == .unavailable,
               var comps = URLComponents(string: "mailto:\(address)") {
                comps.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
                if let url = comps.url, await SystemUI.open(url) {
                    return ToolOutcome(success: true, display: "Opened a draft in your mail app.",
                                       payload: .object([("status", .string("draft_opened")),
                                                         ("note", .string("The user must send it themselves."))]))
                }
            }
            return DraftMessageTool.outcome(result, kind: "email", to: label)
        }
    }
}
