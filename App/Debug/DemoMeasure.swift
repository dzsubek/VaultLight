#if DEBUG
    import AppKit
    import VaultLightCore

    /// DEBUG-only measuring mode for spec 10: `-VLMeasure <absolute .json path>`. Drives the real panel controller,
    /// panel and views over generated, invented entries (no `bw`, no Keychain, no system clipboard), writes the
    /// timings, then stays idle with 1,000 items loaded so memory and CPU can be sampled from outside, and quits.
    @MainActor
    enum DemoMeasure {
        static func requestedFile() -> URL? {
            let arguments = CommandLine.arguments
            guard let flag = arguments.firstIndex(of: "-VLMeasure"), flag + 1 < arguments.count,
                arguments[flag + 1].hasPrefix("/")
            else { return nil }
            return URL(fileURLWithPath: arguments[flag + 1])
        }

        /// What a user types, one keystroke at a time.
        private static let typed = ["github", "aws console", "árvíz", "ghb", "server prod", "zzzz", "e", "tester@"]
        private static let idleTime = Duration.seconds(90)

        static func run(into file: URL) async {
            var report: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier]

            // Keystroke to updated, rendered results at 5,000 items.
            do {
                let controller = controller(itemCount: 5_000)
                await controller.open()
                var samples: [Double] = []
                for text in typed {
                    for length in 1...text.count {
                        let start = ContinuousClock.now
                        controller.queryText = String(text.prefix(length))
                        await controller.submitQuery()
                        controller.panel.displayIfNeeded()
                        samples.append(milliseconds(ContinuousClock.now - start))
                    }
                    controller.queryText = ""
                    await controller.submitQuery()
                }
                controller.close()
                report["keystroke_5000"] = summary(samples)
                report["keystroke_5000_samples_ms"] = samples.map { ($0 * 10).rounded() / 10 }
            }

            // Hotkey to visible panel at 1,000 items: the hotkey's own call, `toggle()`, until the panel is on
            // screen and drawn. The first open is the cold one; the panel is created once and reused (spec 4.2).
            let controller = controller(itemCount: 1_000)
            var opens: [Double] = []
            for _ in 0..<21 {
                let start = ContinuousClock.now
                controller.toggle()
                while !controller.panel.isVisible { await Task.yield() }
                controller.panel.displayIfNeeded()
                opens.append(milliseconds(ContinuousClock.now - start))
                try? await Task.sleep(for: .milliseconds(150))
                controller.close()
                try? await Task.sleep(for: .milliseconds(150))
            }
            report["open_1000_cold_ms"] = opens.first
            report["open_1000_warm"] = summary(Array(opens.dropFirst()))

            report["idle_from"] = Date().timeIntervalSince1970
            report["idle_seconds"] = idleTime.components.seconds
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: file)
            }
            // Idle, unlocked, 1,000 items, panel closed: sample memory and CPU now.
            try? await Task.sleep(for: idleTime)
            withExtendedLifetime(controller) {}
        }

        private static func controller(itemCount: Int) -> PanelController {
            let folders = (0..<5).map { VaultFolder(id: "f\($0)", name: "Folder \($0)") }
            let controller = PanelController(
                vault: DemoVault(entries: entries(count: itemCount), folders: folders),
                clipboard: ClipboardManager(pasteboard: DemoPasteboard()), session: nil,
                onboarding: OnboardingModel(backend: DemoOnboardingBackend()), openURL: { _ in })
            controller.showDemo(.unlocked)
            return controller
        }

        /// Deterministic invented entries with mixed names, usernames, hosts, folders and favorites.
        private static func entries(count: Int) -> [VaultEntry] {
            let words = [
                "GitHub", "GitLab", "AWS", "Console", "Árvíztűrő", "Bank", "Cloud", "Server", "Prod", "Staging",
                "Mail", "Router", "Docker", "Hub", "Netlify", "Postgres", "Hetzner", "Admin", "Office", "Wi-Fi",
            ]
            let tlds = ["com", "io", "net", "org", "example", "hu"]
            var seed: UInt64 = 0x5EED
            func next(_ bound: Int) -> Int {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((seed >> 33) % UInt64(bound))
            }
            return (0..<count).map { number in
                let name = (0..<(1 + next(3))).map { _ in words[next(words.count)] }.joined(separator: " ")
                let host = "\(words[next(words.count)].lowercased()).\(tlds[next(tlds.count)])"
                return VaultEntry(
                    id: "item-\(number)", name: "\(name) \(number)", username: "user\(next(500))@example.com",
                    uris: ["https://login.\(host)/path"], folderId: next(3) == 0 ? "f\(next(5))" : nil,
                    favorite: next(20) == 0, hasTOTP: next(4) == 0)
            }
        }

        private static func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }

        private static func summary(_ samples: [Double]) -> [String: Double] {
            let sorted = samples.sorted()
            guard !sorted.isEmpty else { return [:] }
            return [
                "count": Double(sorted.count), "median_ms": sorted[sorted.count / 2],
                "p95_ms": sorted[min(sorted.count - 1, sorted.count * 95 / 100)], "max_ms": sorted[sorted.count - 1],
            ]
        }
    }
#endif
