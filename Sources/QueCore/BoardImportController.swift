// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

// MARK: - Picker model

/// Pins of one board as shown in the picker: loads pages on demand and tracks the selection.
public final class BoardPickerModel: ObservableObject {
    public let board: PinterestBoard
    /// How many pins load at first (and per "Load More").
    public let batchLimit: Int

    @Published public private(set) var pins: [PinterestBoardPin] = []
    @Published public private(set) var selection: Set<String> = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasMore = true
    /// Pins already in the deck: tagged "In Que" in the picker and left unselected when they load.
    @Published public private(set) var pinsInDeck: Set<String> = []

    var onLoadError: ((PinterestError) -> Void)?

    private var resolver: PinterestBoardResolver
    private var nextBookmark: String?
    private var didFirstPage = false
    /// Newly loaded pins join the selection while this is on ("everything selected" is the starting state).
    private var selectsNewPins = true
    private var anchorIndex: Int?
    private var loadWaiters: [() -> Void] = []

    public init(board: PinterestBoard, batchLimit: Int = BoardImportController.pinCap,
                resolver: PinterestBoardResolver = .shared) {
        self.board = board
        self.batchLimit = batchLimit
        self.resolver = resolver
    }

    public var selectedPins: [PinterestBoardPin] { pins.filter { selection.contains($0.id) } }

    /// Pinterest ended the board clearly short of its pin count (its count includes a few hidden pins, hence the margin).
    public var isShortOfBoard: Bool { !hasMore && !isLoading && board.pinCount > pins.count + 5 }

    /// "Try Loading More": walks the board again from the start on a fresh session. Pins already shown are kept;
    /// new ones are appended in board order.
    public func retryFromStart() {
        guard isShortOfBoard else { return }
        resolver = PinterestBoardResolver()
        didFirstPage = false
        nextBookmark = nil
        hasMore = true
        isLoading = true
        loadPages(until: board.pinCount)
    }

    /// Marks which pins are already in the deck and unselects them (the user can still select them on purpose).
    public func setPinsInDeck(_ ids: Set<String>) {
        pinsInDeck = ids
        selection.subtract(ids)
    }
    public var allSelected: Bool { !pins.isEmpty && selection.count == pins.count }

    // MARK: Selection

    /// Pins in the order the picker shows them: images first, then video pins (which join Que as GIFs).
    public var displayPins: [PinterestBoardPin] { pins.filter { !$0.isVideo } + pins.filter { $0.isVideo } }

    /// Click toggles one pin; Shift-click applies that pin's new state to the whole range from the last click
    /// (in the order shown on screen).
    public func toggle(_ pin: PinterestBoardPin, extendingRange: Bool = false) {
        let shown = displayPins
        guard let index = shown.firstIndex(of: pin) else { return }
        let select = !selection.contains(pin.id)
        if extendingRange, let anchor = anchorIndex, anchor < shown.count {
            for i in min(anchor, index)...max(anchor, index) {
                if select { selection.insert(shown[i].id) } else { selection.remove(shown[i].id) }
            }
        } else if select {
            selection.insert(pin.id)
        } else {
            selection.remove(pin.id)
        }
        anchorIndex = index
    }

    public func selectAll() {
        selectsNewPins = true
        selection = Set(pins.map(\.id))
    }

    public func selectNone() {
        selectsNewPins = false
        selection.removeAll()
    }

