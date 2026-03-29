import AppKit

/// A panel with a searchable table of calibration profiles.
/// Shows name, date, and lens info. Supports select, rename, and delete.
@MainActor
public final class CalibrationPickerPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    private var profiles: [CalibrationProfile] = []
    private var filtered: [CalibrationProfile] = []
    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private var onSelect: ((CalibrationProfile) -> Void)?
    private var onRename: ((CalibrationProfile) -> CalibrationProfile?)?
    private var onNewCalibration: (() -> Void)?
    private weak var library: CalibrationLibrary?

    public init(library: CalibrationLibrary,
                currentProfile: CalibrationProfile?,
                onSelect: @escaping (CalibrationProfile) -> Void,
                onRename: @escaping (CalibrationProfile) -> CalibrationProfile?,
                onNewCalibration: (() -> Void)? = nil) {
        self.library = library
        self.onSelect = onSelect
        self.onRename = onRename
        self.onNewCalibration = onNewCalibration
        let rect = NSRect(x: 0, y: 0, width: 680, height: 400)
        super.init(contentRect: rect,
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
        title = "Calibration Library"
        minSize = NSSize(width: 400, height: 250)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false

        let container = NSView(frame: rect)

        // Search field
        searchField.frame = NSRect(x: 8, y: rect.height - 34, width: rect.width - 16, height: 26)
        searchField.placeholderString = "Filter..."
        searchField.autoresizingMask = [.width, .minYMargin]
        searchField.target = self
        searchField.action = #selector(filterChanged)
        container.addSubview(searchField)

        // Table in scroll view
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 44, width: rect.width, height: rect.height - 82))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"
        nameCol.width = 400
        nameCol.minWidth = 120
        tableView.addTableColumn(nameCol)

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "Created"
        dateCol.width = 100
        dateCol.minWidth = 80
        tableView.addTableColumn(dateCol)

        let lensCol = NSTableColumn(identifier: .init("lens"))
        lensCol.title = "Lenses"
        lensCol.width = 140
        lensCol.minWidth = 80
        tableView.addTableColumn(lensCol)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        // Bottom button bar
        let btnBar = NSView(frame: NSRect(x: 0, y: 0, width: rect.width, height: 40))
        btnBar.autoresizingMask = [.width]

        let selectBtn = NSButton(frame: NSRect(x: rect.width - 90, y: 8, width: 82, height: 24))
        selectBtn.title = "Select"
        selectBtn.bezelStyle = .rounded
        selectBtn.keyEquivalent = "\r"
        selectBtn.target = self
        selectBtn.action = #selector(selectClicked)
        selectBtn.autoresizingMask = [.minXMargin]
        btnBar.addSubview(selectBtn)

        let renameBtn = NSButton(frame: NSRect(x: rect.width - 180, y: 8, width: 82, height: 24))
        renameBtn.title = "Rename"
        renameBtn.bezelStyle = .rounded
        renameBtn.target = self
        renameBtn.action = #selector(renameClicked)
        renameBtn.autoresizingMask = [.minXMargin]
        btnBar.addSubview(renameBtn)

        if onNewCalibration != nil {
            let newBtn = NSButton(frame: NSRect(x: 8, y: 8, width: 120, height: 24))
            newBtn.title = "New Calibration"
            newBtn.bezelStyle = .rounded
            newBtn.target = self
            newBtn.action = #selector(newCalibClicked)
            btnBar.addSubview(newBtn)
        }

        container.addSubview(btnBar)
        contentView = container

        reload()

        // Select current row
        if let current = currentProfile,
           let idx = filtered.firstIndex(where: { $0.url == current.url }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
    }

    private func reload() {
        profiles = library?.availableProfiles() ?? []
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.lowercased()
        if query.isEmpty {
            filtered = profiles
        } else {
            filtered = profiles.filter {
                $0.displayName.lowercased().contains(query) ||
                $0.lensInfo.lowercased().contains(query) ||
                $0.created.lowercased().contains(query)
            }
        }
        tableView.reloadData()
    }

    @objc private func filterChanged() {
        applyFilter()
    }

    @objc private func selectClicked() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        onSelect?(filtered[row])
        close()
    }

    @objc private func renameClicked() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        if let updated = onRename?(filtered[row]) {
            // Update in our list
            if let pi = profiles.firstIndex(where: { $0.url == filtered[row].url }) {
                profiles[pi] = updated
            }
            applyFilter()
            // Re-select
            if let newIdx = filtered.firstIndex(where: { $0.url == updated.url }) {
                tableView.selectRowIndexes(IndexSet(integer: newIdx), byExtendingSelection: false)
            }
        }
    }

    @objc private func newCalibClicked() {
        onNewCalibration?()
    }

    /// Refresh the list (call after calibration completes)
    public func refreshProfiles() {
        reload()
    }

    @objc private func tableDoubleClicked() {
        selectClicked()
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let p = filtered[row]
        let id = tableColumn?.identifier ?? .init("")
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        cell.font = .systemFont(ofSize: 12)

        switch id.rawValue {
        case "name":
            cell.stringValue = p.displayName
        case "date":
            // Show just the date portion
            let dateStr = String(p.created.prefix(10))
            cell.stringValue = dateStr
            cell.textColor = .secondaryLabelColor
        case "lens":
            cell.stringValue = p.lensInfo
            cell.textColor = .secondaryLabelColor
        default:
            break
        }
        return cell
    }
}
