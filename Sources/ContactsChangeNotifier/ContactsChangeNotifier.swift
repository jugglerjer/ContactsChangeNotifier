//
//  ContactsChangeNotifier.swift
//
//  Created by Yonat Sharon on 10/07/2022.
//  Forked by Lubin Labs for macOS support on 04/15/2026.
//

@preconcurrency import Contacts
#if os(macOS)
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
    ///
    /// `excludedTransactionAuthors` is the only echo suppression: the
    /// notifier forwards every `CNContactStoreDidChange` (see
    /// `contactsStoreChanged()`). An app that saves to Contacts should set an
    /// explicit `CNSaveRequest.transactionAuthor` on its saves and pass that
    /// same constant here, e.g.
    /// `.fetchRequest(excludedTransactionAuthors: [bundleID, myWriterAuthor])`.
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
            ) { [weak self] _ in
                self?.contactsStoreChanged()
            }
            #if os(macOS)
            observeMacDatabaseChanges()
            #endif
        }
    }

    #if os(macOS)
    /// Posted system-wide (distributed) by the Contacts daemons after every
    /// save to any AddressBook database: Contacts.app edits, iCloud/CardDAV
    /// syncs, other apps. Undocumented, so it is a second trigger next to
    /// `CNContactStoreDidChange`, never the only one.
    static let addressBookDatabaseChangedNotification = Notification.Name("ABDistributedDatabaseChangedNotification")

    /// On macOS, `CNContactStoreDidChange` alone can't be trusted for external
    /// changes. In-process, Contacts posts it only as AddressBookCore's
    /// rebroadcast of `ABDatabaseChangedExternallyNotification`, and on
    /// macOS 27 a freshly launched process never rebroadcasts: its
    /// persistence stack starts from cached account information
    /// ("Store registration failed: com.apple.accounts Code=7") and stays
    /// silent until an accountsd "accounts changed" event rebuilds it, which
    /// can be minutes or hours later. Measured 2026-10-09: a debug Queue
    /// missed three external edits over 15 minutes that the
    /// already-rebuilt production Queue rebroadcast at once, and a bare CLI
    /// probe got no `CNContactStoreDidChange` for two edits in 50 s while
    /// `ABDistributedDatabaseChangedNotification` arrived within 0.4 s of
    /// each save and a history fetch on it returned the edit.
    ///
    /// So also fetch on:
    ///  - the distributed database-changed notification, with
    ///    `.deliverImmediately`: AppKit suspends distributed delivery while
    ///    the app is inactive, and a background Mac app is the normal case
    ///    for an edit made in Contacts.app;
    ///  - app activation, in case a future macOS stops posting (or renames)
    ///    the undocumented notification.
    ///
    /// Extra triggers are free: forwarding is serialized and token-based, so
    /// a fetch with nothing new posts nothing.
    @MainActor
    private func observeMacDatabaseChanges() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(macDatabaseMayHaveChanged(_:)),
            name: Self.addressBookDatabaseChangedNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(macDatabaseMayHaveChanged(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func macDatabaseMayHaveChanged(_ notification: Notification) {
        forwardQueue.async { [weak self] in
            self?.forwardChangeHistoryEvents()
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
    #endif

    @Sendable @objc private func contactsStoreChanged() {
        // Always fetch and forward the change history, on every platform.
        // The upstream library tried to tell our own saves' echoes from
        // real changes, and both of its heuristics drop real changes:
        //
        //  - `isExternal` keyed on the undocumented
        //    `CNNotificationOriginationExternally` userInfo key, which macOS
        //    never includes, so every external change on macOS (an edit in
        //    Contacts.app, an iCloud sync) looked like an internal echo.
        //  - `applicationIsActive()`: on iOS a change that arrives while the
        //    app is in front (an edit made on the Mac, synced in over iCloud
        //    while the user is in the app) was treated as the app's own
        //    change; on macOS it meant "app is frontmost".
        //
        // A dropped change was lost for good, not just delayed: the drop
        // branch also advanced `lastHistoryToken` past it, so even the next
        // launch's replay could not see it.
        //
        // Forwarding unconditionally is safe. `fetchRequest()` sets
        // `excludedTransactionAuthors`, so saves made under an excluded
        // author produce no events, and `lastHistoryToken` + the serial
        // forward queue make the notification burst idempotent (only the
        // first fetch returns events). Queue doesn't save to Contacts in
        // 2.4.x, so there are no echoes to suppress yet; the 2.5.0 write
        // layer must give its saves an explicit `transactionAuthor` and
        // pass it in `excludedTransactionAuthors`.
        forwardQueue.async { [weak self] in
            self?.forwardChangeHistoryEvents()
        }
    }

    /// Get contacts change events and post them in a `didChangeNotification`
    private func forwardChangeHistoryEvents() {
        do {
            let changeHistoryEvents = try ChangeHistoryForwardStep.run(tokenStorage: historyTokenStorage) { startingToken in
                fetchRequest.startingToken = startingToken
                var error: NSError?
                let fetchResult = store.swiftEnumerator(for: fetchRequest, error: &error)
                if let error = error { throw error }
                return (
                    events: fetchResult.value.compactMap { $0 as? CNChangeHistoryEvent },
                    token: fetchResult.currentHistoryToken
                )
            }
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

/// One forward of change history, without a `CNContactStore`, so it can be tested.
enum ChangeHistoryForwardStep {
    /// Fetches the change history since `startingToken` and returns its
    /// events plus the history token as of that same fetch.
    typealias Fetch = (_ startingToken: Data?) throws -> (events: [CNChangeHistoryEvent], token: Data)

    /// Fetches the history since the stored token, stores the fetch's own
    /// token, and returns the events to post (empty: nothing to post).
    ///
    /// The stored token is the fetch result's `currentHistoryToken`, not a
    /// fresh `CNContactStore.currentHistoryToken` read afterwards: a change
    /// that landed between the fetch and that read would be skipped for
    /// good, because the next fetch starts after it.
    ///
    /// Every event is returned, including `CNChangeHistoryDropEverythingEvent`:
    /// only the observer can re-read its own state, and the token still
    /// advances so the same drop isn't delivered again.
    ///
    /// A failed fetch throws before the token moves, so the next
    /// notification retries from the same point.
    static func run(tokenStorage: HistoryTokenStorage, fetch: Fetch) throws -> [CNChangeHistoryEvent] {
        let result = try fetch(tokenStorage.tokenData)
        tokenStorage.tokenData = result.token
        return result.events
    }
}

// Applies to .CNContactStoreDidChange
private extension Notification {
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