    /// Adds a page of pins (also used by tests). Pins already present are ignored.
    public func appendPage(_ page: [PinterestBoardPin], nextBookmark: String?) {
        let known = Set(pins.map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        pins += fresh
        if selectsNewPins { selection.formUnion(fresh.map(\.id).filter { !pinsInDeck.contains($0) }) }
        self.nextBookmark = nextBookmark
        didFirstPage = true
        hasMore = nextBookmark != nil
    }

    // MARK: Loading

    /// Loads pages until `batchLimit` more pins are in (or the board ends), then calls `completion`.
    public func loadNextBatch(completion: (() -> Void)? = nil) {
        if let completion = completion { loadWaiters.append(completion) }
        guard !isLoading else { return }
        guard hasMore else { flushWaiters(); return }
        isLoading = true
        loadPages(until: pins.count + batchLimit)
    }

    private func loadPages(until target: Int) {
        guard hasMore, pins.count < target else { finishLoading(); return }
        let bookmark = didFirstPage ? nextBookmark : nil
        fetchPage(bookmark: bookmark) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let page):
                self.appendPage(page.pins, nextBookmark: page.nextBookmark)
                self.loadPages(until: target)
            case .failure(let error):
                self.finishLoading()
                self.onLoadError?(error)
            }
        }
    }

    /// Fetches one page; completion on the main queue.
    ///
    /// Pinterest sometimes marks a board as finished ("-end-") after the first page for a given session even though
    /// it has many more pins (seen on a 105-pin board: 25 pins, then "end", in roughly 1 of 3 fresh sessions).
    /// When a page claims to be the last while clearly fewer pins than the board reports are loaded, ask again
    /// on a brand-new session, once. (It used to be up to 5 times, but each retry counts against Pinterest's now much
    /// stricter limit and one board copy could get Que blocked for 10 minutes.) Boards that page normally never retry.
    private func fetchPage(bookmark: String?, attempt: Int = 0,
                           completion: @escaping (Result<(pins: [PinterestBoardPin], nextBookmark: String?), PinterestError>) -> Void) {
        resolver.fetchPins(of: board, bookmark: bookmark) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .success(let page) = result, page.nextBookmark == nil, attempt < 1,
                   self.pins.count + page.pins.count < self.board.pinCount - 5 {
                    self.resolver = PinterestBoardResolver()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.fetchPage(bookmark: bookmark, attempt: attempt + 1, completion: completion)
                    }
                    return
                }
                completion(result)
            }
        }
    }

    private func finishLoading() {
        isLoading = false
        flushWaiters()
    }

    private func flushWaiters() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0() }
    }
}

// MARK: - Downloads

/// Downloads pins as deck-ready files: images as-is (format sniffed), video pins as looping GIFs.
final class PinMediaFetcher {
    /// Where videos download before becoming GIFs: Que's own session folder, so a crash mid-way leaves nothing
    /// outside it (the launch purge cleans old sessions). Set on the main queue before each batch.
    var downloadFolder = FileManager.default.temporaryDirectory
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()
    private static let maxImageBytes = 60 * 1024 * 1024
    private static let maxVideoBytes: Int64 = 150 * 1024 * 1024

    enum Failure: Error { case rateLimited(TimeInterval?), failed }

    /// Completion on the main queue.
    func fetch(_ pin: PinterestBoardPin, completion: @escaping (Result<(data: Data, ext: String), Failure>) -> Void) {
        if let video = pin.videoURL {
            fetchVideoAsGIF(video) { [weak self] result in
                // A video that can't be converted still lands as its still frame.
                if case .failure(.failed) = result { self?.fetchImage(pin.imageURL, completion: completion) }
                else { completion(result) }
            }
        } else {
            fetchImage(pin.imageURL, completion: completion)
        }
    }

