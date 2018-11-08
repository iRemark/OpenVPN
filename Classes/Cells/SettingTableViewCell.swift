//
//  SettingTableViewCell.swift
//  Passepartout-iOS
//
//  Created by Davide De Rosa on 6/13/18.
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

extension Cells {
    static let setting = SettingTableViewCell.Provider()
}

class SettingTableViewCell: UITableViewCell {
    var isTappable: Bool = true {
        didSet {
            selectionStyle = isTappable ? .default : .none
        }
    }
    
    var leftText: String? {
        get {
            return textLabel?.text
        }
        set {
            textLabel?.text = newValue
        }
    }

    var leftTextColor: UIColor? {
        get {
            return textLabel?.textColor
        }
        set {
            textLabel?.textColor = newValue
        }
    }

    var rightText: String? {
        get {
            return detailTextLabel?.text
        }
        set {
            detailTextLabel?.text = newValue
        }
    }

    var rightTextColor: UIColor? {
        get {
            return detailTextLabel?.textColor
        }
        set {
            detailTextLabel?.textColor = newValue
        }
    }
}

extension SettingTableViewCell {
    class Provider: CellProvider {
        typealias T = SettingTableViewCell
        
        func dequeue(from tableView: UITableView, for indexPath: IndexPath) -> SettingTableViewCell {
            let cell = tableView.dequeue(T.self, identifier: Provider.identifier, for: indexPath)
            cell.apply(Theme.current)
            cell.rightText = nil
            cell.isTappable = true
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }
}
