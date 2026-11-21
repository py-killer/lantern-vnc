// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// A local, user-initiated server picker. It never authenticates to a server.
final class VNCDiscoveryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let scanner: VNCDiscovering
    private let networksProvider: () throws -> [LANNetwork]
    private let knownAlias: (String,UInt16) -> String?
    private var aliasServerID: String?
    private var networks: [LANNetwork] = []
    private var servers: [DiscoveredVNCServer] = []
    private var scanPort: UInt16 = 5900
    private let networkPicker = NSPopUpButton(frame:.zero,pullsDown:false)
    private let search = NSButton(title:"Search",target:nil,action:nil)
    private let table = NSTableView()
    private let message = NSTextField(wrappingLabelWithString:"")
    private let context = NSTextField(wrappingLabelWithString:"")
    private let progress = NSProgressIndicator()
    private let choose = NSButton(title:"Save Computer",target:nil,action:nil)
    private let alias = NSTextField(string:"")
    var chosenAlias: String? {
        let value=alias.stringValue.components(separatedBy:.controlCharacters).joined(separator:" ").trimmingCharacters(in:.whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(80))
    }
    private var selection: ((DiscoveredVNCServer,String?) -> Void)?
    var onClose: (() -> Void)?

    init(scanner: VNCDiscovering = VNCNetworkDiscovery(),
         networksProvider: @escaping () throws -> [LANNetwork] = { try VNCNetworkDiscovery.networks() },
         knownAlias: @escaping (String,UInt16) -> String? = { _,_ in nil }) {
        self.scanner = scanner; self.networksProvider = networksProvider; self.knownAlias=knownAlias
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:570,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        panel.title = "Find VNC Servers"; panel.isReleasedWhenClosed = false
        super.init(window:panel); buildUI()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { scanner.cancel() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString:"Find a computer on your network")
        title.font = .systemFont(ofSize:19,weight:.semibold)
        context.font = .systemFont(ofSize:13); context.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize:13); message.identifier = .init("discoveryStatus")
        networkPicker.identifier = .init("discoveryNetwork"); networkPicker.setAccessibilityLabel("Local network")
        networkPicker.target = self; networkPicker.action = #selector(networkChanged)
        search.target=self; search.action=#selector(startSearch); search.bezelStyle = .rounded; search.identifier = .init("discoverySearch")
        let options = NSStackView(views:[networkPicker,search]); options.spacing=10
        networkPicker.setContentHuggingPriority(.defaultLow,for:.horizontal)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let status = NSStackView(views:[progress,message]); status.alignment = .centerY; status.spacing=10
        for (id,title,width) in [("host","Server",390.0),("port","Port",90.0)] {
            let column=NSTableColumn(identifier:.init(id));column.title=title;column.width=width;table.addTableColumn(column)
        }
        table.headerView = NSTableHeaderView(); table.rowHeight=32; table.usesAlternatingRowBackgroundColors=true
        table.allowsMultipleSelection=false; table.allowsEmptySelection=true; table.delegate=self; table.dataSource=self
        table.identifier = .init("discoveryResults"); table.setAccessibilityLabel("Available VNC servers")
        table.target=self; table.doubleAction=#selector(useServer)
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;scroll.documentView=table
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:180).isActive=true
        let aliasLabel=NSTextField(labelWithString:"Confirm a name for this computer")
        aliasLabel.font = .systemFont(ofSize:13,weight:.medium)
        alias.placeholderString="For example, Office PC";alias.isEnabled=false;alias.font = .systemFont(ofSize:14)
        alias.identifier = .init("discoveryAlias");alias.setAccessibilityLabel("Computer alias")
        let nameRow=NSStackView(views:[aliasLabel,alias]);nameRow.orientation = .vertical;nameRow.alignment = .leading;nameRow.spacing=6
        alias.translatesAutoresizingMaskIntoConstraints=false;alias.widthAnchor.constraint(equalTo:nameRow.widthAnchor).isActive=true
        let cancel=NSButton(title:"Cancel",target:self,action:#selector(cancelSearch));cancel.bezelStyle = .rounded;cancel.keyEquivalent="\u{1b}";cancel.identifier = .init("discoveryCancel")
        choose.bezelStyle = .rounded;choose.target=self;choose.action=#selector(useServer);choose.isEnabled=false;choose.identifier = .init("discoveryUseServer");choose.keyEquivalent="\r"
        let spacer=NSView();spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let buttons=NSStackView(views:[spacer,cancel,choose]);buttons.spacing=10
        let stack=NSStackView(views:[title,context,options,status,scroll,nameRow,buttons]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=14;stack.translatesAutoresizingMaskIntoConstraints=false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:22),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-22),stack.topAnchor.constraint(equalTo:content.topAnchor,constant:22),stack.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-22)])
        for child in [context,options,status,scroll,nameRow,buttons] { child.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true }
    }
    /// Configures without starting network traffic, also useful for owned UI tests.
    func configure(port:UInt16,onSelect:@escaping (DiscoveredVNCServer)->Void) {
        configure(port:port,onSelect:{ server,_ in onSelect(server) })
    }
    func configure(port:UInt16,onSelect:@escaping (DiscoveredVNCServer,String?)->Void) {
        scanner.cancel(); scanPort=port; selection=onSelect; alias.stringValue=""; alias.isEnabled=false; aliasServerID=nil; servers=[];table.reloadData();choose.isEnabled=false
        networkPicker.removeAllItems();progress.stopAnimation(nil)
        do {
            networks = try networksProvider()
            for network in networks { networkPicker.addItem(withTitle:network.displayName) }
            search.isEnabled = !networks.isEmpty;networkPicker.isEnabled = !networks.isEmpty
            context.stringValue="Save a discovered VNC computer with a name you recognize."
            if networks.isEmpty {
                message.stringValue="No supported local IPv4 network was found. Connect to Wi-Fi or Ethernet, or enter a server address manually."
            } else { updateContext(); message.stringValue="Ready to search your local network." }
        } catch {
            networks=[];search.isEnabled=false;networkPicker.isEnabled=false
            message.stringValue="Couldn’t read the local network. You can still enter the server address manually."
        }
    }
    func present(on parent:NSWindow,port:UInt16,onSelect:@escaping (DiscoveredVNCServer,String?)->Void) {
        configure(port:port,onSelect:onSelect)
        guard let window=window else { return }
        parent.beginSheet(window)
        if !networks.isEmpty { startSearch() }
    }
    private func updateContext() {
        guard networks.indices.contains(networkPicker.indexOfSelectedItem) else { return }
        let network=networks[networkPicker.indexOfSelectedItem]
        let area=network.isLimitedToLocalNeighborhood ? "the local neighborhood of this larger network" : "this local network"
        context.stringValue="Searches \(area) on port \(scanPort). VNC servers on another port or a VPN may need a manual address."
    }
    @objc private func networkChanged() {
        scanner.cancel();progress.stopAnimation(nil);servers=[];alias.stringValue="";alias.isEnabled=false;aliasServerID=nil;table.reloadData();choose.isEnabled=false
        updateContext();message.stringValue="Ready to search this network.";search.title="Search"
    }
    @objc func startSearch() {
        guard networks.indices.contains(networkPicker.indexOfSelectedItem) else { return }
        scanner.cancel();servers=[];alias.stringValue="";alias.isEnabled=false;aliasServerID=nil;table.reloadData();choose.isEnabled=false;progress.startAnimation(nil);search.title="Search Again"
        message.stringValue="Looking for VNC servers…"
        do {
            try scanner.scan(network:networks[networkPicker.indexOfSelectedItem],port:scanPort,onUpdate:{ [weak self] update in
                guard let self=self else { return }
                _ = self.replaceServers(update.servers,autoSelectSingle:false)
                self.message.stringValue="\(update.servers.count) found · \(update.completed) of \(update.total) addresses checked"
            },onComplete:{ [weak self] found in
                guard let self=self else { return }
                let automaticallySelected=self.replaceServers(found,autoSelectSingle:true)
                self.progress.stopAnimation(nil)
                if automaticallySelected {
                    self.window?.makeFirstResponder(self.alias);self.alias.selectText(nil)
                }
                self.message.stringValue=found.count == 1 ? "Found one VNC server. Confirm its name to add it to your devices." : found.isEmpty ? "No VNC servers found. Check that the server is running, the port is correct, and local-network access is allowed." : "\(found.count) VNC \(found.count==1 ? "server" : "servers") found. Select one to connect."
            })
        } catch {
            progress.stopAnimation(nil);message.stringValue="Couldn’t start the search. Check your local network or enter the address manually."
        }
    }
    /// Reloading a sorted result list must keep the chosen host and edited name.
    @discardableResult private func replaceServers(_ found:[DiscoveredVNCServer],autoSelectSingle:Bool)->Bool {
        let selectedID=servers.indices.contains(table.selectedRow) ? servers[table.selectedRow].id : nil
        let editedName=alias.stringValue
        servers=found;table.reloadData()
        if let selectedID=selectedID,let row=found.firstIndex(where:{$0.id==selectedID}) {
            table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
            updateSelection();alias.stringValue=editedName
            return false
        }
        if autoSelectSingle,found.count == 1 {
            table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
            updateSelection();return true
        }
        table.deselectAll(nil);updateSelection();return false
    }
    func numberOfRows(in tableView:NSTableView)->Int { servers.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard servers.indices.contains(row) else { return nil }
        let server=servers[row]
        let label=knownAlias(server.host,server.port).map { "\($0) · \(server.host)" } ?? server.host
        let text=NSTextField(labelWithString:tableColumn?.identifier.rawValue == "port" ? String(server.port) : label)
        text.font = .monospacedSystemFont(ofSize:14,weight:.regular);return text
    }
    func tableViewSelectionDidChange(_ notification:Notification) { updateSelection() }
    private func updateSelection() {
        let selected=servers.indices.contains(table.selectedRow)
        choose.isEnabled=selected;alias.isEnabled=selected
        if selected {
            let server=servers[table.selectedRow]
            if aliasServerID != server.id {
                aliasServerID=server.id;alias.stringValue=knownAlias(server.host,server.port) ?? "VNC computer"
            }
        } else { aliasServerID=nil;alias.stringValue="" }
    }
    @objc private func useServer() {
        guard servers.indices.contains(table.selectedRow) else { return }
        guard let name=chosenAlias else {
            message.stringValue="Enter a name for this computer, such as Office PC."
            window?.makeFirstResponder(alias);return
        }
        let result=servers[table.selectedRow];let callback=selection;dismiss();callback?(result,name)
    }
    @objc private func cancelSearch() { dismiss() }
    func dismiss() {
        scanner.cancel();progress.stopAnimation(nil)
        if let window=window { window.sheetParent?.endSheet(window);window.orderOut(nil) }
        selection=nil;onClose?()
    }
}
