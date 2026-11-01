import AppKit

enum DockPasteboard {
    static let tileType = NSPasteboard.PasteboardType("com.matanlevi.dawck.tile")
}

// MARK: Drag source — reordering tiles

extension DockContentView: NSDraggingSource {
    func beginTileDrag(id: UUID, event: NSEvent) {
        guard let tile = tiles[id], let rect = visualRect(of: id) else { return }
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: DockPasteboard.tileType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let size = rect.size
        let image = tile.currentImage.map { NSImage(cgImage: $0, size: size) }
        dragItem.setDraggingFrame(rect, contents: image)
        draggingID = id
        setHoverLabelHidden()
        layoutTilesNow()
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : [.move, .delete]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let id = draggingID
        draggingID = nil
        setInsertion(nil)
        showDropRing(false)
        // Dropped on nothing: in Edit mode that means "take it off the dock",
        // with the same poof as the real Dock. Outside Edit mode a stray drag
        // just snaps back.
        if operation.isEmpty, let id, model.isEditing {
            NSAnimationEffect.disappearingItemDefault.show(centeredAt: screenPoint, size: NSSize(width: 64, height: 64))
            delegate?.dockContent(self, remove: id)
        } else {
            layoutTilesNow()
        }
    }

    private func setHoverLabelHidden() { delegate?.dockContent(self, hover: nil, screenRect: nil) }
}

// MARK: Drag destination — files and tiles

extension DockContentView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearDragFeedback() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { currentIntent != nil }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearDragFeedback() }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return Array((urls ?? []).prefix(200))
    }

    private func clearDragFeedback() {
        currentIntent = nil
        highlightTile(nil)
        setInsertion(nil)
        showDropRing(false)
    }

    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let pasteboard = sender.draggingPasteboard

        // Rearranging this dock's own tiles.
        if let raw = pasteboard.string(forType: DockPasteboard.tileType) {
            guard let id = UUID(uuidString: raw), model.tiles.contains(where: { $0.id == id }), canReorder else {
                clearDragFeedback()
                return []
            }
            let index = insertionIndexForDrag(at: p)
            setInsertion(index)
            highlightTile(nil)
            currentIntent = .reorder(tile: id, index: index)
            return .move
        }

        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { clearDragFeedback(); return [] }

        // Dropped *onto* something that wants it: open, move into, stash, trash.
        if let hit = tileID(at: p), let tile = tiles[hit], !model.isDerived || tile.model.item.kind == .file {
            let item = tile.model.item
            var intent: DropIntent?
            switch item.kind {
            case .file:
                if item.path.hasSuffix(".app") { intent = .open(tile: hit) }
                else if item.isDirectory { intent = .moveInto(tile: hit) }
            case .tray, .group: intent = .stash(tile: hit)
            case .trash: intent = .trash
            default: break
            }
            if let intent, delegate?.dockContent(self, canAccept: intent) != false {
                currentIntent = intent
                highlightTile(hit)
                setInsertion(nil)
                showDropRing(false)
                switch intent {
                case .moveInto: return NSEvent.modifierFlags.contains(.option) ? .copy : .move
                case .trash: return .move
                default: return .copy
                }
            }
        }

        // Otherwise, pinning to the dock — if it is allowed to take new tiles.
        if canPin {
            let index = insertionIndexForDrag(at: p)
            setInsertion(index)
            highlightTile(nil)
            showDropRing(model.tiles.isEmpty)
            currentIntent = .pin(index: index)
            return .copy
        }
        clearDragFeedback()
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDragFeedback() }
        guard let intent = currentIntent else { return false }
        if case .reorder = intent {
            return delegate?.dockContent(self, perform: intent, urls: [], copy: false) ?? false
        }
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        return delegate?.dockContent(self, perform: intent, urls: urls, copy: NSEvent.modifierFlags.contains(.option)) ?? false
    }
}
