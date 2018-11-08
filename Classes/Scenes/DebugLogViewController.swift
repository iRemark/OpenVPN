//
//  DebugLogViewController.swift
//  Passepartout-iOS
//
//  Created by Davide De Rosa on 6/12/18.
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
import SwiftyBeaver

private let log = SwiftyBeaver.self

class DebugLogViewController: UIViewController {
    @IBOutlet private weak var textLog: UITextView!
    
    private let vpn = VPN.shared
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        applyDetailTitle(Theme.current)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.Service.Cells.DebugLog.caption
        textLog.contentInsetAdjustmentBehavior = .never

        NotificationCenter.default.addObserver(self, selector: #selector(vpnDidPrepare), name: .VPNDidPrepare, object: nil)
        if vpn.isPrepared {
            startRefreshingLog()
        }
    }
    
    @IBAction private func share(_ sender: Any?) {
        guard let raw = textLog.text, !raw.isEmpty else {
            let alert = Macros.alert(title, L10n.DebugLog.Alerts.EmptyLog.message)
            alert.addCancelAction(L10n.Global.ok)
            present(alert, animated: true, completion: nil)
            return
        }
        let data = DebugLog(raw: raw).decoratedData()

        let path = NSTemporaryDirectory().appending(AppConstants.IssueReporter.Filenames.debugLog)
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url)
        } catch let e {
            log.error("Failed saving temporary debug log file: \(e)")
            return
        }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.barButtonItem = sender as? UIBarButtonItem
        vc.completionWithItemsHandler = { (type, completed, items, error) in
            try? FileManager.default.removeItem(at: url)
        }
        present(vc, animated: true, completion: nil)
    }
    
    @IBAction private func previousSession() {
        textLog.findPrevious(string: GroupConstants.VPN.sessionMarker)
    }
    
    @IBAction private func nextSession() {
        textLog.findNext(string: GroupConstants.VPN.sessionMarker)
    }
    
    private func startRefreshingLog() {
        vpn.requestDebugLog(fallback: AppConstants.Log.debugSnapshot) {
            self.textLog.text = $0
            
            DispatchQueue.main.async {
                self.textLog.scrollToEnd()
                self.refreshLogInBackground()
            }
        }
    }

    private func refreshLogInBackground() {
        let updateBlock = {
            DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.Log.viewerRefreshInterval) { [weak self] in
                self?.refreshLogInBackground()
            }
        }

        // only update if screen is visible
        guard let _ = viewIfLoaded?.window else {
            updateBlock()
            return
        }

        vpn.requestDebugLog(fallback: AppConstants.Log.debugSnapshot) {
            self.textLog.text = $0
            updateBlock()
        }
    }
    
    // MARK: Notifications
    
    @objc private func vpnDidPrepare() {
        startRefreshingLog()
    }
}
