//
//  App+ConfigWatch.swift
//  PHP Monitor
//
//  Created by Nico Verbruggen on 30/03/2021.
//  Copyright © 2023 Nico Verbruggen. All rights reserved.
//

import Foundation

extension App {

    func startWatcher(_ url: URL) {
        Log.perf("No watcher currently active...")
        self.watcher = PhpConfigWatcher(for: url)

        self.watcher.didChange = { url in
            Log.perf("Something has changed in: \(url)")

            // Check if the watcher has last updated the menu less than 0.75s ago
            let distance = self.watcher.lastUpdate?.distance(to: Date().timeIntervalSince1970)
            if distance == nil || distance != nil && distance! > 0.75 {
                Log.perf("Refreshing menu...")
                Task { @MainActor in MainMenu.shared.reloadPhpMonitorMenuInBackground() }
                self.watcher.lastUpdate = Date().timeIntervalSince1970
            }
        }
    }

    func handlePhpConfigWatcher(forceReload: Bool = false) {
        if ActiveFileSystem.shared is TestableFileSystem {
            Log.warn("FS watcher is disabled when using testable filesystem.")
            return
        }

        guard let install = PhpEnvironments.phpInstall else {
            Log.info("It appears as if no PHP installation is currently active.")
            Log.info("The FS watcher will be disabled until a PHP install is active.")
            return
        }

        let url = URL(fileURLWithPath: "\(Paths.etcPath)/php/\(install.version.short)")

        // Check whether the watcher exists and schedule on the main thread
        // if we don't consistently do this, the app will create duplicate watchers
        // due to timing issues, which creates retain cycles.
        Task { @MainActor in
            // Watcher needs to be created
            if self.watcher == nil {
                self.startWatcher(url)
            }

            // Watcher needs to be updated
            if self.watcher.url != url || forceReload {
                self.watcher.disable()
                self.watcher = nil
                Log.perf("Watcher has stopped watching files. Starting new one...")
                self.startWatcher(url)
            }
        }
    }

}
