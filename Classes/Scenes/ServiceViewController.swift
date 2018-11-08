//
//  ServiceViewController.swift
//  Passepartout-iOS
//
//  Created by Davide De Rosa on 6/6/18.
//  Copyright (c) 2018 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Passepartout.
//
//  Passepartout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Passepartout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Passepartout.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit
import NetworkExtension
import CoreTelephony
import TunnelKit

class ServiceViewController: UIViewController, TableModelHost {
    @IBOutlet private weak var tableView: UITableView!

    @IBOutlet private weak var viewWelcome: UIView!

    @IBOutlet private weak var labelWelcome: UILabel!
    
    @IBOutlet private weak var itemEdit: UIBarButtonItem!
    
    var profile: ConnectionProfile? {
        didSet {
            title = profile?.id
            navigationItem.rightBarButtonItem = (profile?.context == .host) ? itemEdit : nil
            reloadModel()
            updateViewsIfNeeded()
        }
    }

    private let service = TransientStore.shared.service
    
    private lazy var vpn = GracefulVPN(service: service)

    private weak var pendingRenameAction: UIAlertAction?

    private var lastInfrastructureUpdate: Date?
    
    // MARK: Table
    
    var model: TableModel<SectionType, RowType> = TableModel()
    
    private let trustedNetworks = TrustedNetworksModel()
    
    // MARK: UIViewController

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
        
        applyDetailTitle(Theme.current)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // fall back to active profile
        if profile == nil {
            profile = service.activeProfile
        }
        if let providerProfile = profile as? ProviderConnectionProfile {
            lastInfrastructureUpdate = InfrastructureFactory.shared.modificationDate(for: providerProfile.name)
        }

        title = profile?.id
        navigationItem.leftBarButtonItem = splitViewController?.displayModeButtonItem
        navigationItem.leftItemsSupplementBackButton = true

