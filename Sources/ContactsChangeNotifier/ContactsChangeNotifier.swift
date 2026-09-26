//
//  ContactsChangeNotifier.swift
//
//  Created by Yonat Sharon on 10/07/2022.
//  Forked by Lubin Labs for macOS support on 04/15/2026.
//

@preconcurrency import Contacts

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if !COCOAPODS
import ContactStoreChangeHistory
#endif

public extension Notification {
    internal static let contactsChangeEventsKey = "ContactsChangeEvents"

    /// Contacts change events in a ``ContactsChangeNotifier.didChangeNotification``
    var contactsChangeEvents: [CNChangeHistoryEvent]? {
        userInfo?[Self.contactsChangeEventsKey] as? [CNChangeHistoryEvent]
    }
}

public extension CNChangeHistoryFetchRequest {
    /// Creates a request with sensible defaults:
    /// Only retrieve contact identifiers, and ignore changes with the `transactionAuthor == Bundle.main.bundleIdentifier`.
    /// Pass parameters to override defaults.
    static func fetchRequest(
        shouldUnifyResults: Bool = true,
        includeGroupChanges: Bool = true,
        excludedTransactionAuthors: [String]? = Bundle.main.bundleIdentifier.flatMap { [$0] },
        additionalContactKeyDescriptors: [CNKeyDescriptor] = []
    ) -> CNChangeHistoryFetchRequest {
        let request = CNChangeHistoryFetchRequest()
        request.shouldUnifyResults = shouldUnifyResults
        request.includeGroupChanges = includeGroupChanges
        request.excludedTransactionAuthors = excludedTransactionAuthors
        request.additionalContactKeyDescriptors = additionalContactKeyDescriptors
        return request
    }
}

/// Posts notifications of *external* changes in Contacts (i.e., changes made outside the app). **Note**: Requires user contacts authorization.
///
/// To use, keep a`ContactsChangeNotifier` object, and observe ``ContactsChangeNotifier.didChangeNotification`` notifications.
///
/// Example:
///
/// ```swift
/// let notifier = ContactsChangeNotifier(store: myCNContactStore)
///
/// init() {
///     NotificationCenter.default.addObserver(
///         self,
///         selector: #selector(contactsStoreChanged), // func that handles change notifications
///         name: ContactsChangeNotifier.didChangeNotification,
///         object: nil
///     )
/// }
/// ```
public final class ContactsChangeNotifier: NSObject, Sendable {
    /// Posted when *external* changes occur in Contacts (i.e., changes made outside the app). Includes `contactsChangeEvents` with all changes.
    ///
    /// Replaces `CNContactStoreDidChange` which is called both for internal changes and for phantom echoes of changes.
    public static let didChangeNotification = Notification.Name("ContactsChangeNotifier.didChangeNotification")

    public let store: CNContactStore

    /// Spec of which changes to observe.
    ///
    /// `startingToken` is ignored: `lastHistoryToken` will be automatically used.
    ///
    /// Use `.fetchRequest()` for sensible defaults.
    public let fetchRequest: CNChangeHistoryFetchRequest

    /// The location where `lastHistoryToken` is stored.
    public let historyTokenStorage: HistoryTokenStorage

    /// Used as `startingToken` when fetching Contacts change history.
    /// Updated after every fetch, to avoid getting the same changes over and over again.
    public var lastHistoryToken: Data? {
        get { historyTokenStorage.tokenData }
        set { historyTokenStorage.tokenData = newValue }
    }

    /// Create a notifier of *external* changes in Contacts (i.e., changes made outside the app). **Note**: Requires user contacts authorization.
    ///
    /// > Warning: To use `iCloudKeyValueStore` as the `lastHistoryToken` storage type,
    /// > add "iCloud" to "Signing & Capabilities" and enable "Key-value storage".
    ///
    /// - Parameters:
    ///   - store: The contacts store to use
    ///   - historyTokenStorage: Where `lastHistoryToken` is stored:  `.userDefaults(suiteName:)` or `.iCloudKeyValueStore` or your own storage implementation.
    ///   - fetchRequest: Optional spec of which changes to observe.
    ///
    ///     `fetchRequest.startingToken` is ignored, `lastHistoryToken` will be used instead.
    public init(
        store: CNContactStore,
        historyTokenStorage: HistoryTokenStorage = .userDefaults,
        fetchRequest: CNChangeHistoryFetchRequest = .fetchRequest()
    ) throws {
        self.store = store
        self.historyTokenStorage = historyTokenStorage
        self.fetchRequest = fetchRequest
        super.init()
        Task {
            try await setupContactStore()
        }
    }

    /// Get changes in Contacts.
    /// - Parameter fetchRequest: Optional change history request.
    ///   By default, uses `self.fetchRequest` with `lastHistoryToken`, so will return only changes made since the last call.
    ///   Passing a request with nil `startingToken` will return all contacts and groups.
    /// - Returns: An enumerator of ``CNChangeHistoryEvent`` objects.
    public func changeHistory(fetchRequest: CNChangeHistoryFetchRequest? = nil) throws -> NSEnumerator {
        let fetchRequest = fetchRequest ?? {
            self.fetchRequest.startingToken = lastHistoryToken
            return self.fetchRequest
        }()
        var error: NSError?
        let fetchResult = store.swiftEnumerator(for: fetchRequest, error: &error)
        if let error = error { throw error }
        return fetchResult.value
    }

    // MARK: - Privates

    @MainActor private var observation: NSObjectProtocol?