    private func fetchImage(_ url: URL, completion: @escaping (Result<(data: Data, ext: String), Failure>) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            let result: Result<(data: Data, ext: String), Failure>
            if let limit = PinterestBoardResolver.rateLimit(in: response) {
                result = .failure(.rateLimited(limit.retryAfter))
            } else if let data = data, !data.isEmpty, data.count <= Self.maxImageBytes,
                      (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false,
                      let ext = Self.imageExtension(for: data) {
                result = .success((data, ext))
            } else {
                result = .failure(.failed)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func fetchVideoAsGIF(_ url: URL, completion: @escaping (Result<(data: Data, ext: String), Failure>) -> Void) {
        var observation: NSKeyValueObservation?
        let folder = downloadFolder
        let task = session.downloadTask(with: url) { tempURL, response, error in
            observation?.invalidate()
            if let limit = PinterestBoardResolver.rateLimit(in: response) {
                DispatchQueue.main.async { completion(.failure(.rateLimited(limit.retryAfter))) }
                return
            }
            guard let tempURL = tempURL, error == nil,
                  (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false else {
                DispatchQueue.main.async { completion(.failure(.failed)) }
                return
            }
            // The temp file disappears when this closure returns: move it first.
            let local = folder.appendingPathComponent("download_\(UUID().uuidString).mp4")
            guard (try? FileManager.default.moveItem(at: tempURL, to: local)) != nil else {
                DispatchQueue.main.async { completion(.failure(.failed)) }
                return
            }
            VideoToGIFConverter.shared.convert(videoURL: local) { gif, _ in   // completes on main
                try? FileManager.default.removeItem(at: local)
                if let gif = gif { completion(.success((gif, "gif"))) } else { completion(.failure(.failed)) }
            }
        }
        observation = task.observe(\.countOfBytesReceived, options: [.new]) { t, _ in
            if t.countOfBytesReceived > Self.maxVideoBytes { t.cancel() }
        }
        task.resume()
    }

    static func imageExtension(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) else { return nil }
        return UTType(uti as String)?.preferredFilenameExtension
    }

    /// Fetches `pins` with limited parallelism and delivers results **in board order** (so the deck keeps the
    /// board's order even when downloads finish out of order). Stops early on a rate limit. Main queue.
    func fetchInOrder(_ pins: [PinterestBoardPin], maxConcurrent: Int = 4,
                      onItem: @escaping (_ index: Int, _ file: (data: Data, ext: String)?) -> Void,
                      completion: @escaping (_ rateLimit: TimeInterval??) -> Void) {
        var nextToStart = 0, nextToDeliver = 0, inFlight = 0
        var buffer: [Int: (data: Data, ext: String)?] = [:]
        var rateLimit: TimeInterval?? = nil
        var finished = false

        func pump() {
            while nextToDeliver < pins.count, let item = buffer[nextToDeliver] {
                buffer[nextToDeliver] = nil
                onItem(nextToDeliver, item)
                nextToDeliver += 1
            }
            let done = nextToDeliver == pins.count || (rateLimit != nil && inFlight == 0)
            if done {
                if !finished { finished = true; completion(rateLimit) }
                return
            }
            while rateLimit == nil, inFlight < maxConcurrent, nextToStart < pins.count {
                let index = nextToStart
                nextToStart += 1
                inFlight += 1
                fetch(pins[index]) { result in
                    inFlight -= 1
                    switch result {
                    case .success(let file): buffer[index] = .some(file)
                    case .failure(.rateLimited(let retry)): rateLimit = .some(retry); buffer[index] = .some(nil)
                    case .failure(.failed): buffer[index] = .some(nil)
                    }
                    pump()
                }
            }
        }
        if pins.isEmpty { completion(nil) } else { pump() }
    }
}

// MARK: - Controller

/// Pinterest board import: a copied board link becomes an *offer* in the pill (nothing is added yet).
/// ⌥-click opens the picker to choose; ⌥-click and hold adds the board's pins to the deck (only the ones not already there).
/// Files only ever go into the deck: never Finder.
public final class BoardImportController {
    /// Pins loaded at first and added by "⌥-click and hold adds all".
    public static let pinCap = 100

    private let queueManager: DeckQueueManager
    private let hudPanel: CursorHUDPanel
    /// Creates the resolver for one board link (a fresh session each time; tests can inject their own).
    private let makeResolver: () -> PinterestBoardResolver
    private let fetcher = PinMediaFetcher()
    private var picker: BoardPickerPanel?
    private var currentModel: BoardPickerModel?
    private var importToken = 0
    /// Board id → (pin id → deck item id) for pins currently in the deck. Kept in sync with the deck, so clearing,
    /// dropping or deleting items makes those pins addable again.
    private var pinsInDeckByBoard: [String: [String: UUID]] = [:]
    /// Boards looked up recently ("username/slug" → the board with the pins loaded so far). Copying the same link
    /// again within `boardMemory` reuses it instead of asking Pinterest again.
    private var recentBoards: [String: (model: BoardPickerModel, at: Date)] = [:]
    static let boardMemory: TimeInterval = 30 * 60

    public init(queueManager: DeckQueueManager, hudPanel: CursorHUDPanel,
                makeResolver: @escaping () -> PinterestBoardResolver = { PinterestBoardResolver() }) {
        self.queueManager = queueManager
        self.hudPanel = hudPanel
        self.makeResolver = makeResolver
        queueManager.addObserver { [weak self] _ in
            guard let self = self, !self.pinsInDeckByBoard.isEmpty else { return }
            // Use the deck as it is *now*: observers are called asynchronously with a snapshot that can predate
            // items added since, and pruning against that snapshot dropped pins that were just added.
            let live = Set(self.queueManager.items.map(\.id))
            self.pinsInDeckByBoard = self.pinsInDeckByBoard
                .mapValues { $0.filter { live.contains($0.value) } }
                .filter { !$0.value.isEmpty }
        }
    }

    private func pinsInDeck(_ board: PinterestBoard) -> Set<String> {
        Set(pinsInDeckByBoard[board.id]?.keys.map { $0 } ?? [])
    }

    /// Entry point when a board link is copied.
    public func handleBoardLink(username: String, slug: String) {
        let key = "\(username)/\(slug)".lowercased()
        recentBoards = recentBoards.filter { Date().timeIntervalSince($0.value.at) < Self.boardMemory }
        if let recent = recentBoards[key] {
            offer(recent.model)
            return
        }
        // A fresh Pinterest session per board link (see PinterestBoardResolver.init for why).
        let resolver = makeResolver()
        resolver.fetchBoard(username: username, slug: slug) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    self.hudPanel.show(Self.notice(for: error))
                case .success(let board):
                    let model = BoardPickerModel(board: board, resolver: resolver)
                    self.recentBoards[key] = (model, Date())
                    self.offer(model)
                }
            }
        }
    }