        labelWelcome.text = L10n.Service.Welcome.message
        labelWelcome.apply(Theme.current)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(vpnDidUpdate), name: .VPNDidChangeStatus, object: nil)
        nc.addObserver(self, selector: #selector(vpnDidUpdate), name: .VPNDidReinstall, object: nil)

        // run this no matter what
        // XXX: convenient here vs AppDelegate for updating table
        vpn.prepare(withProfile: profile) {
            self.reloadModel()
            self.tableView.reloadData()
        }

        updateViewsIfNeeded()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        hideProfileIfDeleted()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        clearSelection()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        guard let sid = segue.identifier, let segueType = StoryboardSegue.Main(rawValue: sid) else {
            return
        }
        
        let destination = segue.destination
        
        switch segueType {
        case .accountSegueIdentifier:
            let vc = destination as? AccountViewController
            vc?.currentCredentials = service.credentials(for: uncheckedProfile)
            vc?.usernamePlaceholder = (profile as? ProviderConnectionProfile)?.infrastructure.defaults.username
            vc?.infrastructureName = (profile as? ProviderConnectionProfile)?.infrastructure.name
            vc?.delegate = self
            
        case .providerPoolSegueIdentifier:
            let vc = destination as? ProviderPoolViewController
            vc?.pools = uncheckedProviderProfile.sortedPools()
            vc?.currentPoolId = uncheckedProviderProfile.poolId
            vc?.delegate = self
            
        case .endpointSegueIdentifier:
            let vc = destination as? EndpointViewController
            vc?.dataSource = profile
            vc?.delegate = self
            vc?.modificationDelegate = self
            
        case .providerPresetSegueIdentifier:
            let vc = destination as? ProviderPresetViewController
            vc?.presets = uncheckedProviderProfile.infrastructure.presets
            vc?.currentPresetId = uncheckedProviderProfile.presetId
            vc?.delegate = self
            
        case .hostParametersSegueIdentifier:
            let vc = destination as? ConfigurationViewController
            vc?.title = L10n.Service.Cells.Host.Parameters.caption
            vc?.initialConfiguration = uncheckedHostProfile.parameters.sessionConfiguration
            vc?.originalConfigurationURL = service.configurationURL(for: uncheckedHostProfile)
            vc?.delegate = self
            
        case .debugLogSegueIdentifier:
            break
        }
    }
    
    // MARK: Actions
    
    func hideProfileIfDeleted() {
        guard let profile = profile else {
            return
        }
        if !service.containsProfile(profile) {
            self.profile = nil
        }
    }
    
    // XXX: outlets can be nil here!
    private func updateViewsIfNeeded() {
        tableView?.reloadData()
        viewWelcome?.isHidden = (profile != nil)
    }
    
    private func activateProfile() {
        service.activateProfile(uncheckedProfile)

        reloadModel()
        tableView.reloadData()

        vpn.disconnect(completionHandler: nil)
    }

    @IBAction private func renameProfile() {
        let alert = Macros.alert(L10n.Service.Alerts.Rename.title, L10n.Global.Host.TitleInput.message)
        alert.addTextField { (field) in
            field.text = self.profile?.id
            field.applyProfileId(Theme.current)
            field.delegate = self
        }
        pendingRenameAction = alert.addDefaultAction(L10n.Global.ok) {
            guard let newId = alert.textFields?.first?.text else {
                return
            }
            self.doRenameCurrentProfile(to: newId)
        }
        alert.addCancelAction(L10n.Global.cancel)
        pendingRenameAction?.isEnabled = false
        present(alert, animated: true, completion: nil)
    }
    
    private func doRenameCurrentProfile(to newId: String) {
        profile = service.renameProfile(uncheckedHostProfile, to: newId)
    }
    
    private func toggleVpnService(cell: ToggleTableViewCell) {
        if cell.isOn {
            guard !service.needsCredentials(for: uncheckedProfile) else {
                let alert = Macros.alert(
                    L10n.Service.Sections.Vpn.header,
                    L10n.Service.Alerts.CredentialsNeeded.message
                )
                alert.addCancelAction(L10n.Global.ok) {
                    cell.setOn(false, animated: true)
                }
                present(alert, animated: true, completion: nil)
                return
            }
            vpn.reconnect { (error) in
                guard error == nil else {
                    cell.setOn(false, animated: true)
                    return
                }
                self.reloadModel()
                self.tableView.reloadData()
            }
        } else {
            vpn.disconnect { (error) in
                self.reloadModel()
                self.tableView.reloadData()
            }
        }
    }
    
    private func confirmVpnReconnection() {
        guard vpn.status == .disconnected else {
            let alert = Macros.alert(
                L10n.Service.Cells.ConnectionStatus.caption,
                L10n.Service.Alerts.ReconnectVpn.message
            )
            alert.addDefaultAction(L10n.Global.ok) {
                self.vpn.reconnect(completionHandler: nil)
            }
            alert.addCancelAction(L10n.Global.cancel)
            present(alert, animated: true, completion: nil)
            return
        }
        vpn.reconnect(completionHandler: nil)
    }
    
    private func refreshProviderInfrastructure() {
        let hud = HUD()
        let isUpdating = InfrastructureFactory.shared.update(uncheckedProviderProfile.name, notBeforeInterval: AppConstants.Web.minimumUpdateInterval) { (response, error) in
            hud.hide()
            guard let response = response else {
                return
            }
            self.lastInfrastructureUpdate = response.1
            self.tableView.reloadData()
        }
        if !isUpdating {
            hud.hide()
        }
    }
    
    private func toggleDisconnectsOnSleep(_ isOn: Bool) {
        service.preferences.disconnectsOnSleep = !isOn
        if vpn.isEnabled {
            vpn.reinstall(completionHandler: nil)
        }
    }
    
    private func toggleResolvesHostname(_ isOn: Bool) {
        service.preferences.resolvesHostname = isOn
        if vpn.isEnabled {
            guard vpn.status == .disconnected else {
                confirmVpnReconnection()
                return
            }
            vpn.reinstall(completionHandler: nil)
        }
    }
    
    private func toggleTrustedConnectionPolicy(_ isOn: Bool, sender: ToggleTableViewCell) {
        let completionHandler: () -> Void = {
            self.service.preferences.trustPolicy = isOn ? .disconnect : .ignore
            if self.vpn.isEnabled {
                self.vpn.reinstall(completionHandler: nil)
            }
        }
        guard isOn else {
            completionHandler()
            return
        }
        guard vpn.isEnabled else {
            completionHandler()
            return
        }
        let alert = Macros.alert(
            L10n.Service.Sections.Trusted.header,
            L10n.Service.Alerts.Trusted.WillDisconnectPolicy.message
        )
        alert.addDefaultAction(L10n.Global.ok) {
            completionHandler()
        }
        alert.addCancelAction(L10n.Global.cancel) {
            sender.setOn(false, animated: true)
        }
        present(alert, animated: true, completion: nil)
    }
    
    private func confirmPotentialTrustedDisconnection(at rowIndex: Int?, completionHandler: @escaping () -> Void) {
        let alert = Macros.alert(
            L10n.Service.Sections.Trusted.header,
            L10n.Service.Alerts.Trusted.WillDisconnectTrusted.message
        )
        alert.addDefaultAction(L10n.Global.ok) {
            completionHandler()
        }
        alert.addCancelAction(L10n.Global.cancel) {
            guard let rowIndex = rowIndex else {
                return
            }
            let indexPath = IndexPath(row: rowIndex, section: self.trustedSectionIndex)
            let cell = self.tableView.cellForRow(at: indexPath) as? ToggleTableViewCell
            cell?.setOn(false, animated: true)
        }
        present(alert, animated: true, completion: nil)
    }
    
    private func testInternetConnectivity() {
        let hud = HUD()
        Utils.checkConnectivityURL(AppConstants.VPN.connectivityURL, timeout: AppConstants.VPN.connectivityTimeout) {
            hud.hide()

            let V = L10n.Service.Alerts.TestConnectivity.Messages.self
            let alert = Macros.alert(
                L10n.Service.Alerts.TestConnectivity.title,
                $0 ? V.success : V.failure
            )
            alert.addCancelAction(L10n.Global.ok)
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    private func displayDataCount() {
        guard vpn.isEnabled else {
            let alert = Macros.alert(
                L10n.Service.Cells.DataCount.caption,
                L10n.Service.Alerts.DataCount.Messages.notAvailable
            )
            alert.addCancelAction(L10n.Global.ok)
            present(alert, animated: true, completion: nil)
            return
        }

        vpn.requestBytesCount {
            let message: String
            if let count = $0 {
                message = L10n.Service.Alerts.DataCount.Messages.current(Int(count.0), Int(count.1))
            } else {
                message = L10n.Service.Alerts.DataCount.Messages.notAvailable
            }
            let alert = Macros.alert(
                L10n.Service.Cells.DataCount.caption,
                message
            )
            alert.addCancelAction(L10n.Global.ok)
            self.present(alert, animated: true, completion: nil)
        }
    }

    private func postSupportRequest() {
        UIApplication.shared.open(AppConstants.URLs.subreddit, options: [:], completionHandler: nil)
    }

    private func reportConnectivityIssue() {
        let attach = IssueReporter.Attachments(debugLog: true, profile: uncheckedProfile)
        IssueReporter.shared.present(in: self, withAttachments: attach)
    }
    
    // MARK: Notifications
    
    @objc private func vpnDidUpdate() {
        reloadVpnStatus()
    }
    
    @objc private func applicationDidBecomeActive() {
        reloadVpnStatus()
    }
}

// MARK: -

extension ServiceViewController: UITableViewDataSource, UITableViewDelegate, ToggleTableViewCellDelegate {
    enum SectionType {
        case vpn
        
        case authentication
        
        case hostProfile
        
        case configuration
        
        case providerInfrastructure
        
        case vpnResolvesHostname
        
        case vpnSurvivesSleep
        
        case trusted
        
        case trustedPolicy
        
        case diagnostics
        
        case feedback
    }
    
    enum RowType: Int {
        case useProfile
        
        case vpnService
        
        case connectionStatus
        
        case reconnect

        case account
        
        case endpoint
        
        case providerPool
        
        case providerPreset
        
        case providerRefresh
        
        case hostParameters
        
        case vpnResolvesHostname
        
        case vpnSurvivesSleep
        
        case trustedMobile
        
        case trustedWiFi
        
        case trustedAddCurrentWiFi
        
        case trustedPolicy
        
        case testConnectivity
        
        case dataCount
        
        case debugLog
        
        case joinCommunity
        
        case reportIssue
    }

    private var trustedSectionIndex: Int {
        return model.index(ofSection: .trusted)
    }
    
    private var serviceIndexPath: IndexPath {
        guard let ip = model.indexPath(row: .vpnService, section: .vpn) else {
            fatalError("Could not locate serviceIndexPath")
        }
        return ip
    }
    
    private var statusIndexPath: IndexPath {
        guard let ip = model.indexPath(row: .connectionStatus, section: .vpn) else {
            fatalError("Could not locate statusIndexPath")
        }
        return ip
    }
    
    private var endpointIndexPath: IndexPath {
        guard let ip = model.indexPath(row: .endpoint, section: .configuration) else {
            fatalError("Could not locate endpointIndexPath")
        }
        return ip
    }
    
    private var providerPresetIndexPath: IndexPath {
        guard let ip = model.indexPath(row: .providerPreset, section: .configuration) else {
            fatalError("Could not locate providerPresetIndexPath")
        }
        return ip
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return model.count
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return model.header(for: section)
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard let title = model.header(for: section) else {
            return 1.0
        }
        guard !title.isEmpty else {
            return 0.0
        }
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let rows = model.rows(for: section)
        if rows.contains(.providerRefresh), let date = lastInfrastructureUpdate {
            return L10n.Service.Sections.ProviderInfrastructure.footer(date.timestamp)
        }
        return model.footer(for: section)
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return model.count(for: section)
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = model.row(at: indexPath)
        switch row {
        case .useProfile:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.applyAction(Theme.current)
            cell.leftText = L10n.Service.Cells.UseProfile.caption
            return cell
            
        case .vpnService:
            guard service.isActiveProfile(uncheckedProfile) else {
                fatalError("Do not show vpnService in non-active profile")
            }

            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.Service.Cells.VpnService.caption
            cell.isOn = vpn.isEnabled
            return cell
            
        case .connectionStatus:
            guard service.isActiveProfile(uncheckedProfile) else {
                fatalError("Do not show connectionStatus in non-active profile")
            }
            
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.applyVPN(Theme.current, with: vpn.isEnabled ? vpn.status : nil, error: service.vpnLastError)
            cell.leftText = L10n.Service.Cells.ConnectionStatus.caption
            cell.accessoryType = .none
            cell.isTappable = false
            return cell
            
        case .reconnect:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.applyAction(Theme.current)
            cell.leftText = L10n.Service.Cells.Reconnect.caption
            cell.accessoryType = .none
            cell.isTappable = !service.needsCredentials(for: uncheckedProfile) && vpn.isEnabled
            return cell

        // shared cells
            
        case .account:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Service.Cells.Account.caption
            cell.rightText = profile?.username
            return cell

        case .endpoint:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Service.Cells.Endpoint.caption

            let V = L10n.Service.Cells.Endpoint.Value.self
            if let provider = profile as? ProviderConnectionProfile {
                cell.rightText = provider.usesProviderEndpoint ? V.manual : V.automatic
            } else {
                cell.rightText = profile?.mainAddress
            }
            return cell
            
        // provider cells
            
        case .providerPool:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Service.Cells.Provider.Pool.caption
            cell.rightText = uncheckedProviderProfile.pool?.name
            return cell
            
        case .providerPreset:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Service.Cells.Provider.Preset.caption
            cell.rightText = uncheckedProviderProfile.preset?.name // XXX: localize?
            return cell
            
        case .providerRefresh:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.applyAction(Theme.current)
            cell.leftText = L10n.Service.Cells.Provider.Refresh.caption
            return cell
            
        // host cells
            
        case .hostParameters:
            let parameters = uncheckedHostProfile.parameters
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Service.Cells.Host.Parameters.caption
            let V = L10n.Service.Cells.Host.Parameters.Value.self
            if !parameters.sessionConfiguration.cipher.embedsDigest {
                cell.rightText = V.cipherDigest(parameters.sessionConfiguration.cipher.genericName, parameters.sessionConfiguration.digest.genericName)
            } else {
                cell.rightText = V.cipher(parameters.sessionConfiguration.cipher.genericName)
            }
            return cell

        // VPN preferences
            
        case .vpnResolvesHostname:
            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.Service.Cells.VpnResolvesHostname.caption
            cell.isOn = service.preferences.resolvesHostname
            return cell
            
        case .vpnSurvivesSleep:
            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.Service.Cells.VpnSurvivesSleep.caption
            cell.isOn = !service.preferences.disconnectsOnSleep
            return cell
            
        case .trustedMobile:
            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.Service.Cells.TrustedMobile.caption
            cell.isOn = service.preferences.trustsMobileNetwork
            return cell
            
        case .trustedWiFi:
            let wifi = trustedNetworks.wifi(at: indexPath.row)
            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.Service.Cells.TrustedWifi.caption(wifi.0)
            cell.isOn = wifi.1
            return cell
            
        case .trustedAddCurrentWiFi:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.applyAction(Theme.current)
            cell.leftText = L10n.Service.Cells.TrustedAddWifi.caption
            return cell

        case .trustedPolicy:
            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.Service.Cells.TrustedPolicy.caption
            cell.isOn = (service.preferences.trustPolicy == .disconnect)
            return cell
            
        // diagnostics
            
        case .testConnectivity:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Service.Cells.TestConnectivity.caption
            return cell

        case .dataCount:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Service.Cells.DataCount.caption
            return cell

        case .debugLog:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Service.Cells.DebugLog.caption
            return cell
            
        // feedback

        case .joinCommunity:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.About.Cells.JoinCommunity.caption
            return cell
            
        case .reportIssue:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Service.Cells.ReportIssue.caption
            return cell
        }
    }
    
//    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
//        cell.isSelected = (indexPath == lastSelectedIndexPath)
//    }
    
    // MARK: Actions
    
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let cell = tableView.cellForRow(at: indexPath) else {
            return nil
        }
        if let settingCell = cell as? SettingTableViewCell {
            guard settingCell.isTappable else {
                return nil
            }
        }
        guard handle(row: model.row(at: indexPath), cell: cell) else {
            return nil
        }
        return indexPath
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return model.row(at: indexPath) == .trustedWiFi
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        precondition(indexPath.section == model.index(ofSection: .trusted))
        trustedNetworks.removeWifi(at: indexPath.row)
    }
    
    func toggleCell(_ cell: ToggleTableViewCell, didToggleToValue value: Bool) {
        guard let item = RowType(rawValue: cell.tag) else {
            return
        }
        handle(row: item, cell: cell)
    }

    // true if enters subscreen
    private func handle(row: RowType, cell: UITableViewCell) -> Bool {
        switch row {
        case .useProfile:
            activateProfile()
            
        case .reconnect:
            confirmVpnReconnection()
            
        case .account:
            perform(segue: StoryboardSegue.Main.accountSegueIdentifier, sender: cell)
            return true
            
        case .endpoint:
            perform(segue: StoryboardSegue.Main.endpointSegueIdentifier, sender: cell)
            return true
            
        case .providerPool:
            perform(segue: StoryboardSegue.Main.providerPoolSegueIdentifier, sender: cell)
            return true

        case .providerPreset:
            perform(segue: StoryboardSegue.Main.providerPresetSegueIdentifier, sender: cell)
            return true
            
        case .providerRefresh:
            refreshProviderInfrastructure()
            return false
            
        case .hostParameters:
            perform(segue: StoryboardSegue.Main.hostParametersSegueIdentifier, sender: cell)
            return true
            
        case .trustedAddCurrentWiFi:
            guard trustedNetworks.addCurrentWifi() else {
                let alert = Macros.alert(
                    L10n.Service.Sections.Trusted.header,
                    L10n.Service.Alerts.Trusted.NoNetwork.message
                )
                alert.addCancelAction(L10n.Global.ok)
                present(alert, animated: true, completion: nil)
                return false
            }
            
        case .testConnectivity:
            testInternetConnectivity()
            
        case .dataCount:
            displayDataCount()

        case .debugLog:
            perform(segue: StoryboardSegue.Main.debugLogSegueIdentifier, sender: cell)
            return true
            
        case .joinCommunity:
            postSupportRequest()
            
        case .reportIssue:
            reportConnectivityIssue()
            
        default:
            break
        }
        return false
    }
    
    private func handle(row: RowType, cell: ToggleTableViewCell) {
        switch row {
        case .vpnService:
            toggleVpnService(cell: cell)
            
        case .vpnResolvesHostname:
            toggleResolvesHostname(cell.isOn)
            
        case .vpnSurvivesSleep:
            toggleDisconnectsOnSleep(cell.isOn)
            
        case .trustedMobile:
            trustedNetworks.setMobile(cell.isOn)
            
        case .trustedWiFi:
            guard let indexPath = tableView.indexPath(for: cell) else {
                return
            }
            if cell.isOn {
                trustedNetworks.enableWifi(at: indexPath.row)
            } else {
                trustedNetworks.disableWifi(at: indexPath.row)
            }
            
        case .trustedPolicy:
            toggleTrustedConnectionPolicy(cell.isOn, sender: cell)
            
        default:
            break
        }
    }
    
    // MARK: Updates

    func reloadModel() {
        model.clear()
        
        guard let profile = profile else {
            return
        }
//        assert(profile != nil, "Profile not set")
        
        let isActiveProfile = service.isActiveProfile(profile)
        let isProvider = (profile as? ProviderConnectionProfile) != nil
        
        // sections
        model.add(.vpn)
        if isProvider {
            model.add(.authentication)
        }
        model.add(.configuration)
        if isProvider {
            model.add(.providerInfrastructure)
        }
        if isActiveProfile {
            if isProvider {
                model.add(.vpnResolvesHostname)
            }
            model.add(.vpnSurvivesSleep)
            model.add(.trusted)
            model.add(.trustedPolicy)
            model.add(.diagnostics)
            model.add(.feedback)
        }

        // headers
        model.setHeader(L10n.Service.Sections.Vpn.header, for: .vpn)
        if isProvider {
            model.setHeader(L10n.Service.Sections.Configuration.header, for: .authentication)
        } else {
            model.setHeader(L10n.Service.Sections.Configuration.header, for: .configuration)
        }
        if isActiveProfile {
            if isProvider {
                model.setHeader("", for: .vpnResolvesHostname)
                model.setHeader("", for: .vpnSurvivesSleep)
            }
            model.setHeader(L10n.Service.Sections.Trusted.header, for: .trusted)
            model.setHeader(L10n.Service.Sections.Diagnostics.header, for: .diagnostics)
            model.setHeader(L10n.About.Sections.Feedback.header, for: .feedback)
        }
        
        // footers
        if isActiveProfile {
            model.setFooter(L10n.Service.Sections.Vpn.footer, for: .vpn)
            if isProvider {
                model.setFooter(L10n.Service.Sections.VpnResolvesHostname.footer, for: .vpnResolvesHostname)
            }
            model.setFooter(L10n.Service.Sections.VpnSurvivesSleep.footer, for: .vpnSurvivesSleep)
            model.setFooter(L10n.Service.Sections.Trusted.footer, for: .trustedPolicy)
        }
        
        // rows
        if isActiveProfile {
            var rows: [RowType] = [.vpnService, .connectionStatus]
            if vpn.isEnabled {
                rows.append(.reconnect)
            }
            model.set(rows, in: .vpn)
        } else {
            model.set([.useProfile], in: .vpn)
        }
        if isProvider {
            model.set([.account], in: .authentication)
            model.set([.providerPool, .endpoint, .providerPreset], in: .configuration)
            model.set([.providerRefresh], in: .providerInfrastructure)
        } else {
            model.set([.account, .endpoint, .hostParameters], in: .configuration)
        }
        if isActiveProfile {
            if isProvider {
                model.set([.vpnResolvesHostname], in: .vpnResolvesHostname)
            }
            model.set([.vpnSurvivesSleep], in: .vpnSurvivesSleep)
            model.set([.trustedPolicy], in: .trustedPolicy)
            model.set([.dataCount, .debugLog], in: .diagnostics)
            model.set([.joinCommunity, .reportIssue], in: .feedback)
        }

        trustedNetworks.delegate = self
        trustedNetworks.load(from: service.preferences)
        model.set(trustedNetworks.rows, in: .trusted)
    }

    private func reloadVpnStatus() {
        guard let profile = profile else {
            return
        }
        guard service.isActiveProfile(profile) else {
            return
        }
        tableView.reloadRows(at: [statusIndexPath], with: .none)
    }
    
    func reloadSelectedRow(andRowAt indexPath: IndexPath? = nil) {
        guard let selectedIP = tableView.indexPathForSelectedRow else {
            return
        }
        var outdatedIPs = [selectedIP]
        if let otherIP = indexPath {
            outdatedIPs.append(otherIP)
        }
        tableView.reloadRows(at: outdatedIPs, with: .none)
        tableView.selectRow(at: selectedIP, animated: false, scrollPosition: .none)
    }

    func clearSelection() {
        guard let selected = tableView.indexPathForSelectedRow else {
            return
        }
        tableView.deselectRow(at: selected, animated: true)
    }
}

