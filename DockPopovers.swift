import SwiftUI
import AppKit
import QuickLookThumbnailing

// MARK: - Thumbnails

/// Quick Look thumbnails, generated off the main thread and cached. Folder
/// popovers used to ask Finder's icon service for a generic icon per file;
/// pictures, PDFs and documents now show what is actually in them.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() { cache.totalCostLimit = 32 * 1024 * 1024 }

    func cached(_ url: URL, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, side) as NSString)
    }

    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        let id = key(url, side) as NSString
        if let hit = cache.object(forKey: id) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: scale, representationTypes: .all)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = representation.nsImage
        cache.setObject(image, forKey: id, cost: Int(side * side * scale * scale * 4))
        return image
    }

    private func key(_ url: URL, _ side: CGFloat) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(Int(side))|\(Int(modified))"
    }
}

// MARK: - Folder contents

struct FolderEntry: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let modified: Date
    let added: Date
    let size: Int64
    let kind: String
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum FolderListing {
    /// Reads one folder, newest or alphabetical as asked. Done off the main
    /// thread by the caller: opening something like Downloads can mean
    /// thousands of entries, and listing them on the main thread froze the dock.
    static func load(_ folder: URL, options: FolderOptions, limit: Int = 600) -> (entries: [FolderEntry], truncated: Bool) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .addedToDirectoryDateKey,
                                      .fileSizeKey, .localizedTypeDescriptionKey, .isPackageKey]
        let flags: FileManager.DirectoryEnumerationOptions = options.showsHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: flags) else {
            return ([], false)
        }
        var entries: [FolderEntry] = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? .distantPast
            return FolderEntry(url: url,
                               isDirectory: (values?.isDirectory ?? false) && !(values?.isPackage ?? false),
                               modified: modified,
                               added: values?.addedToDirectoryDate ?? modified,
                               size: Int64(values?.fileSize ?? 0),
                               kind: values?.localizedTypeDescription ?? "")
        }
        switch options.sort {
        case .name: entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateAdded: entries.sort { $0.added > $1.added }
        case .dateModified: entries.sort { $0.modified > $1.modified }
        case .kind: entries.sort { ($0.kind, $0.name.lowercased()) < ($1.kind, $1.name.lowercased()) }
        }
        let truncated = entries.count > limit
        return (Array(entries.prefix(limit)), truncated)
    }
}

// MARK: - Shared pieces

private struct FileThumb: View {
    let url: URL
    let side: CGFloat
    let wantsPreview: Bool
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? IconProvider.shared.icon(forPath: url.path, size: side))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .task(id: wantsPreview) {
                guard wantsPreview else { image = nil; return }
                if let cached = ThumbnailCache.shared.cached(url, side: side) { image = cached; return }
                image = await ThumbnailCache.shared.thumbnail(for: url, side: side, scale: NSScreen.main?.backingScaleFactor ?? 2)
            }
    }
}