    private func offer(_ model: BoardPickerModel) {
        let board = model.board
        guard board.pinCount > 0 else {
            hudPanel.show(.boardEmpty(name: board.name))
            return
        }
        model.onLoadError = { [weak self] error in self?.hudPanel.show(Self.notice(for: error)) }
        model.setPinsInDeck(pinsInDeck(board))
        currentModel = model

        let choose: () -> Void = { [weak self, weak model] in
            guard let model = model else { return }
            self?.openPicker(model)
        }
        let offerNotice = PillNotice.boardOffer(
            name: board.name, pinCount: board.pinCount, cap: Self.pinCap,
            addAll: { [weak self, weak model] in
                guard let self = self, let model = model else { return }
                // Turn the offer straight into progress (no collapse in between while the pins load).
                self.hudPanel.show(.boardPreparing(name: board.name))
                self.loadFirstBatch(of: model) { [weak self] in self?.addMissing(from: model) }
            },
            choose: choose
        )

        // Decide instantly from what we already know (no network wait): if the deck already holds as many of this
        // board's pins as "⌥-click and hold adds all" would add, it's already added. Pinterest's count includes a few
        // hidden pins (48 reported, 45 served), hence the small margin. The first pins prefetch meanwhile.
        loadFirstBatch(of: model)
        let alreadyIn = pinsInDeck(board).count
        let fullAdd = min(board.pinCount, Self.pinCap)
        if alreadyIn > 0 && alreadyIn >= fullAdd - min(5, fullAdd / 10) {
            hudPanel.show(.boardAlreadyAdded(name: board.name, choose: choose))
        } else {
            hudPanel.show(offerNotice)
        }
    }

    /// Loads the board's first `pinCap` pins unless they're already loaded (a remembered board): loading another
    /// batch would ask Pinterest for pins nobody asked for.
    private func loadFirstBatch(of model: BoardPickerModel, then done: (() -> Void)? = nil) {
        if model.pins.count >= Self.pinCap || !model.hasMore {
            done?()
        } else {
            model.loadNextBatch(completion: done)
        }
    }

