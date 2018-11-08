//
//  AppDelegate.swift
//  VPN
//
//  Created by lichao on 2018/11/7.
//  Copyright © 2018 lichao. All rights reserved.
//

import UIKit


@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UISplitViewControllerDelegate {
    
    var window: UIWindow?
    
    override init() {
        AppConstants.Log.configure()
        super.init()
    }
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        InfrastructureFactory.shared.loadCache()
        Theme.current.applyAppearance()
        
        // Override point for customization after application launch.
        let splitViewController = window!.rootViewController as! UISplitViewController
        //        splitViewController.preferredPrimaryColumnWidthFraction = 0.4
        //        splitViewController.minimumPrimaryColumnWidth = 360.0
        splitViewController.maximumPrimaryColumnWidth = .infinity
        splitViewController.delegate = self
        if UI_USER_INTERFACE_IDIOM() == .pad {
            splitViewController.preferredDisplayMode = .allVisible
            //        } else {
            //            splitViewController.preferredDisplayMode = .primaryOverlay
        }
        
        return true
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
        TransientStore.shared.serialize(withProfiles: true) // synchronize
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }
    
    // MARK: UISplitViewControllerDelegate
    
    func splitViewController(_ splitViewController: UISplitViewController, collapseSecondary secondaryViewController: UIViewController, onto primaryViewController: UIViewController) -> Bool {
        return !TransientStore.shared.service.hasActiveProfile()
    }
    
    // MARK: URLs
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        guard let root = window?.rootViewController else {
            fatalError("No window.rootViewController?")
        }
        
        let topmost = root.presentedViewController ?? root
        
        let fm = FileManager.default
        guard let parsedFile = ParsedFile.from(url, withErrorAlertIn: topmost) else {
            try? fm.removeItem(at: url)
            return true
        }
        if let warning = parsedFile.warning {
            ParsedFile.alertImportWarning(url: url, in: topmost, withWarning: warning) {
                if $0 {
                    self.handleParsedFile(parsedFile, in: topmost)
                } else {
                    try? fm.removeItem(at: url)
                }
            }
            return true
        }
        handleParsedFile(parsedFile, in: topmost)
        return true
    }
    
    private func handleParsedFile(_ parsedFile: ParsedFile, in target: UIViewController) {
        
        // already presented: update parsed configuration
        if let nav = target as? UINavigationController, let wizard = nav.topViewController as? WizardHostViewController {
            if let oldURL = wizard.parsedFile?.url {
                try? FileManager.default.removeItem(at: oldURL)
            }
            wizard.parsedFile = parsedFile
            wizard.removesConfigurationOnCancel = true
            return
        }
        
        // present now
        let wizardNav = StoryboardScene.Organizer.wizardHostIdentifier.instantiate()
        guard let wizard = wizardNav.topViewController as? WizardHostViewController else {
            fatalError("Expected WizardHostViewController from storyboard")
        }
        wizard.parsedFile = parsedFile
        wizard.removesConfigurationOnCancel = true
        
        wizardNav.modalPresentationStyle = .formSheet
        target.present(wizardNav, animated: true, completion: nil)
    }
}

extension UISplitViewController {
    var serviceViewController: ServiceViewController? {
        for vc in viewControllers {
            guard let nav = vc as? UINavigationController else {
                continue
            }
            if let found = nav.viewControllers.first(where: {
                $0 as? ServiceViewController != nil
            }) as? ServiceViewController {
                return found
            }
        }
        return nil
    }
}