private func quickLook(_ url: URL) {
    // `qlmanage -p` is the system's own Quick Look window; it exits when closed.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
    process.arguments = ["-p", url.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

// MARK: - Folder

/// What a pinned folder opens: Grid, List or Fan, sorted and filtered the way
/// that folder was set up.
struct FolderBrowserView: View {
    let folderURL: URL
    @State var options: FolderOptions
    let onOptionsChange: (FolderOptions) -> Void
    let onOpen: (URL) -> Void

    @State private var entries: [FolderEntry] = []
    @State private var truncated = false
    @State private var selection: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: options.layout == .fan ? 280 : 340, height: options.layout == .fan ? min(max(CGFloat(entries.prefix(12).count) * 40 + 80, 140), 560) : 340)
        .task(id: options) { await reload() }
        .focusable()
        .onKeyPress(.space) {
            if let selection { quickLook(selection); return .handled }
            return .ignored
        }
    }

    private func reload() async {
        let folder = folderURL, current = options
        let result = await Task.detached(priority: .userInitiated) { FolderListing.load(folder, options: current) }.value
        entries = result.entries
        truncated = result.truncated
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(folderURL.lastPathComponent).font(.headline).lineLimit(1)
            Spacer()
            Picker("", selection: Binding(get: { options.layout }, set: { options.layout = $0; onOptionsChange(options) })) {
                ForEach(FolderLayout.allCases) { Image(systemName: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 96)
            Menu {
                Picker("Sort By", selection: Binding(get: { options.sort }, set: { options.sort = $0; onOptionsChange(options) })) {
                    ForEach(FolderSort.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                Toggle("Show Hidden Files", isOn: Binding(get: { options.showsHidden }, set: { options.showsHidden = $0; onOptionsChange(options) }))
                Toggle("Show Previews", isOn: Binding(get: { options.showsPreviews }, set: { options.showsPreviews = $0; onOptionsChange(options) }))
                Divider()
                Button("Open in Finder") { onOpen(folderURL) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        if entries.isEmpty {
            Text("This folder is empty.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch options.layout {
            case .grid: grid
            case .list: list
            case .fan: fan
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 14) {
                ForEach(entries) { entry in
                    VStack(spacing: 4) {
                        FileThumb(url: entry.url, side: 52, wantsPreview: options.showsPreviews && !entry.isDirectory)
                        Text(entry.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(width: 76)
                    .padding(.vertical, 4)
                    .background(selection == entry.url ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .onTapGesture(count: 2) { onOpen(entry.url) }
                    .onTapGesture { selection = entry.url }
                    .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
                    .contextMenu { menu(for: entry) }
                }
            }
            .padding(12)
            if truncated { moreNote }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        FileThumb(url: entry.url, side: 22, wantsPreview: options.showsPreviews && !entry.isDirectory)
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(entry.modified.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(selection == entry.url ? Color.accentColor.opacity(0.22) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onOpen(entry.url) }
                    .onTapGesture { selection = entry.url }
                    .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
                    .contextMenu { menu(for: entry) }
                }
            }
            if truncated { moreNote }
        }
    }

    /// Items fan out of the dock in a curve, newest nearest the icon — the
    /// classic stack look, with names.
    private var fan: some View {
        let shown = Array(entries.prefix(12))
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                    let t = CGFloat(index) / CGFloat(max(shown.count - 1, 1))
                    HStack(spacing: 10) {
                        FileThumb(url: entry.url, side: 32, wantsPreview: options.showsPreviews && !entry.isDirectory)
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .offset(x: sin(t * .pi / 2) * 46)
                    .rotationEffect(.degrees(Double(t) * -6), anchor: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(entry.url) }
                    .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
                    .contextMenu { menu(for: entry) }
                }
                if entries.count > shown.count {
                    Button("Show \(entries.count - shown.count) more in Finder") { onOpen(folderURL) }
                        .buttonStyle(.link).padding(.top, 4)
                }
            }
            .padding(12)
        }
    }

    private var moreNote: some View {
        Button("Showing the first \(entries.count) items — open in Finder for the rest") { onOpen(folderURL) }
            .buttonStyle(.link).font(.caption).padding(10)
    }

    @ViewBuilder private func menu(for entry: FolderEntry) -> some View {
        Button("Open") { onOpen(entry.url) }
        Button("Quick Look") { quickLook(entry.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    }
}

// MARK: - Tray

struct TrayPopoverView: View {
    let item: DockItem
    let onChange: (DockItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("File Tray", systemImage: "tray.full").font(.headline)
                Spacer()
                if !item.memberPaths.isEmpty {
                    Button("Empty") { var updated = item; updated.memberPaths.removeAll(); onChange(updated) }
                }
            }
            .padding(.horizontal, 14).padding(.top, 12)

            if item.memberPaths.isEmpty {
                Text("Drag files onto the tray tile to stage them here, then drag them back out wherever you need them.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 14).frame(width: 300, alignment: .leading)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 14) {
                        ForEach(item.memberPaths, id: \.self) { path in
                            let url = URL(fileURLWithPath: path)
                            VStack(spacing: 4) {
                                FileThumb(url: url, side: 48, wantsPreview: true)
                                Text(url.lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(width: 76)
                            // Dragging out is the point of a shelf.
                            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                            .onTapGesture { NSWorkspace.shared.open(url) }
                            .contextMenu {
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("Remove from Tray", role: .destructive) {
                                    var updated = item
                                    updated.memberPaths.removeAll { $0 == path }
                                    onChange(updated)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                .frame(width: 330, height: 260)
            }
        }
    }
}

// MARK: - Group

struct GroupPopoverView: View {
    let paths: [String]
    let onOpen: (URL) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 14) {
                ForEach(paths, id: \.self) { path in
                    VStack(spacing: 4) {
                        Image(nsImage: IconProvider.shared.icon(forPath: path, size: 48))
                            .resizable().aspectRatio(contentMode: .fit).frame(width: 48, height: 48)
                        Text(FileManager.default.displayName(atPath: path)).font(.caption2).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(width: 76)
                    .onTapGesture { onOpen(URL(fileURLWithPath: path)) }
                }
            }
            .padding(14)
        }
        .frame(width: 320, height: min(CGFloat((paths.count + 3) / 4) * 84 + 28, 300))
    }
}

// MARK: - Month calendar

struct CalendarPopoverView: View {
    @State private var month = Date()
    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Button("Today") { month = Date() }.buttonStyle(.borderless).font(.caption)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
            }
            let symbols = calendar.veryShortWeekdaySymbols
            let first = calendar.firstWeekday - 1
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols[(i + first) % 7]).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            let cells = days()
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let isToday = calendar.isDateInToday(day)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(size: 12, weight: isToday ? .bold : .regular, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .foregroundStyle(isToday ? Color.white : Color.primary)
                            .background(isToday ? Color.red : Color.clear, in: Circle())
                    } else {
                        Color.clear.frame(minHeight: 26)
                    }
                }
            }
            Button("Open Calendar") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
            }.buttonStyle(.link).font(.caption)
        }
        .padding(14)
        .frame(width: 250)
    }

    private func shift(_ by: Int) { month = calendar.date(byAdding: .month, value: by, to: month) ?? month }

    private func days() -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in range.indices { cells.append(calendar.date(byAdding: .day, value: offset, to: interval.start)) }
        return cells
    }
}

extension DockEdge {
    /// The popover edge that opens away from the screen edge the dock is on.
    var popoverEdge: NSRectEdge {
        switch self {
        case .bottom: return .maxY
        case .top: return .minY
        case .left: return .maxX
        case .right: return .minX
        }
    }
}