    /// ⌥-click on the offer: adds the board's first pins, skipping any already in the deck.
    private func addMissing(from model: BoardPickerModel) {
        let inDeck = pinsInDeck(model.board)
        let firstPins = Array(model.pins.prefix(Self.pinCap))
        let missing = firstPins.filter { !inDeck.contains($0.id) }
        guard !missing.isEmpty else {
            hudPanel.show(.boardAlreadyAdded(name: model.board.name, choose: { [weak self, weak model] in
                guard let model = model else { return }
                self?.openPicker(model)
            }))
            return
        }
        add(missing, from: model.board, alreadyInDeck: firstPins.count - missing.count)
    }

    // MARK: Picker

    private func openPicker(_ model: BoardPickerModel) {
        // The picker grows out of the pill, so the pill steps aside without its own collapse animation.
        let anchor = hudPanel.frame
        hudPanel.isSuspended = true
        hudPanel.dismissNotice(animated: false)
        model.setPinsInDeck(pinsInDeck(model.board))   // the deck may have changed since the offer

        let panel = BoardPickerPanel(model: model)
        panel.collapseTarget = { [weak hudPanel] in hudPanel?.pillFrameIfShowing }
        // A manual choice is respected as-is: no "already added" alert, even for pins already in the deck.
        panel.onAdd = { [weak self, weak panel] pins in
            panel?.close()
            self?.add(pins, from: model.board, alreadyInDeck: 0)
        }
        panel.onClose = { [weak self] in
            self?.hudPanel.isSuspended = false
            self?.picker = nil
        }
        picker = panel
        panel.present(near: anchor)
    }

    // MARK: Adding

    /// Downloads `pins` into the deck, in board order, with progress in the pill.
    private func add(_ pins: [PinterestBoardPin], from board: PinterestBoard, alreadyInDeck: Int) {
        guard !pins.isEmpty else { return }
        guard !queueManager.isFull else { hudPanel.show(.queFull()); return }
        importToken &+= 1
        let token = importToken
        let clearsAtStart = queueManager.clearCount   // Que emptied meanwhile → the rest is dropped
        var added = 0, processed = 0
        hudPanel.show(.boardAdding(count: pins.count, name: board.name))

        fetcher.downloadFolder = queueManager.sessionDirectory
        fetcher.fetchInOrder(pins, onItem: { [weak self] index, file in
            guard let self = self else { return }
            processed += 1
            if let file = file, self.queueManager.clearCount == clearsAtStart, !self.queueManager.isFull,
               let item = self.queueManager.add(imageData: file.data, extension: file.ext) {
                added += 1
                self.pinsInDeckByBoard[board.id, default: [:]][pins[index].id] = item.id
            }
            if token == self.importToken {
                self.hudPanel.updateNotice(.boardAddingProgress(done: processed, total: pins.count, name: board.name))
            }
        }, completion: { [weak self] rateLimit in
            guard let self = self else { return }
            if self.queueManager.clearCount != clearsAtStart {
                if token == self.importToken { self.hudPanel.dismissNotice() }   // progress has no timer
                return
            }
            if let retry = rateLimit {
                self.hudPanel.show(.pinterestRateLimited(retryAfter: retry, partial: (added, pins.count, "Added")))
            } else if added < pins.count && self.queueManager.isFull {
                self.hudPanel.show(.queFull())   // filled up part-way; the rest wasn't lost, there was no room
            } else if added == 0 {
                self.hudPanel.show(.nothingDownloaded())
            } else {
                self.hudPanel.show(.boardAdded(added: added, requested: pins.count, name: board.name,
                                               alreadyInDeck: alreadyInDeck))
            }
        })
    }

    static func notice(for error: PinterestError) -> PillNotice {
        switch error {
        case .rateLimited(let retry): return .pinterestRateLimited(retryAfter: retry)
        case .notFound: return .boardNotFound()
        case .privateProfile: return .boardOnPrivateProfile()
        case .offline: return .pinterestUnreachable()
        case .unexpected: return .pinterestUnexpected()
        }
    }
}
