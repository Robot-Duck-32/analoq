import Foundation

enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: .main, value: key, comment: "")
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: args)
    }

    static func pluralKey(_ base: String, count: Int) -> String {
        "\(base).\(count == 1 ? "one" : "other")"
    }
}
