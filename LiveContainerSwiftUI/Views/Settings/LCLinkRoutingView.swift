//
//  LCLinkRoutingView.swift
//  LiveContainer
//
//  Choose which guest app opens incoming links (web pages, URL schemes, domains).
//  Rules are stored in the app group defaults under "LCLinkRoutingRules" and are
//  enforced by TweakLoader (UIKit+GuestHooks.m) inside guest processes.
//

import SwiftUI

struct LCLinkRule: Equatable {
    var web: Bool = false
    var schemes: [String] = []
    var domains: [String] = []
}

struct LCLinkRoutingView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @State private var rules: [String: LCLinkRule] = [:]
    @State private var loaded = false

    private var installedApps: [LCAppModel] {
        sharedModel.apps.filter { $0.appInfo.relativeBundlePath != nil }
    }

    private var webAppBinding: Binding<String> {
        Binding(
            get: { rules.first(where: { $0.value.web })?.key ?? "" },
            set: { newValue in
                for key in Array(rules.keys) {
                    rules[key]?.web = false
                }
                if !newValue.isEmpty {
                    var rule = rules[newValue] ?? LCLinkRule()
                    rule.web = true
                    rules[newValue] = rule
                }
                save()
            }
        )
    }

    var body: some View {
        List {
            Section {
                Picker(selection: webAppBinding) {
                    Text("Ask every time").tag("")
                    ForEach(installedApps, id: \.appInfo.relativeBundlePath) { app in
                        Text(app.displayName).tag(app.appInfo.relativeBundlePath ?? "")
                    }
                } label: {
                    Text("Open web links in")
                }
            } footer: {
                Text("http and https links go straight to this app instead of asking. This wins over \"Always Open URL in Current App\".")
            }

            Section {
                ForEach(installedApps, id: \.appInfo.relativeBundlePath) { app in
                    NavigationLink {
                        LCLinkRuleEditView(
                            title: app.displayName,
                            declaredSchemes: LCLinkRoutingView.declaredSchemes(for: app.appInfo),
                            rule: Binding(
                                get: { rules[app.appInfo.relativeBundlePath ?? ""] ?? LCLinkRule() },
                                set: { newValue in
                                    rules[app.appInfo.relativeBundlePath ?? ""] = newValue
                                    save()
                                }
                            )
                        )
                    } label: {
                        HStack {
                            Text(app.displayName)
                            Spacer()
                            Text(summary(for: app))
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                Text("Per-app rules")
            } footer: {
                Text("Give a URL scheme (x://, spotify://) or a domain (x.com) to a specific app.")
            }
        }
        .navigationTitle("Link Handling")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func summary(for app: LCAppModel) -> String {
        guard let key = app.appInfo.relativeBundlePath, let rule = rules[key] else { return "" }
        var parts: [String] = []
        if rule.web { parts.append("web") }
        if !rule.schemes.isEmpty {
            parts.append("\(rule.schemes.count) scheme\(rule.schemes.count == 1 ? "" : "s")")
        }
        if !rule.domains.isEmpty {
            parts.append("\(rule.domains.count) domain\(rule.domains.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let dict = LCUtils.appGroupUserDefault.dictionary(forKey: "LCLinkRoutingRules") as? [String: [String: Any]] else {
            return
        }
        var out: [String: LCLinkRule] = [:]
        for (key, value) in dict {
            var rule = LCLinkRule()
            rule.web = value["web"] as? Bool ?? false
            rule.schemes = value["schemes"] as? [String] ?? []
            rule.domains = value["domains"] as? [String] ?? []
            out[key] = rule
        }
        rules = out
    }

    private func save() {
        var dict: [String: [String: Any]] = [:]
        for (key, rule) in rules where rule.web || !rule.schemes.isEmpty || !rule.domains.isEmpty {
            dict[key] = ["web": rule.web, "schemes": rule.schemes, "domains": rule.domains]
        }
        LCUtils.appGroupUserDefault.set(dict, forKey: "LCLinkRoutingRules")
    }

    static func declaredSchemes(for appInfo: LCAppInfo) -> [String] {
        guard let plist = NSDictionary(contentsOfFile: appInfo.bundlePath() + "/Info.plist") else { return [] }
        let types = plist["CFBundleURLTypes"] as? [[String: Any]] ?? []
        var schemes: [String] = []
        for type in types {
            if let list = type["CFBundleURLSchemes"] as? [String] {
                schemes.append(contentsOf: list.map { $0.lowercased() })
            }
        }
        return Array(Set(schemes)).sorted()
    }
}

struct LCLinkRuleEditView: View {
    let title: String
    let declaredSchemes: [String]
    @Binding var rule: LCLinkRule
    @State private var domainText = ""

    var body: some View {
        Form {
            Section {
                Toggle("Open web links here", isOn: $rule.web)
            } footer: {
                Text("Pairs with the web link choice on the previous screen.")
            }

            if !declaredSchemes.isEmpty {
                Section {
                    ForEach(declaredSchemes, id: \.self) { scheme in
                        Toggle(scheme + "://", isOn: Binding(
                            get: { rule.schemes.contains(scheme) },
                            set: { on in
                                if on {
                                    if !rule.schemes.contains(scheme) { rule.schemes.append(scheme) }
                                } else {
                                    rule.schemes.removeAll { $0 == scheme }
                                }
                            }
                        ))
                    }
                } header: {
                    Text("URL schemes")
                }
            }

            Section {
                TextField("x.com, instagram.com", text: $domainText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(applyDomains)
                if !rule.domains.isEmpty {
                    Text(rule.domains.joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Domains")
            } footer: {
                Text("Comma separated. Subdomains match too (x.com covers www.x.com).")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { domainText = rule.domains.joined(separator: ", ") }
        .onDisappear(perform: applyDomains)
    }

    private func applyDomains() {
        rule.domains = domainText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}