// MARK: -

extension ServiceViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard string.rangeOfCharacter(from: CharacterSet.filename.inverted) == nil else {
            return false
        }
        if let text = textField.text {
            let replacement = (text as NSString).replacingCharacters(in: range, with: string)
            pendingRenameAction?.isEnabled = (replacement != uncheckedProfile.id)
        }
        return true
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        return true
    }
}

// MARK: -

extension ServiceViewController: TrustedNetworksModelDelegate {
    func trustedNetworksCouldDisconnect(_: TrustedNetworksModel) -> Bool {
        return (service.preferences.trustPolicy == .disconnect) && (vpn.status != .disconnected)
    }
    
    func trustedNetworksShouldConfirmDisconnection(_: TrustedNetworksModel, triggeredAt rowIndex: Int, completionHandler: @escaping () -> Void) {
        confirmPotentialTrustedDisconnection(at: rowIndex, completionHandler: completionHandler)
    }
    
    func trustedNetworks(_: TrustedNetworksModel, shouldInsertWifiAt rowIndex: Int) {
        model.set(trustedNetworks.rows, in: .trusted)
        tableView.insertRows(at: [IndexPath(row: rowIndex, section: trustedSectionIndex)], with: .bottom)
    }
    
    func trustedNetworks(_: TrustedNetworksModel, shouldReloadWifiAt rowIndex: Int, isTrusted: Bool) {
        let genericCell = tableView.cellForRow(at: IndexPath(row: rowIndex, section: trustedSectionIndex))
        guard let cell = genericCell as? ToggleTableViewCell else {
            fatalError("Not a trusted Wi-Fi cell (\(type(of: genericCell)) != ToggleTableViewCell)")
        }
        guard isTrusted != cell.isOn else {
            return
        }
        cell.setOn(isTrusted, animated: true)
    }
    