    /// Serializes `forwardChangeHistoryEvents` calls. One external save
    /// posts `CNContactStoreDidChange` many times in a burst; with
    /// concurrent forwarding, every task fetched with the SAME starting
    /// token (none had advanced it yet), so observers received the same
    /// events once per notification — measured 8 duplicate posts for a
    /// single contact edit. Serialized, the first fetch advances the
    /// token and the rest of the burst fetches empty history.
    private let forwardQueue = DispatchQueue(label: "ContactsChangeNotifier.forward", qos: .background)

    private func setupContactStore() async throws {
        try await store.requestAccess(for: .contacts)

        // wake up store, otherwise change notification not received
        _ = store.defaultContainerIdentifier()

        // don't get changes that occurred before app was ever run
        if nil == lastHistoryToken {
            lastHistoryToken = store.currentHistoryToken
        } else { // get changes since the last update
            forwardQueue.async { [weak self] in
                self?.forwardChangeHistoryEvents()
            }
        }

        await MainActor.run {
            observation = NotificationCenter.default.addObserver(
                forName: .CNContactStoreDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.contactsStoreChanged(isExternal: notification.isContactsStoreChangeExternal)
            }
        }
    }

    @Sendable @objc private func contactsStoreChanged(isExternal: Bool) {
        #if os(macOS)
        // On macOS, always fetch and forward the change history. The iOS
        // heuristics below don't translate:
        //
        //  - `isExternal` keys on the undocumented
        //    `CNNotificationOriginationExternally` userInfo key, which macOS
        //    never includes — so every external change (an edit in
        //    Contacts.app, an iCloud sync) was classified as an internal
        //    echo, dropped, and — because the guard's else-branch advances
        //    `lastHistoryToken` — permanently skipped: even the next
        //    launch's replay couldn't see it.
        //  - `applicationIsActive()` means "app is frontmost" on macOS, not
        //    "the user is inside our app making changes"; a change
        //    notification landing after the user switches back to the app
        //    would be dropped the same way.
        //
        // Forwarding unconditionally is safe: `fetchRequest()` already sets
        // `excludedTransactionAuthors` to our own bundle id, so our own
        // saves produce no events, and `lastHistoryToken` + the serial
        // forward queue make the notification burst idempotent (only the
        // first fetch returns events).
        forwardQueue.async { [weak self] in
            self?.forwardChangeHistoryEvents()
        }
        #else
        // avoid phantom echoes of internal changes by checking application state:
        //   .background => called from background refresh => external change
        //   .inactive => called when app opened => external change
        //   .active => regular app execution => internal change
        Task { @MainActor in
            guard isExternal, !applicationIsActive() else {
                lastHistoryToken = store.currentHistoryToken
                return
            }

            forwardQueue.async { [weak self] in
                self?.forwardChangeHistoryEvents()
            }
        }
        #endif
    }

    @MainActor
    private func applicationIsActive() -> Bool {
        #if os(iOS)
        return UIApplication.safeShared?.applicationState == .active
        #elseif os(macOS)
        return NSApplication.shared.isActive
        #endif
    }

    /// Get contacts change events and post them in a `didChangeNotification`
    private func forwardChangeHistoryEvents() {
        do {
            let changes = try changeHistory()
            lastHistoryToken = store.currentHistoryToken
            let changeHistoryEvents = changes.compactMap { $0 as? CNChangeHistoryEvent }
            guard !changeHistoryEvents.isEmpty else { return }
            // Explicit priority: a bare `Task {}` here would inherit
            // `forwardQueue`'s .background QoS, and observers run inside
            // this task, so every `Task {}` they start would be .background
            // too. On Apple silicon .background runs only on the efficiency
            // cores and gets a new thread only while fewer than two of the
            // process's threads are busy, so observer work (and anything it
            // waits on, like Firestore writes) can stall for minutes.
            Task(priority: .utility) { @MainActor [weak self] in
                self?.postNotification(changeHistoryEvents: changeHistoryEvents)
            }
        } catch {
            #if DEBUG
            print("ContactsChangeNotifier failed to get Contacts change history:", error.localizedDescription)
            #endif
        }
    }

    private func postNotification(changeHistoryEvents: [CNChangeHistoryEvent]) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Notification.contactsChangeEventsKey: changeHistoryEvents]
        )
    }
}

// Applies to .CNContactStoreDidChange
private extension Notification {
    /// (Undocumented) Did the change originate outside the app
    var isContactsStoreChangeExternal: Bool {
        nil != userInfo?["CNNotificationOriginationExternally"]
    }

    /// (Undocumented) Empty for external-to-app changes, some `CNDataMapperContactStore` for internal changes.
    var contactsStoreChangeSources: NSArray {
        userInfo?["CNNotificationSourcesKey"] as? NSArray ?? []
    }

    /// (Undocumented) Empty for external-to-app changes, something like `["CA37C0B8-85A0-49BF-A03B-3F3C40C2CF8E"]` for internal changes.
    var contactsStoreChangeIdentifiers: [String] {
        (userInfo?["CNNotificationSaveIdentifiersKey"] as? NSArray ?? [])
            .compactMap { $0 as? String }
    }
}

#if os(iOS)
// From https://stackoverflow.com/a/69153780/1176162
extension UIApplication {
    static var safeShared: UIApplication? {
        guard UIApplication.responds(to: Selector(("sharedApplication"))) else {
            return nil
        }

        guard let unmanagedSharedApplication = UIApplication.perform(Selector(("sharedApplication"))) else {
            return nil
        }

        return unmanagedSharedApplication.takeUnretainedValue() as? UIApplication
    }
}
#endif
