import Testing
@testable import MacSweepCore

struct ToolbarPreferencesTests {
    private struct CardContract {
        let title: String
        let icon: String
        let key: String
    }

    @Test func preservesMenuBarVisibilityKey() {
        #expect(MenuBarPreferences.iconVisibleKey == "showMenuBarIcon")
    }

    @Test func preservesEveryCompanionCardContract() throws {
        let expected: [CompanionToolbarCard: CardContract] = [
            .storage: CardContract(
                title: "Macintosh HD",
                icon: "internaldrive",
                key: "companion.toolbar.card.storage.visible"
            ),
            .memory: CardContract(
                title: "Memory",
                icon: "memorychip",
                key: "companion.toolbar.card.memory.visible"
            ),
            .battery: CardContract(
                title: "Battery",
                icon: "battery.100",
                key: "companion.toolbar.card.battery.visible"
            ),
            .cpu: CardContract(
                title: "CPU",
                icon: "cpu",
                key: "companion.toolbar.card.cpu.visible"
            ),
            .network: CardContract(
                title: "Wi-Fi",
                icon: "wifi",
                key: "companion.toolbar.card.network.visible"
            ),
            .devices: CardContract(
                title: "Devices",
                icon: "antenna.radiowaves.left.and.right",
                key: "companion.toolbar.card.devices.visible"
            ),
            .smartCare: CardContract(
                title: "Smart Care",
                icon: "magnifyingglass",
                key: "companion.toolbar.card.smartCare.visible"
            )
        ]

        #expect(CompanionToolbarCard.allCases.count == expected.count)
        for card in CompanionToolbarCard.allCases {
            let contract = try #require(expected[card])
            #expect(card.id == card.rawValue)
            #expect(card.title == contract.title)
            #expect(card.icon == contract.icon)
            #expect(card.visibilityKey == contract.key)
        }
    }

    @Test func cardIdentifiersAndDefaultsKeysAreUnique() {
        let cards = CompanionToolbarCard.allCases
        let rawValues = Set(cards.map(\.rawValue))
        let visibilityKeys = Set(cards.map(\.visibilityKey))

        #expect(rawValues.count == cards.count)
        #expect(visibilityKeys.count == cards.count)
        #expect(!visibilityKeys.contains(MenuBarPreferences.iconVisibleKey))
    }
}