    func trustedNetworks(_: TrustedNetworksModel, shouldDeleteWifiAt rowIndex: Int) {
        model.set(trustedNetworks.rows, in: .trusted)
        tableView.deleteRows(at: [IndexPath(row: rowIndex, section: trustedSectionIndex)], with: .top)
    }
    
    func trustedNetworksShouldReinstall(_: TrustedNetworksModel) {
        service.preferences.trustsMobileNetwork = trustedNetworks.trustsMobileNetwork
        service.preferences.trustedWifis = trustedNetworks.trustedWifis
        if vpn.isEnabled {
            vpn.reinstall(completionHandler: nil)
        }
    }
}

// MARK: -

extension ServiceViewController: ConfigurationModificationDelegate {
    func configuration(didUpdate newConfiguration: SessionProxy.Configuration) {
        if let hostProfile = profile as? HostConnectionProfile {
            var builder = hostProfile.parameters.builder()
            builder.sessionConfiguration = newConfiguration
            hostProfile.parameters = builder.build()
        }
        reloadSelectedRow()
    }
    
    func configurationShouldReinstall() {
        vpn.reinstallIfEnabled()
    }
}

extension ServiceViewController: AccountViewControllerDelegate {
    func accountController(_ vc: AccountViewController, didEnterCredentials credentials: Credentials) {
    }
    
    func accountControllerDidComplete(_ accountVC: AccountViewController) {
        navigationController?.popViewController(animated: true)

        let credentials = accountVC.credentials
        guard credentials != service.credentials(for: uncheckedProfile) else {
            return
        }
        try? service.setCredentials(credentials, for: uncheckedProfile)
        reloadSelectedRow()
        vpn.reinstallIfEnabled()
    }
}

extension ServiceViewController: EndpointViewControllerDelegate {
    func endpointController(_: EndpointViewController, didUpdateWithNewAddress newAddress: String?, newProtocol: TunnelKitProvider.EndpointProtocol?) {
        if let providerProfile = profile as? ProviderConnectionProfile {
            providerProfile.manualAddress = newAddress
            providerProfile.manualProtocol = newProtocol
        }
        reloadSelectedRow()
    }
}

extension ServiceViewController: ProviderPoolViewControllerDelegate {
    func providerPoolController(_ vc: ProviderPoolViewController, didSelectPool pool: Pool) {
        navigationController?.popViewController(animated: true)

        guard pool.id != uncheckedProviderProfile.poolId else {
            return
        }
        uncheckedProviderProfile.poolId = pool.id
        reloadSelectedRow(andRowAt: endpointIndexPath)
        vpn.reinstallIfEnabled()
    }
}

extension ServiceViewController: ProviderPresetViewControllerDelegate {
    func providerPresetController(_: ProviderPresetViewController, didSelectPreset preset: InfrastructurePreset) {
        navigationController?.popViewController(animated: true)
        
        guard preset.id != uncheckedProviderProfile.presetId else {
            return
        }
        uncheckedProviderProfile.presetId = preset.id
        reloadSelectedRow(andRowAt: endpointIndexPath)
        vpn.reinstallIfEnabled()
    }
}

// MARK: -

private extension ServiceViewController {
    private var uncheckedProfile: ConnectionProfile {
        guard let profile = profile else {
            fatalError("Expected non-nil profile here")
        }
        return profile
    }

    private var uncheckedProviderProfile: ProviderConnectionProfile {
        guard let profile = profile as? ProviderConnectionProfile else {
            fatalError("Expected ProviderConnectionProfile (found: \(type(of: self.profile)))")
        }
        return profile
    }
    
    private var uncheckedHostProfile: HostConnectionProfile {
        guard let profile = profile as? HostConnectionProfile else {
            fatalError("Expected HostConnectionProfile (found: \(type(of: self.profile)))")
        }
        return profile
    }
}
